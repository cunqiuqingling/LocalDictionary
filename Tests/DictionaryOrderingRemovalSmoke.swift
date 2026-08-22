import Foundation

private enum SmokeError: Error { case failed(String) }

private final class AssertionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private let runtimeAssertions = AssertionCounter()

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw SmokeError.failed(message) }
    runtimeAssertions.increment()
}

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

private func descriptor(
    id: String,
    sourceKind: DictionarySourceKind = .managedLocal,
    level: DictionaryQueryLevel = .normal,
    position: Int64,
    enabled: Bool = true,
    state: DictionaryState = .ready,
    createdAt: Date = fixedDate
) -> DictionaryDescriptor {
    let ownership = DictionaryOwnershipPolicy.defaultOwnership(for: sourceKind)!
    let publicationID = "00000000-0000-0000-0000-000000000003"
    let indexPath = "Dictionaries/\(id)/index/dictionary.\(publicationID).sqlite"
    let metadata: OpenResourceInstallationMetadata? = sourceKind == .openResource ?
        OpenResourceInstallationMetadata(
            resourceID: "synthetic-\(id.replacingOccurrences(of: "-", with: ""))",
            resourceRevision: 1, resourceVersion: "1", manifestVersion: 1,
            manifestSHA256: String(repeating: "a", count: 64), verifiedKeyID: "test",
            payloadSHA256: String(repeating: "b", count: 64), payloadBytes: 1,
            sidecarRelativePath: "Dictionaries/\(id)/resource-installation.json", languages: ["en"],
            license: OpenResourceLicenseMetadata(name: "Synthetic", version: "1", url: "https://example.test", attribution: "Synthetic"),
            sourceProject: "https://example.test", officialPageReference: "https://example.test/page",
            expectedEntryCount: OpenResourceEntryCountMetadata(minimum: 1, maximum: 1), installedAt: fixedDate
        ) : nil
    return DictionaryDescriptor(
        dictionaryID: id,
        displayName: "Dictionary \(id)",
        sourceKind: sourceKind,
        queryLevel: level,
        sortPosition: position,
        enabled: enabled,
        state: state,
        indexMetadata: DictionaryIndexMetadata(
            schemaVersion: 1, entryCount: 9, indexFileSize: 17,
            sourceFileSize: 11, sourceModifiedAt: fixedDate,
            sourceSHA256: String(repeating: "a", count: 64), indexedAt: fixedDate
        ),
        formatterIdentifier: sourceKind == .managedLocal || sourceKind == .openResource
            ? DictionaryFormatterIdentifier.genericMDictV1 : "legacy.v1",
        capabilities: .unknown,
        relativePaths: sourceKind == .managedLocal
            ? DictionaryRelativePaths(
                dictionary: "Dictionaries/\(id)/dictionary.mdx",
                resources: [],
                index: state == .ready ? indexPath : nil
            ) : sourceKind == .openResource
                ? DictionaryRelativePaths(
                    dictionary: "Dictionaries/\(id)/payload.mdx",
                    resources: [], index: state == .ready ? indexPath : nil
                ) : .empty,
        createdAt: createdAt,
        updatedAt: fixedDate,
        storageOwnership: ownership,
        openResourceMetadata: metadata,
        publishedIndexIdentity:
            (state == .ready &&
             DictionaryOwnershipPolicy.policy(
                for: sourceKind, ownership: ownership
             )?.isAppManaged == true)
            ? PublishedIndexIdentity(
                indexPublicationID: publicationID,
                indexSHA256: String(repeating: "c", count: 64),
                indexFileSize: 17,
                sourceSHA256: String(repeating: "a", count: 64),
                sourceFileSize: 11,
                schemaVersion: 1,
                entryCount: 9,
                indexedAt: fixedDate,
                relativePath: indexPath
            ) : nil
    )
}

private func catalog(_ dictionaries: [DictionaryDescriptor]) -> DictionaryCatalog {
    DictionaryCatalog(schemaVersion: DictionaryCatalog.currentSchemaVersion,
                      createdAt: fixedDate, updatedAt: fixedDate,
                      dictionaries: dictionaries)
}

private func orderedIDs(_ value: DictionaryCatalog,
                        level: DictionaryQueryLevel) -> [String] {
    value.activeSortedDictionaries.filter { $0.queryLevel == level }.map(\.dictionaryID)
}

