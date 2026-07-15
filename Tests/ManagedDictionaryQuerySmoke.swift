import CryptoKit
import Foundation
import SQLite3

private enum SmokeError: Error { case failed(String) }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeError.failed(message) }
}

private actor MockManagedRuntime: ManagedDictionaryQueryRuntime {
    var outcomes: [String: ManagedDictionaryRuntimeOutcome]
    private var queriedIDs: [String] = []
    private var resetCount = 0

    init(outcomes: [String: ManagedDictionaryRuntimeOutcome]) {
        self.outcomes = outcomes
    }

    func lookup(descriptor: DictionaryDescriptor,
                query: String) async -> ManagedDictionaryRuntimeOutcome {
        queriedIDs.append(descriptor.dictionaryID)
        return outcomes[descriptor.dictionaryID] ?? .miss
    }

    func reset() { resetCount += 1 }

    func snapshot() -> ([String], Int) { (queriedIDs, resetCount) }
}

private func descriptor(id: String, position: Int64, enabled: Bool = true,
                        state: DictionaryState = .ready,
                        level: DictionaryQueryLevel = .normal,
                        formatterIdentifier: String =
                            DictionaryFormatterIdentifier.genericMDictV1)
    -> DictionaryDescriptor {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return DictionaryDescriptor(
        dictionaryID: id,
        displayName: "Managed \(id)",
        sourceKind: .managedLocal,
        queryLevel: level,
        sortPosition: position,
        enabled: enabled,
        state: state,
        indexMetadata: DictionaryIndexMetadata(
            schemaVersion: 1, entryCount: 1, indexFileSize: 1,
            sourceFileSize: 1, sourceModifiedAt: now,
            sourceSHA256: String(repeating: "0", count: 64), indexedAt: now
        ),
        formatterIdentifier: formatterIdentifier,
        capabilities: .unknown,
        relativePaths: DictionaryRelativePaths(
            dictionary: "Dictionaries/\(id)/source/test.mdx",
            resources: [],
            index: "Dictionaries/\(id)/index/dictionary.sqlite"
        ),
        createdAt: now,
        updatedAt: now
    )
}

private func hit(id: String) -> ManagedDictionaryQueryHit {
    ManagedDictionaryQueryHit(
        dictionaryID: id,
        displayName: "Managed \(id)",
        matchedHeadword: "prompt",
        blocks: [GenericMDictBlock(
            kind: .paragraph,
            level: 0,
            runs: [GenericMDictTextRun(text: "安全中文释义", bold: false,
                                       italic: false, code: false)]
        )],
        plainText: "安全中文释义",
        truncated: false
    )
}

private func catalog(_ dictionaries: [DictionaryDescriptor]) -> DictionaryCatalog {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return DictionaryCatalog(schemaVersion: 1, createdAt: now,
                             updatedAt: now, dictionaries: dictionaries)
}

