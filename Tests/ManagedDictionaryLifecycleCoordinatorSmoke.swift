import Foundation

private enum SmokeFailure: Error { case failed(String) }

private struct Smoke {
    var assertions = 0
    var actorState = 0
    var runtime = 0
    var catalog = 0
    var barriers = 0
    var cancellation = 0
    var ordering = 0
    var runtimeEviction = 0
    var releaseBarrier = 0
    var generationDrain = 0
    var batchFinalization = 0
    var identityBinding = 0
    var snapshotFailClosed = 0

    mutating func check(_ message: String, category: WritableKeyPath<Smoke, Int>,
                        _ condition: @autoclosure () -> Bool) throws {
        assertions += 1
        self[keyPath: category] += 1
        guard condition() else { throw SmokeFailure.failed(message) }
    }
}

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func waitForQueuedOperations(_ expected: Int,
                                     coordinator: ManagedDictionaryLifecycleCoordinator,
                                     dictionaryID: String) async -> Bool {
    for _ in 0..<1_000 {
        if await coordinator.snapshot(for: dictionaryID)?.queuedOperationCount == expected {
            return true
        }
        await Task.yield()
    }
    return false
}

private actor Runtime: ManagedDictionaryQueryRuntime {
    private var outcomes: [String: ManagedDictionaryRuntimeOutcome]
    private var queried: [String] = []
    private var removed: [String] = []

    init(outcomes: [String: ManagedDictionaryRuntimeOutcome]) { self.outcomes = outcomes }

    func lookup(descriptor: DictionaryDescriptor, generation: UInt64,
                query: String) async -> ManagedDictionaryRuntimeOutcome {
        queried.append(descriptor.dictionaryID)
        return outcomes[descriptor.dictionaryID] ?? .miss
    }

    func remove(dictionaryID: String) { removed.append(dictionaryID) }
    func remove(dictionaryID: String, generation: UInt64) { removed.append(dictionaryID) }
    func reset() {}
    func snapshot() -> (queried: [String], removed: [String]) { (queried, removed) }
}

private actor BlockingRuntime: ManagedDictionaryQueryRuntime {
    let entered = Gate()
    let continueLookup = Gate()
    private var resetCount = 0
    private var removeCount = 0
    private var lookupCount = 0

    func lookup(descriptor: DictionaryDescriptor, generation: UInt64,
                query: String) async -> ManagedDictionaryRuntimeOutcome {
        lookupCount += 1
        await entered.open()
        await continueLookup.wait()
        return .hit(hit(descriptor.dictionaryID))
    }

    func remove(dictionaryID: String) { removeCount += 1 }
    func remove(dictionaryID: String, generation: UInt64) { removeCount += 1 }
    func reset() { resetCount += 1 }

    func snapshot() -> (resetCount: Int, removeCount: Int, lookupCount: Int) {
        (resetCount, removeCount, lookupCount)
    }
}

/// Deterministic multi-dictionary runtime used to pause after an earlier candidate has been
/// collected but before the complete batch reaches its final lifecycle snapshot.
private actor BatchRuntime: ManagedDictionaryQueryRuntime {
    let blockedLookupEntered = Gate()
    let continueBlockedLookup = Gate()
    private let blockedDictionaryID: String?
    private var outcomes: [String: ManagedDictionaryRuntimeOutcome]
    private var queried: [String] = []
    private var scopedRemovals: [(dictionaryID: String, generation: UInt64)] = []
    private var broadRemovals: [String] = []

    init(blockedDictionaryID: String? = nil,
         outcomes: [String: ManagedDictionaryRuntimeOutcome]) {
        self.blockedDictionaryID = blockedDictionaryID
        self.outcomes = outcomes
    }

    func lookup(descriptor: DictionaryDescriptor,
                generation: UInt64,
                query: String) async -> ManagedDictionaryRuntimeOutcome {
        queried.append(descriptor.dictionaryID)
        if descriptor.dictionaryID == blockedDictionaryID {
            await blockedLookupEntered.open()
            await continueBlockedLookup.wait()
        }
        if Task.isCancelled { return .miss }
        return outcomes[descriptor.dictionaryID] ?? .miss
    }

    func remove(dictionaryID: String) {
        broadRemovals.append(dictionaryID)
    }

    func remove(dictionaryID: String, generation: UInt64) {
        scopedRemovals.append((dictionaryID, generation))
    }

    func reset() {}

    func snapshot() -> (queried: [String],
                        scopedRemovals: [(dictionaryID: String, generation: UInt64)],
                        broadRemovals: [String]) {
        (queried, scopedRemovals, broadRemovals)
    }
}

private actor GenerationRuntime: ManagedDictionaryQueryRuntime {
    let firstEntered = Gate()
    let secondEntered = Gate()
    let releaseFirst = Gate()
    let releaseSecond = Gate()
    let scopedRemovalEntered = Gate()
    let releaseScopedRemoval = Gate()
    private var oldLookupCount = 0
    private var cachedGenerations: Set<UInt64> = []
    private var scopedRemovals: [UInt64] = []
    private var broadRemovalCount = 0

    func lookup(descriptor: DictionaryDescriptor, generation: UInt64,
                query: String) async -> ManagedDictionaryRuntimeOutcome {
        cachedGenerations.insert(generation)
        if generation == 1 {
            oldLookupCount += 1
            if oldLookupCount == 1 {
                await firstEntered.open()
                await releaseFirst.wait()
            } else {
                await secondEntered.open()
                await releaseSecond.wait()
            }
        }
        return .hit(hit(descriptor.dictionaryID))
    }

    func remove(dictionaryID: String) { broadRemovalCount += 1 }

    func remove(dictionaryID: String, generation: UInt64) async {
        scopedRemovals.append(generation)
        await scopedRemovalEntered.open()
        await releaseScopedRemoval.wait()
        cachedGenerations.remove(generation)
    }

    func removeAll(dictionaryID: String) { broadRemovalCount += 1 }
    func reset() {}

    func snapshot() -> (cached: Set<UInt64>, scoped: [UInt64], broad: Int) {
        (cachedGenerations, scopedRemovals, broadRemovalCount)
    }
}

private func descriptor(_ id: String, sourceKind: DictionarySourceKind = .managedLocal,
                        ownership: DictionaryStorageOwnership = .appManagedImported,
                        level: DictionaryQueryLevel = .normal, position: Int64 = 0,
                        enabled: Bool = true, state: DictionaryState = .ready) -> DictionaryDescriptor {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let metadata = sourceKind == .openResource ? OpenResourceInstallationMetadata(
        resourceID: "synthetic-resource-\(id)", resourceRevision: 1,
        resourceVersion: "1", manifestVersion: 1,
        manifestSHA256: String(repeating: "a", count: 64), verifiedKeyID: "synthetic-key",
        payloadSHA256: String(repeating: "b", count: 64), payloadBytes: 1,
        sidecarRelativePath: "Dictionaries/\(id)/resource-installation.json",
        languages: ["en"], license: OpenResourceLicenseMetadata(name: "Synthetic", version: "1", url: "https://example.invalid", attribution: "Synthetic"),
        sourceProject: "Synthetic", officialPageReference: "https://example.invalid",
        expectedEntryCount: OpenResourceEntryCountMetadata(minimum: 0, maximum: 1),
        installedAt: now
    ) : nil
    return DictionaryDescriptor(
        dictionaryID: id, displayName: "Synthetic \(id)", sourceKind: sourceKind,
        queryLevel: level, sortPosition: position, enabled: enabled, state: state,
        indexMetadata: DictionaryIndexMetadata(schemaVersion: 1, entryCount: 1,
                                               indexFileSize: 1, sourceFileSize: 1,
                                               sourceModifiedAt: now,
                                               sourceSHA256: String(repeating: "c", count: 64),
                                               indexedAt: now),
        formatterIdentifier: DictionaryFormatterIdentifier.genericMDictV1,
        capabilities: .unknown,
        relativePaths: DictionaryRelativePaths(
            dictionary: "Dictionaries/\(id)/\(sourceKind == .openResource ? "payload.mdx" : "source/test.mdx")",
            resources: [], index: "Dictionaries/\(id)/index/dictionary.sqlite"
        ), createdAt: now, updatedAt: now, storageOwnership: ownership,
        openResourceMetadata: metadata
    )
}

