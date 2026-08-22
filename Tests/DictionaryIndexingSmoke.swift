import CryptoKit
import Darwin
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

    func next(source: DictionaryIndexSourceCapability,
              request: DictionaryIndexBuildRequest,
              token: DictionaryIndexCancellationToken) -> DictionaryIndexBuildOutcome {
        let builder = builders.withLock { builders in
            builders.isEmpty ? nil : builders.removeFirst()
        }
        return builder?(source, request, token) ?? .failure("测试 Builder 已耗尽。")
    }
}

private func syntheticSourceOpener(
    onOpen: (@Sendable (String) -> Void)? = nil
) -> DictionaryIndexSourceOpenFunction {
    { root, relativePath, expectedSize, expectedSHA256, token in
        if token.isCancelled { throw CancellationError() }
        onOpen?(relativePath)
        let url = root.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let digest = sha256(data)
        guard UInt64(data.count) == expectedSize,
              digest == expectedSHA256 else {
            throw DictionaryIndexError.sourceChanged
        }
        return DictionaryIndexSourceCapability(
            sourceFileSize: UInt64(data.count),
            sourceSHA256: digest,
            storage: data as NSData,
            validation: {
                guard let current = try? Data(contentsOf: url) else { return false }
                return UInt64(current.count) == expectedSize &&
                    sha256(current) == expectedSHA256
            }
        )
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

private final class SyntheticCandidateState: @unchecked Sendable {
    let candidate: URL
    let final: URL
    var current: URL

    init(candidate: URL, final: URL) {
        self.candidate = candidate
        self.final = final
        current = candidate
    }
}

private let syntheticCandidateFactory: DictionaryIndexCandidateFactory = { plan in
    let candidate = plan.indexDirectoryURL.appendingPathComponent(plan.candidateName)
    let final = plan.indexDirectoryURL.appendingPathComponent(plan.finalName)
    guard FileManager.default.createFile(
        atPath: candidate.path, contents: Data(), attributes: [.posixPermissions: 0o600]
    ) else {
        throw DictionaryIndexError.candidateCreationFailed
    }
    let state = SyntheticCandidateState(candidate: candidate, final: final)
    return DictionaryIndexCandidateCapability(
        publicationID: plan.publicationID,
        candidateIndexURL: candidate,
        finalName: plan.finalName,
        storage: state,
        seal: { expectedCount in
            var database: OpaquePointer?
            guard sqlite3_open_v2(
                candidate.path, &database,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
            ) == SQLITE_OK, let database else {
                if let database { sqlite3_close(database) }
                throw DictionaryIndexError.invalidSQLite
            }
            defer { sqlite3_close(database) }
            guard sqliteText(database, "PRAGMA integrity_check") == "ok" else {
                throw DictionaryIndexError.integrityCheckFailed
            }
            guard sqliteText(database,
                    "SELECT value FROM metadata WHERE key='schema_version' LIMIT 1"
                  ) == String(plan.expectedSchemaVersion),
                  sqliteText(database, "SELECT COUNT(*) FROM entries") ==
                    String(expectedCount) else {
                throw DictionaryIndexError.indexIdentityMismatch
            }
            let data = try Data(contentsOf: candidate)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: candidate.path
            )
            return DictionaryIndexSealResult(
                entryCount: expectedCount,
                indexFileSize: UInt64(data.count),
                indexSHA256: sha256(data)
            )
        },
        publish: {
            guard candidate.path.withCString({ source in
                final.path.withCString { destination in
                    Darwin.renameatx_np(
                        AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_EXCL)
                    )
                }
            }) == 0 else {
                throw DictionaryIndexError.publicationFailed
            }
            state.current = final
        },
        discard: { try? FileManager.default.removeItem(at: state.current) },
        commit: {}
    )
}

private func sqliteText(_ database: OpaquePointer, _ sql: String) -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let text = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: text)
}