private func execute(_ database: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw SmokeError.failed("sqlite fixture failed")
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private enum ManagedSourceLayout {
    case root
    case sourceDirectory

    func relativePath(dictionaryID: String) -> String {
        switch self {
        case .root: return "Dictionaries/\(dictionaryID)/test.mdx"
        case .sourceDirectory: return "Dictionaries/\(dictionaryID)/source/test.mdx"
        }
    }
}

private func validatedFixture(root: URL, schema: Int = 1,
                              digestOverride: String? = nil,
                              id: String = "00000000-0000-0000-0000-000000000001",
                              layout: ManagedSourceLayout = .sourceDirectory,
                              formatterIdentifier: String =
                                DictionaryFormatterIdentifier.genericMDictV1)
    throws -> DictionaryDescriptor {
    let sourcePath = layout.relativePath(dictionaryID: id)
    let source = root.appendingPathComponent(sourcePath)
    let index = root.appendingPathComponent("Dictionaries/\(id)/index/dictionary.sqlite")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: index.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let bytes = Data("synthetic-mdx-placeholder".utf8)
    try bytes.write(to: source)
    var database: OpaquePointer?
    guard sqlite3_open(index.path, &database) == SQLITE_OK, let database else {
        throw SmokeError.failed("sqlite open failed")
    }
    try execute(database, "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    try execute(database, "INSERT INTO metadata VALUES('schema_version','\(schema)')")
    sqlite3_close(database)
    let sourceSize = UInt64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
    let indexSize = UInt64(try index.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return DictionaryDescriptor(
        dictionaryID: id,
        displayName: "Synthetic Managed",
        sourceKind: .managedLocal,
        queryLevel: .normal,
        sortPosition: 0,
        enabled: true,
        state: .ready,
        indexMetadata: DictionaryIndexMetadata(
            schemaVersion: 1, entryCount: 1, indexFileSize: indexSize,
            sourceFileSize: sourceSize, sourceModifiedAt: now,
            sourceSHA256: digestOverride ?? digest(bytes), indexedAt: now
        ),
        formatterIdentifier: formatterIdentifier,
        capabilities: .unknown,
        relativePaths: DictionaryRelativePaths(
            dictionary: sourcePath, resources: [],
            index: "Dictionaries/\(id)/index/dictionary.sqlite"
        ),
        createdAt: now,
        updatedAt: now
    )
}

private func testRoutingAndStateFiltering() async throws {
    let first = descriptor(id: "b", position: 0)
    let second = descriptor(id: "a", position: 0)
    let disabled = descriptor(id: "disabled", position: -2, enabled: false)
    let pending = descriptor(id: "pending", position: -1, state: .pendingIndex)
    let failed = descriptor(id: "failed", position: -1, state: .failed)
    let fallback = descriptor(id: "fallback", position: -3, level: .fallback)
    let legacy = descriptor(
        id: "c", position: 0,
        formatterIdentifier: DictionaryFormatterIdentifier.legacyGenericMDictV1
    )
    var unsupportedFormatter = descriptor(id: "unsupported", position: -4)
    unsupportedFormatter.formatterIdentifier = "dictionary-specific-formatter"
    let runtime = MockManagedRuntime(outcomes: [
        "a": .hit(hit(id: "a")), "b": .unavailable,
        "c": .hit(hit(id: "c")),
        "disabled": .hit(hit(id: "disabled")), "pending": .hit(hit(id: "pending")),
        "failed": .hit(hit(id: "failed")), "fallback": .hit(hit(id: "fallback")),
        "unsupported": .hit(hit(id: "unsupported"))
    ])
    let service = ManagedDictionaryQueryService(
        catalog: catalog([first, second, legacy, disabled, pending, failed, fallback,
                          unsupportedFormatter]),
        runtime: runtime
    )
    let skipped = await service.lookup("prompt", preferredMatched: true)
    try expect(skipped.skippedBecausePreferredMatched && skipped.hits.isEmpty,
               "preferred hit must skip managed dictionaries")
    let skippedSnapshot = await runtime.snapshot()
    try expect(skippedSnapshot.0.isEmpty,
               "preferred hit must not call managed runtime")

    let batch = await service.lookup("prompt")
    try expect(batch.hits.map(\.dictionaryID) == ["a", "c"],
               "canonical and legacy formatter identifiers should both query")
    try expect(batch.unavailableDictionaryIDs == ["b"], "single failure should be isolated")
    let queried = await runtime.snapshot().0
    try expect(queried == ["a", "b", "c"],
               "stable sort and state filters must be applied")
    try expect(!queried.contains("disabled") && !queried.contains("pending") &&
               !queried.contains("failed") && !queried.contains("fallback") &&
               !queried.contains("unsupported"),
               "ineligible dictionaries must never be queried")

    await service.replaceCatalog(catalog([second]))
    let replacedSnapshot = await runtime.snapshot()
    try expect(replacedSnapshot.1 == 1, "catalog replacement should reset runtimes")
}

private func testRuntimeValidationAndReadOnlySQLite() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalDictionary-B3-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptor = try validatedFixture(root: root)
    let indexURL = root.appendingPathComponent(descriptor.relativePaths.index!)
    let before = try Data(contentsOf: indexURL)
    let validator = ManagedDictionaryRuntimeValidator(
        applicationSupportRootURL: root, expectedSchemaVersion: 1
    )
    let plan = try validator.validate(descriptor)
    try expect(plan.dictionaryID == descriptor.dictionaryID, "valid runtime plan expected")
    let after = try Data(contentsOf: indexURL)
    try expect(after == before,
               "runtime validation must not modify SQLite")

    let legacyID = "00000000-0000-0000-0000-000000000002"
    let legacyRootDescriptor = try validatedFixture(
        root: root,
        id: legacyID,
        layout: .root,
        formatterIdentifier: DictionaryFormatterIdentifier.legacyGenericMDictV1
    )
    let legacyPlan = try validator.validate(legacyRootDescriptor)
    try expect(legacyPlan.sourceURL.lastPathComponent == "test.mdx",
               "B1 root MDX with legacy formatter should validate")

    var unknownFormatter = legacyRootDescriptor
    unknownFormatter.formatterIdentifier = "unknown-formatter"
    do {
        _ = try validator.validate(unknownFormatter)
        throw SmokeError.failed("unknown formatter must be rejected")
    } catch ManagedDictionaryRuntimeValidationError.ineligible {}

    var mismatch = descriptor
    mismatch.indexMetadata.sourceSHA256 = String(repeating: "f", count: 64)
    do {
        _ = try validator.validate(mismatch)
        throw SmokeError.failed("SHA mismatch must fail")
    } catch ManagedDictionaryRuntimeValidationError.sourceChanged {}

    let wrongRoot = root.appendingPathComponent("wrong-schema")
    let wrongSchema = try validatedFixture(root: wrongRoot, schema: 2)
    do {
        _ = try ManagedDictionaryRuntimeValidator(
            applicationSupportRootURL: wrongRoot, expectedSchemaVersion: 1
        ).validate(wrongSchema)
        throw SmokeError.failed("schema mismatch must fail")
    } catch ManagedDictionaryRuntimeValidationError.schemaMismatch {}

    var absolute = descriptor
    absolute.relativePaths.dictionary = "/tmp/unsafe.mdx"
    do {
        _ = try validator.validate(absolute)
        throw SmokeError.failed("absolute path must fail")
    } catch ManagedDictionaryRuntimeValidationError.unsafePath {}

    var traversal = descriptor
    traversal.relativePaths.dictionary =
        "Dictionaries/\(descriptor.dictionaryID)/source/../test.mdx"
    do {
        _ = try validator.validate(traversal)
        throw SmokeError.failed("parent traversal must fail")
    } catch ManagedDictionaryRuntimeValidationError.unsafePath {}

    var otherDictionary = descriptor
    otherDictionary.relativePaths.dictionary =
        "Dictionaries/00000000-0000-0000-0000-000000000099/source/test.mdx"
    do {
        _ = try validator.validate(otherDictionary)
        throw SmokeError.failed("other dictionary UUID path must fail")
    } catch ManagedDictionaryRuntimeValidationError.unsafePath {}

    var fileURL = descriptor
    fileURL.relativePaths.dictionary = "file:///tmp/unsafe.mdx"
    do {
        _ = try validator.validate(fileURL)
        throw SmokeError.failed("file URL must fail")
    } catch ManagedDictionaryRuntimeValidationError.unsafePath {}

    let external = root.appendingPathComponent("outside.mdx")
    try Data("outside-managed-root".utf8).write(to: external)
    let symlink = root.appendingPathComponent(
        "Dictionaries/\(descriptor.dictionaryID)/escape.mdx"
    )
    try FileManager.default.createSymbolicLink(at: symlink,
                                               withDestinationURL: external)
    var escapingSymlink = descriptor
    escapingSymlink.relativePaths.dictionary =
        "Dictionaries/\(descriptor.dictionaryID)/escape.mdx"
    do {
        _ = try validator.validate(escapingSymlink)
        throw SmokeError.failed("escaping symlink must fail")
    } catch ManagedDictionaryRuntimeValidationError.unsafePath {}

    var unsafeIndex = descriptor
    unsafeIndex.relativePaths.index = "/tmp/unsafe.sqlite"
    do {
        _ = try validator.validate(unsafeIndex)
        throw SmokeError.failed("absolute index path must fail")
    } catch ManagedDictionaryRuntimeValidationError.unsafePath {}

    try FileManager.default.removeItem(at: plan.sourceURL)
    do {
        _ = try validator.validate(descriptor)
        throw SmokeError.failed("missing source must fail")
    } catch ManagedDictionaryRuntimeValidationError.missingFile {}
}

private func testSafeCollectionSnapshot() throws {
    let id = "00000000-0000-0000-0000-000000000099"
    let source = StructuredDictionarySource(
        phonetics: [], partsOfSpeech: [],
        definitions: ["安全正文，不含原始 HTML。"], examples: [],
        source: "用户词典", dictionaryID: id
    )
    let entry = StructuredDictionaryEntry(headword: "prompt", sources: [source])
    let markdown = ObsidianNoteStore.markdownBlock(for: entry, newline: "\n")
    try expect(markdown.contains("### 用户词典"), "source name should be preserved")
    try expect(markdown.contains("- 词典标识：\(id)"), "stable dictionaryID should be preserved")
    try expect(markdown.contains("安全正文"), "safe snapshot should be preserved")
    try expect(!markdown.contains("<script") && !markdown.contains("javascript:"),
               "dangerous HTML must not reach Markdown")
}

@main
struct ManagedDictionaryQuerySmoke {
    static func main() async throws {
        try await testRoutingAndStateFiltering()
        try testRuntimeValidationAndReadOnlySQLite()
        try testSafeCollectionSnapshot()
        print("Managed dictionary query smoke: PASS")
    }
}