private func catalog(_ descriptors: [DictionaryDescriptor]) -> DictionaryCatalog {
    var value = DictionaryCatalog.empty(now: Date(timeIntervalSince1970: 1_700_000_000))
    value.dictionaries = descriptors
    return value
}

private func hit(_ id: String) -> ManagedDictionaryQueryHit {
    ManagedDictionaryQueryHit(dictionaryID: id, displayName: "Synthetic \(id)",
                              matchedHeadword: "safe", blocks: [], plainText: "safe",
                              truncated: false)
}

private func replacingRuntimeIdentity(_ value: DictionaryDescriptor) -> DictionaryDescriptor {
    var replacement = value
    replacement.relativePaths.dictionary =
        "Dictionaries/\(value.dictionaryID)/source/replacement.mdx"
    replacement.indexMetadata.sourceSHA256 = String(repeating: "d", count: 64)
    replacement.indexMetadata.sourceFileSize = 2
    replacement.indexMetadata.indexFileSize = 2
    replacement.updatedAt = value.updatedAt.addingTimeInterval(1)
    return replacement
}

private func expectError(_ expected: ManagedDictionaryLifecycleError,
                         _ operation: () async throws -> Void) async throws {
    do {
        try await operation()
        throw SmokeFailure.failed("expected lifecycle error \(expected)")
    } catch let error as ManagedDictionaryLifecycleError {
        guard error == expected else { throw SmokeFailure.failed("unexpected lifecycle error") }
    }
}

private func testLeaseAndDrain(smoke: inout Smoke) async throws {
    let first = descriptor("00000000-0000-0000-0000-000000000101")
    let second = descriptor("00000000-0000-0000-0000-000000000102")
    let coordinator = ManagedDictionaryLifecycleCoordinator(catalog: catalog([first, second]))
    let firstGeneration = try (await coordinator.generation(for: first.dictionaryID))
        .unwrap("first generation")
    let leaseA = try await coordinator.acquireQueryLease(for: first.dictionaryID,
                                                         expectedGeneration: firstGeneration)
    let leaseB = try await coordinator.acquireQueryLease(for: first.dictionaryID,
                                                         expectedGeneration: firstGeneration)
    try smoke.check("lease IDs are unique", category: \.actorState, leaseA.leaseID != leaseB.leaseID)
    let twoLeases = await coordinator.snapshot(for: first.dictionaryID)
    try smoke.check("two same-dictionary leases are active", category: \.actorState,
                    twoLeases?.activeLeaseCount == 2)
    let drain = Task { try await coordinator.acquireExclusiveOperation(for: first.dictionaryID,
                                                                         operation: .remove) }
    while await coordinator.snapshot(for: first.dictionaryID)?.phase != .draining { await Task.yield() }
    try await expectError(.dictionaryLifecycleDraining) {
        _ = try await coordinator.acquireQueryLease(for: first.dictionaryID)
    }
    try smoke.check("drain rejects new same-dictionary leases", category: \.barriers, true)
    let secondHeldLease = try await coordinator.acquireQueryLease(for: second.dictionaryID)
    let secondSnapshot = await coordinator.snapshot(for: second.dictionaryID)
    try smoke.check("other dictionary remains available while first drains", category: \.barriers,
                    secondSnapshot?.activeLeaseCount == 1)
    await coordinator.release(secondHeldLease)
    await coordinator.release(leaseA)
    await coordinator.release(leaseA)
    let oneLease = await coordinator.snapshot(for: first.dictionaryID)
    try smoke.check("idempotent release leaves one active lease", category: \.actorState,
                    oneLease?.activeLeaseCount == 1)
    await coordinator.release(leaseB)
    let permit = try await drain.value
    let exclusive = await coordinator.snapshot(for: first.dictionaryID)
    try smoke.check("drain becomes exclusive only after active leases finish", category: \.barriers,
                    exclusive?.phase == .exclusive)
    await coordinator.complete(permit, disposition: .available(incrementGeneration: true))
    let nextGeneration = await coordinator.generation(for: first.dictionaryID)
    try smoke.check("publication increments generation", category: \.actorState,
                    nextGeneration == firstGeneration + 1)
    try await expectError(.staleDictionaryGeneration) {
        _ = try await coordinator.acquireQueryLease(for: first.dictionaryID,
                                                    expectedGeneration: firstGeneration)
    }
    let remove = try await coordinator.acquireExclusiveOperation(for: first.dictionaryID,
                                                                   operation: .remove)
    await coordinator.complete(remove, disposition: .retired)
    try await expectError(.dictionaryRetired) {
        _ = try await coordinator.acquireQueryLease(for: first.dictionaryID)
    }
}

private func testFinalReleaseOutcome(smoke: inout Smoke) async throws {
    let item = descriptor("00000000-0000-0000-0000-000000000114")
    let coordinator = ManagedDictionaryLifecycleCoordinator(catalog: catalog([item]))
    let generation = try (await coordinator.generation(for: item.dictionaryID))
        .unwrap("release outcome generation")
    let first = try await coordinator.acquireQueryLease(for: item.dictionaryID)
    let second = try await coordinator.acquireQueryLease(for: item.dictionaryID)
    let batchSnapshots = await coordinator.queryValidationSnapshots(
        for: [item.dictionaryID, item.dictionaryID]
    )
    try smoke.check("batch snapshot de-duplicates IDs without changing lease state",
                    category: \.batchFinalization,
                    batchSnapshots.count == 1 &&
                        batchSnapshots[item.dictionaryID]?.activeLeaseCount == 2 &&
                        batchSnapshots[item.dictionaryID]?.runtimeIdentity ==
                            ManagedDictionaryRuntimeIdentity(item))
    let firstOutcome = await coordinator.releaseForFinalValidation(first)
    try smoke.check("non-final release is reported atomically", category: \.generationDrain,
                    firstOutcome.wasReleased && firstOutcome.drainedGeneration == nil &&
                        firstOutcome.postReleaseSnapshot?.activeLeaseCount == 1)
    let repeatedOutcome = await coordinator.releaseForFinalValidation(first)
    try smoke.check("repeated final release is idempotent", category: \.generationDrain,
                    !repeatedOutcome.wasReleased && repeatedOutcome.drainedGeneration == nil)
    let foreignLease = ManagedDictionaryRuntimeLease(dictionaryID: item.dictionaryID,
                                                     generation: generation,
                                                     leaseID: UUID())
    let foreignOutcome = await coordinator.releaseForFinalValidation(foreignLease)
    try smoke.check("unknown lease cannot drain another query", category: \.generationDrain,
                    !foreignOutcome.wasReleased &&
                        foreignOutcome.postReleaseSnapshot?.activeLeaseCount == 1)
    let finalOutcome = await coordinator.releaseForFinalValidation(second)
    try smoke.check("last lease reports only its drained generation", category: \.generationDrain,
                    finalOutcome.wasReleased && finalOutcome.drainedGeneration == generation &&
                        finalOutcome.postReleaseSnapshot?.generation == generation)

    let pendingLease = try await coordinator.acquireQueryLease(for: item.dictionaryID)
    var replacement = item
    replacement.indexMetadata.indexFileSize = 2
    replacement.updatedAt = item.updatedAt.addingTimeInterval(1)
    await coordinator.initialize(reconciledCatalog: catalog([replacement]))
    let transitionedOutcome = await coordinator.releaseForFinalValidation(pendingLease)
    try smoke.check("final release advances the pending transition before reporting", category: \.generationDrain,
                    transitionedOutcome.drainedGeneration == generation &&
                        transitionedOutcome.postReleaseSnapshot?.generation == generation + 1 &&
                        transitionedOutcome.postReleaseSnapshot?.phase == .available)
}