@MainActor
private func testOrderingAndPersistence(root: URL) throws {
    let preferred = [
        descriptor(id: "p2", sourceKind: .legacyReference,
                   level: .preferred, position: 2),
        descriptor(id: "p1", sourceKind: .legacyReference,
                   level: .preferred, position: 1)
    ]
    let normal = [
        descriptor(id: "00000000-0000-0000-0000-000000000002", position: 2),
        descriptor(id: "00000000-0000-0000-0000-000000000001", position: 1)
    ]
    let fallback = [
        descriptor(id: "00000000-0000-4000-8000-0000000000f2", sourceKind: .openResource,
                   level: .fallback, position: 2),
        descriptor(id: "00000000-0000-4000-8000-0000000000f1", sourceKind: .openResource,
                   level: .fallback, position: 1)
    ]
    let initial = catalog(preferred + normal + fallback)
    let store = DictionaryCatalogStore(directoryURL: root.appendingPathComponent("Catalog"))
    try store.save(initial)
    let coordinator = DictionaryCatalogOrderCoordinator(catalog: initial,
                                                        catalogStore: store)

    var updated = try DictionaryCatalogOrdering.moving("p2", direction: .up,
                                                       in: coordinator.catalog)
    _ = try coordinator.save(updated)
    updated = try DictionaryCatalogOrdering.moving(normal[0].dictionaryID,
                                                   direction: .up,
                                                   in: coordinator.catalog)
    _ = try coordinator.save(updated)
    updated = try DictionaryCatalogOrdering.moving("00000000-0000-4000-8000-0000000000f2", direction: .up,
                                                   in: coordinator.catalog)
    _ = try coordinator.save(updated)
    let reloaded = store.load()
    try expect(reloaded.sortedDictionaries.map(\.dictionaryID) == [
        "p2", "p1", normal[0].dictionaryID, normal[1].dictionaryID,
        fallback[0].dictionaryID, fallback[1].dictionaryID
    ], "one unified cross-source order should persist")
    try expect(orderedIDs(reloaded, level: .preferred) == ["p2", "p1"],
               "preferred order should persist")
    try expect(orderedIDs(reloaded, level: .normal) == normal.map(\.dictionaryID),
               "normal order should persist")
    try expect(orderedIDs(reloaded, level: .fallback) == ["00000000-0000-4000-8000-0000000000f2", "00000000-0000-4000-8000-0000000000f1"],
               "fallback order should persist")

    let crossSource = try DictionaryCatalogOrdering.moving(
        "p2", toDisplayedRow: 3, in: reloaded
    )
    try expect(crossSource.sortedDictionaries.map(\.dictionaryID).prefix(4) == [
        "p1", normal[0].dictionaryID, "p2", normal[1].dictionaryID
    ], "legacy/imported cross-source drag was rejected")
    let openFirst = try DictionaryCatalogOrdering.moving(
        fallback[0].dictionaryID, toDisplayedRow: 0, in: crossSource
    )
    try expect(openFirst.sortedDictionaries.first?.dictionaryID == fallback[0].dictionaryID,
               "open resource could not move ahead of imported/legacy dictionaries")
    try expect(!DictionaryCatalogOrdering.canMove("p2", direction: .up, in: reloaded),
               "unified first dictionary must not move up")
    try expect(DictionaryCatalogOrdering.canMove("p1", direction: .down, in: reloaded),
               "legacy dictionary could not move down across a source boundary")

    let failedCoordinator = DictionaryCatalogOrderCoordinator(
        catalog: reloaded, catalogStore: store,
        saveCatalog: { _ in throw SmokeError.failed("injected save failure") }
    )
    let failedProposal = try DictionaryCatalogOrdering.moving("p1", direction: .up,
                                                              in: reloaded)
    do {
        _ = try failedCoordinator.save(failedProposal)
        throw SmokeError.failed("save failure should propagate")
    } catch SmokeError.failed(let message) where message == "injected save failure" {}
    try expect(failedCoordinator.catalog == reloaded,
               "failed save must keep in-memory order")
    try expect(store.load() == reloaded, "failed save must keep disk order")

    var duplicatePositions = reloaded
    for index in duplicatePositions.dictionaries.indices
    where duplicatePositions.dictionaries[index].queryLevel == .normal {
        duplicatePositions.dictionaries[index].sortPosition = 7
    }
    let expectedTieOrder = normal.map(\.dictionaryID).sorted()
    try expect(orderedIDs(duplicatePositions, level: .normal) == expectedTieOrder,
               "dictionaryID must deterministically break position ties")
}

private func testRestoreDefaultsAndAdapter() throws {
    let legacyIDs = DictionaryCatalogOrdering.legacyDefaultOrder
    var values = legacyIDs.enumerated().map { index, id in
        descriptor(id: id, sourceKind: .legacyReference,
                   level: .preferred, position: Int64(legacyIDs.count - index),
                   enabled: index != 1, state: index == 2 ? .failed : .ready)
    }
    let firstNormal = descriptor(
        id: "00000000-0000-0000-0000-000000000011", position: 8,
        createdAt: fixedDate.addingTimeInterval(20)
    )
    let secondNormal = descriptor(
        id: "00000000-0000-0000-0000-000000000012", position: 2,
        createdAt: fixedDate.addingTimeInterval(10)
    )
    values += [firstNormal, secondNormal]
    let initial = catalog(values)
    let restored = DictionaryCatalogOrdering.restoringDefaults(in: initial)
    try expect(orderedIDs(restored, level: .preferred) == legacyIDs,
               "legacy default order should be restored")
    try expect(orderedIDs(restored, level: .normal) ==
               [secondNormal.dictionaryID, firstNormal.dictionaryID],
               "managed defaults should use createdAt")
    for original in initial.dictionaries {
        let value = restored.dictionaries.first { $0.dictionaryID == original.dictionaryID }!
        try expect(value.enabled == original.enabled && value.state == original.state &&
                   value.queryLevel == original.queryLevel &&
                   value.indexMetadata == original.indexMetadata &&
                   value.formatterIdentifier == original.formatterIdentifier,
                   "default restore must only change order metadata")
    }

    let config = AppConfig(
        primaryDictionary: "/fixture/oxford.mdx", indexPath: "/fixture/oxford.sqlite",
        century21Dictionary: "/fixture/century.mdx",
        century21IndexPath: "/fixture/century.sqlite",
        newOxfordDictionary: "/fixture/new.mdx",
        newOxfordIndexPath: "/fixture/new.sqlite",
        medicalDictionary: "/fixture/medical.mdx",
        medicalIndexPath: "/fixture/medical.sqlite",
        affixRootDictionary: "/fixture/root.mdx",
        affixRootIndexPath: "/fixture/root.sqlite"
    )
    let adapted = LegacyDictionaryConfigAdapter().adapt(config, into: initial)
    for id in legacyIDs {
        let before = initial.dictionaries.first { $0.dictionaryID == id }!
        let after = adapted.dictionaries.first { $0.dictionaryID == id }!
        try expect(after.sortPosition == before.sortPosition,
                   "legacy adapter must preserve user order")
    }
}

