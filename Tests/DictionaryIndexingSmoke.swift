import CryptoKit
import Foundation
import SQLite3
import Synchronization

private enum SmokeFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self { case .assertion(let message): return message }
    }
}

private func expect(_ condition: @autoclosure () -> Bool,
                    _ message: String) throws {
    if !condition() { throw SmokeFailure.assertion(message) }
}

private final class ScriptedBuilder: Sendable {
    private let builders: Mutex<[DictionaryIndexBuildFunction]>

    init(_ builders: [DictionaryIndexBuildFunction]) {
        self.builders = Mutex(builders)
    }

    func next(source: URL, index: URL,
              token: DictionaryIndexCancellationToken) -> DictionaryIndexBuildOutcome {
        let builder = builders.withLock { builders in
            builders.isEmpty ? nil : builders.removeFirst()
        }
        return builder?(source, index, token) ?? .failure("测试 Builder 已耗尽。")
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func execute(_ database: OpaquePointer, _ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? "sqlite error"
        sqlite3_free(message)
        throw SmokeFailure.assertion(detail)
    }
}

private func validBuilder(entries: Int = 3) -> DictionaryIndexBuildFunction {
    { _, indexURL, token in
        if token.isCancelled { return .cancelled }
        var database: OpaquePointer?
        guard sqlite3_open_v2(indexURL.path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let database else { return .failure("无法创建测试索引。") }
        defer { sqlite3_close(database) }
        do {
            try execute(database, "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute(database, "CREATE TABLE entries (id INTEGER PRIMARY KEY, headword TEXT NOT NULL COLLATE BINARY, folded TEXT NOT NULL COLLATE BINARY, record_start INTEGER NOT NULL, record_end INTEGER NOT NULL)")
            try execute(database, "INSERT INTO metadata(key,value) VALUES('schema_version','1'),('entry_count','\(entries)')")
            for index in 0..<entries {
                try execute(database, "INSERT INTO entries(headword,folded,record_start,record_end) VALUES('word\(index)','word\(index)',\(index),\(index + 1))")
            }
            return token.isCancelled ? .cancelled
                : .success(DictionaryIndexBuildProduct(reportedEntryCount: UInt64(entries)))
        } catch {
            return .failure("无法创建测试索引。")
        }
    }
}

private func invalidIntegrityBuilder() -> DictionaryIndexBuildFunction {
    { source, index, token in
        let outcome = validBuilder()(source, index, token)
        guard case .success = outcome else { return outcome }
        guard let handle = try? FileHandle(forWritingTo: index) else {
            return .failure("无法损坏测试索引。")
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: 4_096)
        try? handle.write(contentsOf: Data(repeating: 0xff, count: 256))
        try? handle.synchronize()
        return .success(DictionaryIndexBuildProduct(reportedEntryCount: 3))
    }
}

private func blockingBuilder() -> DictionaryIndexBuildFunction {
    { _, _, token in
        while !token.isCancelled { usleep(2_000) }
        return .cancelled
    }
}

@MainActor
private struct Fixture {
    let root: URL
    let catalogStore: DictionaryCatalogStore
    let dictionaryID: String
    let sourceURL: URL
    let descriptor: DictionaryDescriptor

    init(name: String, state: DictionaryState = .pendingIndex,
         digestOverride: String? = nil,
         sourceAtManagedRoot: Bool = false,
         formatterIdentifier: String = DictionaryFormatterIdentifier.genericMDictV1) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-B2-\(name)-\(UUID().uuidString)",
                                    isDirectory: true)
        dictionaryID = UUID().uuidString.lowercased()
        let sourceRelativePath = sourceAtManagedRoot
            ? "Dictionaries/\(dictionaryID)/test.mdx"
            : "Dictionaries/\(dictionaryID)/source/test.mdx"
        sourceURL = root.appendingPathComponent(sourceRelativePath)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = Data("generated-b2-fixture-\(name)".utf8)
        try data.write(to: sourceURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        descriptor = DictionaryDescriptor(
            dictionaryID: dictionaryID,
            displayName: "Generated B2 Fixture",
            sourceKind: .managedLocal,
            queryLevel: .normal,
            sortPosition: 50,
            enabled: true,
            state: state,
            indexMetadata: DictionaryIndexMetadata(
                schemaVersion: nil,
                entryCount: nil,
                indexFileSize: nil,
                sourceFileSize: UInt64(data.count),
                sourceModifiedAt: now,
                sourceSHA256: digestOverride ?? sha256(data),
                indexedAt: nil
            ),
            formatterIdentifier: formatterIdentifier,
            capabilities: .unknown,
            relativePaths: DictionaryRelativePaths(
                dictionary: sourceRelativePath,
                resources: [], index: nil
            ),
            createdAt: now,
            updatedAt: now
        )
        catalogStore = DictionaryCatalogStore(directoryURL: root.appendingPathComponent("Catalog"))
        // R1 writers always reload the latest durable Catalog inside the mutation lock.
        // A fixture therefore establishes its initial synthetic Catalog before indexing starts.
        try catalogStore.save(catalog)
    }

    var catalog: DictionaryCatalog {
        DictionaryCatalog(schemaVersion: DictionaryCatalog.currentSchemaVersion,
                          createdAt: descriptor.createdAt,
                          updatedAt: descriptor.updatedAt,
                          dictionaries: [descriptor])
    }

    func coordinator(
        builder: @escaping DictionaryIndexBuildFunction,
        capacity: UInt64 = UInt64.max,
        lifecycleCoordinator: ManagedDictionaryLifecycleCoordinator =
            ManagedDictionaryLifecycleCoordinator()
    ) -> ManagedDictionaryIndexCoordinator {
        ManagedDictionaryIndexCoordinator(
            catalog: catalog,
            catalogStore: catalogStore,
            applicationSupportRootURL: root,
            buildIndex: builder,
            expectedSchemaVersion: 1,
            hooks: DictionaryIndexingHooks(
                availableCapacity: { _ in capacity },
                beforePublish: {}
            ), lifecycleCoordinator: lifecycleCoordinator
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private func waitUntilIdle(_ coordinator: ManagedDictionaryIndexCoordinator,
                           timeout: Duration = .seconds(3)) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while coordinator.activity != nil && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try expect(coordinator.activity == nil, "index task timed out")
}

@MainActor
private func testSuccessfulStateMachine() async throws {
    let fixture = try Fixture(name: "success")
    defer { fixture.cleanup() }
    try fixture.catalogStore.save(fixture.catalog)
    let coordinator = fixture.coordinator(builder: validBuilder(entries: 4))
    try expect(coordinator.start(dictionaryID: fixture.dictionaryID) == .started,
               "pendingIndex should start")
    try await waitUntilIdle(coordinator)
    let descriptor = coordinator.catalog.dictionaries[0]
    try expect(descriptor.state == .ready, "successful index should become ready")
    try expect(descriptor.indexMetadata.entryCount == 4, "entry count should be validated")
    try expect(descriptor.indexMetadata.schemaVersion == 1, "schema should be recorded")
    try expect(descriptor.indexMetadata.indexFileSize ?? 0 > 0, "index size should be recorded")
    try expect(descriptor.relativePaths.index ==
               "Dictionaries/\(fixture.dictionaryID)/index/dictionary.sqlite",
               "Catalog index path must be relative")
    try expect(!(descriptor.relativePaths.index?.hasPrefix("/") ?? true),
               "Catalog must not store an absolute index path")
    try expect(fixture.catalogStore.load().dictionaries.first?.state == .ready,
               "ready Catalog must remain decodable after atomic save")
    var database: OpaquePointer?
    let finalURL = fixture.root.appendingPathComponent(descriptor.relativePaths.index!)
    try expect(sqlite3_open_v2(finalURL.path, &database,
                               SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
               "published SQLite should open read-only")
    if let database { sqlite3_close(database) }
}

@MainActor
private func testFailureAndRetry() async throws {
    let fixture = try Fixture(name: "retry")
    defer { fixture.cleanup() }
    let scripted = ScriptedBuilder([
        { _, _, _ in .failure("测试构建失败。") }, validBuilder(entries: 2)
    ])
    let coordinator = fixture.coordinator(builder: { source, index, token in
        scripted.next(source: source, index: index, token: token)
    })
    try expect(coordinator.start(dictionaryID: fixture.dictionaryID) == .started,
               "failed test should start")
    try await waitUntilIdle(coordinator)
    try expect(coordinator.catalog.dictionaries[0].state == .failed,
               "builder failure should become failed")
    try expect(fixture.catalogStore.load().dictionaries.first?.state == .failed,
               "failed state must leave a valid Catalog")
    try expect(coordinator.start(dictionaryID: fixture.dictionaryID) == .started,
               "failed state should retry")
    try await waitUntilIdle(coordinator)
    try expect(coordinator.catalog.dictionaries[0].state == .ready,
               "retry should become ready")
}

@MainActor
private func testCancellationAndConcurrency() async throws {
    let first = try Fixture(name: "cancel")
    defer { first.cleanup() }
    var catalog = first.catalog
    let secondID = UUID().uuidString.lowercased()
    var second = first.descriptor
    second.dictionaryID = secondID
    second.relativePaths.dictionary = "Dictionaries/\(secondID)/source/test.mdx"
    second.sortPosition = 51
    let secondSource = first.root.appendingPathComponent(second.relativePaths.dictionary!)
    try FileManager.default.createDirectory(at: secondSource.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let data = try Data(contentsOf: first.sourceURL)
    try data.write(to: secondSource)
    catalog.dictionaries.append(second)
    let coordinator = ManagedDictionaryIndexCoordinator(
        catalog: catalog,
        catalogStore: first.catalogStore,
        applicationSupportRootURL: first.root,
        buildIndex: blockingBuilder(),
        expectedSchemaVersion: 1,
        hooks: DictionaryIndexingHooks(availableCapacity: { _ in UInt64.max },
                                       beforePublish: {})
    )
    try expect(coordinator.start(dictionaryID: first.dictionaryID) == .started,
               "first index should start")
    try expect(coordinator.start(dictionaryID: secondID) == .busy,
               "second index must not run concurrently")
    coordinator.cancel(dictionaryID: first.dictionaryID)
    try await waitUntilIdle(coordinator)
    try expect(coordinator.catalog.dictionaries[0].state == .pendingIndex,
               "cancel should return to pendingIndex")
    try expect(first.catalogStore.load().dictionaries.first?.state == .pendingIndex,
               "cancel must leave a valid pendingIndex Catalog")
    let final = first.root.appendingPathComponent(
        "Dictionaries/\(first.dictionaryID)/index/dictionary.sqlite")
    try expect(!FileManager.default.fileExists(atPath: final.path),
               "cancel must not publish final SQLite")
}

@MainActor
private func testPermitBeforeIndexingCatalogMutation() async throws {
    let fixture = try Fixture(name: "permit-before-index")
    defer { fixture.cleanup() }
    var activeDescriptor = fixture.descriptor
    activeDescriptor.state = .ready
    let lifecycle = ManagedDictionaryLifecycleCoordinator(catalog: DictionaryCatalog(
        schemaVersion: DictionaryCatalog.currentSchemaVersion,
        createdAt: activeDescriptor.createdAt, updatedAt: activeDescriptor.updatedAt,
        dictionaries: [activeDescriptor]
    ))
    let coordinator = fixture.coordinator(builder: blockingBuilder(), lifecycleCoordinator: lifecycle)
    let activeLease = try await lifecycle.acquireQueryLease(for: fixture.dictionaryID)
    try expect(coordinator.start(dictionaryID: fixture.dictionaryID) == .started,
               "permit-first index should start")
    while await lifecycle.snapshot(for: fixture.dictionaryID)?.phase != .draining {
        await Task.yield()
    }
    try expect(coordinator.catalog.dictionaries[0].state == .pendingIndex,
               "Catalog must remain pending until the index permit is acquired")
    await lifecycle.release(activeLease)
    while coordinator.catalog.dictionaries[0].state != .indexing {
        await Task.yield()
    }
    let indexingSnapshot = await lifecycle.snapshot(for: fixture.dictionaryID)
    try expect(indexingSnapshot?.phase == .exclusive,
               "index Catalog mutation occurs while the exclusive permit is held")
    coordinator.cancel(dictionaryID: fixture.dictionaryID)
    try await waitUntilIdle(coordinator)
    try expect(coordinator.catalog.dictionaries[0].state == .pendingIndex,
               "cancelled permit-first index returns to pendingIndex")
}

@MainActor
private func testValidationFailures() async throws {
    let integrity = try Fixture(name: "integrity")
    defer { integrity.cleanup() }
    var coordinator = integrity.coordinator(builder: invalidIntegrityBuilder())
    _ = coordinator.start(dictionaryID: integrity.dictionaryID)
    try await waitUntilIdle(coordinator)
    try expect(coordinator.catalog.dictionaries[0].state == .failed,
               "integrity failure must not become ready")
    try expect((coordinator.failureMessage(for: integrity.dictionaryID) ?? "")
        .contains("完整性"), "integrity_check failure should be classified explicitly")

    let mismatch = try Fixture(name: "sha", digestOverride: String(repeating: "0", count: 64))
    defer { mismatch.cleanup() }
    coordinator = mismatch.coordinator(builder: validBuilder())
    _ = coordinator.start(dictionaryID: mismatch.dictionaryID)
    try await waitUntilIdle(coordinator)
    try expect(coordinator.catalog.dictionaries[0].state == .failed,
               "SHA mismatch must fail")
    try expect(!(coordinator.failureMessage(for: mismatch.dictionaryID) ?? "")
        .contains(mismatch.root.path), "errors must not expose absolute paths")

    let missing = try Fixture(name: "missing")
    defer { missing.cleanup() }
    try FileManager.default.removeItem(at: missing.sourceURL)
    coordinator = missing.coordinator(builder: validBuilder())
    _ = coordinator.start(dictionaryID: missing.dictionaryID)
    try await waitUntilIdle(coordinator)
    try expect(coordinator.catalog.dictionaries[0].state == .failed,
               "missing source must fail safely")

    let space = try Fixture(name: "space")
    defer { space.cleanup() }
    coordinator = space.coordinator(builder: validBuilder(), capacity: 0)
    _ = coordinator.start(dictionaryID: space.dictionaryID)
    try await waitUntilIdle(coordinator)
    try expect(coordinator.catalog.dictionaries[0].state == .failed,
               "insufficient space must fail before building")
}

@MainActor
private func testFailurePreservesExistingIndex() async throws {
    let fixture = try Fixture(name: "preserve", state: .failed)
    defer { fixture.cleanup() }
    let final = fixture.root.appendingPathComponent(
        "Dictionaries/\(fixture.dictionaryID)/index/dictionary.sqlite")
    try FileManager.default.createDirectory(at: final.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let previous = Data("previous-valid-index-marker".utf8)
    try previous.write(to: final)
    let coordinator = fixture.coordinator(builder: { _, _, _ in .failure("测试失败。") })
    _ = coordinator.start(dictionaryID: fixture.dictionaryID)
    try await waitUntilIdle(coordinator)
    let preserved = try Data(contentsOf: final)
    try expect(preserved == previous,
               "failed build must not overwrite an existing final index")
}

@MainActor
private func testInterruptedRecovery() throws {
    let fixture = try Fixture(name: "interrupted", state: .indexing)
    defer { fixture.cleanup() }
    let candidate = fixture.root.appendingPathComponent(
        "Dictionaries/\(fixture.dictionaryID)/index/dictionary.sqlite.building")
    try FileManager.default.createDirectory(at: candidate.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("unfinished".utf8).write(to: candidate)
    let coordinator = fixture.coordinator(builder: validBuilder())
    let recovered = coordinator.recoverInterruptedTasks(in: fixture.catalog)
    try expect(recovered.dictionaries[0].state == .pendingIndex,
               "interrupted state must recover to pendingIndex")
    try expect(recovered.dictionaries[0].relativePaths.index == nil,
               "unfinished candidate must not be treated as ready")
}

@MainActor
private func testOwnershipPolicyEligibility() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalDictionary-B2-OpenResource-\(UUID().uuidString)",
                                isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dictionaryID = UUID().uuidString.lowercased()
    let relativeSource = "Dictionaries/\(dictionaryID)/payload.mdx"
    let source = root.appendingPathComponent(relativeSource)
    try FileManager.default.createDirectory(
        at: source.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let bytes = Data("synthetic-open-resource-index".utf8)
    try bytes.write(to: source)
    let checksum = sha256(bytes)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let metadata = OpenResourceInstallationMetadata(
        resourceID: "synthetic-index-resource",
        resourceRevision: 1,
        resourceVersion: "1.0",
        manifestVersion: 1,
        manifestSHA256: String(repeating: "a", count: 64),
        verifiedKeyID: "test-key",
        payloadSHA256: checksum,
        payloadBytes: UInt64(bytes.count),
        sidecarRelativePath:
            "Dictionaries/\(dictionaryID)/resource-installation.json",
        languages: ["en"],
        license: OpenResourceLicenseMetadata(
            name: "Synthetic", version: "1",
            url: "https://example.test/license", attribution: "Synthetic"
        ),
        sourceProject: "https://example.test/project",
        officialPageReference: "https://example.test/page",
        expectedEntryCount: OpenResourceEntryCountMetadata(minimum: 1, maximum: 2),
        installedAt: now
    )
    let descriptor = DictionaryDescriptor(
        dictionaryID: dictionaryID,
        displayName: "Synthetic Open Resource",
        sourceKind: .openResource,
        queryLevel: .fallback,
        sortPosition: 1,
        enabled: false,
        state: .pendingIndex,
        indexMetadata: DictionaryIndexMetadata(
            schemaVersion: nil, entryCount: nil, indexFileSize: nil,
            sourceFileSize: UInt64(bytes.count), sourceModifiedAt: now,
            sourceSHA256: checksum, indexedAt: nil
        ),
        formatterIdentifier: DictionaryFormatterIdentifier.genericMDictV1,
        capabilities: .unknown,
        relativePaths: DictionaryRelativePaths(
            dictionary: relativeSource, resources: [], index: nil
        ),
        createdAt: now,
        updatedAt: now,
        storageOwnership: .appManagedOpenResource,
        openResourceMetadata: metadata
    )
    let catalog = DictionaryCatalog(
        schemaVersion: DictionaryCatalog.currentSchemaVersion,
        createdAt: now,
        updatedAt: now,
        dictionaries: [descriptor]
    )
    let store = DictionaryCatalogStore(
        directoryURL: root.appendingPathComponent("Catalog")
    )
    try store.save(catalog)
    let coordinator = ManagedDictionaryIndexCoordinator(
        catalog: catalog,
        catalogStore: store,
        applicationSupportRootURL: root,
        buildIndex: validBuilder(entries: 2),
        expectedSchemaVersion: 1,
        hooks: DictionaryIndexingHooks(
            availableCapacity: { _ in UInt64.max }, beforePublish: {}
        )
    )
    try expect(coordinator.start(dictionaryID: dictionaryID) == .started,
               "appManagedOpenResource should enter managed indexing")
    try await waitUntilIdle(coordinator)
    try expect(coordinator.catalog.dictionaries.first?.state == .ready,
               "appManagedOpenResource index should become ready")

    var external = descriptor
    external.sourceKind = .externalReference
    external.storageOwnership = .externalReference
    external.openResourceMetadata = nil
    let externalCatalog = DictionaryCatalog(
        schemaVersion: DictionaryCatalog.currentSchemaVersion,
        createdAt: now,
        updatedAt: now,
        dictionaries: [external]
    )
    let externalCoordinator = ManagedDictionaryIndexCoordinator(
        catalog: externalCatalog,
        catalogStore: store,
        applicationSupportRootURL: root,
        buildIndex: validBuilder(entries: 2),
        expectedSchemaVersion: 1
    )
    if case .unavailable = externalCoordinator.start(dictionaryID: dictionaryID) {
        // Expected.
    } else {
        throw SmokeFailure.assertion("externalReference entered managed indexing")
    }
}

@MainActor
private func testB1B2B3Compatibility() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalDictionary-B1-B2-B3-\(UUID().uuidString)",
                                isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("fixture/imported.mdx")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let bytes = Data("generated-b1-import-fixture".utf8)
    try bytes.write(to: source)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let preview = DictionaryImportPreview(
        sourceMDXURL: source,
        displayName: "B1 Imported Fixture",
        originalFileName: source.lastPathComponent,
        mdxFileSize: UInt64(bytes.count),
        sourceModifiedAt: now,
        header: MDictHeaderSummary(title: "B1 Imported Fixture",
                                   engineVersion: "2.0", encoding: "UTF-8",
                                   compression: .compressed, isEncrypted: false),
        mdxSHA256: sha256(bytes),
        mddCandidates: [],
        automaticallySelectedMDDIDs: []
    )
    let store = DictionaryCatalogStore(directoryURL:
        root.appendingPathComponent("Catalog", isDirectory: true))
    let fixedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!
    let importService = DictionaryImportService(
        dictionariesRootURL: root.appendingPathComponent("Dictionaries", isDirectory: true),
        catalogStore: store,
        hooks: DictionaryImportServiceHooks(
            availableCapacity: { _ in UInt64.max },
            beforeCopy: { _ in },
            beforePublish: {}
        ),
        identifierProvider: { fixedID }
    )
    var imported = try await importService.importSelections(
        [DictionaryImportSelection(preview: preview, selectedMDDIDs: [])],
        into: .empty(now: now),
        now: now
    )
    try expect(imported.dictionaries[0].relativePaths.dictionary ==
               "Dictionaries/\(fixedID.uuidString.lowercased())/imported.mdx",
               "B1 must publish the managed MDX at the UUID root")
    imported.dictionaries[0].formatterIdentifier =
        DictionaryFormatterIdentifier.legacyGenericMDictV1
    try store.save(imported)

    let coordinator = ManagedDictionaryIndexCoordinator(
        catalog: imported,
        catalogStore: store,
        applicationSupportRootURL: root,
        buildIndex: validBuilder(entries: 2),
        expectedSchemaVersion: 1,
        hooks: DictionaryIndexingHooks(availableCapacity: { _ in UInt64.max },
                                       beforePublish: {})
    )
    try expect(coordinator.start(dictionaryID: fixedID.uuidString.lowercased()) == .started,
               "persisted B1 descriptor should enter B2 indexing")
    try await waitUntilIdle(coordinator)
    let ready = coordinator.catalog.dictionaries[0]
    try expect(ready.state == .ready, "B1 descriptor should become B2 ready")
    let plan = try ManagedDictionaryRuntimeValidator(
        applicationSupportRootURL: root,
        expectedSchemaVersion: 1
    ).validate(ready)
    try expect(plan.dictionaryID == fixedID.uuidString.lowercased(),
               "B1 root layout and legacy formatter should pass B3 validation")
    try expect(plan.sourceURL.standardizedFileURL ==
               root.appendingPathComponent(ready.relativePaths.dictionary!).standardizedFileURL,
               "B3 validation must preserve the imported B1 managed MDX location")
}

@main
@MainActor
struct DictionaryIndexingSmoke {
    static func main() async throws {
        try await testSuccessfulStateMachine()
        try await testFailureAndRetry()
        try await testCancellationAndConcurrency()
        try await testPermitBeforeIndexingCatalogMutation()
        try await testValidationFailures()
        try await testFailurePreservesExistingIndex()
        try testInterruptedRecovery()
        try await testOwnershipPolicyEligibility()
        try await testB1B2B3Compatibility()
        print("Dictionary indexing smoke: PASS")
    }
}