private func testStructuredThrowAndCancellation(smoke: inout Smoke) async throws {
    let item = descriptor("00000000-0000-0000-0000-000000000103")
    let coordinator = ManagedDictionaryLifecycleCoordinator(catalog: catalog([item]))
    do {
        _ = try await coordinator.withQueryLease(for: item.dictionaryID) { _ in
            throw SmokeFailure.failed("synthetic query failure")
        } as Int
    } catch {}
    let afterThrow = await coordinator.snapshot(for: item.dictionaryID)
    try smoke.check("throwing query closure releases its lease", category: \.cancellation,
                    afterThrow?.activeLeaseCount == 0)
    let cancelled = Task {
        _ = try await coordinator.withQueryLease(for: item.dictionaryID) { _ in
            while !Task.isCancelled { await Task.yield() }
            try Task.checkCancellation()
            return 0
        } as Int
    }
    while await coordinator.snapshot(for: item.dictionaryID)?.activeLeaseCount != 1 {
        await Task.yield()
    }
    cancelled.cancel()
    _ = await cancelled.result
    let afterCancellation = await coordinator.snapshot(for: item.dictionaryID)
    try smoke.check("cancelled closure releases its lease", category: \.cancellation,
                    afterCancellation?.activeLeaseCount == 0)

    let held = try await coordinator.acquireQueryLease(for: item.dictionaryID)
    let waitingOperation = Task {
        try await coordinator.acquireExclusiveOperation(for: item.dictionaryID, operation: .index)
    }
    while await coordinator.snapshot(for: item.dictionaryID)?.phase != .draining {
        await Task.yield()
    }
    waitingOperation.cancel()
    let operationResult = await waitingOperation.result
    if case .failure(let error as ManagedDictionaryLifecycleError) = operationResult {
        try smoke.check("cancelled drain waiter returns fixed error", category: \.cancellation,
                        error == .lifecycleOperationCancelled)
    } else {
        throw SmokeFailure.failed("exclusive cancellation must not acquire a permit")
    }
    await coordinator.release(held)
    let resumed = await coordinator.snapshot(for: item.dictionaryID)
    try smoke.check("cancelled drain waiter restores admission", category: \.cancellation,
                    resumed?.phase == .available && resumed?.activeLeaseCount == 0)
}

private func testIdentityTransitions(smoke: inout Smoke) async throws {
    let item = descriptor("00000000-0000-0000-0000-000000000104")
    let coordinator = ManagedDictionaryLifecycleCoordinator(catalog: catalog([item]))
    let generation = try (await coordinator.generation(for: item.dictionaryID)).unwrap("generation")
    let oldLease = try await coordinator.acquireQueryLease(for: item.dictionaryID,
                                                            expectedGeneration: generation)
    var changed = item
    changed.indexMetadata.indexFileSize = 2
    changed.updatedAt = item.updatedAt.addingTimeInterval(1)
    await coordinator.initialize(reconciledCatalog: catalog([changed]))
    let pending = await coordinator.snapshot(for: item.dictionaryID)
    try smoke.check("identity transition drains an active old generation", category: \.barriers,
                    pending?.phase == .draining && pending?.generation == generation &&
                        pending?.activeLeaseCount == 1)
    try await expectError(.dictionaryLifecycleTransitionPending) {
        _ = try await coordinator.acquireQueryLease(for: item.dictionaryID)
    }
    let waiter = Task {
        try await coordinator.acquireExclusiveOperation(for: item.dictionaryID, operation: .index)
    }
    let transitionWaiterQueued = await waitForQueuedOperations(1, coordinator: coordinator,
                                                                dictionaryID: item.dictionaryID)
    try smoke.check("identity transition queues its exclusive waiter", category: \.barriers,
                    transitionWaiterQueued)
    await coordinator.release(oldLease)
    let permit = try await waiter.value
    let afterOldRelease = await coordinator.snapshot(for: item.dictionaryID)
    try smoke.check("old lease releases after generation transition", category: \.actorState,
                    permit.generation == generation + 1 &&
                        afterOldRelease?.activeLeaseCount == 0)
    await coordinator.complete(permit, disposition: .available(incrementGeneration: false))
    let newLease = try await coordinator.acquireQueryLease(for: item.dictionaryID,
                                                            expectedGeneration: generation + 1)
    await coordinator.release(newLease)
    try smoke.check("new generation accepts a new lease", category: \.actorState, true)

    let deletionLease = try await coordinator.acquireQueryLease(for: item.dictionaryID)
    await coordinator.initialize(reconciledCatalog: catalog([]))
    let deletionPending = await coordinator.snapshot(for: item.dictionaryID)
    try smoke.check("descriptor deletion drains an active lease", category: \.barriers,
                    deletionPending?.phase == .draining)
    await coordinator.release(deletionLease)
    try await expectError(.dictionaryRetired) {
        _ = try await coordinator.acquireQueryLease(for: item.dictionaryID)
    }
    let afterDeletion = await coordinator.snapshot(for: item.dictionaryID)
    try smoke.check("descriptor deletion retires after old lease release", category: \.actorState,
                    afterDeletion?.activeLeaseCount == 0)
}

private func testLatestWinsPendingTransitions(smoke: inout Smoke) async throws {
    let item = descriptor("00000000-0000-0000-0000-000000000108")
    let coordinator = ManagedDictionaryLifecycleCoordinator(catalog: catalog([item]))
    let generation = try (await coordinator.generation(for: item.dictionaryID)).unwrap("generation")
    let lease = try await coordinator.acquireQueryLease(for: item.dictionaryID)
    var identityB = item
    identityB.indexMetadata.indexFileSize = 2
    identityB.updatedAt = item.updatedAt.addingTimeInterval(1)
    var identityC = item
    identityC.indexMetadata.indexFileSize = 3
    identityC.updatedAt = item.updatedAt.addingTimeInterval(2)
    await coordinator.initialize(reconciledCatalog: catalog([identityB]))
    await coordinator.initialize(reconciledCatalog: catalog([identityC]))
    let beforeRelease = await coordinator.snapshot(for: item.dictionaryID)
    try smoke.check("A to B to C remains draining until old lease releases", category: \.barriers,
                    beforeRelease?.generation == generation)
    await coordinator.release(lease)
    let afterLatestRelease = await coordinator.generation(for: item.dictionaryID)
    try smoke.check("latest pending identity publishes exactly one generation", category: \.actorState,
                    afterLatestRelease == generation + 1)
    await coordinator.initialize(reconciledCatalog: catalog([identityC]))
    let afterRepeatedC = await coordinator.generation(for: item.dictionaryID)
    try smoke.check("published C does not trigger a second transition", category: \.actorState,
                    afterRepeatedC == generation + 1)

    let deleted = descriptor("00000000-0000-0000-0000-000000000109")
    let deletionCoordinator = ManagedDictionaryLifecycleCoordinator(catalog: catalog([deleted]))
    let deletionLease = try await deletionCoordinator.acquireQueryLease(for: deleted.dictionaryID)
    var deletionB = deleted
    deletionB.indexMetadata.indexFileSize = 2
    await deletionCoordinator.initialize(reconciledCatalog: catalog([deletionB]))
    await deletionCoordinator.initialize(reconciledCatalog: catalog([]))
    await deletionCoordinator.release(deletionLease)
    try await expectError(.dictionaryRetired) {
        _ = try await deletionCoordinator.acquireQueryLease(for: deleted.dictionaryID)
    }
    let deletionSnapshot = await deletionCoordinator.snapshot(for: deleted.dictionaryID)
    try smoke.check("deletion supersedes an older pending identity", category: \.ordering,
                    deletionSnapshot?.phase == .retired)

    let disabled = descriptor("00000000-0000-0000-0000-000000000110")
    let disabledCoordinator = ManagedDictionaryLifecycleCoordinator(catalog: catalog([disabled]))
    let disabledLease = try await disabledCoordinator.acquireQueryLease(for: disabled.dictionaryID)
    var disabledB = disabled
    disabledB.indexMetadata.indexFileSize = 2
    var disabledC = disabled
    disabledC.enabled = false
    disabledC.updatedAt = disabled.updatedAt.addingTimeInterval(2)
    await disabledCoordinator.initialize(reconciledCatalog: catalog([disabledB]))
    await disabledCoordinator.initialize(reconciledCatalog: catalog([disabledC]))
    await disabledCoordinator.release(disabledLease)
    try await expectError(.dictionaryRuntimeUnavailable) {
        _ = try await disabledCoordinator.acquireQueryLease(for: disabled.dictionaryID)
    }
    let disabledSnapshot = await disabledCoordinator.snapshot(for: disabled.dictionaryID)
    try smoke.check("disabled descriptor supersedes pending identity with suspension", category: \.ordering,
                    disabledSnapshot?.phase == .suspended)
}