private func validBuilder(entries: Int = 3) -> DictionaryIndexBuildFunction {
    { _, request, token in
        let indexURL = request.candidateIndexURL
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
    { source, request, token in
        let outcome = validBuilder()(source, request, token)
        guard case .success = outcome else { return outcome }
        guard let handle = try? FileHandle(
            forWritingTo: request.candidateIndexURL
        ) else {
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
        openSource: @escaping DictionaryIndexSourceOpenFunction =
            syntheticSourceOpener(),
        capacity: UInt64 = UInt64.max,
        lifecycleCoordinator: ManagedDictionaryLifecycleCoordinator =
            ManagedDictionaryLifecycleCoordinator(),
        runtimeInvalidator: @escaping @Sendable (String) async -> Void = { _ in }
    ) -> ManagedDictionaryIndexCoordinator {
        ManagedDictionaryIndexCoordinator(
            catalog: catalog,
            catalogStore: catalogStore,
            applicationSupportRootURL: root,
            openSource: openSource,
            buildIndex: builder,
            createCandidate: syntheticCandidateFactory,
            expectedSchemaVersion: 1,
            hooks: DictionaryIndexingHooks(
                availableCapacity: { _ in capacity },
                beforePublish: {}
            ), lifecycleCoordinator: lifecycleCoordinator,
            runtimeInvalidator: runtimeInvalidator
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
    try expect(
        descriptor.state == .ready,
        "successful index should become ready: " +
            (coordinator.failureMessage(for: fixture.dictionaryID) ?? "no failure")
    )
    try expect(descriptor.indexMetadata.entryCount == 4, "entry count should be validated")
    try expect(descriptor.indexMetadata.schemaVersion == 1, "schema should be recorded")
    try expect(descriptor.indexMetadata.indexFileSize ?? 0 > 0, "index size should be recorded")
    try expect(descriptor.relativePaths.index?.hasPrefix(
        "Dictionaries/\(fixture.dictionaryID)/index/dictionary."
    ) == true && descriptor.relativePaths.index?.hasSuffix(".sqlite") == true,
               "Catalog index path must be versioned and relative")
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
    let coordinator = fixture.coordinator(builder: { source, request, token in
        scripted.next(source: source, request: request, token: token)
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
        openSource: syntheticSourceOpener(),
        buildIndex: blockingBuilder(),
        createCandidate: syntheticCandidateFactory,
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
private func testPlanUsesLatestDescriptorAfterPermit() async throws {
    let fixture = try Fixture(name: "latest-plan")
    defer { fixture.cleanup() }
    var active = fixture.descriptor
    active.state = .ready
    let activeCatalog = DictionaryCatalog(schemaVersion: DictionaryCatalog.currentSchemaVersion,
                                         createdAt: active.createdAt, updatedAt: active.updatedAt,
                                         dictionaries: [active])
    let lifecycle = ManagedDictionaryLifecycleCoordinator(catalog: activeCatalog)
    let observedSource = Mutex<String?>(nil)
    let opener = syntheticSourceOpener { relativePath in
        observedSource.withLock { $0 = relativePath }
    }
    let coordinator = fixture.coordinator(
        builder: validBuilder(entries: 2),
        openSource: opener,
        lifecycleCoordinator: lifecycle
    )
    let activeLease = try await lifecycle.acquireQueryLease(for: fixture.dictionaryID)
    try expect(coordinator.start(dictionaryID: fixture.dictionaryID) == .started,
               "index should queue behind the active lease")
    while await lifecycle.snapshot(for: fixture.dictionaryID)?.phase != .draining {
        await Task.yield()
    }

    let replacementURL = fixture.root.appendingPathComponent(
        "Dictionaries/\(fixture.dictionaryID)/source/replacement.mdx"
    )
    let replacementData = Data("replacement-index-source".utf8)
    try replacementData.write(to: replacementURL)
    var replacement = fixture.descriptor
    replacement.relativePaths.dictionary =
        "Dictionaries/\(fixture.dictionaryID)/source/replacement.mdx"
    replacement.indexMetadata.sourceFileSize = UInt64(replacementData.count)
    replacement.indexMetadata.sourceSHA256 = sha256(replacementData)
    replacement.updatedAt = replacement.updatedAt.addingTimeInterval(1)
    let replacementCatalog = DictionaryCatalog(
        schemaVersion: DictionaryCatalog.currentSchemaVersion,
        createdAt: replacement.createdAt, updatedAt: replacement.updatedAt,
        dictionaries: [replacement]
    )
    try fixture.catalogStore.save(replacementCatalog)
    coordinator.synchronize(catalog: replacementCatalog)
    await lifecycle.initialize(reconciledCatalog: replacementCatalog)
    await lifecycle.release(activeLease)
    try await waitUntilIdle(coordinator)
    try expect(observedSource.withLock { $0 } ==
               replacement.relativePaths.dictionary,
               "index plan must be created from descriptor B after permit acquisition")
    try expect(coordinator.catalog.dictionaries.first?.indexMetadata.sourceSHA256 == sha256(replacementData),
               "ready Catalog must retain descriptor B source identity")

    let deletion = try Fixture(name: "deleted-plan")
    defer { deletion.cleanup() }
    var deletionActive = deletion.descriptor
    deletionActive.state = .ready
    let deletionLifecycle = ManagedDictionaryLifecycleCoordinator(catalog: DictionaryCatalog(
        schemaVersion: DictionaryCatalog.currentSchemaVersion,
        createdAt: deletionActive.createdAt, updatedAt: deletionActive.updatedAt,
        dictionaries: [deletionActive]
    ))
    let buildCount = Mutex(0)
    let deletionCoordinator = deletion.coordinator(builder: { source, request, token in
        buildCount.withLock { $0 += 1 }
        return validBuilder()(source, request, token)
    }, lifecycleCoordinator: deletionLifecycle)
    let deletionLease = try await deletionLifecycle.acquireQueryLease(for: deletion.dictionaryID)
    try expect(deletionCoordinator.start(dictionaryID: deletion.dictionaryID) == .started,
               "deleted-plan index should queue")
    while await deletionLifecycle.snapshot(for: deletion.dictionaryID)?.phase != .draining {
        await Task.yield()
    }
    let empty = DictionaryCatalog.empty(now: Date(timeIntervalSince1970: 1_700_000_001))
    try deletion.catalogStore.save(empty)
    deletionCoordinator.synchronize(catalog: empty)
    await deletionLifecycle.initialize(reconciledCatalog: empty)
    await deletionLifecycle.release(deletionLease)
    try await waitUntilIdle(deletionCoordinator)
    try expect(buildCount.withLock { $0 } == 0,
               "deleted descriptor must not build or publish an index after permit wait")
    try expect(deletionCoordinator.catalog.dictionaries.isEmpty,
               "deleted descriptor must not be moved to indexing")
}

@MainActor
private func testDisabledReadyPublishesSuspended() async throws {
    let fixture = try Fixture(name: "disabled-ready")
    defer { fixture.cleanup() }
    var disabled = fixture.descriptor
    disabled.enabled = false
    let disabledCatalog = DictionaryCatalog(schemaVersion: DictionaryCatalog.currentSchemaVersion,
                                            createdAt: disabled.createdAt,
                                            updatedAt: disabled.updatedAt,
                                            dictionaries: [disabled])
    try fixture.catalogStore.save(disabledCatalog)
    let lifecycle = ManagedDictionaryLifecycleCoordinator(catalog: disabledCatalog)
    let coordinator = ManagedDictionaryIndexCoordinator(
        catalog: disabledCatalog,
        catalogStore: fixture.catalogStore,
        applicationSupportRootURL: fixture.root,
        openSource: syntheticSourceOpener(),
        buildIndex: validBuilder(entries: 2),
        createCandidate: syntheticCandidateFactory,
        expectedSchemaVersion: 1,
        hooks: DictionaryIndexingHooks(availableCapacity: { _ in UInt64.max }, beforePublish: {}),
        lifecycleCoordinator: lifecycle
    )
    try expect(coordinator.start(dictionaryID: fixture.dictionaryID) == .started,
               "disabled descriptor may build an index without becoming query available")
    try await waitUntilIdle(coordinator)
    try expect(coordinator.catalog.dictionaries.first?.state == .ready,
               "disabled descriptor retains ready index state")
    let disabledSnapshot = await lifecycle.snapshot(for: fixture.dictionaryID)
    try expect(disabledSnapshot?.phase == .suspended,
               "disabled ready descriptor must publish suspended lifecycle disposition")
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
private func testCapabilityRevalidatedBeforePublication() async throws {
    let fixture = try Fixture(name: "capability-publication-gate")
    defer { fixture.cleanup() }
    let validationCalls = Mutex(0)
    let opener: DictionaryIndexSourceOpenFunction = {
        _, _, expectedSize, expectedDigest, _ in
        DictionaryIndexSourceCapability(
            sourceFileSize: expectedSize,
            sourceSHA256: expectedDigest,
            validation: {
                validationCalls.withLock {
                    $0 += 1
                    return $0 <= 4
                }
            }
        )
    }
    let lifecycle = ManagedDictionaryLifecycleCoordinator(catalog: fixture.catalog)
    let coordinator = fixture.coordinator(
        builder: validBuilder(entries: 2),
        openSource: opener,
        lifecycleCoordinator: lifecycle
    )
    try expect(coordinator.start(dictionaryID: fixture.dictionaryID) == .started,
               "capability publication gate should start")
    try await waitUntilIdle(coordinator)
    try expect(validationCalls.withLock { $0 } >= 5,
               "source capability was not revalidated in finish")
    try expect(coordinator.catalog.dictionaries.first?.state == .failed,
               "post-build source rebind incorrectly committed ready Catalog")
    let final = fixture.root.appendingPathComponent(
        "Dictionaries/\(fixture.dictionaryID)/index/dictionary.sqlite")
    try expect(!FileManager.default.fileExists(atPath: final.path),
               "post-build source rebind published final candidate")
    let lifecycleState = await lifecycle.snapshot(for: fixture.dictionaryID)
    try expect(lifecycleState?.phase == .suspended,
               "post-build source rebind restored query availability")
}

@MainActor
private func testSourceOpensBeforeRuntimeInvalidation() async throws {
    let fixture = try Fixture(name: "source-before-invalidation")
    defer { fixture.cleanup() }
    let events = Mutex<[String]>([])
    let opener = syntheticSourceOpener { _ in
        events.withLock { $0.append("source") }
    }
    let builder: DictionaryIndexBuildFunction = { source, request, token in
        events.withLock { $0.append("build") }
        return validBuilder(entries: 2)(source, request, token)
    }
    let coordinator = fixture.coordinator(
        builder: builder,
        openSource: opener,
        runtimeInvalidator: { _ in
            events.withLock { $0.append("invalidate") }
        }
    )
    try expect(coordinator.start(dictionaryID: fixture.dictionaryID) == .started,
               "source ordering fixture should start")
    try await waitUntilIdle(coordinator)
    try expect(events.withLock { $0 } == ["source", "invalidate", "build"],
               "source capability must precede invalidation and parser build")
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
        openSource: syntheticSourceOpener(),
        buildIndex: validBuilder(entries: 2),
        createCandidate: syntheticCandidateFactory,
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
        openSource: syntheticSourceOpener(),
        buildIndex: validBuilder(entries: 2),
        createCandidate: syntheticCandidateFactory,
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
        openSource: syntheticSourceOpener(),
        buildIndex: validBuilder(entries: 2),
        createCandidate: syntheticCandidateFactory,
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
    try expect(plan.sourceRelativePath == ready.relativePaths.dictionary,
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
        try await testPlanUsesLatestDescriptorAfterPermit()
        try await testDisabledReadyPublishesSuspended()
        try await testValidationFailures()
        try await testFailurePreservesExistingIndex()
        try await testCapabilityRevalidatedBeforePublication()
        try await testSourceOpensBeforeRuntimeInvalidation()
        try testInterruptedRecovery()
        try await testOwnershipPolicyEligibility()
        try await testB1B2B3Compatibility()
        print("Dictionary indexing smoke: PASS")
    }
}
