import Foundation

/// Process-local coordination for one managed dictionary runtime.  This is intentionally keyed
/// by dictionaryID: an operation draining dictionary A never holds dictionary B's leases.
enum ManagedDictionaryLifecycleError: Error, Equatable, Sendable {
    case dictionaryRuntimeUnavailable
    case dictionaryLifecycleDraining
    case dictionaryExclusiveOperationInProgress
    case dictionaryRetired
    case staleDictionaryGeneration
    case queryLeaseCancelled
    case lifecycleOperationCancelled
    case dictionaryLifecycleTransitionPending
    case dictionaryLifecycleShuttingDown
}

enum ManagedDictionaryLifecycleOperation: String, Sendable {
    case install
    case index
    case remove
    case reconcile
    case runtimeInvalidation
}

enum ManagedDictionaryLifecycleDisposition: Sendable {
    /// Resume normal admission.  A new generation is published when requested.
    case available(incrementGeneration: Bool)
    /// Keep the descriptor fail-closed until reconciliation or a later operation resolves it.
    case suspended(incrementGeneration: Bool)
    /// Permanently reject this process's old runtime identity.
    case retired
}

struct ManagedDictionaryRuntimeLease: Equatable, Sendable {
    let dictionaryID: String
    let generation: UInt64
    let leaseID: UUID
}

struct ManagedDictionaryLifecyclePermit: Equatable, Sendable {
    let dictionaryID: String
    let generation: UInt64
    let operation: ManagedDictionaryLifecycleOperation
    fileprivate let operationID: UUID
}

/// Canonical runtime-affecting Catalog identity. Presentation-only fields such as display name and
/// sort position are intentionally excluded, while every field that can change lookup eligibility
/// or the source/index selected by a runtime is included.
struct ManagedDictionaryRuntimeIdentity: Equatable, Sendable {
    let sourceKind: DictionarySourceKind
    let ownership: DictionaryStorageOwnership
    let state: DictionaryState
    let enabled: Bool
    let queryLevel: DictionaryQueryLevel
    let dictionaryPath: String?
    let indexPath: String?
    let indexSchemaVersion: Int?
    let sourceDigest: String?
    let sourceFileSize: UInt64?
    let indexFileSize: UInt64?
    let indexPublicationID: String?
    let indexDigest: String?
    let formatterIdentifier: String

    init(_ descriptor: DictionaryDescriptor) {
        sourceKind = descriptor.sourceKind
        ownership = descriptor.storageOwnership
        state = descriptor.state
        enabled = descriptor.enabled
        queryLevel = descriptor.queryLevel
        dictionaryPath = descriptor.relativePaths.dictionary
        indexPath = descriptor.relativePaths.index
        indexSchemaVersion = descriptor.indexMetadata.schemaVersion
        sourceDigest = descriptor.indexMetadata.sourceSHA256
        sourceFileSize = descriptor.indexMetadata.sourceFileSize
        indexFileSize = descriptor.indexMetadata.indexFileSize
        indexPublicationID = descriptor.publishedIndexIdentity?.indexPublicationID
        indexDigest = descriptor.publishedIndexIdentity?.indexSHA256
        formatterIdentifier = descriptor.formatterIdentifier
    }
}

/// Immutable diagnostic state used only by synthetic tests.  It contains no file paths or
/// descriptor content and is also useful for safe internal observability.
struct ManagedDictionaryLifecycleSnapshot: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable { case available, draining, exclusive, suspended, retired }

    let dictionaryID: String
    let generation: UInt64
    let phase: Phase
    let activeLeaseCount: Int
    let queuedOperationCount: Int
    let runtimeIdentity: ManagedDictionaryRuntimeIdentity?
    /// A queued exclusive operation without a Catalog identity transition may allow an already
    /// running current-generation query to return. Pending identity transitions never do.
    let allowsCurrentGenerationResult: Bool
}