private func testFIFOAndShutdown(smoke: inout Smoke) async throws {
    let item = descriptor("00000000-0000-0000-0000-000000000105")
    let coordinator = ManagedDictionaryLifecycleCoordinator(catalog: catalog([item]))
    let first = try await coordinator.acquireExclusiveOperation(for: item.dictionaryID, operation: .index)
    let second = Task { try await coordinator.acquireExclusiveOperation(for: item.dictionaryID, operation: .remove) }
    let firstWaiterQueued = await waitForQueuedOperations(1, coordinator: coordinator,
                                                           dictionaryID: item.dictionaryID)
    try smoke.check("first FIFO waiter queues", category: \.barriers,
                    firstWaiterQueued)
    let third = Task { try await coordinator.acquireExclusiveOperation(for: item.dictionaryID, operation: .reconcile) }
    let secondWaiterQueued = await waitForQueuedOperations(2, coordinator: coordinator,
                                                            dictionaryID: item.dictionaryID)
    try smoke.check("second FIFO waiter queues", category: \.barriers,
                    secondWaiterQueued)
    await coordinator.complete(first, disposition: .available(incrementGeneration: false))
    let secondPermit = try await second.value
    try smoke.check("exclusive waiters are FIFO", category: \.barriers,
                    secondPermit.operation == .remove)
    await coordinator.complete(secondPermit, disposition: .available(incrementGeneration: false))
    let thirdPermit = try await third.value
    try smoke.check("FIFO advances the next exclusive waiter", category: \.barriers,
                    thirdPermit.operation == .reconcile)
    await coordinator.complete(thirdPermit, disposition: .available(incrementGeneration: false))

    let cancellationCoordinator = ManagedDictionaryLifecycleCoordinator(catalog: catalog([item]))
    let heldPermit = try await cancellationCoordinator.acquireExclusiveOperation(
        for: item.dictionaryID, operation: .index
    )
    let cancelledHead = Task {
        try await cancellationCoordinator.acquireExclusiveOperation(for: item.dictionaryID, operation: .remove)
    }
    _ = await waitForQueuedOperations(1, coordinator: cancellationCoordinator,
                                      dictionaryID: item.dictionaryID)
    let survivingWaiter = Task {
        try await cancellationCoordinator.acquireExclusiveOperation(for: item.dictionaryID, operation: .reconcile)
    }
    let cancellationQueueReady = await waitForQueuedOperations(2, coordinator: cancellationCoordinator,
                                                                dictionaryID: item.dictionaryID)
    try smoke.check("cancel queue-head fixture has B then C queued", category: \.cancellation,
                    cancellationQueueReady)
    cancelledHead.cancel()
    let cancelledHeadResult = await cancelledHead.result
    if case .failure(let error as ManagedDictionaryLifecycleError) = cancelledHeadResult {
        try smoke.check("cancelled queue head returns fixed cancellation error", category: \.cancellation,
                        error == .lifecycleOperationCancelled)
    } else {
        throw SmokeFailure.failed("cancelled queue head unexpectedly acquired a permit")
    }
    await cancellationCoordinator.complete(heldPermit, disposition: .available(incrementGeneration: false))
    let survivingPermit = try await survivingWaiter.value
    try smoke.check("cancelling B advances FIFO writer C", category: \.cancellation,
                    survivingPermit.operation == .reconcile)
    await cancellationCoordinator.complete(survivingPermit, disposition: .available(incrementGeneration: false))

    let lateCancellationCoordinator = ManagedDictionaryLifecycleCoordinator(catalog: catalog([item]))
    let completed = Task {
        try await lateCancellationCoordinator.acquireExclusiveOperation(for: item.dictionaryID, operation: .index)
    }
    let completedPermit = try await completed.value
    await lateCancellationCoordinator.complete(completedPermit, disposition: .available(incrementGeneration: false))
    completed.cancel()
    let followupPermit = try await lateCancellationCoordinator.acquireExclusiveOperation(
        for: item.dictionaryID, operation: .remove
    )
    try smoke.check("late cancellation does not poison the next exclusive operation", category: \.cancellation,
                    followupPermit.operation == .remove)
    await lateCancellationCoordinator.complete(followupPermit, disposition: .available(incrementGeneration: false))

    let held = try await coordinator.acquireQueryLease(for: item.dictionaryID)
    let queued = Task { try await coordinator.acquireExclusiveOperation(for: item.dictionaryID, operation: .remove) }
    let shutdownWaiterQueued = await waitForQueuedOperations(1, coordinator: coordinator,
                                                              dictionaryID: item.dictionaryID)
    try smoke.check("shutdown waiter queues", category: \.cancellation,
                    shutdownWaiterQueued)
    await coordinator.shutdown()
    let queuedResult = await queued.result
    if case .failure(let error as ManagedDictionaryLifecycleError) = queuedResult {
        try smoke.check("shutdown resumes queued exclusive waiter exactly once", category: \.cancellation,
                        error == .dictionaryLifecycleShuttingDown)
    } else {
        throw SmokeFailure.failed("shutdown must reject queued exclusive waiter")
    }
    await coordinator.release(held)
    let afterShutdown = await coordinator.snapshot(for: item.dictionaryID)
    try smoke.check("shutdown clears queued work and keeps admission closed", category: \.cancellation,
                    afterShutdown?.queuedOperationCount == 0)
}

private func testCurrentCatalogRecheck(smoke: inout Smoke) async throws {
    let item = descriptor("00000000-0000-0000-0000-000000000106")
    let runtime = BlockingRuntime()
    let service = ManagedDictionaryQueryService(catalog: catalog([item]), runtime: runtime)
    let query = Task { await service.lookup("safe") }
    await runtime.entered.wait()
    var disabled = item
    disabled.enabled = false
    disabled.updatedAt = item.updatedAt.addingTimeInterval(1)
    await service.replaceCatalog(catalog([disabled]))
    let beforeCompletion = await runtime.snapshot()
    try smoke.check("Catalog replacement does not close an active runtime", category: \.runtime,
                    beforeCompletion.resetCount == 0 && beforeCompletion.removeCount == 0)
    await runtime.continueLookup.open()
    let batch = await query.value
    try smoke.check("current Catalog disables an in-flight result", category: \.ordering,
                    batch.hits.isEmpty)
    let snapshot = await service.lifecycleCoordinator.snapshot(for: item.dictionaryID)
    try smoke.check("current Catalog recheck leaves no active lease", category: \.runtime,
                    snapshot?.activeLeaseCount == 0 && snapshot?.phase == .suspended)
    let afterCompletion = await runtime.snapshot()
    try smoke.check("stale runtime closes only after its lease ends", category: \.runtime,
                    afterCompletion.removeCount == 1)

    let deletedItem = descriptor("00000000-0000-0000-0000-000000000107")
    let deletedRuntime = BlockingRuntime()
    let deletedService = ManagedDictionaryQueryService(catalog: catalog([deletedItem]), runtime: deletedRuntime)
    let deletedQuery = Task { await deletedService.lookup("safe") }
    await deletedRuntime.entered.wait()
    await deletedService.replaceCatalog(catalog([]))
    let beforeDeletedCompletion = await deletedRuntime.snapshot()
    try smoke.check("descriptor deletion does not close an active runtime", category: \.runtime,
                    beforeDeletedCompletion.removeCount == 0)
    await deletedRuntime.continueLookup.open()
    let deletedBatch = await deletedQuery.value
    try smoke.check("current Catalog deletion blocks an in-flight result", category: \.ordering,
                    deletedBatch.hits.isEmpty)
    let afterDeletedCompletion = await deletedRuntime.snapshot()
    try smoke.check("deleted runtime closes after its lease ends", category: \.runtime,
                    afterDeletedCompletion.removeCount == 1)
}

