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
    func reset() {}
    func snapshot() -> (queried: [String], removed: [String]) { (queried, removed) }
}

private actor BlockingRuntime: ManagedDictionaryQueryRuntime {
    let entered = Gate()
    let continueLookup = Gate()
    private var resetCount = 0
    private var removeCount = 0

    func lookup(descriptor: DictionaryDescriptor, generation: UInt64,
                query: String) async -> ManagedDictionaryRuntimeOutcome {
        await entered.open()
        await continueLookup.wait()
        return .hit(hit(descriptor.dictionaryID))
    }

    func remove(dictionaryID: String) { removeCount += 1 }
    func reset() { resetCount += 1 }

    func snapshot() -> (resetCount: Int, removeCount: Int) { (resetCount, removeCount) }
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
        try await testStructuredThrowAndCancellation(smoke: &smoke)
        try await testIdentityTransitions(smoke: &smoke)
        try await testFIFOAndShutdown(smoke: &smoke)
        try await testCurrentCatalogRecheck(smoke: &smoke)
        try await testOpenResourceFallback(smoke: &smoke)
        try await testCatalogTransaction(smoke: &smoke)
        print("Managed lifecycle/query coordination smoke: PASS (\(smoke.assertions) total runtime assertions)")
        print("categories: actor-state=\(smoke.actorState) query-runtime=\(smoke.runtime) catalog=\(smoke.catalog) POSIX=0 barrier=\(smoke.barriers) cancellation=\(smoke.cancellation) ordering=\(smoke.ordering) helper-only=0")
    }
}