@MainActor
private func testLegacyRegistrationRetirement(base: URL) throws {
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let source = base.appendingPathComponent("century.mdx")
    let index = base.appendingPathComponent("century.sqlite")
    let config = base.appendingPathComponent("local.json")
    try Data("external-mdx-placeholder".utf8).write(to: source)
    try Data("external-index-placeholder".utf8).write(to: index)
    try Data("external-config-placeholder".utf8).write(to: config)
    let snapshots = try [source, index, config].map { try Data(contentsOf: $0) }

    var legacy = descriptor(
        id: DictionarySourceID.century21.rawValue,
        sourceKind: .legacyReference, level: .preferred, position: 1
    )
    legacy.displayName = "21 世纪大英汉词典"
    let initial = catalog([legacy])
    let retired = try LegacyDictionaryRegistrationRetirement.retiring(
        dictionaryID: legacy.dictionaryID, in: initial,
        now: fixedDate.addingTimeInterval(1)
    )
    let tombstone = retired.dictionaries.first
    try expect(tombstone?.isRetiredLegacyRegistration == true &&
               tombstone?.enabled == false && tombstone?.state == .disabled,
               "legacy registration was not retired atomically")
    try expect(retired.activeSortedDictionaries.isEmpty,
               "retired legacy registration remained in the user-visible order")
    for (offset, url) in [source, index, config].enumerated() {
        try expect(try Data(contentsOf: url) == snapshots[offset],
                   "legacy registration retirement modified an external file")
    }
    try expect(
        (try? LegacyDictionaryRegistrationRetirement.retiring(
            dictionaryID: legacy.dictionaryID, in: retired
        )) == nil,
        "retired legacy registration could be retired twice"
    )
    let imported = descriptor(
        id: "00000000-0000-0000-0000-000000000099",
        sourceKind: .managedLocal, level: .normal, position: 1
    )
    var reimported = retired
    reimported.dictionaries.append(imported)
    try expect(reimported.activeSortedDictionaries.map(\.dictionaryID) == [
        imported.dictionaryID
    ], "legacy tombstone blocked a new managed import")

    // Production retirement is a full lifecycle mutation, not an ordering-only save.  Prove the
    // tombstone survives a fresh Catalog load so local.json cannot resurrect it after relaunch.
    let store = DictionaryCatalogStore(
        directoryURL: base.appendingPathComponent("Catalog", isDirectory: true)
    )
    try store.save(initial)
    _ = try store.mutate { latest, _ in
        latest = try LegacyDictionaryRegistrationRetirement.retiring(
            dictionaryID: legacy.dictionaryID, in: latest,
            now: fixedDate.addingTimeInterval(2)
        )
    }
    let relaunched = store.load()
    try expect(
        relaunched.dictionaries.first?.isRetiredLegacyRegistration == true &&
            relaunched.activeSortedDictionaries.isEmpty,
        "durable Catalog reload resurrected a retired legacy registration"
    )
}

private actor MockRuntime: ManagedDictionaryQueryRuntime {
    private var queried: [String] = []
    private var removed: [String] = []

    func lookup(descriptor: DictionaryDescriptor,
                generation: UInt64,
                query: String) -> ManagedDictionaryRuntimeOutcome {
        queried.append(descriptor.dictionaryID)
        return .hit(ManagedDictionaryQueryHit(
            dictionaryID: descriptor.dictionaryID,
            displayName: descriptor.displayName,
            matchedHeadword: query,
            blocks: [GenericMDictBlock(
                kind: .paragraph, level: 0,
                runs: [GenericMDictTextRun(text: "safe", bold: false,
                                           italic: false, code: false)]
            )],
            plainText: "safe", truncated: false
        ))
    }

    func remove(dictionaryID: String) { removed.append(dictionaryID) }
    func remove(dictionaryID: String, generation: UInt64) { removed.append(dictionaryID) }
    func reset() {}
    func snapshot() -> (queried: [String], removed: [String]) { (queried, removed) }
}

/// Test-only synchronization for the test-macro observer. Every access is
/// serialized because the coordinator crosses a detached filesystem task.
private final class RuntimeDispositionSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func record(_ resumed: Bool) {
        lock.lock()
        values.append(resumed)
        lock.unlock()
    }

    func snapshot() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private actor DeferredRuntime: ManagedDictionaryQueryRuntime {
    private var lookupStarted = false
    private var mayFinish = false
    private var removed: [String] = []

    func lookup(descriptor: DictionaryDescriptor,
                generation: UInt64,
                query: String) async -> ManagedDictionaryRuntimeOutcome {
        lookupStarted = true
        while !mayFinish { await Task.yield() }
        return .hit(ManagedDictionaryQueryHit(
            dictionaryID: descriptor.dictionaryID,
            displayName: descriptor.displayName,
            matchedHeadword: query,
            blocks: [GenericMDictBlock(
                kind: .paragraph, level: 0,
                runs: [GenericMDictTextRun(text: "stale", bold: false,
                                           italic: false, code: false)]
            )],
            plainText: "stale", truncated: false
        ))
    }

    func remove(dictionaryID: String) { removed.append(dictionaryID) }
    func remove(dictionaryID: String, generation: UInt64) { removed.append(dictionaryID) }
    func reset() {}
    func hasStarted() -> Bool { lookupStarted }
    func finish() { mayFinish = true }
    func removedIDs() -> [String] { removed }
}