private func testFinalValidationReentrancy(smoke: inout Smoke) async throws {
    let item = descriptor("00000000-0000-0000-0000-000000000111")
    let runtime = BlockingRuntime()
    let lifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([item]))
    let service = ManagedDictionaryQueryService(catalog: catalog([item]), runtime: runtime,
                                                lifecycleCoordinator: lifecycle)
    let validationEntered = Gate()
    let continueValidation = Gate()
    await lifecycle.setBeforeBatchQueryValidationSnapshotForTesting {
        await validationEntered.open()
        await continueValidation.wait()
    }
    let query = Task { await service.lookup("safe") }
    await runtime.entered.wait()
    await runtime.continueLookup.open()
    await validationEntered.wait()
    var disabled = item
    disabled.enabled = false
    disabled.updatedAt = item.updatedAt.addingTimeInterval(1)
    await service.replaceCatalog(catalog([disabled]))
    await continueValidation.open()
    let disabledBatch = await query.value
    let disabledSnapshot = await lifecycle.snapshot(for: item.dictionaryID)
    try smoke.check("final validation reads disabled Catalog after generation await", category: \.ordering,
                    disabledBatch.hits.isEmpty)
    try smoke.check("reentrant disabled validation releases lease", category: \.runtime,
                    disabledSnapshot?.activeLeaseCount == 0)

    let deleted = descriptor("00000000-0000-0000-0000-000000000112")
    let deletedRuntime = BlockingRuntime()
    let deletedLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([deleted]))
    let deletedService = ManagedDictionaryQueryService(catalog: catalog([deleted]), runtime: deletedRuntime,
                                                       lifecycleCoordinator: deletedLifecycle)
    let deletedEntered = Gate()
    let continueDeleted = Gate()
    await deletedLifecycle.setBeforeBatchQueryValidationSnapshotForTesting {
        await deletedEntered.open()
        await continueDeleted.wait()
    }
    let deletedQuery = Task { await deletedService.lookup("safe") }
    await deletedRuntime.entered.wait()
    await deletedRuntime.continueLookup.open()
    await deletedEntered.wait()
    await deletedService.replaceCatalog(catalog([]))
    await continueDeleted.open()
    let deletedBatch = await deletedQuery.value
    let deletedSnapshot = await deletedLifecycle.snapshot(for: deleted.dictionaryID)
    try smoke.check("final validation reads deleted Catalog after generation await", category: \.ordering,
                    deletedBatch.hits.isEmpty)
    try smoke.check("reentrant deletion validation releases lease", category: \.runtime,
                    deletedSnapshot?.activeLeaseCount == 0)
}

/// Pauses the exact old P1 window: the lookup is complete and the final release has been entered,
/// but the release has not yet returned to the query actor. The final Catalog read must therefore
/// observe the disable/delete that happens while that cross-actor call is suspended.
private func testReleaseWindowFinalValidation(smoke: inout Smoke) async throws {
    let item = descriptor("00000000-0000-0000-0000-000000000115")
    let runtime = BlockingRuntime()
    let lifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([item]))
    let service = ManagedDictionaryQueryService(catalog: catalog([item]), runtime: runtime,
                                                lifecycleCoordinator: lifecycle)
    let releaseEntered = Gate()
    let continueRelease = Gate()
    await lifecycle.setBeforeFinalLeaseReleaseForTesting {
        await releaseEntered.open()
        await continueRelease.wait()
    }
    let query = Task { await service.lookup("safe") }
    await runtime.entered.wait()
    await runtime.continueLookup.open()
    await releaseEntered.wait()
    try smoke.check("disable fixture pauses inside final release", category: \.releaseBarrier, true)
    var disabled = item
    disabled.enabled = false
    disabled.updatedAt = item.updatedAt.addingTimeInterval(1)
    await service.replaceCatalog(catalog([disabled]))
    await continueRelease.open()
    let disabledBatch = await query.value
    let disabledSnapshot = await lifecycle.snapshot(for: item.dictionaryID)
    let disabledRuntime = await runtime.snapshot()
    try smoke.check("disable during release window drops the old result", category: \.ordering,
                    disabledBatch.hits.isEmpty)
    try smoke.check("disable during release window releases exactly one lease", category: \.generationDrain,
                    disabledSnapshot?.activeLeaseCount == 0 && disabledSnapshot?.phase == .suspended)
    try smoke.check("disable during release window performs no second lookup", category: \.runtime,
                    disabledRuntime.lookupCount == 1 && disabledRuntime.removeCount == 1)

    let deleted = descriptor("00000000-0000-0000-0000-000000000116")
    let deletedRuntime = BlockingRuntime()
    let deletedLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([deleted]))
    let deletedService = ManagedDictionaryQueryService(catalog: catalog([deleted]), runtime: deletedRuntime,
                                                       lifecycleCoordinator: deletedLifecycle)
    let deletedReleaseEntered = Gate()
    let continueDeletedRelease = Gate()
    await deletedLifecycle.setBeforeFinalLeaseReleaseForTesting {
        await deletedReleaseEntered.open()
        await continueDeletedRelease.wait()
    }
    let deletedQuery = Task { await deletedService.lookup("safe") }
    await deletedRuntime.entered.wait()
    await deletedRuntime.continueLookup.open()
    await deletedReleaseEntered.wait()
    try smoke.check("delete fixture pauses inside final release", category: \.releaseBarrier, true)
    await deletedService.replaceCatalog(catalog([]))
    await continueDeletedRelease.open()
    let deletedBatch = await deletedQuery.value
    let deletedSnapshot = await deletedLifecycle.snapshot(for: deleted.dictionaryID)
    let deletedRuntimeSnapshot = await deletedRuntime.snapshot()
    try smoke.check("delete during release window drops the old result", category: \.ordering,
                    deletedBatch.hits.isEmpty)
    try smoke.check("delete during release window retires and releases the lease", category: \.generationDrain,
                    deletedSnapshot?.activeLeaseCount == 0 && deletedSnapshot?.phase == .retired)
    try smoke.check("delete during release window performs no second lookup", category: \.runtime,
                    deletedRuntimeSnapshot.lookupCount == 1 && deletedRuntimeSnapshot.removeCount == 1)
    let deletionRejected: Bool
    do {
        _ = try await deletedLifecycle.acquireQueryLease(for: deleted.dictionaryID)
        deletionRejected = false
    } catch let error as ManagedDictionaryLifecycleError {
        deletionRejected = error == .dictionaryRetired
    }
    try smoke.check("retired descriptor rejects a later query", category: \.ordering, deletionRejected)
}

