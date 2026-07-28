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

/// Immutable diagnostic state used only by synthetic tests.  It contains no file paths or
/// descriptor content and is also useful for safe internal observability.
struct ManagedDictionaryLifecycleSnapshot: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable { case available, draining, exclusive, suspended, retired }

    let dictionaryID: String
    let generation: UInt64
    let phase: Phase
    let activeLeaseCount: Int
    let queuedOperationCount: Int
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

    private struct DescriptorIdentity: Equatable {
        let sourceKind: DictionarySourceKind
        let ownership: DictionaryStorageOwnership
        let state: DictionaryState
        let enabled: Bool
        let dictionaryPath: String?
        let indexPath: String?
        let sourceDigest: String?
        let updatedAt: Date

        init(_ descriptor: DictionaryDescriptor) {
            sourceKind = descriptor.sourceKind
            ownership = descriptor.storageOwnership
            state = descriptor.state
            enabled = descriptor.enabled
            dictionaryPath = descriptor.relativePaths.dictionary
            indexPath = descriptor.relativePaths.index
            sourceDigest = descriptor.indexMetadata.sourceSHA256
            updatedAt = descriptor.updatedAt
        }
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
        var identity: DescriptorIdentity?
        var activeLeases: Set<UUID>
        var operationQueue: [OperationWaiter]

        init(generation: UInt64 = 1,
             phase: Phase = .available,
             identity: DescriptorIdentity? = nil) {
            self.generation = generation
            self.phase = phase
            idlePhase = phase
            self.identity = identity
            activeLeases = []
            operationQueue = []
        }
    }

    private var states: [String: State] = [:]
    private var acceptingNewWork = true
    /// Covers cancellation racing before a continuation has been enqueued.  IDs are one-shot and
    /// removed by enqueue, so repeated cancellation cannot grow this set without bound.
    private var cancelledOperationRequestIDs: Set<UUID> = []

    init(catalog: DictionaryCatalog = .empty()) {
        for descriptor in catalog.dictionaries {
            let phase = Self.initialPhase(for: descriptor)
            states[descriptor.dictionaryID] = State(phase: phase,
                                                    identity: DescriptorIdentity(descriptor))
        }
    }

    /// Establishes process-local availability only after startup reconciliation has produced a
    /// Catalog.  A retired UUID is intentionally never silently reused in this process.
    func initialize(reconciledCatalog catalog: DictionaryCatalog) {
        let descriptors = Dictionary(uniqueKeysWithValues: catalog.dictionaries.map {
            ($0.dictionaryID, $0)
        })

        for (dictionaryID, descriptor) in descriptors {
            let identity = DescriptorIdentity(descriptor)
            if var existing = states[dictionaryID] {
                switch existing.phase {
                case .retired, .draining, .exclusive:
                    // The permit owner publishes the disposition after its durable Catalog
                    // transaction.  A concurrent observer must not invalidate that permit.
                    continue
                case .available, .suspended:
                    break
                }
                if existing.identity != identity {
                    existing.generation &+= 1
                    existing.identity = identity
                    if existing.activeLeases.isEmpty && existing.operationQueue.isEmpty {
                        let phase = Self.initialPhase(for: descriptor)
                        existing.phase = phase
                        existing.idlePhase = phase
                    }
                    states[dictionaryID] = existing
                }
            } else {
                let phase = Self.initialPhase(for: descriptor)
                states[dictionaryID] = State(phase: phase, identity: identity)
            }
        }

        for dictionaryID in Set(states.keys).subtracting(descriptors.keys) {
            guard var state = states[dictionaryID] else { continue }
            switch state.phase {
            case .retired, .draining, .exclusive:
                continue
            case .available, .suspended:
                break
            }
            state.generation &+= 1
            if state.activeLeases.isEmpty {
                state.phase = .retired
                state.idlePhase = .retired
            } else {
                state.phase = .draining
                state.idlePhase = .retired
            }
            states[dictionaryID] = state
        }
    }

    func generation(for dictionaryID: String) -> UInt64? { states[dictionaryID]?.generation }

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
            state.activeLeases.insert(lease.leaseID)
            states[dictionaryID] = state
            return lease
        case .draining:
            throw ManagedDictionaryLifecycleError.dictionaryLifecycleDraining
        case .exclusive:
            throw ManagedDictionaryLifecycleError.dictionaryExclusiveOperationInProgress
        case .suspended:
            throw ManagedDictionaryLifecycleError.dictionaryRuntimeUnavailable
        case .retired:
            throw ManagedDictionaryLifecycleError.dictionaryRetired
        }
    }

    /// Idempotent release.  A stale or already released lease cannot affect a newer generation.
    func release(_ lease: ManagedDictionaryRuntimeLease) {
        guard var state = states[lease.dictionaryID], state.generation == lease.generation,
              state.activeLeases.remove(lease.leaseID) != nil else { return }
        states[lease.dictionaryID] = state
        advance(dictionaryID: lease.dictionaryID)
    }

    /// Acquire the per-dictionary exclusive permit.  This marks the dictionary draining before
    /// waiting, so later queries cannot starve a queued lifecycle operation.
    func acquireExclusiveOperation(
        for dictionaryID: String,
        operation: ManagedDictionaryLifecycleOperation
    ) async throws -> ManagedDictionaryLifecyclePermit {
        if Task.isCancelled { throw ManagedDictionaryLifecycleError.lifecycleOperationCancelled }
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
            if case .available = state.phase { state.phase = .suspended }
            state.idlePhase = .suspended
            states[dictionaryID] = state
        }
    }

    func snapshot(for dictionaryID: String) -> ManagedDictionaryLifecycleSnapshot? {
        guard let state = states[dictionaryID] else { return nil }
        return ManagedDictionaryLifecycleSnapshot(dictionaryID: dictionaryID,
                                                   generation: state.generation,
                                                   phase: state.phase.snapshot,
                                                   activeLeaseCount: state.activeLeases.count,
                                                   queuedOperationCount: state.operationQueue.count)
    }

    private func enqueueExclusive(dictionaryID: String, requestID: UUID,
                                  operation: ManagedDictionaryLifecycleOperation,
                                  continuation: CheckedContinuation<ManagedDictionaryLifecyclePermit, Error>) {
        if cancelledOperationRequestIDs.remove(requestID) != nil {
            continuation.resume(throwing: ManagedDictionaryLifecycleError.lifecycleOperationCancelled)
            return
        }
        guard acceptingNewWork else {
            continuation.resume(throwing: ManagedDictionaryLifecycleError.dictionaryRuntimeUnavailable)
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
        guard var state = states[dictionaryID] else {
            cancelledOperationRequestIDs.insert(requestID)
            return
        }
        guard let index = state.operationQueue.firstIndex(where: { $0.id == requestID }) else {
            if case .exclusive(let activeID, _) = state.phase, activeID == requestID {
                return
            }
            cancelledOperationRequestIDs.insert(requestID)
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
        if state.activeLeases.isEmpty, case .draining = state.phase {
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

    private static func initialPhase(for descriptor: DictionaryDescriptor) -> Phase {
        switch descriptor.state {
        case .missingResources, .corrupt, .failed, .invalid, .unavailable, .importFailed:
            return .suspended
        default:
            return .available
        }
    }
}