private func testQueryOrderingAndStaleResultProtection() async throws {
    let first = descriptor(id: "00000000-0000-0000-0000-000000000031", position: 2)
    let second = descriptor(id: "00000000-0000-0000-0000-000000000032", position: 1)
    let runtime = MockRuntime()
    let service = ManagedDictionaryQueryService(catalog: catalog([first, second]),
                                                runtime: runtime)
    let batch = await service.lookup("prompt")
    try expect(batch.hits.map(\.dictionaryID) ==
               [second.dictionaryID, first.dictionaryID],
               "managed query results should follow Catalog order")

    let deferred = DeferredRuntime()
    let lifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog([first]))
    let staleService = ManagedDictionaryQueryService(catalog: catalog([first]),
                                                     runtime: deferred,
                                                     lifecycleCoordinator: lifecycle)
    let task = Task { await staleService.lookup("prompt") }
    while !(await deferred.hasStarted()) { await Task.yield() }
    let draining = Task {
        try await lifecycle.acquireExclusiveOperation(for: first.dictionaryID, operation: .remove)
    }
    while await lifecycle.snapshot(for: first.dictionaryID)?.phase != .draining {
        await Task.yield()
    }
    await deferred.finish()
    let protectedBatch = await task.value
    try expect(protectedBatch.hits.map(\.dictionaryID) == [first.dictionaryID],
               "drained query must finish while its runtime lease remains active")
    let permit = try await draining.value
    await staleService.invalidateRuntime(dictionaryID: first.dictionaryID)
    await lifecycle.complete(permit, disposition: .available(incrementGeneration: true))
    try expect(await deferred.removedIDs() == [first.dictionaryID],
               "exclusive removal should release only the drained target runtime")
}

private struct RemovalFixture {
    let root: URL
    let descriptor: DictionaryDescriptor
    let catalog: DictionaryCatalog
    let managedDirectory: URL
    let pendingDirectory: URL
    let originalSource: URL
    let note: URL
}

private func removalFixture(base: URL, suffix: String,
                            state: DictionaryState = .ready) throws -> RemovalFixture {
    let id = "00000000-0000-0000-0000-0000000000\(suffix)"
    let root = base.appendingPathComponent("root-\(suffix)")
    let managed = root.appendingPathComponent("Dictionaries/\(id)", isDirectory: true)
    let index = managed.appendingPathComponent("index", isDirectory: true)
    let original = base.appendingPathComponent("original-\(suffix).mdx")
    let note = base.appendingPathComponent("note-\(suffix).md")
    try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: original)
    try Data("managed-copy".utf8).write(to: managed.appendingPathComponent("dictionary.mdx"))
    try Data("sqlite".utf8).write(to: index.appendingPathComponent("dictionary.sqlite"))
    try Data("saved snapshot".utf8).write(to: note)
    let value = descriptor(id: id, position: 2, state: state)
    return RemovalFixture(
        root: root,
        descriptor: value,
        catalog: catalog([
            descriptor(id: "00000000-0000-0000-0000-000000000099", position: 1),
            value
        ]),
        managedDirectory: managed,
        pendingDirectory: root.appendingPathComponent("PendingDeletion/\(id)"),
        originalSource: original,
        note: note
    )
}

@MainActor
private func coordinator(for fixture: RemovalFixture,
                         runtime: MockRuntime,
                         hooks: ManagedDictionaryRemovalHooks = .live,
                         isIndexing: @escaping (String) -> Bool = { _ in false },
                         saveCatalog: ManagedDictionaryRemovalCoordinator.SaveCatalog? = nil)
    -> ManagedDictionaryRemovalCoordinator {
    let store = DictionaryCatalogStore(
        directoryURL: fixture.root.appendingPathComponent("Catalog")
    )
    try? store.save(fixture.catalog)
    return ManagedDictionaryRemovalCoordinator(
        catalog: fixture.catalog,
        catalogStore: store,
        applicationSupportRootURL: fixture.root,
        queryService: ManagedDictionaryQueryService(catalog: fixture.catalog,
                                                    runtime: runtime),
        isIndexing: isIndexing,
        hooks: hooks,
        saveCatalog: saveCatalog
    )
}

@MainActor
private func testSuccessfulRemoval(base: URL) async throws {
    let fixture = try removalFixture(base: base, suffix: "21")
    let originalBytes = try Data(contentsOf: fixture.originalSource)
    let noteBytes = try Data(contentsOf: fixture.note)
    let runtime = MockRuntime()
    let value = coordinator(for: fixture, runtime: runtime)
    let result = await value.remove(dictionaryID: fixture.descriptor.dictionaryID)
    try expect(
        result == .removed(cleanupDeferred: false),
        "managed removal should succeed, got \(String(describing: result))"
    )
    try expect(!FileManager.default.fileExists(atPath: fixture.managedDirectory.path) &&
               !FileManager.default.fileExists(atPath: fixture.pendingDirectory.path),
               "managed files and staging should be removed")
    try expect(try Data(contentsOf: fixture.originalSource) == originalBytes,
               "original import source must remain untouched")
    try expect(try Data(contentsOf: fixture.note) == noteBytes,
               "saved note snapshot must remain untouched")
    try expect(!value.catalog.dictionaries.contains {
        $0.dictionaryID == fixture.descriptor.dictionaryID
    }, "descriptor should be removed")
    try expect(value.catalog.dictionaries.first?.sortPosition == 1,
               "remaining positions should be compact")
    let runtimeState = await runtime.snapshot()
    try expect(runtimeState.removed == [fixture.descriptor.dictionaryID],
               "target runtime should be released before removal")
}