private func testBatchFinalizationAcrossLaterLookup(smoke: inout Smoke) async throws {
    let a = descriptor("00000000-0000-0000-0000-000000000401", position: 0)
    let b = descriptor("00000000-0000-0000-0000-000000000402", position: 1)

    let disableRuntime = BatchRuntime(
        blockedDictionaryID: b.dictionaryID,
        outcomes: [a.dictionaryID: .hit(hit(a.dictionaryID)),
                   b.dictionaryID: .hit(hit(b.dictionaryID))]
    )
    let disableLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([a, b]))
    let disableService = ManagedDictionaryQueryService(
        catalog: catalog([a, b]), runtime: disableRuntime,
        lifecycleCoordinator: disableLifecycle
    )
    let disableQuery = Task { await disableService.lookup("safe") }
    await disableRuntime.blockedLookupEntered.wait()
    var disabledA = a
    disabledA.enabled = false
    disabledA.updatedAt = a.updatedAt.addingTimeInterval(1)
    await disableService.replaceCatalog(catalog([disabledA, b]))
    await disableRuntime.continueBlockedLookup.open()
    let disabledBatch = await disableQuery.value
    let disabledRuntimeState = await disableRuntime.snapshot()
    let disabledASnapshot = await disableLifecycle.snapshot(for: a.dictionaryID)
    let disabledBSnapshot = await disableLifecycle.snapshot(for: b.dictionaryID)
    try smoke.check("batch drops A disabled while B lookup is suspended",
                    category: \.batchFinalization,
                    disabledBatch.hits.map(\.dictionaryID) == [b.dictionaryID])
    try smoke.check("batch disable fixture queries A and B exactly once",
                    category: \.batchFinalization,
                    disabledRuntimeState.queried == [a.dictionaryID, b.dictionaryID])
    try smoke.check("batch disable releases every lease and suspends A",
                    category: \.batchFinalization,
                    disabledASnapshot?.activeLeaseCount == 0 &&
                        disabledASnapshot?.phase == .suspended &&
                        disabledBSnapshot?.activeLeaseCount == 0)
    try smoke.check("batch disable never broad-evicts a runtime",
                    category: \.runtimeEviction,
                    disabledRuntimeState.broadRemovals.isEmpty)

    let deleteRuntime = BatchRuntime(
        blockedDictionaryID: b.dictionaryID,
        outcomes: [a.dictionaryID: .hit(hit(a.dictionaryID)),
                   b.dictionaryID: .hit(hit(b.dictionaryID))]
    )
    let deleteLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([a, b]))
    let deleteService = ManagedDictionaryQueryService(
        catalog: catalog([a, b]), runtime: deleteRuntime,
        lifecycleCoordinator: deleteLifecycle
    )
    let deleteQuery = Task { await deleteService.lookup("safe") }
    await deleteRuntime.blockedLookupEntered.wait()
    await deleteService.replaceCatalog(catalog([b]))
    await deleteRuntime.continueBlockedLookup.open()
    let deletedBatch = await deleteQuery.value
    let deletedRuntimeState = await deleteRuntime.snapshot()
    let deletedASnapshot = await deleteLifecycle.snapshot(for: a.dictionaryID)
    let deletedBSnapshot = await deleteLifecycle.snapshot(for: b.dictionaryID)
    try smoke.check("batch drops A deleted while B lookup is suspended",
                    category: \.batchFinalization,
                    deletedBatch.hits.map(\.dictionaryID) == [b.dictionaryID])
    try smoke.check("batch deletion retires A without resurrecting its descriptor",
                    category: \.batchFinalization,
                    deletedASnapshot?.phase == .retired &&
                        deletedASnapshot?.activeLeaseCount == 0 &&
                        deletedBSnapshot?.activeLeaseCount == 0)
    try smoke.check("batch deletion does not requery either descriptor",
                    category: \.batchFinalization,
                    deletedRuntimeState.queried == [a.dictionaryID, b.dictionaryID])

    let replaceRuntime = BatchRuntime(
        blockedDictionaryID: b.dictionaryID,
        outcomes: [a.dictionaryID: .hit(hit(a.dictionaryID)),
                   b.dictionaryID: .hit(hit(b.dictionaryID))]
    )
    let replaceLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([a, b]))
    let replaceService = ManagedDictionaryQueryService(
        catalog: catalog([a, b]), runtime: replaceRuntime,
        lifecycleCoordinator: replaceLifecycle
    )
    let replaceQuery = Task { await replaceService.lookup("safe") }
    await replaceRuntime.blockedLookupEntered.wait()
    let replacementA = replacingRuntimeIdentity(a)
    await replaceService.replaceCatalog(catalog([replacementA, b]))
    await replaceRuntime.continueBlockedLookup.open()
    let replacementBatch = await replaceQuery.value
    let firstReplacementRuntimeState = await replaceRuntime.snapshot()
    try smoke.check("eligible A2 identity cannot authorize the old A1 result",
                    category: \.identityBinding,
                    replacementBatch.hits.map(\.dictionaryID) == [b.dictionaryID])
    try smoke.check("identity replacement never automatically requeries A2",
                    category: \.identityBinding,
                    firstReplacementRuntimeState.queried == [a.dictionaryID, b.dictionaryID])
    let nextBatch = await replaceService.lookup("safe")
    let secondReplacementRuntimeState = await replaceRuntime.snapshot()
    try smoke.check("A2 is used only by the user's next lookup",
                    category: \.identityBinding,
                    nextBatch.hits.map(\.dictionaryID) == [a.dictionaryID, b.dictionaryID] &&
                        secondReplacementRuntimeState.queried ==
                            [a.dictionaryID, b.dictionaryID, a.dictionaryID, b.dictionaryID])

    let presentationRuntime = BatchRuntime(
        blockedDictionaryID: b.dictionaryID,
        outcomes: [a.dictionaryID: .hit(hit(a.dictionaryID)),
                   b.dictionaryID: .hit(hit(b.dictionaryID))]
    )
    let presentationLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([a, b]))
    let presentationService = ManagedDictionaryQueryService(
        catalog: catalog([a, b]), runtime: presentationRuntime,
        lifecycleCoordinator: presentationLifecycle
    )
    let presentationQuery = Task { await presentationService.lookup("safe") }
    await presentationRuntime.blockedLookupEntered.wait()
    var renamedA = a
    renamedA.displayName = "Renamed synthetic dictionary"
    renamedA.sortPosition = 99
    renamedA.updatedAt = a.updatedAt.addingTimeInterval(3)
    await presentationService.replaceCatalog(catalog([renamedA, b]))
    await presentationRuntime.continueBlockedLookup.open()
    let presentationBatch = await presentationQuery.value
    try smoke.check("display name and sort position do not change runtime identity",
                    category: \.identityBinding,
                    presentationBatch.hits.map(\.dictionaryID) == [a.dictionaryID, b.dictionaryID])
}

private func testBatchSnapshotFailClosedAndGeneration(smoke: inout Smoke) async throws {
    let a = descriptor("00000000-0000-0000-0000-000000000403", position: 0)
    let b = descriptor("00000000-0000-0000-0000-000000000404", position: 1)

    let fallback = descriptor(
        "00000000-0000-0000-0000-000000000406",
        sourceKind: .openResource, ownership: .appManagedOpenResource,
        level: .fallback
    )
    let missingRuntime = Runtime(outcomes: [
        a.dictionaryID: .hit(hit(a.dictionaryID)),
        fallback.dictionaryID: .hit(hit(fallback.dictionaryID))
    ])
    let missingLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([a, fallback]))
    await missingLifecycle.setOmittedQueryValidationSnapshotIDsForTesting([a.dictionaryID])
    let missingService = ManagedDictionaryQueryService(
        catalog: catalog([a, fallback]), runtime: missingRuntime,
        lifecycleCoordinator: missingLifecycle
    )
    let missingBatch = await missingService.lookup("safe")
    let missingQueries = await missingRuntime.snapshot().queried
    try smoke.check("missing batch snapshot fails the candidate closed",
                    category: \.snapshotFailClosed,
                    missingBatch.hits.isEmpty &&
                        missingBatch.unavailableDictionaryIDs.isEmpty &&
                        !missingBatch.skippedBecausePreferredMatched &&
                        missingQueries == [a.dictionaryID])

    let generationRuntime = BatchRuntime(
        blockedDictionaryID: b.dictionaryID,
        outcomes: [a.dictionaryID: .hit(hit(a.dictionaryID)),
                   b.dictionaryID: .hit(hit(b.dictionaryID))]
    )
    let generationLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([a, b]))
    let generationService = ManagedDictionaryQueryService(
        catalog: catalog([a, b]), runtime: generationRuntime,
        lifecycleCoordinator: generationLifecycle
    )
    let generationQuery = Task { await generationService.lookup("safe") }
    await generationRuntime.blockedLookupEntered.wait()
    let generationPermit = try await generationLifecycle.acquireExclusiveOperation(
        for: a.dictionaryID, operation: .reconcile
    )
    await generationLifecycle.complete(
        generationPermit, disposition: .available(incrementGeneration: true)
    )
    await generationRuntime.continueBlockedLookup.open()
    let generationBatch = await generationQuery.value
    try smoke.check("batch drops a candidate whose generation changed while B awaited",
                    category: \.batchFinalization,
                    generationBatch.hits.map(\.dictionaryID) == [b.dictionaryID])

    let unavailableRuntime = BatchRuntime(
        blockedDictionaryID: b.dictionaryID,
        outcomes: [a.dictionaryID: .hit(hit(a.dictionaryID)),
                   b.dictionaryID: .unavailable]
    )
    let unavailableLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([a, b]))
    let unavailableService = ManagedDictionaryQueryService(
        catalog: catalog([a, b]), runtime: unavailableRuntime,
        lifecycleCoordinator: unavailableLifecycle
    )
    let unavailableQuery = Task { await unavailableService.lookup("safe") }
    await unavailableRuntime.blockedLookupEntered.wait()
    var disabledA = a
    disabledA.enabled = false
    disabledA.updatedAt = a.updatedAt.addingTimeInterval(2)
    await unavailableService.replaceCatalog(catalog([disabledA, b]))
    await unavailableRuntime.continueBlockedLookup.open()
    let unavailableBatch = await unavailableQuery.value
    try smoke.check("later unavailable outcome does not bypass final validation of A",
                    category: \.batchFinalization,
                    unavailableBatch.hits.isEmpty &&
                        unavailableBatch.unavailableDictionaryIDs == [b.dictionaryID])

    let orderedRuntime = Runtime(
        outcomes: [a.dictionaryID: .hit(hit(a.dictionaryID)),
                   b.dictionaryID: .hit(hit(b.dictionaryID))]
    )
    let orderedService = ManagedDictionaryQueryService(catalog: catalog([a, b]),
                                                       runtime: orderedRuntime)
    let orderedBatch = await orderedService.lookup("safe")
    try smoke.check("batch finalizer preserves stable Catalog query order",
                    category: \.batchFinalization,
                    orderedBatch.hits.map(\.dictionaryID) == [a.dictionaryID, b.dictionaryID])

    let cancellationRuntime = BatchRuntime(
        blockedDictionaryID: b.dictionaryID,
        outcomes: [a.dictionaryID: .hit(hit(a.dictionaryID)),
                   b.dictionaryID: .hit(hit(b.dictionaryID))]
    )
    let cancellationLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([a, b]))
    let cancellationService = ManagedDictionaryQueryService(
        catalog: catalog([a, b]), runtime: cancellationRuntime,
        lifecycleCoordinator: cancellationLifecycle
    )
    let cancellationQuery = Task { await cancellationService.lookup("safe") }
    await cancellationRuntime.blockedLookupEntered.wait()
    cancellationQuery.cancel()
    await cancellationRuntime.continueBlockedLookup.open()
    let cancellationBatch = await cancellationQuery.value
    let cancelledA = await cancellationLifecycle.snapshot(for: a.dictionaryID)
    let cancelledB = await cancellationLifecycle.snapshot(for: b.dictionaryID)
    try smoke.check("cooperative later cancellation returns only a prior final-valid candidate",
                    category: \.cancellation,
                    cancellationBatch.hits.map(\.dictionaryID) == [a.dictionaryID])
    try smoke.check("cooperative later cancellation releases all batch leases",
                    category: \.cancellation,
                    cancelledA?.activeLeaseCount == 0 && cancelledB?.activeLeaseCount == 0)
}

