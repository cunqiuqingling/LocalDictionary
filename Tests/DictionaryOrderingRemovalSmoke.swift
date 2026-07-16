import Foundation

private enum SmokeError: Error { case failed(String) }

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw SmokeError.failed(message) }
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
    DictionaryDescriptor(
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
        formatterIdentifier: sourceKind == .managedLocal
            ? DictionaryFormatterIdentifier.genericMDictV1 : "legacy.v1",
        capabilities: .unknown,
        relativePaths: sourceKind == .managedLocal
            ? DictionaryRelativePaths(
                dictionary: "Dictionaries/\(id)/dictionary.mdx",
                resources: [],
                index: "Dictionaries/\(id)/index/dictionary.sqlite"
            ) : .empty,
        createdAt: createdAt,
        updatedAt: fixedDate
    )
}

private func catalog(_ dictionaries: [DictionaryDescriptor]) -> DictionaryCatalog {
    DictionaryCatalog(schemaVersion: DictionaryCatalog.currentSchemaVersion,
                      createdAt: fixedDate, updatedAt: fixedDate,
                      dictionaries: dictionaries)
}

private func orderedIDs(_ value: DictionaryCatalog,
                        level: DictionaryQueryLevel) -> [String] {
    value.sortedDictionaries.filter { $0.queryLevel == level }.map(\.dictionaryID)
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
        descriptor(id: "f2", sourceKind: .openResource,
                   level: .fallback, position: 2),
        descriptor(id: "f1", sourceKind: .openResource,
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
    updated = try DictionaryCatalogOrdering.moving("f2", direction: .up,
                                                   in: coordinator.catalog)
    _ = try coordinator.save(updated)
    let reloaded = store.load()
    try expect(orderedIDs(reloaded, level: .preferred) == ["p2", "p1"],
               "preferred order should persist")
    try expect(orderedIDs(reloaded, level: .normal) == normal.map(\.dictionaryID),
               "normal order should persist")
    try expect(orderedIDs(reloaded, level: .fallback) == ["f2", "f1"],
               "fallback order should persist")

    do {
        _ = try DictionaryCatalogOrdering.moving("p2", toDisplayedRow: 3, in: reloaded)
        throw SmokeError.failed("cross-level drag must fail")
    } catch DictionaryCatalogOrderingError.crossLevelMove {}
    try expect(!DictionaryCatalogOrdering.canMove("p2", direction: .up, in: reloaded),
               "group first must not move up")
    try expect(!DictionaryCatalogOrdering.canMove("p1", direction: .down, in: reloaded),
               "group last must not move down")

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

private actor MockRuntime: ManagedDictionaryQueryRuntime {
    private var queried: [String] = []
    private var removed: [String] = []

    func lookup(descriptor: DictionaryDescriptor,
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
    func reset() {}
    func snapshot() -> (queried: [String], removed: [String]) { (queried, removed) }
}

private actor DeferredRuntime: ManagedDictionaryQueryRuntime {
    private var lookupStarted = false
    private var mayFinish = false
    private var removed: [String] = []

    func lookup(descriptor: DictionaryDescriptor,
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
    let staleService = ManagedDictionaryQueryService(catalog: catalog([first]),
                                                     runtime: deferred)
    let task = Task { await staleService.lookup("prompt") }
    while !(await deferred.hasStarted()) { await Task.yield() }
    await staleService.suspend(dictionaryID: first.dictionaryID)
    await deferred.finish()
    let staleBatch = await task.value
    try expect(staleBatch.hits.isEmpty,
               "result completing after suspension must be discarded")
    try expect(await deferred.removedIDs() == [first.dictionaryID],
               "suspension should release only the target runtime")
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
    try expect(result == .removed(cleanupDeferred: false), "managed removal should succeed")
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
        try await testQueryOrderingAndStaleResultProtection()
        try await testSuccessfulRemoval(base: base)
        try await testRemovalGuardsAndRollback(base: base)
        try testRecoveryAndPathSafety(base: base)
        try await testDeferredCleanupRecovery(base: base)
        print("Dictionary ordering/removal smoke: PASS")
    }
}
