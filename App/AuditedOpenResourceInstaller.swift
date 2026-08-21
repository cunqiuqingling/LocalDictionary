import CryptoKit
import Darwin
import Foundation
import SQLite3

enum AuditedArchive {
    static let ok: Int32 = 0
    static let eof: Int32 = 1

    @_silgen_name("archive_read_new") static func readNew() -> OpaquePointer?
    @_silgen_name("archive_read_support_filter_xz")
    static func supportFilterXZ(_ archive: OpaquePointer?) -> Int32
    @_silgen_name("archive_read_support_filter_gzip")
    static func supportFilterGZIP(_ archive: OpaquePointer?) -> Int32
    @_silgen_name("archive_read_support_format_tar")
    static func supportFormatTAR(_ archive: OpaquePointer?) -> Int32
    @_silgen_name("archive_read_support_format_raw")
    static func supportFormatRaw(_ archive: OpaquePointer?) -> Int32
    @_silgen_name("archive_read_open_filename")
    static func openFilename(_ archive: OpaquePointer?, _ path: UnsafePointer<CChar>?,
                             _ blockSize: Int) -> Int32
    @_silgen_name("archive_read_next_header")
    static func nextHeader(_ archive: OpaquePointer?,
                           _ entry: UnsafeMutablePointer<OpaquePointer?>) -> Int32
    @_silgen_name("archive_read_data")
    static func readData(_ archive: OpaquePointer?, _ buffer: UnsafeMutableRawPointer?,
                         _ size: Int) -> Int
    @_silgen_name("archive_read_data_skip")
    static func skipData(_ archive: OpaquePointer?) -> Int32
    @_silgen_name("archive_read_free") static func free(_ archive: OpaquePointer?) -> Int32
    @_silgen_name("archive_entry_pathname")
    static func entryPath(_ entry: OpaquePointer?) -> UnsafePointer<CChar>?
    @_silgen_name("archive_entry_size")
    static func entrySize(_ entry: OpaquePointer?) -> Int64
    @_silgen_name("archive_entry_filetype")
    static func entryType(_ entry: OpaquePointer?) -> UInt32
    @_silgen_name("archive_entry_symlink")
    static func entrySymlink(_ entry: OpaquePointer?) -> UnsafePointer<CChar>?
    @_silgen_name("archive_entry_hardlink")
    static func entryHardlink(_ entry: OpaquePointer?) -> UnsafePointer<CChar>?
}

enum AuditedOpenResourceError: LocalizedError, Equatable, Sendable {
    case invalidMetadata
    case digestMismatch
    case unsafeArchive
    case malformedSource
    case entryLimit
    case sqliteFailure
    case integrityFailure
    case publicationConflict
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "开放资源的发布审计元数据无效。"
        case .digestMismatch: return "开放资源的固定摘要校验失败。"
        case .unsafeArchive: return "开放资源归档未通过路径、类型或膨胀限制检查。"
        case .malformedSource: return "开放资源不符合已审核的最小格式子集。"
        case .entryLimit: return "开放资源超过词条或单条文本安全限制。"
        case .sqliteFailure: return "无法建立开放资源内部 SQLite。"
        case .integrityFailure: return "开放资源 SQLite 完整性或身份验证失败。"
        case .publicationConflict: return "开放资源发布目标已存在。"
        case .cancelled: return "开放资源转换已取消。"
        }
    }
}

struct AuditedOpenResourceInstallationCoordinator: Sendable {
    typealias Progress = @Sendable (FreeDictInstallationStage) -> Void
    private static let sqliteTransient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    @MainActor
    func install(
        _ verified: VerifiedPayloadStagingResult,
        resource: BundledOpenResourceDefinition,
        dictionariesRoot: URL,
        catalogStore: DictionaryCatalogStore,
        mode: OpenResourceInstallationMode,
        progress: @escaping Progress = { _ in }
    ) async throws -> FreeDictInstallationResult {
        guard resource.sourceFormat != .freeDictStarDictTarXZ else {
            throw AuditedOpenResourceError.invalidMetadata
        }
        let catalog = catalogStore.load()
        let sortPosition: Int64
        let enabled: Bool
        switch mode {
        case .newInstallation:
            guard !catalog.dictionaries.contains(where: {
                $0.openResourceMetadata?.resourceID == resource.resourceID
            }) else { throw OpenResourceInstallationError.resourceAlreadyInstalled }
            sortPosition = (catalog.dictionaries.map(\.sortPosition).max() ?? 0) + 1
            enabled = true
        case .update(let replacingID):
            guard let prior = catalog.dictionaries.first(where: {
                $0.dictionaryID == replacingID &&
                    $0.openResourceMetadata?.resourceID == resource.resourceID &&
                    ($0.openResourceMetadata?.resourceRevision ?? 0) <
                        resource.resourceRevision
            }) else { throw OpenResourceInstallationError.invalidIdentity }
            sortPosition = prior.sortPosition
            enabled = false
        }
        let worker = Task.detached(priority: .utility) {
            try Self.installSynchronously(
                verified, resource: resource, dictionariesRoot: dictionariesRoot,
                sortPosition: sortPosition, enabled: enabled, progress: progress
            )
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            do {
                _ = try catalogStore.mutate { latest, _ in
                    switch mode {
                    case .newInstallation:
                        guard !latest.dictionaries.contains(where: {
                            $0.openResourceMetadata?.resourceID == resource.resourceID
                        }) else {
                            throw OpenResourceInstallationError.resourceAlreadyInstalled
                        }
                    case .update(let replacingID):
                        guard latest.dictionaries.contains(where: {
                            $0.dictionaryID == replacingID &&
                                $0.openResourceMetadata?.resourceID == resource.resourceID &&
                                ($0.openResourceMetadata?.resourceRevision ?? 0) <
                                    resource.resourceRevision
                        }) else { throw OpenResourceInstallationError.invalidIdentity }
                    }
                    latest.dictionaries.append(result.descriptor)
                    latest.updatedAt = result.descriptor.updatedAt
                }
            } catch {
                throw OpenResourceInstallationError.catalogCommitFailedAfterFilesystemPublish
            }
            try? FileManager.default.removeItem(
                at: verified.verifiedFileURL.deletingLastPathComponent()
            )
            return result
        } catch is CancellationError {
            throw AuditedOpenResourceError.cancelled
        }
    }