private func testQueuedWriterIdentityBinding(smoke: inout Smoke) async throws {
    let item = descriptor("00000000-0000-0000-0000-000000000405")
    let unchangedRuntime = BlockingRuntime()
    let unchangedLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([item]))
    let unchangedService = ManagedDictionaryQueryService(
        catalog: catalog([item]), runtime: unchangedRuntime,
        lifecycleCoordinator: unchangedLifecycle
    )
    let unchangedQuery = Task { await unchangedService.lookup("safe") }
    await unchangedRuntime.entered.wait()
    let unchangedWriter = Task {
        try await unchangedLifecycle.acquireExclusiveOperation(
            for: item.dictionaryID, operation: .reconcile
        )
    }
    let unchangedQueued = await waitForQueuedOperations(
        1, coordinator: unchangedLifecycle, dictionaryID: item.dictionaryID
    )
    try smoke.check("unchanged writer fixture is deterministically queued",
                    category: \.barriers, unchangedQueued)
    await unchangedRuntime.continueLookup.open()
    let unchangedPermit = try await unchangedWriter.value
    let unchangedBatch = await unchangedQuery.value
    try smoke.check("queued writer with unchanged identity permits the started query",
                    category: \.identityBinding,
                    unchangedBatch.hits.map(\.dictionaryID) == [item.dictionaryID])
    await unchangedLifecycle.complete(
        unchangedPermit, disposition: .available(incrementGeneration: false)
    )

    let changedRuntime = BlockingRuntime()
    let changedLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([item]))
    let changedService = ManagedDictionaryQueryService(
        catalog: catalog([item]), runtime: changedRuntime,
        lifecycleCoordinator: changedLifecycle
    )
    let changedQuery = Task { await changedService.lookup("safe") }
    await changedRuntime.entered.wait()
    let changedWriter = Task {
        try await changedLifecycle.acquireExclusiveOperation(
            for: item.dictionaryID, operation: .reconcile
        )
    }
    let changedQueued = await waitForQueuedOperations(
        1, coordinator: changedLifecycle, dictionaryID: item.dictionaryID
    )
    try smoke.check("changed writer fixture is deterministically queued",
                    category: \.barriers, changedQueued)
    await changedService.replaceCatalog(catalog([replacingRuntimeIdentity(item)]))
    await changedRuntime.continueLookup.open()
    let changedPermit = try await changedWriter.value
    let changedBatch = await changedQuery.value
    try smoke.check("queued writer cannot authorize a different eligible identity",
                    category: \.identityBinding, changedBatch.hits.isEmpty)
    let changedSnapshot = await changedLifecycle.snapshot(for: item.dictionaryID)
    try smoke.check("changed writer advances generation and releases the old lease",
                    category: \.identityBinding,
                    changedPermit.generation == 2 &&
                        changedSnapshot?.activeLeaseCount == 0)
    await changedLifecycle.complete(
        changedPermit, disposition: .available(incrementGeneration: false)
    )
}

private func testGenerationScopedRuntimeEviction(smoke: inout Smoke) async throws {
    let item = descriptor("00000000-0000-0000-0000-000000000113")
    let runtime = GenerationRuntime()
    let lifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([item]))
    let service = ManagedDictionaryQueryService(catalog: catalog([item]), runtime: runtime,
                                                lifecycleCoordinator: lifecycle)
    let first = Task { await service.lookup("one") }
    let second = Task { await service.lookup("two") }
    await runtime.firstEntered.wait()
    await runtime.secondEntered.wait()
    var replacement = item
    replacement.indexMetadata.indexFileSize = 2
    replacement.updatedAt = item.updatedAt.addingTimeInterval(1)
    await service.replaceCatalog(catalog([replacement]))
    await runtime.releaseFirst.open()
    _ = await first.value
    let afterFirst = await runtime.snapshot()
    try smoke.check("first old lease does not evict generation N", category: \.runtimeEviction,
                    afterFirst.cached.contains(1) && afterFirst.scoped.isEmpty)
    await runtime.releaseSecond.open()
    await runtime.scopedRemovalEntered.wait()
    let nextGeneration = await lifecycle.generation(for: item.dictionaryID)
    try smoke.check("last old lease publishes generation N plus one", category: \.runtimeEviction,
                    nextGeneration == 2)
    let newBatch = await service.lookup("three")
    try smoke.check("generation N plus one query remains usable during N eviction", category: \.runtimeEviction,
                    newBatch.hits.map(\.dictionaryID) == [item.dictionaryID])
    await runtime.releaseScopedRemoval.open()
    _ = await second.value
    let final = await runtime.snapshot()
    try smoke.check("generation scoped eviction closes only N exactly once", category: \.runtimeEviction,
                    final.scoped == [1] && !final.cached.contains(1) && final.cached.contains(2))
    try smoke.check("stale query never calls broad runtime removal", category: \.runtimeEviction,
                    final.broad == 0)
}