@MainActor
private func testRemovalGuardsAndRollback(base: URL) async throws {
    let indexing = try removalFixture(base: base, suffix: "22", state: .indexing)
    let indexingResult = await coordinator(for: indexing, runtime: MockRuntime())
        .remove(dictionaryID: indexing.descriptor.dictionaryID)
    try expect(indexingResult == .failed(.indexingInProgress),
               "indexing dictionary must not be removed")
    try expect(FileManager.default.fileExists(atPath: indexing.managedDirectory.path),
               "indexing guard must keep files")

    let rollback = try removalFixture(base: base, suffix: "23")
    let value = coordinator(
        for: rollback, runtime: MockRuntime(),
        saveCatalog: { _ in throw SmokeError.failed("catalog failure") }
    )
    let rollbackResult = await value.remove(dictionaryID: rollback.descriptor.dictionaryID)
    try expect(rollbackResult == .failed(.catalogWriteFailed),
               "catalog failure should be reported")
    try expect(FileManager.default.fileExists(atPath: rollback.managedDirectory.path) &&
               !FileManager.default.fileExists(atPath: rollback.pendingDirectory.path),
               "catalog failure should restore managed directory")
    try expect(value.catalog == rollback.catalog,
               "catalog failure should preserve catalog")

    let legacy = descriptor(id: "legacy", sourceKind: .legacyReference,
                            level: .preferred, position: 1)
    let legacyCatalog = catalog([legacy])
    let store = DictionaryCatalogStore(directoryURL: base.appendingPathComponent("legacy-catalog"))
    let legacyCoordinator = ManagedDictionaryRemovalCoordinator(
        catalog: legacyCatalog, catalogStore: store,
        applicationSupportRootURL: base.appendingPathComponent("legacy-root"),
        queryService: ManagedDictionaryQueryService(catalog: legacyCatalog,
                                                    runtime: MockRuntime()),
        isIndexing: { _ in false }
    )
    try expect(await legacyCoordinator.remove(dictionaryID: "legacy") ==
               .failed(.notManagedLocal), "legacy references must never be removed")
}

@MainActor
private func testRemovalEarlyReturnRetry(base: URL) async throws {
    func makeCoordinator(_ initial: DictionaryCatalog, fixture: RemovalFixture,
                         indexing: @escaping (String) -> Bool = { _ in false }) throws
        -> (ManagedDictionaryRemovalCoordinator, DictionaryCatalogStore) {
        let store = DictionaryCatalogStore(directoryURL: fixture.root.appendingPathComponent("retry-catalog"))
        try store.save(initial)
        let service = ManagedDictionaryQueryService(catalog: initial, runtime: MockRuntime())
        return (ManagedDictionaryRemovalCoordinator(
            catalog: initial, catalogStore: store, applicationSupportRootURL: fixture.root,
            queryService: service, isIndexing: indexing
        ), store)
    }

    let missing = try removalFixture(base: base, suffix: "34")
    let (missingCoordinator, missingStore) = try makeCoordinator(.empty(now: fixedDate), fixture: missing)
    try expect(await missingCoordinator.remove(dictionaryID: missing.descriptor.dictionaryID) ==
               .failed(.dictionaryNotFound), "missing descriptor returns its precise error")
    try expect(!missingCoordinator.isRemoving(missing.descriptor.dictionaryID),
               "dictionaryNotFound must clear active removal state")
    try missingStore.save(missing.catalog)
    missingCoordinator.synchronize(catalog: missing.catalog)
    try expect(await missingCoordinator.remove(dictionaryID: missing.descriptor.dictionaryID) ==
               .removed(cleanupDeferred: false), "missing descriptor retry must not be blocked")

    let ownership = try removalFixture(base: base, suffix: "35")
    let legacy = descriptor(id: ownership.descriptor.dictionaryID, sourceKind: .legacyReference,
                            level: .preferred, position: 1)
    let (ownershipCoordinator, ownershipStore) = try makeCoordinator(catalog([legacy]), fixture: ownership)
    try expect(await ownershipCoordinator.remove(dictionaryID: ownership.descriptor.dictionaryID) ==
               .failed(.notManagedLocal), "ownership guard returns its precise error")
    try expect(!ownershipCoordinator.isRemoving(ownership.descriptor.dictionaryID),
               "ownership guard must clear active removal state")
    try ownershipStore.save(ownership.catalog)
    ownershipCoordinator.synchronize(catalog: ownership.catalog)
    try expect(await ownershipCoordinator.remove(dictionaryID: ownership.descriptor.dictionaryID) ==
               .removed(cleanupDeferred: false), "ownership guard retry must not be blocked")

    let indexing = try removalFixture(base: base, suffix: "36", state: .indexing)
    let (indexingCoordinator, indexingStore) = try makeCoordinator(indexing.catalog, fixture: indexing)
    try expect(await indexingCoordinator.remove(dictionaryID: indexing.descriptor.dictionaryID) ==
               .failed(.indexingInProgress), "indexing guard returns its precise error")
    try expect(!indexingCoordinator.isRemoving(indexing.descriptor.dictionaryID),
               "indexing guard must clear active removal state")
    var ready = indexing.catalog
    guard let readyIndex = ready.dictionaries.firstIndex(where: { $0.dictionaryID == indexing.descriptor.dictionaryID }) else {
        throw SmokeError.failed("indexing retry fixture")
    }
    ready.dictionaries[readyIndex] = descriptor(
        id: indexing.descriptor.dictionaryID,
        position: indexing.descriptor.sortPosition,
        state: .ready
    )
    try indexingStore.save(ready)
    indexingCoordinator.synchronize(catalog: ready)
    try expect(await indexingCoordinator.remove(dictionaryID: indexing.descriptor.dictionaryID) ==
               .removed(cleanupDeferred: false), "indexing guard retry must not be blocked")
}