/// Atomically describes one release and the lifecycle state published immediately afterwards.
/// A generation is eligible for precise cache eviction only when its final recorded lease ended.
struct ManagedDictionaryLeaseRelease: Equatable, Sendable {
    let lease: ManagedDictionaryRuntimeLease
    let wasReleased: Bool
    let drainedGeneration: UInt64?
    /// An already-issued query may still publish if it was released while no Catalog identity
    /// transition was pending. A queued exclusive operation alone does not make its result stale.
    let resultMayPublish: Bool
    let postReleaseSnapshot: ManagedDictionaryLifecycleSnapshot?
}

/// The coordinator never performs file work or Catalog persistence.  Callers first acquire an
/// exclusive permit, then do their worker and short Catalog transaction, and finally publish one
/// explicit disposition.  Consequently it never holds a Catalog lock while waiting for leases.
actor ManagedDictionaryLifecycleCoordinator {
    private enum Phase: Equatable {
        case available
        case draining
        case exclusive(UUID, ManagedDictionaryLifecycleOperation)
        case suspended
        case retired

        var snapshot: ManagedDictionaryLifecycleSnapshot.Phase {
            switch self {
            case .available: .available
            case .draining: .draining
            case .exclusive: .exclusive
            case .suspended: .suspended
            case .retired: .retired
            }
        }
    }

    /// A Catalog change that invalidates a runtime is not published over active leases.  It first
    /// drains the old generation, then advances generation exactly once at a safe boundary.
    private struct PendingTransition {
        let identity: ManagedDictionaryRuntimeIdentity?
        let idlePhase: Phase
    }

    private struct LeaseRecord {
        let generation: UInt64
    }

    private struct OperationWaiter {
        let id: UUID
        let operation: ManagedDictionaryLifecycleOperation
        let continuation: CheckedContinuation<ManagedDictionaryLifecyclePermit, Error>
    }

    private struct State {
        var generation: UInt64
        var phase: Phase
        var idlePhase: Phase
        var identity: ManagedDictionaryRuntimeIdentity?
        var activeLeases: [UUID: LeaseRecord]
        var operationQueue: [OperationWaiter]
        var pendingTransition: PendingTransition?

        init(generation: UInt64 = 1,
             phase: Phase = .available,
             identity: ManagedDictionaryRuntimeIdentity? = nil) {
            self.generation = generation
            self.phase = phase
            idlePhase = phase
            self.identity = identity
            activeLeases = [:]
            operationQueue = []
            pendingTransition = nil
        }
    }

    private var states: [String: State] = [:]
    private var acceptingNewWork = true
    /// Covers cancellation racing before a continuation has been enqueued.  The marker is only
    /// retained until enqueue observes it; terminal requests never add a marker.
    private var cancelledOperationRequestIDs: Set<UUID> = []

#if MANAGED_DICTIONARY_LIFECYCLE_TESTING
    private var beforeBatchQueryValidationSnapshotForTesting: (@Sendable () async -> Void)?
    private var beforeFinalLeaseReleaseForTesting: (@Sendable () async -> Void)?
    private var omittedQueryValidationSnapshotIDsForTesting: Set<String> = []

    func setBeforeBatchQueryValidationSnapshotForTesting(_ hook: (@Sendable () async -> Void)?) {
        beforeBatchQueryValidationSnapshotForTesting = hook
    }

    func setBeforeFinalLeaseReleaseForTesting(_ hook: (@Sendable () async -> Void)?) {
        beforeFinalLeaseReleaseForTesting = hook
    }

    func setOmittedQueryValidationSnapshotIDsForTesting(_ dictionaryIDs: Set<String>) {
        omittedQueryValidationSnapshotIDsForTesting = dictionaryIDs
    }
#endif

    init(catalog: DictionaryCatalog = .empty()) {
        for descriptor in catalog.dictionaries {
            let phase = Self.initialPhase(for: descriptor)
            states[descriptor.dictionaryID] = State(phase: phase,
                                                    identity: ManagedDictionaryRuntimeIdentity(descriptor))
        }
    }

    /// Establishes process-local availability only after startup reconciliation has produced a
    /// Catalog.  A retired UUID is intentionally never silently reused in this process.
    func initialize(reconciledCatalog catalog: DictionaryCatalog) {
        let descriptors = Dictionary(uniqueKeysWithValues: catalog.dictionaries.map {
            ($0.dictionaryID, $0)
        })

        for (dictionaryID, descriptor) in descriptors {
            let identity = ManagedDictionaryRuntimeIdentity(descriptor)
            if var existing = states[dictionaryID] {
                switch existing.phase {
                case .retired:
                    // The permit owner publishes the disposition after its durable Catalog
                    // transaction.  A concurrent observer must not invalidate that permit.
                    continue
                case .draining:
                    let idlePhase = Self.initialPhase(for: descriptor)
                    let pendingIdentity = existing.pendingTransition?.identity ?? existing.identity
                    let pendingPhase = existing.pendingTransition?.idlePhase ?? existing.idlePhase
                    if pendingIdentity != identity || pendingPhase != idlePhase {
                        existing.pendingTransition = PendingTransition(identity: identity,
                                                                     idlePhase: idlePhase)
                        existing.idlePhase = idlePhase
                        states[dictionaryID] = existing
                    }
                    continue
                case .exclusive:
                    // The permit already drained prior readers.  Accept the committed identity
                    // without changing generation; complete() publishes the next generation.
                    existing.identity = identity
                    states[dictionaryID] = existing
                    continue
                case .available, .suspended:
                    break
                }
                if existing.identity != identity {
                    scheduleTransition(&existing,
                                       identity: identity,
                                       idlePhase: Self.initialPhase(for: descriptor))
                    states[dictionaryID] = existing
                    advance(dictionaryID: dictionaryID)
                }
            } else {
                let phase = Self.initialPhase(for: descriptor)
                states[dictionaryID] = State(phase: phase, identity: identity)
            }
        }

        for dictionaryID in Set(states.keys).subtracting(descriptors.keys) {
            guard var state = states[dictionaryID] else { continue }
            switch state.phase {
            case .retired, .exclusive:
                continue
            case .draining:
                state.pendingTransition = PendingTransition(identity: nil, idlePhase: .retired)
                state.idlePhase = .retired
                states[dictionaryID] = state
                continue
            case .available, .suspended:
                break
            }
            scheduleTransition(&state, identity: nil, idlePhase: .retired)
            states[dictionaryID] = state
            advance(dictionaryID: dictionaryID)
        }
    }

    func generation(for dictionaryID: String) -> UInt64? { states[dictionaryID]?.generation }

    /// Returns one coherent validation view for the whole result batch. No lease, phase, queue, or
    /// generation is changed while collecting these snapshots.
    func queryValidationSnapshots(
        for dictionaryIDs: [String]
    ) async -> [String: ManagedDictionaryLifecycleSnapshot] {
#if MANAGED_DICTIONARY_LIFECYCLE_TESTING
        if let hook = beforeBatchQueryValidationSnapshotForTesting { await hook() }
        let omitted = omittedQueryValidationSnapshotIDsForTesting
#endif
        var output: [String: ManagedDictionaryLifecycleSnapshot] = [:]
        for dictionaryID in Set(dictionaryIDs) {
#if MANAGED_DICTIONARY_LIFECYCLE_TESTING
            if omitted.contains(dictionaryID) { continue }
#endif
            if let value = snapshot(for: dictionaryID) {
                output[dictionaryID] = value
            }
        }
        return output
    }

    func withQueryLease<T: Sendable>(
        for dictionaryID: String,
        expectedGeneration: UInt64? = nil,
        _ body: @Sendable (ManagedDictionaryRuntimeLease) async throws -> T
    ) async throws -> T {
        if Task.isCancelled { throw ManagedDictionaryLifecycleError.queryLeaseCancelled }
        let lease = try acquireQueryLease(for: dictionaryID, expectedGeneration: expectedGeneration)
        do {
            // Do not release from an onCancel handler: a non-cooperative body may still be
            // touching its runtime after cancellation is observed.  Releasing only when the body
            // returns preserves the drain guarantee; cooperative cancellation still exits here.
            let value = try await body(lease)
            release(lease)
            return value
        } catch is CancellationError {
            release(lease)
            throw ManagedDictionaryLifecycleError.queryLeaseCancelled
        } catch {
            release(lease)
            throw error
        }
    }

    func acquireQueryLease(for dictionaryID: String,
                           expectedGeneration: UInt64? = nil) throws -> ManagedDictionaryRuntimeLease {
        if Task.isCancelled { throw ManagedDictionaryLifecycleError.queryLeaseCancelled }
        guard acceptingNewWork, var state = states[dictionaryID] else {
            throw ManagedDictionaryLifecycleError.dictionaryRuntimeUnavailable
        }
        if let expectedGeneration, expectedGeneration != state.generation {
            throw ManagedDictionaryLifecycleError.staleDictionaryGeneration
        }
        switch state.phase {
        case .available:
            let lease = ManagedDictionaryRuntimeLease(dictionaryID: dictionaryID,
                                                       generation: state.generation,
                                                       leaseID: UUID())
            state.activeLeases[lease.leaseID] = LeaseRecord(generation: lease.generation)
            states[dictionaryID] = state
            return lease
        case .draining:
            throw state.pendingTransition == nil
                ? ManagedDictionaryLifecycleError.dictionaryLifecycleDraining
                : ManagedDictionaryLifecycleError.dictionaryLifecycleTransitionPending
        case .exclusive:
            throw ManagedDictionaryLifecycleError.dictionaryExclusiveOperationInProgress
        case .suspended:
            throw ManagedDictionaryLifecycleError.dictionaryRuntimeUnavailable
        case .retired:
            throw ManagedDictionaryLifecycleError.dictionaryRetired
        }
    }

    /// Idempotent release. A lease is matched by its own recorded generation, never by the
    /// coordinator's current generation, so a pending transition cannot orphan an old lease.
    @discardableResult
    func release(_ lease: ManagedDictionaryRuntimeLease) -> ManagedDictionaryLeaseRelease? {
        let outcome = releaseLease(lease)
        return outcome.wasReleased ? outcome : nil
    }

    /// The final query path uses this single actor operation to release its lease, advance any
    /// pending drain, and obtain the post-release state without inferring safety from a later
    /// current-generation read.
    func releaseForFinalValidation(_ lease: ManagedDictionaryRuntimeLease) async
        -> ManagedDictionaryLeaseRelease {
#if MANAGED_DICTIONARY_LIFECYCLE_TESTING
        if let hook = beforeFinalLeaseReleaseForTesting { await hook() }
#endif
        return releaseLease(lease)
    }

    private func releaseLease(_ lease: ManagedDictionaryRuntimeLease) -> ManagedDictionaryLeaseRelease {
        guard var state = states[lease.dictionaryID],
              let record = state.activeLeases[lease.leaseID],
              record.generation == lease.generation else {
            return ManagedDictionaryLeaseRelease(
                lease: lease,
                wasReleased: false,
                drainedGeneration: nil,
                resultMayPublish: false,
                postReleaseSnapshot: snapshot(for: lease.dictionaryID)
            )
        }
        let resultMayPublish = state.phase == .available ||
            (state.phase == .draining && state.pendingTransition == nil)
        state.activeLeases[lease.leaseID] = nil
        let releasedLastLeaseForGeneration = !state.activeLeases.values.contains {
            $0.generation == lease.generation
        }
        states[lease.dictionaryID] = state
        advance(dictionaryID: lease.dictionaryID)
        return ManagedDictionaryLeaseRelease(
            lease: lease,
            wasReleased: true,
            drainedGeneration: releasedLastLeaseForGeneration ? lease.generation : nil,
            resultMayPublish: resultMayPublish,
            postReleaseSnapshot: snapshot(for: lease.dictionaryID)
        )
    }

    /// Acquire the per-dictionary exclusive permit.  This marks the dictionary draining before
    /// waiting, so later queries cannot starve a queued lifecycle operation.
    func acquireExclusiveOperation(
        for dictionaryID: String,
        operation: ManagedDictionaryLifecycleOperation
    ) async throws -> ManagedDictionaryLifecyclePermit {
        if Task.isCancelled { throw ManagedDictionaryLifecycleError.lifecycleOperationCancelled }
        guard acceptingNewWork else { throw ManagedDictionaryLifecycleError.dictionaryLifecycleShuttingDown }
        let requestID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                enqueueExclusive(dictionaryID: dictionaryID, requestID: requestID,
                                 operation: operation, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancelExclusiveWaiter(dictionaryID: dictionaryID, requestID: requestID) }
        })
    }

    /// Caller must invoke exactly once.  A mismatched or stale permit is ignored fail-closed.
    func complete(_ permit: ManagedDictionaryLifecyclePermit,
                  disposition: ManagedDictionaryLifecycleDisposition) {
        guard var state = states[permit.dictionaryID] else { return }
        guard case .exclusive(let operationID, _) = state.phase,
              operationID == permit.operationID, state.generation == permit.generation else { return }

        switch disposition {
        case .available(let incrementGeneration):
            if incrementGeneration { state.generation &+= 1 }
            state.idlePhase = .available
        case .suspended(let incrementGeneration):
            if incrementGeneration { state.generation &+= 1 }
            state.idlePhase = .suspended
        case .retired:
            state.generation &+= 1
            state.idlePhase = .retired
        }
        // A queued writer keeps admission closed between exclusive operations.  This is per
        // dictionary only and preserves FIFO order without a global operation lock.
        state.phase = state.operationQueue.isEmpty ? state.idlePhase : .draining
        states[permit.dictionaryID] = state
        advance(dictionaryID: permit.dictionaryID)
    }

    /// Stops admission during application termination. Existing leases are allowed to finish.
    func shutdown() {
        acceptingNewWork = false
        for dictionaryID in states.keys {
            guard var state = states[dictionaryID] else { continue }
            let waiters = state.operationQueue
            state.operationQueue.removeAll()
            if case .available = state.phase { state.phase = .suspended }
            if case .draining = state.phase, state.activeLeases.isEmpty { state.phase = .suspended }
            state.idlePhase = .suspended
            states[dictionaryID] = state
            waiters.forEach {
                $0.continuation.resume(throwing: ManagedDictionaryLifecycleError.dictionaryLifecycleShuttingDown)
            }
        }
        cancelledOperationRequestIDs.removeAll()
    }

    func snapshot(for dictionaryID: String) -> ManagedDictionaryLifecycleSnapshot? {
        guard let state = states[dictionaryID] else { return nil }
        return ManagedDictionaryLifecycleSnapshot(dictionaryID: dictionaryID,
                                                   generation: state.generation,
                                                   phase: state.phase.snapshot,
                                                   activeLeaseCount: state.activeLeases.count,
                                                   queuedOperationCount: state.operationQueue.count,
                                                   runtimeIdentity: state.identity,
                                                   allowsCurrentGenerationResult:
                                                       state.phase == .available ||
                                                       (state.phase == .draining &&
                                                        state.pendingTransition == nil))
    }

    private func enqueueExclusive(dictionaryID: String, requestID: UUID,
                                  operation: ManagedDictionaryLifecycleOperation,
                                  continuation: CheckedContinuation<ManagedDictionaryLifecyclePermit, Error>) {
        if cancelledOperationRequestIDs.remove(requestID) != nil {
            continuation.resume(throwing: ManagedDictionaryLifecycleError.lifecycleOperationCancelled)
            return
        }
        guard acceptingNewWork else {
            continuation.resume(throwing: ManagedDictionaryLifecycleError.dictionaryLifecycleShuttingDown)
            return
        }
        var state = states[dictionaryID] ?? State()
        if state.phase == .retired {
            continuation.resume(throwing: ManagedDictionaryLifecycleError.dictionaryRetired)
            return
        }
        state.operationQueue.append(OperationWaiter(id: requestID, operation: operation,
                                                    continuation: continuation))
        if state.phase == .available || state.phase == .suspended {
            state.idlePhase = state.phase
            state.phase = .draining
        }
        states[dictionaryID] = state
        advance(dictionaryID: dictionaryID)
    }

    private func cancelExclusiveWaiter(dictionaryID: String, requestID: UUID) {
        guard var state = states[dictionaryID] else { return }
        guard let index = state.operationQueue.firstIndex(where: { $0.id == requestID }) else {
            if case .exclusive(let activeID, _) = state.phase, activeID == requestID {
                return
            }
            return
        }
        let waiter = state.operationQueue.remove(at: index)
        if state.operationQueue.isEmpty, case .draining = state.phase,
           state.activeLeases.isEmpty {
            state.phase = state.idlePhase
        }
        states[dictionaryID] = state
        waiter.continuation.resume(throwing: ManagedDictionaryLifecycleError.lifecycleOperationCancelled)
        advance(dictionaryID: dictionaryID)
    }

    private func advance(dictionaryID: String) {
        guard var state = states[dictionaryID] else { return }
        guard acceptingNewWork else {
            if state.activeLeases.isEmpty, case .draining = state.phase { state.phase = .suspended }
            states[dictionaryID] = state
            return
        }
        if state.activeLeases.isEmpty, case .draining = state.phase {
            if let transition = state.pendingTransition {
                state.generation &+= 1
                state.identity = transition.identity
                state.idlePhase = transition.idlePhase
                state.pendingTransition = nil
                if transition.idlePhase == .retired {
                    let waiters = state.operationQueue
                    state.operationQueue.removeAll()
                    state.phase = .retired
                    states[dictionaryID] = state
                    waiters.forEach {
                        $0.continuation.resume(throwing: ManagedDictionaryLifecycleError.dictionaryRetired)
                    }
                    return
                }
                state.phase = state.operationQueue.isEmpty ? state.idlePhase : .draining
                states[dictionaryID] = state
                if case .draining = state.phase { advance(dictionaryID: dictionaryID) }
                return
            }
            if state.operationQueue.isEmpty {
                state.phase = state.idlePhase
                states[dictionaryID] = state
                return
            }
            let waiter = state.operationQueue.removeFirst()
            let permit = ManagedDictionaryLifecyclePermit(dictionaryID: dictionaryID,
                                                          generation: state.generation,
                                                          operation: waiter.operation,
                                                          operationID: waiter.id)
            state.phase = .exclusive(waiter.id, waiter.operation)
            states[dictionaryID] = state
            waiter.continuation.resume(returning: permit)
            return
        }
        if state.activeLeases.isEmpty, state.operationQueue.isEmpty,
           state.phase == .draining, state.idlePhase == .retired {
            state.phase = .retired
            states[dictionaryID] = state
        }
    }

    private func scheduleTransition(_ state: inout State,
                                    identity: ManagedDictionaryRuntimeIdentity?,
                                    idlePhase: Phase) {
        state.pendingTransition = PendingTransition(identity: identity, idlePhase: idlePhase)
        if state.activeLeases.isEmpty && state.operationQueue.isEmpty {
            state.generation &+= 1
            state.identity = identity
            state.idlePhase = idlePhase
            state.phase = idlePhase
            state.pendingTransition = nil
        } else if state.phase == .available || state.phase == .suspended {
            state.idlePhase = idlePhase
            state.phase = .draining
        }
    }

    private static func initialPhase(for descriptor: DictionaryDescriptor) -> Phase {
        guard descriptor.enabled, descriptor.state == .ready else { return .suspended }
        return .available
    }
}