private func testOpenResourceFallback(smoke: inout Smoke) async throws {
    let normal = descriptor("00000000-0000-0000-0000-000000000201", position: 0)
    let fallbackA = descriptor("00000000-0000-0000-0000-000000000202", sourceKind: .openResource,
                               ownership: .appManagedOpenResource, level: .fallback, position: 2)
    let fallbackB = descriptor("00000000-0000-0000-0000-000000000203", sourceKind: .openResource,
                               ownership: .appManagedOpenResource, level: .fallback, position: 1)
    let disabled = descriptor("00000000-0000-0000-0000-000000000204", sourceKind: .openResource,
                              ownership: .appManagedOpenResource, level: .fallback, enabled: false)
    let runtime = Runtime(outcomes: [normal.dictionaryID: .miss,
                                     fallbackA.dictionaryID: .hit(hit(fallbackA.dictionaryID)),
                                     fallbackB.dictionaryID: .miss,
                                     disabled.dictionaryID: .hit(hit(disabled.dictionaryID))])
    let service = ManagedDictionaryQueryService(catalog: catalog([normal, fallbackA, fallbackB, disabled]),
                                                runtime: runtime)
    let batch = await service.lookup("safe")
    try smoke.check("fallback hit is returned after managedLocal miss", category: \.ordering,
                    batch.hits.map(\.dictionaryID) == [fallbackA.dictionaryID])
    let queried = await runtime.snapshot().queried
    try smoke.check("fallback resources use Catalog stable order", category: \.ordering,
                    queried == [normal.dictionaryID, fallbackB.dictionaryID, fallbackA.dictionaryID])
    try smoke.check("disabled open resource is not queried", category: \.ordering,
                    !queried.contains(disabled.dictionaryID))
    let releasedNormalLease = await service.lifecycleCoordinator.snapshot(for: normal.dictionaryID)
    try smoke.check("production query service releases its runtime lease after lookup", category: \.runtime,
                    releasedNormalLease?.activeLeaseCount == 0)

    let localHitRuntime = Runtime(outcomes: [normal.dictionaryID: .hit(hit(normal.dictionaryID)),
                                             fallbackA.dictionaryID: .hit(hit(fallbackA.dictionaryID))])
    let localHitService = ManagedDictionaryQueryService(catalog: catalog([normal, fallbackA]),
                                                        runtime: localHitRuntime)
    let localHit = await localHitService.lookup("safe")
    let localQueried = await localHitRuntime.snapshot().queried
    try smoke.check("managedLocal hit prevents fallback lookup", category: \.ordering,
                    localHit.hits.map(\.dictionaryID) == [normal.dictionaryID] &&
                    localQueried == [normal.dictionaryID])
    let preferred = await localHitService.lookup("safe", preferredMatched: true)
    try smoke.check("preferred hit skips both managed tiers", category: \.ordering,
                    preferred.skippedBecausePreferredMatched && preferred.hits.isEmpty)

    let pending = descriptor("00000000-0000-0000-0000-000000000205", sourceKind: .openResource,
                             ownership: .appManagedOpenResource, level: .fallback, state: .pendingIndex)
    let indexing = descriptor("00000000-0000-0000-0000-000000000206", sourceKind: .openResource,
                              ownership: .appManagedOpenResource, level: .fallback, state: .indexing)
    let corrupt = descriptor("00000000-0000-0000-0000-000000000207", sourceKind: .openResource,
                             ownership: .appManagedOpenResource, level: .fallback, state: .corrupt)
    let wrongOwnership = descriptor("00000000-0000-0000-0000-000000000208", sourceKind: .openResource,
                                    ownership: .appManagedImported, level: .fallback)
    let wrongLevel = descriptor("00000000-0000-0000-0000-000000000209", sourceKind: .openResource,
                                ownership: .appManagedOpenResource, level: .normal)
    let ready = descriptor("00000000-0000-0000-0000-000000000210", sourceKind: .openResource,
                           ownership: .appManagedOpenResource, level: .fallback)
    let eligibilityRuntime = Runtime(outcomes: [ready.dictionaryID: .hit(hit(ready.dictionaryID))])
    let eligibilityService = ManagedDictionaryQueryService(
        catalog: catalog([pending, indexing, corrupt, wrongOwnership, wrongLevel, ready]),
        runtime: eligibilityRuntime
    )
    let eligibilityBatch = await eligibilityService.lookup("safe")
    let eligibilityQueries = await eligibilityRuntime.snapshot().queried
    try smoke.check("only ready app-managed fallback is eligible", category: \.ordering,
                    eligibilityBatch.hits.map(\.dictionaryID) == [ready.dictionaryID] &&
                    eligibilityQueries == [ready.dictionaryID])

    let broken = descriptor("00000000-0000-0000-0000-000000000211", sourceKind: .openResource,
                            ownership: .appManagedOpenResource, level: .fallback, position: 0)
    let surviving = descriptor("00000000-0000-0000-0000-000000000212", sourceKind: .openResource,
                               ownership: .appManagedOpenResource, level: .fallback, position: 1)
    let isolationRuntime = Runtime(outcomes: [broken.dictionaryID: .unavailable,
                                              surviving.dictionaryID: .hit(hit(surviving.dictionaryID))])
    let isolationService = ManagedDictionaryQueryService(catalog: catalog([broken, surviving]),
                                                         runtime: isolationRuntime)
    let isolationBatch = await isolationService.lookup("safe")
    try smoke.check("one broken fallback is isolated from the next fallback", category: \.ordering,
                    isolationBatch.hits.map(\.dictionaryID) == [surviving.dictionaryID] &&
                    isolationBatch.unavailableDictionaryIDs == [broken.dictionaryID])
}

/// Exercises the actual CatalogStore mutation/atomic-save path, but only beneath an isolated
/// synthetic temporary root. This keeps the lifecycle test independent of Application Support.
@MainActor
private func performSyntheticCatalogTransaction() throws -> DictionaryCatalog {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("LocalDictionary-2C-lifecycle-catalog-\(UUID().uuidString)",
                                isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let item = descriptor("00000000-0000-0000-0000-000000000301")
    let store = DictionaryCatalogStore(directoryURL: root)
    _ = try store.mutate { catalog, _ in
        catalog.dictionaries = [item]
        catalog.updatedAt = Date(timeIntervalSince1970: 1_700_000_001)
    }
    return store.load()
}

private func testCatalogTransaction(smoke: inout Smoke) async throws {
    let persisted = try await performSyntheticCatalogTransaction()
    try smoke.check("Catalog transaction persists one synthetic descriptor", category: \.catalog,
                    persisted.dictionaries.count == 1)
    try smoke.check("Catalog transaction preserves only a safe relative path", category: \.catalog,
                    persisted.dictionaries.first?.relativePaths.dictionary ==
                        "Dictionaries/00000000-0000-0000-0000-000000000301/source/test.mdx")
}

private extension Optional where Wrapped == UInt64 {
    func unwrap(_ message: String) throws -> UInt64 {
        guard let self else { throw SmokeFailure.failed(message) }
        return self
    }
}

@main
struct ManagedDictionaryLifecycleCoordinatorSmoke {
    static func main() async throws {
        var smoke = Smoke()
        try await testLeaseAndDrain(smoke: &smoke)
        try await testFinalReleaseOutcome(smoke: &smoke)
        try await testStructuredThrowAndCancellation(smoke: &smoke)
        try await testIdentityTransitions(smoke: &smoke)
        try await testLatestWinsPendingTransitions(smoke: &smoke)
        try await testFIFOAndShutdown(smoke: &smoke)
        try await testCurrentCatalogRecheck(smoke: &smoke)
        try await testFinalValidationReentrancy(smoke: &smoke)
        try await testReleaseWindowFinalValidation(smoke: &smoke)
        try await testBatchFinalizationAcrossLaterLookup(smoke: &smoke)
        try await testBatchSnapshotFailClosedAndGeneration(smoke: &smoke)
        try await testQueuedWriterIdentityBinding(smoke: &smoke)
        try await testGenerationScopedRuntimeEviction(smoke: &smoke)
        try await testOpenResourceFallback(smoke: &smoke)
        try await testCatalogTransaction(smoke: &smoke)
        print("Managed lifecycle/query coordination smoke: PASS (\(smoke.assertions) total runtime assertions)")
        print("categories: actor-state=\(smoke.actorState) query-runtime=\(smoke.runtime) catalog=\(smoke.catalog) runtime-eviction=\(smoke.runtimeEviction) batch-finalization=\(smoke.batchFinalization) identity-binding=\(smoke.identityBinding) snapshot-fail-closed=\(smoke.snapshotFailClosed) POSIX=0 barrier=\(smoke.barriers) release-barrier=\(smoke.releaseBarrier) generation-drain=\(smoke.generationDrain) cancellation=\(smoke.cancellation) ordering=\(smoke.ordering) helper-only=0")
    }
}