    private static func installSynchronously(
        _ verified: VerifiedPayloadStagingResult,
        resource: BundledOpenResourceDefinition,
        dictionariesRoot: URL,
        sortPosition: Int64,
        enabled: Bool,
        progress: @escaping Progress
    ) throws -> FreeDictInstallationResult {
        try cancellationPoint()
        let identity = verified.installationIdentity
        guard identity.resourceID == resource.resourceID,
              identity.resourceRevision == resource.resourceRevision,
              identity.payloadSHA256 == resource.sha256,
              verified.verifiedSHA256 == resource.sha256,
              verified.actualByteCount == resource.downloadBytes,
              verified.payloadComponent == identity.sourceComponent,
              identity.formatterIdentifier == resource.transformerIdentifier else {
            throw AuditedOpenResourceError.invalidMetadata
        }
        progress(.validatingSource)
        if resource.officialDigestAlgorithm == "SHA-512" {
            guard try digest(verified.verifiedFileURL, sha512: true) ==
                    resource.officialDigest else {
                throw AuditedOpenResourceError.digestMismatch
            }
        } else {
            guard resource.officialDigestAlgorithm == "SHA-256",
                  verified.verifiedSHA256 == resource.officialDigest else {
                throw AuditedOpenResourceError.digestMismatch
            }
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: dictionariesRoot, withIntermediateDirectories: true)
        let partial = dictionariesRoot.appendingPathComponent(
            ".open-resource-partial-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let final = dictionariesRoot.appendingPathComponent(
            identity.dictionaryID, isDirectory: true
        )
        guard !fileManager.fileExists(atPath: partial.path),
              !fileManager.fileExists(atPath: final.path) else {
            throw AuditedOpenResourceError.publicationConflict
        }
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? fileManager.removeItem(at: partial) } }

        let conversion = partial.appendingPathComponent("conversion", isDirectory: true)
        try fileManager.createDirectory(at: conversion, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        let publicationID = UUID().uuidString.lowercased()
        let indexDirectory = partial.appendingPathComponent("index", isDirectory: true)
        try fileManager.createDirectory(at: indexDirectory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        let outputURL = indexDirectory.appendingPathComponent(
            "dictionary.\(publicationID).sqlite"
        )
        let builder = try SQLiteBuilder(
            url: outputURL, identity: identity, publicationID: publicationID,
            resource: resource, progress: progress
        )
        do {
            try parse(resource: resource, source: verified.verifiedFileURL,
                      conversion: conversion, append: builder.append)
            try builder.finish()
        } catch {
            builder.abort()
            throw error
        }
        let builtEntries = builder.insertedCount
        guard builtEntries >= resource.minimumConvertedEntryCount,
              builtEntries <= resource.maximumEntries else {
            throw AuditedOpenResourceError.integrityFailure
        }
        progress(.validatingIndex)
        try validateSQLite(outputURL, identity: identity, publicationID: publicationID,
                           resource: resource, entryCount: builtEntries)
        guard chmod(outputURL.path, 0o400) == 0 else {
            throw AuditedOpenResourceError.sqliteFailure
        }
        let outputBytes = try regularFileSize(outputURL)
        let outputSHA = try digest(outputURL, sha512: false)

        let receipt = OpenResourceInstallationSidecar(
            identity: identity,
            sourceURL: resource.downloadURL.absoluteString,
            officialDigestAlgorithm: resource.officialDigestAlgorithm,
            officialDigest: resource.officialDigest,
            transformerVersion: resource.transformerVersion,
            outputSchemaVersion: resource.outputSchemaVersion,
            outputPublicationID: publicationID,
            outputSHA256: outputSHA,
            outputIntegrityStatus: "ok"
        )
        _ = try receipt.validated()
        let receiptURL = partial.appendingPathComponent(
            OpenResourceInstallationIdentity.sidecarComponent
        )
        try writeExclusive(try receipt.encodedData(), to: receiptURL)
        try fileManager.removeItem(at: conversion)
        try synchronize(outputURL)
        try synchronize(receiptURL)
        try synchronize(indexDirectory)
        try synchronize(partial)

        let now = Date()
        let relativeIndex = "Dictionaries/\(identity.dictionaryID)/index/" +
            "dictionary.\(publicationID).sqlite"
        let descriptor = DictionaryDescriptor(
            dictionaryID: identity.dictionaryID,
            displayName: identity.displayName,
            sourceKind: .openResource,
            queryLevel: .fallback,
            sortPosition: sortPosition,
            enabled: enabled,
            state: .ready,
            indexMetadata: DictionaryIndexMetadata(
                schemaVersion: resource.outputSchemaVersion,
                entryCount: builtEntries,
                indexFileSize: outputBytes,
                sourceFileSize: resource.downloadBytes,
                sourceModifiedAt: nil,
                sourceSHA256: resource.sha256,
                indexedAt: now
            ),
            formatterIdentifier: resource.transformerIdentifier,
            capabilities: resource.capabilities,
            relativePaths: DictionaryRelativePaths(
                dictionary: nil,
                resources: [], index: relativeIndex
            ),
            createdAt: identity.installedAt,
            updatedAt: now,
            storageOwnership: .appManagedOpenResource,
            openResourceMetadata: identity.catalogMetadata,
            publishedIndexIdentity: PublishedIndexIdentity(
                indexPublicationID: publicationID,
                indexSHA256: outputSHA,
                indexFileSize: outputBytes,
                sourceSHA256: resource.sha256,
                sourceFileSize: resource.downloadBytes,
                schemaVersion: resource.outputSchemaVersion,
                entryCount: builtEntries,
                indexedAt: now,
                relativePath: relativeIndex
            )
        )
        progress(.publishing)
        try cancellationPoint()
        guard rename(partial.path, final.path) == 0 else {
            throw AuditedOpenResourceError.publicationConflict
        }
        published = true
        try synchronize(dictionariesRoot)
        return FreeDictInstallationResult(descriptor: descriptor, receipt: receipt)
    }

    fileprivate struct ParsedEntry {
        let headword: String
        let partOfSpeech: String
        let definition: String
        let sourceID: String
    }

    private final class SQLiteBuilder: @unchecked Sendable {
        private var database: OpaquePointer?
        private var entryStatement: OpaquePointer?
        private var termStatement: OpaquePointer?
        private let identity: OpenResourceInstallationIdentity
        private let publicationID: String
        private let resource: BundledOpenResourceDefinition
        private let progress: Progress
        private(set) var insertedCount: UInt64 = 0
        private var finished = false

        init(url: URL, identity: OpenResourceInstallationIdentity,
             publicationID: String, resource: BundledOpenResourceDefinition,
             progress: @escaping Progress) throws {
            self.identity = identity
            self.publicationID = publicationID
            self.resource = resource
            self.progress = progress
            guard sqlite3_open_v2(url.path, &database,
                                  SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE |
                                    SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let database else { throw AuditedOpenResourceError.sqliteFailure }
            guard chmod(url.path, 0o600) == 0 else {
                throw AuditedOpenResourceError.sqliteFailure
            }
            try execute(database, "PRAGMA journal_mode=DELETE")
            try execute(database, "PRAGMA synchronous=FULL")
            try execute(database, "PRAGMA temp_store=FILE")
            try execute(database,
                "CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            try execute(database, """
                CREATE TABLE entries(
                  id INTEGER PRIMARY KEY,
                  normalized_headword TEXT NOT NULL,
                  display_headword TEXT NOT NULL,
                  language_pair TEXT NOT NULL,
                  part_of_speech TEXT NOT NULL,
                  chinese_definition TEXT NOT NULL,
                  source_entry_id TEXT NOT NULL,
                  resource_id TEXT NOT NULL,
                  source_version TEXT NOT NULL,
                  source_sha256 TEXT NOT NULL,
                  transformer_version TEXT NOT NULL,
                  headword TEXT NOT NULL,
                  lemma TEXT NOT NULL,
                  definition TEXT NOT NULL,
                  snippet TEXT NOT NULL
                )
                """)
            try execute(database,
                "CREATE INDEX entries_headword ON entries(normalized_headword,id)")
            try execute(database, """
                CREATE TABLE terms(
                  term TEXT NOT NULL,
                  entry_id INTEGER NOT NULL,
                  weight INTEGER NOT NULL,
                  PRIMARY KEY(term,entry_id)
                ) WITHOUT ROWID
                """)
            try execute(database, "CREATE INDEX terms_entry ON terms(entry_id)")
            let metadata = [
                "open_resource_schema_version": String(resource.outputSchemaVersion),
                "reverse_schema_version": String(ReverseIndexIdentity.openResourceSchemaVersion),
                "dictionary_id": identity.dictionaryID,
                "resource_id": resource.resourceID,
                "source_version": resource.version,
                "source_sha256": resource.sha256,
                "transformer_id": resource.transformerIdentifier,
                "transformer_version": resource.transformerVersion,
                "index_publication_id": publicationID,
                "license": resource.licenseIdentifier,
                "language_pair": "\(resource.sourceLanguage)-\(resource.targetLanguage)"
            ]
            for item in metadata {
                try insertMetadata(database, key: item.key, value: item.value)
            }
            guard sqlite3_prepare_v2(database, """
                INSERT INTO entries(
                  normalized_headword,display_headword,language_pair,part_of_speech,
                  chinese_definition,source_entry_id,resource_id,source_version,source_sha256,
                  transformer_version,headword,lemma,definition,snippet
                ) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?2,?1,?5,?11)
                """, -1, &entryStatement, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(database,
                    "INSERT OR REPLACE INTO terms(term,entry_id,weight) VALUES(?1,?2,?3)",
                    -1, &termStatement, nil) == SQLITE_OK else {
                throw AuditedOpenResourceError.sqliteFailure
            }
            try execute(database, "BEGIN IMMEDIATE")
        }

        func append(_ raw: ParsedEntry) throws {
            try cancellationPoint()
            guard let database, let entryStatement, let termStatement else {
                throw AuditedOpenResourceError.sqliteFailure
            }
            let display = raw.headword.precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = display.lowercased(with: Locale(identifier: "en_US_POSIX"))
            let part = raw.partOfSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
            guard UInt64(raw.definition.utf8.count) <= resource.maximumEntryBytes else {
                throw AuditedOpenResourceError.entryLimit
            }
            let normalizedDefinition = raw.definition.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            let definition = normalizedDefinition
            guard !display.isEmpty, display.count <= 160, !normalized.isEmpty,
                  part.count <= 64, !definition.isEmpty,
                  !raw.sourceID.isEmpty, raw.sourceID.count <= 128,
                  insertedCount < resource.maximumEntries else {
                throw AuditedOpenResourceError.entryLimit
            }
            let snippet = ReverseLookupNormalizer.snippet(definition, maximum: 480)
            let values = [
                normalized, display,
                "\(resource.sourceLanguage)-\(resource.targetLanguage)",
                part, definition, raw.sourceID, resource.resourceID, resource.version,
                resource.sha256, resource.transformerVersion, snippet
            ]
            sqlite3_reset(entryStatement)
            sqlite3_clear_bindings(entryStatement)
            for (offset, value) in values.enumerated() {
                bind(value, to: entryStatement, at: Int32(offset + 1))
            }
            guard sqlite3_step(entryStatement) == SQLITE_DONE else {
                throw AuditedOpenResourceError.sqliteFailure
            }
            let rowID = sqlite3_last_insert_rowid(database)
            for (term, weight) in ReverseLookupNormalizer.weightedTerms(in: definition) {
                sqlite3_reset(termStatement)
                sqlite3_clear_bindings(termStatement)
                bind(term, to: termStatement, at: 1)
                sqlite3_bind_int64(termStatement, 2, rowID)
                sqlite3_bind_int(termStatement, 3, Int32(weight))
                guard sqlite3_step(termStatement) == SQLITE_DONE else {
                    throw AuditedOpenResourceError.sqliteFailure
                }
            }
            insertedCount += 1
            if insertedCount % 4_096 == 0 {
                try execute(database, "COMMIT")
                progress(.buildingIndex(processed: insertedCount,
                                        total: resource.expectedEntryCount))
                let delay = ReverseIndexThermalPacing.delayMicroseconds(
                    for: ProcessInfo.processInfo.thermalState
                )
                if delay > 0 { usleep(delay) } else { sched_yield() }
                try execute(database, "BEGIN IMMEDIATE")
            } else if insertedCount % 256 == 0 {
                progress(.converting(processed: insertedCount,
                                     total: resource.expectedEntryCount))
            }
        }

        func finish() throws {
            guard !finished, let database else {
                throw AuditedOpenResourceError.sqliteFailure
            }
            sqlite3_finalize(entryStatement)
            sqlite3_finalize(termStatement)
            entryStatement = nil
            termStatement = nil
            try execute(database, "COMMIT")
            try insertMetadata(database, key: "entry_count", value: String(insertedCount))
            try execute(database, "ANALYZE")
            try execute(database, "PRAGMA optimize")
            guard sqlite3_close(database) == SQLITE_OK else {
                throw AuditedOpenResourceError.sqliteFailure
            }
            self.database = nil
            finished = true
        }

        func abort() {
            sqlite3_finalize(entryStatement)
            sqlite3_finalize(termStatement)
            entryStatement = nil
            termStatement = nil
            if let database {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                sqlite3_close(database)
                self.database = nil
            }
            finished = true
        }

        deinit { if !finished { abort() } }
    }

    private static func parse(
        resource: BundledOpenResourceDefinition,
        source: URL,
        conversion: URL,
        append: (ParsedEntry) throws -> Void
    ) throws {
        switch resource.sourceFormat {
        case .ccCedictTextGZIP:
            let text = conversion.appendingPathComponent("cedict.txt")
            try decompressRaw(source, to: text,
                              maximumBytes: resource.maximumExpandedBytes,
                              gzip: true)
            var lineNumber: UInt64 = 0
            try forEachLine(text, maximumLineBytes: boundedEntryBytes(resource)) { line in
                lineNumber += 1
                guard !line.hasPrefix("#") else { return }
                let parsed = try parseCCCEDICT(line, lineNumber: lineNumber)
                try append(parsed.traditional)
                if parsed.simplified.headword != parsed.traditional.headword {
                    try append(parsed.simplified)
                }
            }
        case .kaikkiWiktionaryJSONL:
            var lineNumber: UInt64 = 0
            try forEachLine(source, maximumLineBytes: boundedEntryBytes(resource)) { line in
                lineNumber += 1
                if let value = try parseKaikki(line, lineNumber: lineNumber) {
                    try append(value)
                }
            }
        case .wordNetDataTarGZIP:
            let files = try extractSelectedArchive(
                source, to: conversion, resource: resource,
                select: { path in
                    ["data.noun", "data.verb", "data.adj", "data.adv"]
                        .contains(URL(fileURLWithPath: path).lastPathComponent)
                }
            )
            guard files.count == 4 else { throw AuditedOpenResourceError.unsafeArchive }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let part = file.lastPathComponent.replacingOccurrences(of: "data.", with: "")
                try forEachLine(file, maximumLineBytes: boundedEntryBytes(resource)) { line in
                    for entry in try parseWordNet(line, part: part) { try append(entry) }
                }
            }
        case .gcideMarkupTarXZ:
            let files = try extractSelectedArchive(
                source, to: conversion, resource: resource,
                select: { path in
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    return name.count == 6 && name.hasPrefix("CIDE.") &&
                        name.last?.isLetter == true
                }
            )
            guard files.count == 26 else { throw AuditedOpenResourceError.unsafeArchive }
            var sourceOrdinal: UInt64 = 0
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var paragraph = ""
                try forEachLine(
                    file, maximumLineBytes: boundedEntryBytes(resource),
                    encoding: .isoLatin1
                ) { line in
                    if paragraph.isEmpty, !line.contains("<p>") { return }
                    paragraph += line + "\n"
                    guard UInt64(paragraph.utf8.count) <= resource.maximumEntryBytes else {
                        throw AuditedOpenResourceError.entryLimit
                    }
                    if line.contains("</p>") {
                        sourceOrdinal += 1
                        if let entry = try parseGCIDE(paragraph, ordinal: sourceOrdinal) {
                            try append(entry)
                        }
                        paragraph.removeAll(keepingCapacity: true)
                    }
                }
                guard paragraph.isEmpty else {
                    throw AuditedOpenResourceError.malformedSource
                }
            }
        case .freeDictStarDictTarXZ:
            throw AuditedOpenResourceError.invalidMetadata
        }
    }

    private static func boundedEntryBytes(_ resource: BundledOpenResourceDefinition) -> Int {
        Int(min(resource.maximumEntryBytes, UInt64(Int.max)))
    }

    fileprivate static func parseCCCEDICT(_ line: String, lineNumber: UInt64) throws
        -> (traditional: ParsedEntry, simplified: ParsedEntry) {
        guard let firstSpace = line.firstIndex(of: " "),
              let secondSpace = line[line.index(after: firstSpace)...].firstIndex(of: " "),
              let closeBracket = line[secondSpace...].firstIndex(of: "]"),
              closeBracket < line.endIndex else {
            throw AuditedOpenResourceError.malformedSource
        }
        let traditional = String(line[..<firstSpace])
        let simplified = String(line[line.index(after: firstSpace)..<secondSpace])
        let definitionStart = line.index(after: closeBracket)
        let rawDefinition = line[definitionStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawDefinition.hasPrefix("/"), rawDefinition.hasSuffix("/") else {
            throw AuditedOpenResourceError.malformedSource
        }
        let definition = rawDefinition.dropFirst().dropLast()
            .split(separator: "/").joined(separator: "; ")
        let sourceID = "cedict:\(lineNumber)"
        return (
            ParsedEntry(headword: traditional, partOfSpeech: "",
                        definition: definition, sourceID: sourceID + ":t"),
            ParsedEntry(headword: simplified, partOfSpeech: "",
                        definition: definition, sourceID: sourceID + ":s")
        )
    }

    fileprivate static func parseKaikki(_ line: String, lineNumber: UInt64) throws
        -> ParsedEntry? {
        guard let data = line.data(using: .utf8) else {
            throw AuditedOpenResourceError.malformedSource
        }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                throw AuditedOpenResourceError.malformedSource
            }
            object = decoded
        } catch is AuditedOpenResourceError {
            throw AuditedOpenResourceError.malformedSource
        } catch {
            throw AuditedOpenResourceError.malformedSource
        }
        guard let language = object["lang_code"] as? String else {
            throw AuditedOpenResourceError.malformedSource
        }
        guard language == "en" else { return nil }
        guard let word = object["word"] as? String,
              let senses = object["senses"] as? [[String: Any]] else {
            throw AuditedOpenResourceError.malformedSource
        }
        var glosses: [String] = []
        for sense in senses {
            if let values = sense["glosses"] as? [String] {
                glosses.append(contentsOf: values)
            }
            if glosses.count >= 12 { break }
        }
        var seen: Set<String> = []
        let definition = glosses.filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(12).joined(separator: "；")
        guard !definition.isEmpty else { return nil }
        return ParsedEntry(
            headword: word,
            partOfSpeech: object["pos_title"] as? String ??
                object["pos"] as? String ?? "",
            definition: definition,
            sourceID: "kaikki:\(lineNumber)"
        )
    }

    fileprivate static func parseWordNet(_ line: String, part: String) throws
        -> [ParsedEntry] {
        guard !line.isEmpty, line.first?.isNumber == true else { return [] }
        let halves = line.split(separator: "|", maxSplits: 1,
                                omittingEmptySubsequences: false)
        guard halves.count == 2 else { throw AuditedOpenResourceError.malformedSource }
        let columns = halves[0].split(whereSeparator: { $0.isWhitespace })
        guard columns.count >= 5, let wordCount = Int(columns[3], radix: 16),
              wordCount > 0, wordCount <= 256,
              columns.count >= 4 + wordCount * 2 else {
            throw AuditedOpenResourceError.malformedSource
        }
        let definition = halves[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !definition.isEmpty else { return [] }
        let offset = String(columns[0])
        return (0..<wordCount).map { index in
            ParsedEntry(
                headword: String(columns[4 + index * 2])
                    .replacingOccurrences(of: "_", with: " "),
                partOfSpeech: part,
                definition: definition,
                sourceID: "wordnet:\(offset):\(index)"
            )
        }
    }

    fileprivate static func parseGCIDE(_ paragraph: String, ordinal: UInt64) throws
        -> ParsedEntry? {
        guard let headword = firstTag("ent", in: paragraph) else { return nil }
        let definitions = allTags("def", in: paragraph).map(stripMarkup)
            .filter { !$0.isEmpty }
        guard !definitions.isEmpty else { return nil }
        let part = firstTag("pos", in: paragraph).map(stripMarkup) ?? ""
        return ParsedEntry(
            headword: stripMarkup(headword), partOfSpeech: part,
            definition: definitions.prefix(8).joined(separator: "; "),
            sourceID: "gcide:\(ordinal)"
        )
    }

    private static func firstTag(_ name: String, in source: String) -> String? {
        allTags(name, in: source).first
    }

    private static func allTags(_ name: String, in source: String) -> [String] {
        let pattern = "<\(name)(?:\\s[^>]*)?>(.*?)</\(name)>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges == 2,
                  let value = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[value])
        }
    }

    private static func stripMarkup(_ source: String) -> String {
        let withoutTags = source.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression
        )
        return withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func forEachLine(
        _ url: URL, maximumLineBytes: Int,
        encoding: String.Encoding = .utf8,
        body: (String) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while true {
            try cancellationPoint()
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)
            guard pending.count <= maximumLineBytes + 64 * 1024 else {
                throw AuditedOpenResourceError.entryLimit
            }
            while let newline = pending.firstIndex(of: 0x0a) {
                var line = pending.prefix(upTo: newline)
                if line.last == 0x0d { line = line.dropLast() }
                guard line.count <= maximumLineBytes,
                      let text = String(data: line, encoding: encoding) else {
                    throw AuditedOpenResourceError.malformedSource
                }
                try body(text)
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty {
            guard pending.count <= maximumLineBytes,
                  let text = String(data: pending, encoding: encoding) else {
                throw AuditedOpenResourceError.malformedSource
            }
            try body(text)
        }
    }

    private static func decompressRaw(_ source: URL, to destination: URL,
                                      maximumBytes: UInt64, gzip: Bool) throws {
        guard let archive = AuditedArchive.readNew() else {
            throw AuditedOpenResourceError.unsafeArchive
        }
        defer { _ = AuditedArchive.free(archive) }
        let filter = gzip ? AuditedArchive.supportFilterGZIP(archive) :
            AuditedArchive.supportFilterXZ(archive)
        guard filter == AuditedArchive.ok,
              AuditedArchive.supportFormatRaw(archive) == AuditedArchive.ok,
              source.path.withCString({
                  AuditedArchive.openFilename(archive, $0, 64 * 1024)
              }) == AuditedArchive.ok else {
            throw AuditedOpenResourceError.unsafeArchive
        }
        var entry: OpaquePointer?
        guard AuditedArchive.nextHeader(archive, &entry) == AuditedArchive.ok else {
            throw AuditedOpenResourceError.unsafeArchive
        }
        try writeArchiveEntry(archive, to: destination, maximumBytes: maximumBytes)
        var extra: OpaquePointer?
        guard AuditedArchive.nextHeader(archive, &extra) == AuditedArchive.eof else {
            throw AuditedOpenResourceError.unsafeArchive
        }
    }

    private static func extractSelectedArchive(
        _ source: URL,
        to directory: URL,
        resource: BundledOpenResourceDefinition,
        select: (String) -> Bool
    ) throws -> [URL] {
        guard let archive = AuditedArchive.readNew() else {
            throw AuditedOpenResourceError.unsafeArchive
        }
        defer { _ = AuditedArchive.free(archive) }
        let filter: Int32
        switch resource.sourceFormat {
        case .wordNetDataTarGZIP: filter = AuditedArchive.supportFilterGZIP(archive)
        case .gcideMarkupTarXZ: filter = AuditedArchive.supportFilterXZ(archive)
        default: throw AuditedOpenResourceError.unsafeArchive
        }
        guard filter == AuditedArchive.ok,
              AuditedArchive.supportFormatTAR(archive) == AuditedArchive.ok,
              source.path.withCString({
                  AuditedArchive.openFilename(archive, $0, 64 * 1024)
              }) == AuditedArchive.ok else {
            throw AuditedOpenResourceError.unsafeArchive
        }
        var output: [URL] = []
        var total: UInt64 = 0
        var names: Set<String> = []
        while true {
            try cancellationPoint()
            var entry: OpaquePointer?
            let status = AuditedArchive.nextHeader(archive, &entry)
            if status == AuditedArchive.eof { break }
            guard status == AuditedArchive.ok, let entry,
                  let rawPath = AuditedArchive.entryPath(entry) else {
                throw AuditedOpenResourceError.unsafeArchive
            }
            let path = String(cString: rawPath)
            let components = NSString(string: path).pathComponents
            guard !path.hasPrefix("/"), !components.contains(".."),
                  !components.contains("."), path.utf8.count <= 512,
                  AuditedArchive.entrySymlink(entry) == nil,
                  AuditedArchive.entryHardlink(entry) == nil else {
                throw AuditedOpenResourceError.unsafeArchive
            }
            let type = AuditedArchive.entryType(entry)
            if type == UInt32(S_IFDIR) {
                guard AuditedArchive.skipData(archive) == AuditedArchive.ok else {
                    throw AuditedOpenResourceError.unsafeArchive
                }
                continue
            }
            guard type == UInt32(S_IFREG), AuditedArchive.entrySize(entry) >= 0 else {
                throw AuditedOpenResourceError.unsafeArchive
            }
            let size = UInt64(AuditedArchive.entrySize(entry))
            let next = total.addingReportingOverflow(size)
            guard !next.overflow, next.partialValue <= resource.maximumExpandedBytes else {
                throw AuditedOpenResourceError.unsafeArchive
            }
            total = next.partialValue
            if select(path) {
                let name = URL(fileURLWithPath: path).lastPathComponent
                guard names.insert(name).inserted,
                      resource.archiveMembers[name] == nil ||
                        resource.archiveMembers[name] == size else {
                    throw AuditedOpenResourceError.unsafeArchive
                }
                let destination = directory.appendingPathComponent(name)
                try writeArchiveEntry(archive, to: destination,
                                      maximumBytes: min(size, resource.maximumExpandedBytes))
                guard try regularFileSize(destination) == size else {
                    throw AuditedOpenResourceError.unsafeArchive
                }
                output.append(destination)
            } else {
                guard AuditedArchive.skipData(archive) == AuditedArchive.ok else {
                    throw AuditedOpenResourceError.unsafeArchive
                }
            }
        }
        guard Set(resource.archiveMembers.keys).isSubset(of: names) else {
            throw AuditedOpenResourceError.unsafeArchive
        }
        return output
    }

    private static func writeArchiveEntry(_ archive: OpaquePointer,
                                          to destination: URL,
                                          maximumBytes: UInt64) throws {
        let descriptor = destination.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw AuditedOpenResourceError.unsafeArchive }
        defer { Darwin.close(descriptor) }
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellationPoint()
            let count = buffer.withUnsafeMutableBytes {
                AuditedArchive.readData(archive, $0.baseAddress, $0.count)
            }
            guard count >= 0 else { throw AuditedOpenResourceError.unsafeArchive }
            if count == 0 { break }
            let next = total.addingReportingOverflow(UInt64(count))
            guard !next.overflow, next.partialValue <= maximumBytes else {
                throw AuditedOpenResourceError.unsafeArchive
            }
            try buffer.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let written = Darwin.write(
                        descriptor, base.advanced(by: offset), count - offset
                    )
                    guard written > 0 else { throw AuditedOpenResourceError.unsafeArchive }
                    offset += written
                }
            }
            total = next.partialValue
        }
        guard fsync(descriptor) == 0 else {
            throw AuditedOpenResourceError.unsafeArchive
        }
    }

    private static func validateSQLite(
        _ url: URL,
        identity: OpenResourceInstallationIdentity,
        publicationID: String,
        resource: BundledOpenResourceDefinition,
        entryCount: UInt64
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw AuditedOpenResourceError.integrityFailure }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1,
                                 &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              String(cString: sqlite3_column_text(statement, 0)) == "ok" else {
            sqlite3_finalize(statement)
            throw AuditedOpenResourceError.integrityFailure
        }
        sqlite3_finalize(statement)
        let expected = [
            "dictionary_id": identity.dictionaryID,
            "resource_id": resource.resourceID,
            "source_version": resource.version,
            "source_sha256": resource.sha256,
            "transformer_id": resource.transformerIdentifier,
            "transformer_version": resource.transformerVersion,
            "index_publication_id": publicationID,
            "entry_count": String(entryCount),
            "license": resource.licenseIdentifier
        ]
        for item in expected where try metadata(database, key: item.key) != item.value {
            throw AuditedOpenResourceError.integrityFailure
        }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        if result == SQLITE_INTERRUPT || Task.isCancelled {
            throw AuditedOpenResourceError.cancelled
        }
        guard result == SQLITE_OK else { throw AuditedOpenResourceError.sqliteFailure }
    }

    private static func insertMetadata(_ database: OpaquePointer,
                                       key: String, value: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "INSERT OR REPLACE INTO metadata(key,value) VALUES(?1,?2)",
            -1, &statement, nil) == SQLITE_OK else {
            throw AuditedOpenResourceError.sqliteFailure
        }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        bind(value, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AuditedOpenResourceError.sqliteFailure
        }
    }

    private static func metadata(_ database: OpaquePointer, key: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT value FROM metadata WHERE key=?1 LIMIT 1", -1,
            &statement, nil) == SQLITE_OK else {
            throw AuditedOpenResourceError.integrityFailure
        }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else {
            throw AuditedOpenResourceError.integrityFailure
        }
        return String(cString: raw)
    }

    private static func bind(_ value: String, to statement: OpaquePointer?,
                             at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private static func digest(_ url: URL, sha512: Bool) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher256 = SHA256()
        var hasher512 = SHA512()
        while true {
            try cancellationPoint()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            if sha512 { hasher512.update(data: data) }
            else { hasher256.update(data: data) }
        }
        let bytes = sha512 ? Array(hasher512.finalize()) : Array(hasher256.finalize())
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func boundedCopy(_ source: URL, to destination: URL,
                                    expectedBytes: UInt64) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let descriptor = destination.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw AuditedOpenResourceError.publicationConflict }
        defer { Darwin.close(descriptor) }
        var total: UInt64 = 0
        while true {
            try cancellationPoint()
            let data = try input.read(upToCount: 256 * 1024) ?? Data()
            if data.isEmpty { break }
            total += UInt64(data.count)
            guard total <= expectedBytes else { throw AuditedOpenResourceError.digestMismatch }
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(
                        descriptor, base.advanced(by: offset), raw.count - offset
                    )
                    guard written > 0 else { throw AuditedOpenResourceError.sqliteFailure }
                    offset += written
                }
            }
        }
        guard total == expectedBytes, fsync(descriptor) == 0 else {
            throw AuditedOpenResourceError.digestMismatch
        }
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw AuditedOpenResourceError.publicationConflict }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    descriptor, base.advanced(by: offset), raw.count - offset
                )
                guard written > 0 else { throw AuditedOpenResourceError.sqliteFailure }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw AuditedOpenResourceError.sqliteFailure }
    }

    private static func regularFileSize(_ url: URL) throws -> UInt64 {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              value.st_nlink == 1, value.st_size > 0 else {
            throw AuditedOpenResourceError.integrityFailure
        }
        return UInt64(value.st_size)
    }

    private static func synchronize(_ url: URL) throws {
        let flags = url.hasDirectoryPath ? O_RDONLY | O_DIRECTORY : O_RDONLY
        let descriptor = url.path.withCString {
            Darwin.open($0, flags | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw AuditedOpenResourceError.sqliteFailure }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw AuditedOpenResourceError.sqliteFailure }
    }

    private static func cancellationPoint() throws {
        if Task.isCancelled { throw AuditedOpenResourceError.cancelled }
    }
}

#if OPEN_RESOURCE_CONVERTER_TESTING
enum AuditedOpenResourceSecurityTestHooks {
    static func parseCCCEDICT(_ line: String) throws -> [(String, String)] {
        let value = try AuditedOpenResourceInstallationCoordinator
            .parseCCCEDICT(line, lineNumber: 1)
        return [(value.traditional.headword, value.traditional.definition),
                (value.simplified.headword, value.simplified.definition)]
    }

    static func parseKaikki(_ line: String) throws -> (String, String)? {
        guard let value = try AuditedOpenResourceInstallationCoordinator
            .parseKaikki(line, lineNumber: 1) else { return nil }
        return (value.headword, value.definition)
    }

    static func parseWordNet(_ line: String) throws -> [(String, String)] {
        try AuditedOpenResourceInstallationCoordinator
            .parseWordNet(line, part: "noun")
            .map { ($0.headword, $0.definition) }
    }

    static func parseGCIDE(_ paragraph: String) throws -> (String, String)? {
        guard let value = try AuditedOpenResourceInstallationCoordinator
            .parseGCIDE(paragraph, ordinal: 1) else { return nil }
        return (value.headword, value.definition)
    }
}
#endif