private func testRecoveryAndPathSafety(base: URL) throws {
    let fixture = try removalFixture(base: base, suffix: "24")
    let worker = ManagedDictionaryRemovalWorker(applicationSupportRootURL: fixture.root)
    let plan = try worker.makePlan(for: fixture.descriptor)
    try worker.stage(plan)
    let restored = worker.recoverPendingDeletions(catalog: fixture.catalog)
    try expect(restored.restoredDictionaryIDs == [fixture.descriptor.dictionaryID] &&
               FileManager.default.fileExists(atPath: fixture.managedDirectory.path),
               "catalog-owned pending directory should recover")

    let cleanup = try removalFixture(base: base, suffix: "25")
    let cleanupWorker = ManagedDictionaryRemovalWorker(applicationSupportRootURL: cleanup.root)
    let cleanupPlan = try cleanupWorker.makePlan(for: cleanup.descriptor)
    try cleanupWorker.stage(cleanupPlan)
    let cleaned = cleanupWorker.recoverPendingDeletions(catalog: .empty(now: fixedDate))
    try expect(cleaned.cleanedDictionaryIDs == [cleanup.descriptor.dictionaryID] &&
               !FileManager.default.fileExists(atPath: cleanup.pendingDirectory.path),
               "orphan pending directory should be cleaned")

    var unsafe = fixture.descriptor
    let invalidPaths = [
        "/tmp/unsafe.mdx",
        "Dictionaries/\(unsafe.dictionaryID)/../unsafe.mdx",
        "Dictionaries/00000000-0000-0000-0000-000000000099/dictionary.mdx",
        "Dictionaries/\(unsafe.dictionaryID)/deeper/path/dictionary.mdx"
    ]
    for path in invalidPaths {
        unsafe.relativePaths.dictionary = path
        do {
            _ = try worker.makePlan(for: unsafe)
            throw SmokeError.failed("unsafe path should fail: \(path)")
        } catch ManagedDictionaryRemovalError.unsafeManagedPath {}
    }

    let symlinkID = "00000000-0000-0000-0000-000000000026"
    let symlinkRoot = base.appendingPathComponent("symlink-root")
    let external = base.appendingPathComponent("external-managed", isDirectory: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try Data("outside".utf8).write(to: external.appendingPathComponent("dictionary.mdx"))
    try FileManager.default.createDirectory(
        at: symlinkRoot.appendingPathComponent("Dictionaries"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: symlinkRoot.appendingPathComponent("Dictionaries/\(symlinkID)"),
        withDestinationURL: external
    )
    let escaping = descriptor(id: symlinkID, position: 1)
    do {
        _ = try ManagedDictionaryRemovalWorker(
            applicationSupportRootURL: symlinkRoot
        ).makePlan(for: escaping)
        throw SmokeError.failed("symlink escape should fail")
    } catch ManagedDictionaryRemovalError.unsafeManagedPath {}
}

private func testRemovalIdentityRaces(base: URL) throws {
#if OWNED_LIFECYCLE_TESTING
    let stageFixture = try removalFixture(base: base, suffix: "28")
    let worker = ManagedDictionaryRemovalWorker(applicationSupportRootURL: stageFixture.root)
    let stagePlan: ManagedDictionaryRemovalPlan
    do {
        stagePlan = try worker.makePlan(for: stageFixture.descriptor)
    } catch { throw SmokeError.failed("stage fixture plan: \(error)") }
    let retained = stageFixture.root.appendingPathComponent("retained-stage", isDirectory: true)
    ManagedDictionaryRemovalTestObserver.beforeRenameBinding = { phase, _ in
        guard phase == .stage else { return }
        guard Darwin.rename(stageFixture.managedDirectory.path, retained.path) == 0,
              Darwin.mkdir(stageFixture.managedDirectory.path, 0o700) == 0 else {
            throw SmokeError.failed("stage substitution setup")
        }
    }
    do {
        try worker.stage(stagePlan)
        throw SmokeError.failed("stage substitution must fail closed")
    } catch ManagedDictionaryRemovalError.removalStageIdentityMismatch {}
    ManagedDictionaryRemovalTestObserver.beforeRenameBinding = nil
    try expect(FileManager.default.fileExists(atPath: retained.path) &&
               FileManager.default.fileExists(atPath: stageFixture.managedDirectory.path) &&
               !FileManager.default.fileExists(atPath: stageFixture.pendingDirectory.path),
               "stage substitution must preserve both directories without publishing pending")

    let rollbackFixture = try removalFixture(base: base, suffix: "29")
    let rollbackWorker = ManagedDictionaryRemovalWorker(applicationSupportRootURL: rollbackFixture.root)
    let rollbackPlan: ManagedDictionaryRemovalPlan
    do {
        rollbackPlan = try rollbackWorker.makePlan(for: rollbackFixture.descriptor)
    } catch { throw SmokeError.failed("rollback fixture plan: \(error)") }
    do {
        try rollbackWorker.stage(rollbackPlan)
    } catch {
        throw SmokeError.failed("rollback fixture stage: \(error)")
    }
    let retainedPending = rollbackFixture.root.appendingPathComponent("retained-pending", isDirectory: true)
    ManagedDictionaryRemovalTestObserver.beforeRenameBinding = { phase, _ in
        guard phase == .rollback else { return }
        guard Darwin.rename(rollbackFixture.pendingDirectory.path, retainedPending.path) == 0,
              Darwin.mkdir(rollbackFixture.pendingDirectory.path, 0o700) == 0 else {
            throw SmokeError.failed("rollback substitution setup")
        }
    }
    do {
        try rollbackWorker.rollback(rollbackPlan)
        throw SmokeError.failed("rollback substitution must fail closed")
    } catch ManagedDictionaryRemovalError.removalRollbackIdentityMismatch {}
    ManagedDictionaryRemovalTestObserver.beforeRenameBinding = nil
    try expect(FileManager.default.fileExists(atPath: retainedPending.path) &&
               FileManager.default.fileExists(atPath: rollbackFixture.pendingDirectory.path) &&
               !FileManager.default.fileExists(atPath: rollbackFixture.managedDirectory.path),
               "rollback substitution must preserve pending objects")

    let conflictFixture = try removalFixture(base: base, suffix: "30")
    let conflictWorker = ManagedDictionaryRemovalWorker(applicationSupportRootURL: conflictFixture.root)
    let conflictPlan: ManagedDictionaryRemovalPlan
    do {
        conflictPlan = try conflictWorker.makePlan(for: conflictFixture.descriptor)
    } catch { throw SmokeError.failed("conflict fixture plan: \(error)") }
    do {
        try conflictWorker.stage(conflictPlan)
    } catch {
        throw SmokeError.failed("conflict fixture stage: \(error)")
    }
    try FileManager.default.createDirectory(at: conflictFixture.managedDirectory,
                                            withIntermediateDirectories: false)
    do {
        try conflictWorker.rollback(conflictPlan)
        throw SmokeError.failed("rollback target conflict must fail")
    } catch ManagedDictionaryRemovalError.rollbackFailed {}
    try expect(FileManager.default.fileExists(atPath: conflictFixture.pendingDirectory.path),
               "rollback conflict must retain pending object")
#endif
}

@MainActor
private func testCoordinatorStageFailureDisposition(base: URL) async throws {
#if OWNED_LIFECYCLE_TESTING
    defer {
        ManagedDictionaryRemovalTestObserver.beforeRenameBinding = nil
        ManagedDictionaryRemovalTestObserver.afterRenameBeforeIdentityConfirmation = nil
        ManagedDictionaryRemovalTestObserver.runtimeDisposition = nil
    }

    let substitution = try removalFixture(base: base, suffix: "31")
    let substitutionStore = DictionaryCatalogStore(
        directoryURL: substitution.root.appendingPathComponent("Catalog")
    )
    try substitutionStore.save(substitution.catalog)
    let substitutionRuntime = MockRuntime()
    let substitutionService = ManagedDictionaryQueryService(
        catalog: substitution.catalog, runtime: substitutionRuntime
    )
    let substitutionCoordinator = ManagedDictionaryRemovalCoordinator(
        catalog: substitution.catalog,
        catalogStore: substitutionStore,
        applicationSupportRootURL: substitution.root,
        queryService: substitutionService,
        isIndexing: { _ in false }
    )
    let substitutionDisposition = RuntimeDispositionSpy()
    let retained = substitution.root.appendingPathComponent("retained-coordinator-stage")
    ManagedDictionaryRemovalTestObserver.runtimeDisposition = { resumed in
        substitutionDisposition.record(resumed)
    }
    ManagedDictionaryRemovalTestObserver.beforeRenameBinding = { phase, _ in
        guard phase == .stage else { return }
        guard Darwin.rename(substitution.managedDirectory.path, retained.path) == 0,
              Darwin.mkdir(substitution.managedDirectory.path, 0o700) == 0 else {
            throw SmokeError.failed("coordinator stage substitution setup")
        }
    }
    let substitutionResult = await substitutionCoordinator.remove(
        dictionaryID: substitution.descriptor.dictionaryID
    )
    try expect(substitutionResult == .failed(
        .stageFailureRuntimeRemainsSuspended(.removalStageIdentityMismatch)
    ), "coordinator stage substitution must report suspended identity failure")
    try expect(substitutionCoordinator.catalog == substitution.catalog,
               "stage substitution must preserve Catalog descriptor")
    try expect(substitutionStore.load() == substitution.catalog,
               "stage substitution must preserve durable Catalog")
    try expect(substitutionDisposition.snapshot() == [false],
               "stage substitution must not resume runtime")
    let blocked = await substitutionService.lookup("synthetic")
    let blockedAgain = await substitutionService.lookup("synthetic")
    try expect(!blocked.hits.contains { $0.dictionaryID == substitution.descriptor.dictionaryID } &&
               !blockedAgain.hits.contains { $0.dictionaryID == substitution.descriptor.dictionaryID },
               "stage substitution must keep the target dictionary suspended")
    try expect(!(await substitutionRuntime.snapshot()).queried
                    .contains(substitution.descriptor.dictionaryID),
               "suspended target dictionary must not invoke runtime lookup")
    try expect(FileManager.default.fileExists(atPath: retained.path) &&
               FileManager.default.fileExists(atPath: substitution.managedDirectory.path) &&
               !FileManager.default.fileExists(atPath: substitution.pendingDirectory.path),
               "stage substitution must preserve original and replacement without PendingDeletion")

    ManagedDictionaryRemovalTestObserver.beforeRenameBinding = nil
    ManagedDictionaryRemovalTestObserver.runtimeDisposition = nil

    let benign = try removalFixture(base: base, suffix: "32")
    let benignStore = DictionaryCatalogStore(
        directoryURL: benign.root.appendingPathComponent("Catalog")
    )
    try benignStore.save(benign.catalog)
    let benignRuntime = MockRuntime()
    let benignService = ManagedDictionaryQueryService(catalog: benign.catalog,
                                                      runtime: benignRuntime)
    let benignCoordinator = ManagedDictionaryRemovalCoordinator(
        catalog: benign.catalog,
        catalogStore: benignStore,
        applicationSupportRootURL: benign.root,
        queryService: benignService,
        isIndexing: { _ in false }
    )
    let benignDisposition = RuntimeDispositionSpy()
    ManagedDictionaryRemovalTestObserver.runtimeDisposition = { resumed in
        benignDisposition.record(resumed)
    }
    ManagedDictionaryRemovalTestObserver.beforeRenameBinding = { phase, _ in
        guard phase == .stage else { return }
        throw SmokeError.failed("benign pre-rename stage failure")
    }
    let benignResult = await benignCoordinator.remove(dictionaryID: benign.descriptor.dictionaryID)
    try expect(benignResult == .failed(.stagingFailed),
               "benign pre-rename failure must preserve its primary error")
    try expect(benignCoordinator.catalog == benign.catalog &&
               benignStore.load() == benign.catalog,
               "benign pre-rename failure must preserve Catalog")
    try expect(benignDisposition.snapshot() == [true],
               "matching final identity must resume runtime exactly once")
    let resumed = await benignService.lookup("synthetic")
    try expect(resumed.hits.count == 2,
               "matching final identity must restore managed query eligibility")
    try expect((await benignRuntime.snapshot()).queried.count == 2,
               "safe resume must reach both eligible runtime dictionaries")

    ManagedDictionaryRemovalTestObserver.beforeRenameBinding = nil
    ManagedDictionaryRemovalTestObserver.runtimeDisposition = nil

    let postPublish = try removalFixture(base: base, suffix: "33")
    let postPublishStore = DictionaryCatalogStore(
        directoryURL: postPublish.root.appendingPathComponent("Catalog")
    )
    try postPublishStore.save(postPublish.catalog)
    let postPublishRuntime = MockRuntime()
    let postPublishService = ManagedDictionaryQueryService(
        catalog: postPublish.catalog, runtime: postPublishRuntime
    )
    let postPublishCoordinator = ManagedDictionaryRemovalCoordinator(
        catalog: postPublish.catalog,
        catalogStore: postPublishStore,
        applicationSupportRootURL: postPublish.root,
        queryService: postPublishService,
        isIndexing: { _ in false }
    )
    let postPublishDisposition = RuntimeDispositionSpy()
    let retainedPending = postPublish.root.appendingPathComponent("retained-post-publish")
    ManagedDictionaryRemovalTestObserver.runtimeDisposition = { resumed in
        postPublishDisposition.record(resumed)
    }
    ManagedDictionaryRemovalTestObserver.afterRenameBeforeIdentityConfirmation = { phase, _ in
        guard phase == .stage else { return }
        guard Darwin.rename(postPublish.pendingDirectory.path, retainedPending.path) == 0,
              Darwin.mkdir(postPublish.pendingDirectory.path, 0o700) == 0 else {
            throw SmokeError.failed("post-publish substitution setup")
        }
    }
    let postPublishResult = await postPublishCoordinator.remove(
        dictionaryID: postPublish.descriptor.dictionaryID
    )
    try expect(postPublishResult == .failed(
        .stageFailureRuntimeRemainsSuspended(.filesystemPublishedButIdentityUnconfirmed)
    ), "post-publish identity uncertainty must remain suspended")
    try expect(postPublishCoordinator.catalog == postPublish.catalog &&
               postPublishStore.load() == postPublish.catalog,
               "post-publish uncertainty must preserve Catalog")
    try expect(postPublishDisposition.snapshot() == [false],
               "post-publish uncertainty must not resume runtime")
    try expect(!(await postPublishService.lookup("synthetic")).hits.contains {
        $0.dictionaryID == postPublish.descriptor.dictionaryID
    }, "post-publish uncertainty must block the target managed query")
    try expect(FileManager.default.fileExists(atPath: retainedPending.path) &&
               FileManager.default.fileExists(atPath: postPublish.pendingDirectory.path),
               "post-publish uncertainty must preserve both pending objects")
#endif
}

@MainActor
private func testDeferredCleanupRecovery(base: URL) async throws {
    let fixture = try removalFixture(base: base, suffix: "27")
    let hooks = ManagedDictionaryRemovalHooks(removeItem: { _ in
        throw SmokeError.failed("injected cleanup failure")
    })
    let value = coordinator(for: fixture, runtime: MockRuntime(), hooks: hooks)
    let result = await value.remove(dictionaryID: fixture.descriptor.dictionaryID)
    try expect(result == .removed(cleanupDeferred: true),
               "cleanup failure should defer without restoring catalog entry")
    try expect(FileManager.default.fileExists(atPath: fixture.pendingDirectory.path),
               "deferred cleanup should retain staged directory")
    let report = ManagedDictionaryRemovalWorker(
        applicationSupportRootURL: fixture.root
    ).recoverPendingDeletions(catalog: value.catalog)
    try expect(report.cleanedDictionaryIDs == [fixture.descriptor.dictionaryID] &&
               !FileManager.default.fileExists(atPath: fixture.pendingDirectory.path),
               "next launch should clean orphan staging")
}

@main
struct DictionaryOrderingRemovalSmoke {
    @MainActor
    static func main() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-B4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try testOrderingAndPersistence(root: base.appendingPathComponent("ordering"))
        try testRestoreDefaultsAndAdapter()
        try testLegacyRegistrationRetirement(
            base: base.appendingPathComponent("legacy-retirement")
        )
        try await testQueryOrderingAndStaleResultProtection()
        try await testSuccessfulRemoval(base: base)
        try await testRemovalGuardsAndRollback(base: base)
        try await testRemovalEarlyReturnRetry(base: base)
        try testRecoveryAndPathSafety(base: base)
        try testRemovalIdentityRaces(base: base)
        try await testCoordinatorStageFailureDisposition(base: base)
        try await testDeferredCleanupRecovery(base: base)
        print("Dictionary ordering/removal smoke: PASS " +
              "(\(runtimeAssertions.current()) total runtime assertions)")
    }
}
