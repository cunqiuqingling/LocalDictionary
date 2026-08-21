import CryptoKit
import Darwin
import Foundation
import SQLite3

enum FreeDictResourceError: LocalizedError, Equatable, Sendable {
    case invalidStarterMetadata
    case sourceDigestMismatch
    case unsafeArchive
    case unsupportedSource
    case malformedIndex
    case invalidEntry
    case sqliteFailure
    case integrityFailure
    case publicationConflict
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidStarterMetadata: return "内置开放资源元数据无效。"
        case .sourceDigestMismatch: return "官方资源摘要校验失败。"
        case .unsafeArchive: return "开放资源压缩包未通过成员和膨胀限制检查。"
        case .unsupportedSource: return "开放资源格式或许可证元数据与已审核版本不一致。"
        case .malformedIndex: return "StarDict 索引结构无效。"
        case .invalidEntry: return "开放词典包含超出安全子集的词条。"
        case .sqliteFailure: return "无法建立本地开放资源索引。"
        case .integrityFailure: return "本地开放资源索引完整性验证失败。"
        case .publicationConflict: return "开放资源发布目标已存在。"
        case .cancelled: return "开放资源转换已取消。"
        }
    }
}

enum FreeDictInstallationStage: Equatable, Sendable {
    case validatingSource
    case converting(processed: UInt64, total: UInt64?)
    case buildingIndex(processed: UInt64, total: UInt64?)
    case validatingIndex
    case publishing
}

struct FreeDictInstallationResult: Sendable {
    let descriptor: DictionaryDescriptor
    let receipt: OpenResourceInstallationSidecar
}

#if OPEN_RESOURCE_UI_TESTING
struct FreeDictStarDictInstallationCoordinator: Sendable {
    typealias Progress = @Sendable (FreeDictInstallationStage) -> Void

    @MainActor
    func install(
        _ verified: VerifiedPayloadStagingResult,
        resource: BundledOpenResourceDefinition,
        dictionariesRoot: URL,
        catalogStore: DictionaryCatalogStore,
        mode: OpenResourceInstallationMode,
        progress: @escaping Progress = { _ in }
    ) async throws -> FreeDictInstallationResult {
        _ = (verified, resource, dictionariesRoot, catalogStore, mode, progress)
        throw FreeDictResourceError.invalidStarterMetadata
    }
}
#else
struct FreeDictStarDictInstallationCoordinator: Sendable {
    typealias Progress = @Sendable (FreeDictInstallationStage) -> Void
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @MainActor
    func install(
        _ verified: VerifiedPayloadStagingResult,
        resource: BundledOpenResourceDefinition,
        dictionariesRoot: URL,
        catalogStore: DictionaryCatalogStore,
        mode: OpenResourceInstallationMode,
        progress: @escaping Progress = { _ in }
    ) async throws -> FreeDictInstallationResult {
        let currentCatalog = catalogStore.load()
        let sortPosition: Int64
        let enabled: Bool
        switch mode {
        case .newInstallation:
            guard !currentCatalog.dictionaries.contains(where: {
                $0.openResourceMetadata?.resourceID == resource.resourceID
            }) else { throw OpenResourceInstallationError.resourceAlreadyInstalled }
            enabled = true
            sortPosition = Self.nextFallbackPosition(currentCatalog)
        case .update(let replacingDictionaryID):
            guard let replacing = currentCatalog.dictionaries.first(where: {
                $0.dictionaryID == replacingDictionaryID &&
                    $0.openResourceMetadata?.resourceID == resource.resourceID &&
                    ($0.openResourceMetadata?.resourceRevision ?? 0) < resource.resourceRevision
            }) else { throw OpenResourceInstallationError.invalidIdentity }
            enabled = false
            sortPosition = replacing.sortPosition
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
            } onCancel: {
                worker.cancel()
            }
            do {
                _ = try catalogStore.mutate { catalog, _ in
                    switch mode {
                    case .newInstallation:
                        guard !catalog.dictionaries.contains(where: {
                            $0.openResourceMetadata?.resourceID == resource.resourceID
                        }) else {
                            throw OpenResourceInstallationError.resourceAlreadyInstalled
                        }
                    case .update(let replacingDictionaryID):
                        guard catalog.dictionaries.contains(where: {
                            $0.dictionaryID == replacingDictionaryID &&
                                $0.openResourceMetadata?.resourceID == resource.resourceID &&
                                ($0.openResourceMetadata?.resourceRevision ?? 0) <
                                    resource.resourceRevision
                        }) else { throw OpenResourceInstallationError.invalidIdentity }
                    }
                    catalog.dictionaries.append(result.descriptor)
                    catalog.updatedAt = result.descriptor.updatedAt
                }
            } catch {
#if OPEN_RESOURCE_CONVERTER_TESTING
                throw error
#else
                throw OpenResourceInstallationError.catalogCommitFailedAfterFilesystemPublish
#endif
            }
            try? FileManager.default.removeItem(
                at: verified.verifiedFileURL.deletingLastPathComponent()
            )
            return result
        } catch is CancellationError {
            throw FreeDictResourceError.cancelled
        }
    }

    private static func installSynchronously(
        _ verified: VerifiedPayloadStagingResult,
        resource: BundledOpenResourceDefinition,
        dictionariesRoot: URL,
        sortPosition: Int64,
        enabled: Bool,
        progress: Progress
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
            throw FreeDictResourceError.invalidStarterMetadata
        }
        progress(.validatingSource)
        guard try digest(verified.verifiedFileURL, algorithm: .sha512) ==
                resource.officialDigest else {
            throw FreeDictResourceError.sourceDigestMismatch
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: dictionariesRoot, withIntermediateDirectories: true)
        let partial = dictionariesRoot.appendingPathComponent(
            ".open-resource-partial-\(UUID().uuidString.lowercased())", isDirectory: true
        )
        let final = dictionariesRoot.appendingPathComponent(identity.dictionaryID, isDirectory: true)
        guard !fileManager.fileExists(atPath: partial.path),
              !fileManager.fileExists(atPath: final.path) else {
            throw FreeDictResourceError.publicationConflict
        }
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        var published = false
        defer {
            if !published { try? fileManager.removeItem(at: partial) }
        }

        let extracted = partial.appendingPathComponent("conversion", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        let ifoURL = extracted.appendingPathComponent("source.ifo")
        let compressedIndexURL = extracted.appendingPathComponent("source.idx.gz")
        let indexURL = extracted.appendingPathComponent("source.idx")
        let dictionaryURL = extracted.appendingPathComponent("source.dict")
        let pair = archivePair(for: resource)
        let archiveSizes = try extractArchive(
            verified.verifiedFileURL,
            expected: resource.archiveMembers,
            destinations: [
                "\(pair)/\(pair).ifo": ifoURL,
                "\(pair)/\(pair).idx.gz": compressedIndexURL,
                "\(pair)/\(pair).dict": dictionaryURL
            ],
            maximumExpandedBytes: resource.maximumExpandedBytes
        )
        let sourceInfo = try validateIFO(ifoURL, resource: resource)
        try decompressGZIP(
            compressedIndexURL, to: indexURL, expectedBytes: sourceInfo.indexFileBytes
        )
        guard let dictionaryBytes = archiveSizes["\(pair)/\(pair).dict"] else {
            throw FreeDictResourceError.unsafeArchive
        }

        let publicationID = UUID().uuidString.lowercased()
        let outputDirectory = partial.appendingPathComponent("index", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        let outputURL = outputDirectory.appendingPathComponent(
            "dictionary.\(publicationID).sqlite"
        )
        let builtEntries = try buildSQLite(
            indexURL: indexURL, dictionaryURL: dictionaryURL, outputURL: outputURL,
            identity: identity, publicationID: publicationID, resource: resource,
            languagePair: pair, expectedIndexBytes: sourceInfo.indexFileBytes,
            expectedDictionaryBytes: dictionaryBytes,
            expectedSourceEntries: sourceInfo.wordCount,
            progress: progress
        )
        guard builtEntries >= min(resource.minimumConvertedEntryCount, sourceInfo.wordCount),
              builtEntries <= resource.maximumEntries else {
            throw FreeDictResourceError.integrityFailure
        }
        progress(.validatingIndex)
        try validateSQLite(outputURL, identity: identity, publicationID: publicationID,
                           resource: resource, entryCount: builtEntries)
        guard chmod(outputURL.path, 0o400) == 0 else {
            throw FreeDictResourceError.sqliteFailure
        }
        let outputBytes = try regularFileSize(outputURL)
        let outputSHA256 = try digest(outputURL, algorithm: .sha256)

        let receipt = OpenResourceInstallationSidecar(
            identity: identity,
            sourceURL: resource.downloadURL.absoluteString,
            officialDigestAlgorithm: resource.officialDigestAlgorithm,
            officialDigest: resource.officialDigest,
            transformerVersion: resource.transformerVersion,
            outputSchemaVersion: resource.outputSchemaVersion,
            outputPublicationID: publicationID,
            outputSHA256: outputSHA256,
            outputIntegrityStatus: "ok"
        )
        _ = try receipt.validated()
        let receiptURL = partial.appendingPathComponent(
            OpenResourceInstallationIdentity.sidecarComponent
        )
        try writeExclusive(try receipt.encodedData(), to: receiptURL)
        try fileManager.removeItem(at: extracted)
        try synchronize(outputURL); try synchronize(receiptURL)
        try synchronize(outputDirectory); try synchronize(partial)

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
                indexSHA256: outputSHA256,
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
            throw FreeDictResourceError.publicationConflict
        }
        published = true
        try synchronize(dictionariesRoot)
        return FreeDictInstallationResult(descriptor: descriptor, receipt: receipt)
    }

    @discardableResult
    fileprivate static func extractArchive(
        _ source: URL,
        expected: [String: UInt64],
        destinations: [String: URL],
        maximumExpandedBytes: UInt64
    ) throws -> [String: UInt64] {
        guard let archive = AuditedArchive.readNew() else {
            throw FreeDictResourceError.unsafeArchive
        }
        defer { _ = AuditedArchive.free(archive) }
        guard AuditedArchive.supportFilterXZ(archive) == AuditedArchive.ok,
              AuditedArchive.supportFormatTAR(archive) == AuditedArchive.ok,
              source.path.withCString({ AuditedArchive.openFilename(archive, $0, 64 * 1024) }) ==
                AuditedArchive.ok else { throw FreeDictResourceError.unsafeArchive }
        var seen: Set<String> = []
        var observed: [String: UInt64] = [:]
        var total: UInt64 = 0
        while true {
            try cancellationPoint()
            var entry: OpaquePointer?
            let status = AuditedArchive.nextHeader(archive, &entry)
            if status == AuditedArchive.eof { break }
            guard status == AuditedArchive.ok, let entry,
                  let rawPath = AuditedArchive.entryPath(entry) else {
                throw FreeDictResourceError.unsafeArchive
            }
            let path = String(cString: rawPath)
            let dynamic = expected.isEmpty
            let allowedDynamicPath = destinations[path] != nil ||
                ["README", "COPYING", "INSTALL", "ChangeLog"].contains {
                    path.hasSuffix("/\($0)")
                }
            let rawSize = AuditedArchive.entrySize(entry)
            guard (dynamic ? allowedDynamicPath : expected[path] != nil),
                  seen.insert(path).inserted,
                  AuditedArchive.entryType(entry) == UInt32(S_IFREG),
                  AuditedArchive.entrySymlink(entry) == nil,
                  AuditedArchive.entryHardlink(entry) == nil,
                  rawSize >= 0 else {
                throw FreeDictResourceError.unsafeArchive
            }
            let expectedSize = expected[path] ?? UInt64(rawSize)
            guard dynamic || UInt64(rawSize) == expectedSize else {
                throw FreeDictResourceError.unsafeArchive
            }
            let next = total.addingReportingOverflow(expectedSize)
            guard !next.overflow, next.partialValue <= maximumExpandedBytes else {
                throw FreeDictResourceError.unsafeArchive
            }
            total = next.partialValue
            if let destination = destinations[path] {
                try readArchiveEntry(archive, to: destination, exactBytes: expectedSize)
            } else {
                guard AuditedArchive.skipData(archive) == AuditedArchive.ok else {
                    throw FreeDictResourceError.unsafeArchive
                }
            }
            observed[path] = expectedSize
        }
        if expected.isEmpty {
            guard Set(destinations.keys).isSubset(of: seen) else {
                throw FreeDictResourceError.unsafeArchive
            }
        } else if seen != Set(expected.keys) {
            throw FreeDictResourceError.unsafeArchive
        }
        return observed
    }

    private static func decompressGZIP(_ source: URL, to destination: URL,
                                       expectedBytes: UInt64) throws {
        guard let archive = AuditedArchive.readNew() else {
            throw FreeDictResourceError.unsafeArchive
        }
        defer { _ = AuditedArchive.free(archive) }
        guard AuditedArchive.supportFilterGZIP(archive) == AuditedArchive.ok,
              AuditedArchive.supportFormatRaw(archive) == AuditedArchive.ok,
              source.path.withCString({ AuditedArchive.openFilename(archive, $0, 64 * 1024) }) ==
                AuditedArchive.ok else { throw FreeDictResourceError.unsafeArchive }
        var entry: OpaquePointer?
        guard AuditedArchive.nextHeader(archive, &entry) == AuditedArchive.ok else {
            throw FreeDictResourceError.unsafeArchive
        }
        try readArchiveEntry(archive, to: destination, exactBytes: expectedBytes)
        var extra: OpaquePointer?
        guard AuditedArchive.nextHeader(archive, &extra) == AuditedArchive.eof else {
            throw FreeDictResourceError.unsafeArchive
        }
    }

    private static func readArchiveEntry(_ archive: OpaquePointer, to destination: URL,
                                         exactBytes: UInt64) throws {
        let fd = destination.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw FreeDictResourceError.unsafeArchive }
        defer { Darwin.close(fd) }
        var written: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellationPoint()
            let count = buffer.withUnsafeMutableBytes {
                AuditedArchive.readData(archive, $0.baseAddress, $0.count)
            }
            guard count >= 0 else { throw FreeDictResourceError.unsafeArchive }
            if count == 0 { break }
            let next = written.addingReportingOverflow(UInt64(count))
            guard !next.overflow, next.partialValue <= exactBytes else {
                throw FreeDictResourceError.unsafeArchive
            }
            try buffer.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let result = Darwin.write(fd, base.advanced(by: offset), count - offset)
                    guard result > 0 else { throw FreeDictResourceError.unsafeArchive }
                    offset += result
                }
            }
            written = next.partialValue
        }
        guard written == exactBytes, fsync(fd) == 0 else {
            throw FreeDictResourceError.unsafeArchive
        }
    }

    private struct StarDictSourceInfo {
        let wordCount: UInt64
        let indexFileBytes: UInt64
    }

    private static func validateIFO(_ url: URL,
                                    resource: BundledOpenResourceDefinition) throws
        -> StarDictSourceInfo {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= 256 * 1024,
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("StarDict's dict ifo file\n"),
              text.contains("version=3.0.0\n") else {
            throw FreeDictResourceError.unsupportedSource
        }
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        guard let wordCount = fields["wordcount"].flatMap(UInt64.init), wordCount > 0,
              wordCount <= resource.maximumEntries,
              let indexBytes = fields["idxfilesize"].flatMap(UInt64.init), indexBytes > 0,
              indexBytes <= resource.maximumExpandedBytes,
              fields["sametypesequence"] == "h",
              let bookName = fields["bookname"], !bookName.isEmpty else {
            throw FreeDictResourceError.unsupportedSource
        }
        return StarDictSourceInfo(wordCount: wordCount, indexFileBytes: indexBytes)
    }

    private static func buildSQLite(
        indexURL: URL,
        dictionaryURL: URL,
        outputURL: URL,
        identity: OpenResourceInstallationIdentity,
        publicationID: String,
        resource: BundledOpenResourceDefinition,
        languagePair: String,
        expectedIndexBytes: UInt64,
        expectedDictionaryBytes: UInt64,
        expectedSourceEntries: UInt64,
        progress: Progress
    ) throws -> UInt64 {
        let indexData = try Data(contentsOf: indexURL, options: [.mappedIfSafe])
        guard UInt64(indexData.count) == expectedIndexBytes else {
            throw FreeDictResourceError.malformedIndex
        }
        let dictionary = try FileHandle(forReadingFrom: dictionaryURL)
        defer { try? dictionary.close() }
        var database: OpaquePointer?
        guard sqlite3_open_v2(outputURL.path, &database,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let database else {
            throw FreeDictResourceError.sqliteFailure
        }
        defer { sqlite3_close(database) }
        guard chmod(outputURL.path, 0o600) == 0 else { throw FreeDictResourceError.sqliteFailure }
        try execute(database, "PRAGMA journal_mode=DELETE")
        try execute(database, "PRAGMA synchronous=FULL")
        try execute(database, "PRAGMA temp_store=FILE")
        try execute(database, "CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
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
        try execute(database, "CREATE INDEX entries_headword ON entries(normalized_headword,id)")
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
            "language_pair": languagePair
        ]
        for pair in metadata { try insertMetadata(database, key: pair.key, value: pair.value) }
        var entryStatement: OpaquePointer?
        var termStatement: OpaquePointer?
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
            throw FreeDictResourceError.sqliteFailure
        }
        defer { sqlite3_finalize(entryStatement); sqlite3_finalize(termStatement) }
        try execute(database, "BEGIN IMMEDIATE")
        var cursor = 0
        var sourceCount: UInt64 = 0
        var insertedCount: UInt64 = 0
        var previousOffset: UInt64 = 0
        while cursor < indexData.count {
            try cancellationPoint()
            guard let terminator = indexData[cursor...].firstIndex(of: 0),
                  terminator > cursor,
                  terminator - cursor <= 512,
                  terminator + 9 <= indexData.count,
                  let headword = String(data: indexData[cursor..<terminator], encoding: .utf8)
            else { throw FreeDictResourceError.malformedIndex }
            let offset = UInt64(readBigEndian(indexData, at: terminator + 1))
            let size = UInt64(readBigEndian(indexData, at: terminator + 5))
            guard size > 0, size <= resource.maximumEntryBytes,
                  offset >= previousOffset,
                  offset + size <= expectedDictionaryBytes else {
                throw FreeDictResourceError.malformedIndex
            }
            previousOffset = offset
            try dictionary.seek(toOffset: offset)
            let html = try dictionary.read(upToCount: Int(size)) ?? Data()
            guard html.count == Int(size), let htmlText = String(data: html, encoding: .utf8) else {
                throw FreeDictResourceError.invalidEntry
            }
            let parsed = try StarDictHTMLSubset.parse(
                htmlText,
                requireCJK: archivePair(for: resource).hasSuffix("-zho")
            )
            let display = headword.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizeHeadword(display)
            guard !display.isEmpty, display.count <= 160, !normalized.isEmpty else {
                throw FreeDictResourceError.invalidEntry
            }
            sourceCount += 1
            cursor = terminator + 9
            guard sourceCount <= resource.maximumEntries else {
                throw FreeDictResourceError.malformedIndex
            }
            if parsed.chineseDefinition.isEmpty {
                if sourceCount % 256 == 0 {
                    progress(.converting(processed: sourceCount,
                                         total: resource.expectedEntryCount))
                }
                continue
            }
            insertedCount += 1
            let sourceEntryID = "stardict:\(sourceCount):\(offset)"
            let snippet = ReverseLookupNormalizer.snippet(parsed.chineseDefinition, maximum: 480)
            let values = [normalized, display, languagePair, parsed.partOfSpeech,
                          parsed.chineseDefinition,
                          sourceEntryID, resource.resourceID, resource.version, resource.sha256,
                          resource.transformerVersion, snippet]
            sqlite3_reset(entryStatement); sqlite3_clear_bindings(entryStatement)
            for (index, value) in values.enumerated() {
                bind(value, to: entryStatement, at: Int32(index + 1))
            }
            guard sqlite3_step(entryStatement) == SQLITE_DONE else {
                throw FreeDictResourceError.sqliteFailure
            }
            let rowID = sqlite3_last_insert_rowid(database)
            for (term, weight) in ReverseLookupNormalizer.weightedTerms(
                in: parsed.chineseDefinition
            ) {
                sqlite3_reset(termStatement); sqlite3_clear_bindings(termStatement)
                bind(term, to: termStatement, at: 1)
                sqlite3_bind_int64(termStatement, 2, rowID)
                sqlite3_bind_int(termStatement, 3, Int32(weight))
                guard sqlite3_step(termStatement) == SQLITE_DONE else {
                    throw FreeDictResourceError.sqliteFailure
                }
            }
            if insertedCount % 4_096 == 0 {
                try execute(database, "COMMIT")
                progress(.buildingIndex(processed: sourceCount,
                                        total: resource.expectedEntryCount))
                let delay = ReverseIndexThermalPacing.delayMicroseconds(
                    for: ProcessInfo.processInfo.thermalState
                )
                if delay > 0 { usleep(delay) } else { sched_yield() }
                try execute(database, "BEGIN IMMEDIATE")
            } else if sourceCount % 256 == 0 {
                progress(.converting(processed: sourceCount,
                                     total: resource.expectedEntryCount))
            }
        }
        guard sourceCount == expectedSourceEntries else {
            throw FreeDictResourceError.malformedIndex
        }
        try execute(database, "COMMIT")
        try insertMetadata(database, key: "entry_count", value: String(insertedCount))
        try insertMetadata(database, key: "source_entry_count", value: String(sourceCount))
        try insertMetadata(database, key: "skipped_entry_count",
                           value: String(sourceCount - insertedCount))
        try execute(database, "ANALYZE")
        try execute(database, "PRAGMA optimize")
        return insertedCount
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
              let database else { throw FreeDictResourceError.integrityFailure }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) ==
                SQLITE_OK else { throw FreeDictResourceError.integrityFailure }
        guard sqlite3_step(statement) == SQLITE_ROW,
              String(cString: sqlite3_column_text(statement, 0)) == "ok" else {
            sqlite3_finalize(statement)
            throw FreeDictResourceError.integrityFailure
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
        for pair in expected where try metadata(database, key: pair.key) != pair.value {
            throw FreeDictResourceError.integrityFailure
        }
    }

    private enum DigestAlgorithm { case sha256, sha512 }

    private static func digest(_ url: URL, algorithm: DigestAlgorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256()
        var sha512 = SHA512()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try cancellationPoint()
            switch algorithm {
            case .sha256: sha256.update(data: data)
            case .sha512: sha512.update(data: data)
            }
        }
        let bytes: [UInt8]
        switch algorithm {
        case .sha256: bytes = Array(sha256.finalize())
        case .sha512: bytes = Array(sha512.finalize())
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func boundedCopy(_ source: URL, to destination: URL,
                                    expectedBytes: UInt64) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let fd = destination.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw FreeDictResourceError.publicationConflict }
        defer { Darwin.close(fd) }
        var total: UInt64 = 0
        while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
            try cancellationPoint()
            total += UInt64(data.count)
            guard total <= expectedBytes else { throw FreeDictResourceError.sourceDigestMismatch }
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let result = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                    guard result > 0 else { throw FreeDictResourceError.sqliteFailure }
                    offset += result
                }
            }
        }
        guard total == expectedBytes, fsync(fd) == 0 else {
            throw FreeDictResourceError.sourceDigestMismatch
        }
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let fd = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw FreeDictResourceError.publicationConflict }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let result = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                guard result > 0 else { throw FreeDictResourceError.sqliteFailure }
                offset += result
            }
        }
        guard fsync(fd) == 0 else { throw FreeDictResourceError.sqliteFailure }
    }

    private static func regularFileSize(_ url: URL) throws -> UInt64 {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              value.st_nlink == 1, value.st_size > 0 else {
            throw FreeDictResourceError.integrityFailure
        }
        return UInt64(value.st_size)
    }

    private static func synchronize(_ url: URL) throws {
        let flags = url.hasDirectoryPath ? O_RDONLY | O_DIRECTORY : O_RDONLY
        let fd = url.path.withCString { Darwin.open($0, flags | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw FreeDictResourceError.sqliteFailure }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw FreeDictResourceError.sqliteFailure }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        if result == SQLITE_INTERRUPT || Task.isCancelled { throw FreeDictResourceError.cancelled }
        guard result == SQLITE_OK else { throw FreeDictResourceError.sqliteFailure }
    }

    private static func insertMetadata(_ database: OpaquePointer,
                                       key: String, value: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "INSERT OR REPLACE INTO metadata(key,value) VALUES(?1,?2)",
            -1, &statement, nil) == SQLITE_OK else { throw FreeDictResourceError.sqliteFailure }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1); bind(value, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FreeDictResourceError.sqliteFailure
        }
    }

    private static func metadata(_ database: OpaquePointer, key: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT value FROM metadata WHERE key=?1 LIMIT 1", -1, &statement, nil) == SQLITE_OK
        else { throw FreeDictResourceError.integrityFailure }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else {
            throw FreeDictResourceError.integrityFailure
        }
        return String(cString: raw)
    }

    private static func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private static func readBigEndian(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func normalizeHeadword(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func archivePair(for resource: BundledOpenResourceDefinition) -> String {
        "\(iso6393(resource.sourceLanguage))-\(iso6393(resource.targetLanguage))"
    }

    private static func iso6393(_ value: String) -> String {
        switch value.lowercased() {
        case "zh", "zh-hans", "zho": return "zho"
        case "en", "eng": return "eng"
        case "de", "deu", "ger": return "deu"
        case "ja", "jpn": return "jpn"
        case "fr", "fra", "fre": return "fra"
        case "es", "spa": return "spa"
        case "it", "ita": return "ita"
        case "pt", "por": return "por"
        case "ru", "rus": return "rus"
        default: return value.lowercased()
        }
    }

    private static func nextFallbackPosition(_ catalog: DictionaryCatalog) -> Int64 {
        (catalog.dictionaries.filter { $0.queryLevel == .fallback }
            .map(\.sortPosition).max() ?? -1) + 1
    }

    private static func cancellationPoint() throws {
        if Task.isCancelled { throw FreeDictResourceError.cancelled }
    }
}

private enum StarDictHTMLSubset {
    struct Parsed { let partOfSpeech: String; let chineseDefinition: String }

    static func parse(_ source: String, requireCJK: Bool = true) throws -> Parsed {
        guard source.utf8.count <= 16 * 1024,
              !source.localizedCaseInsensitiveContains("<!doctype"),
              !source.localizedCaseInsensitiveContains("<!entity") else {
            throw FreeDictResourceError.invalidEntry
        }
        var depth = 0
        var divDepth = 0
        var grammarDepth = 0
        var position = source.startIndex
        var chinese: [String] = []
        var partOfSpeech = ""
        var totalText = 0
        while position < source.endIndex {
            if source[position] == "<" {
                guard let close = source[position...].firstIndex(of: ">") else {
                    throw FreeDictResourceError.invalidEntry
                }
                let tag = String(source[source.index(after: position)..<close]).lowercased()
                let closing = tag.hasPrefix("/")
                let name = tag.drop(while: { $0 == "/" || $0.isWhitespace })
                    .prefix(while: { $0.isLetter || $0.isNumber })
                if closing {
                    depth = max(0, depth - 1)
                    if name == "div" { divDepth = max(0, divDepth - 1) }
                    if name == "font", grammarDepth > 0 { grammarDepth -= 1 }
                } else if name != "br" {
                    depth += 1
                    guard depth <= 64 else { throw FreeDictResourceError.invalidEntry }
                    if name == "div" { divDepth += 1 }
                    if name == "font", tag.contains("class=\"grammar\"") ||
                        tag.contains("class='grammar'") { grammarDepth += 1 }
                }
                position = source.index(after: close)
                continue
            }
            let next = source[position...].firstIndex(of: "<") ?? source.endIndex
            let raw = String(source[position..<next])
            let text = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            totalText += text.count
            guard totalText <= 12_000 else { throw FreeDictResourceError.invalidEntry }
            if grammarDepth > 0, !text.isEmpty {
                partOfSpeech = String(text.prefix(64))
            }
            if divDepth > 0, !text.isEmpty, !requireCJK || containsCJK(text) {
                let bounded = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if !bounded.isEmpty { chinese.append(String(bounded.prefix(600))) }
            }
            position = next
        }
        var seen: Set<String> = []
        let definition = chinese.filter { seen.insert($0).inserted }
            .prefix(12).joined(separator: "；")
        guard definition.count <= 2_000 else {
            throw FreeDictResourceError.invalidEntry
        }
        return Parsed(partOfSpeech: partOfSpeech, chineseDefinition: definition)
    }

    private static func decodeEntities(_ source: String) -> String {
        source.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value) ||
                (0x4E00...0x9FFF).contains($0.value) ||
                (0xF900...0xFAFF).contains($0.value)
        }
    }
}

#if OPEN_RESOURCE_CONVERTER_TESTING
enum FreeDictSecurityTestHooks {
    static func parseHTML(_ value: String) throws -> (partOfSpeech: String, definition: String) {
        let parsed = try StarDictHTMLSubset.parse(value)
        return (parsed.partOfSpeech, parsed.chineseDefinition)
    }

    static func parseHTML(_ data: Data) throws -> (partOfSpeech: String, definition: String) {
        guard let value = String(data: data, encoding: .utf8) else {
            throw FreeDictResourceError.invalidEntry
        }
        return try parseHTML(value)
    }

    static func inspectArchive(_ source: URL, expected: [String: UInt64],
                               maximumExpandedBytes: UInt64) throws {
        try FreeDictStarDictInstallationCoordinator.extractArchive(
            source, expected: expected, destinations: [:],
            maximumExpandedBytes: maximumExpandedBytes
        )
    }
}
#endif

enum OpenResourceSQLiteRuntime {
    /// Validates the converted open-resource authority rather than passing it to the generic
    /// managed-MDX index verifier. The two SQLite formats intentionally have different schemas.
    static func validatePublishedIndex(
        descriptor: DictionaryDescriptor,
        applicationSupportRootURL: URL
    ) -> Bool {
        guard descriptor.sourceKind == .openResource,
              descriptor.storageOwnership == .appManagedOpenResource,
              DictionaryFormatterIdentifier.supportsOpenResourceSQLite(
                descriptor.formatterIdentifier
              ), descriptor.state == .ready,
              let resource = descriptor.openResourceMetadata,
              let published = descriptor.publishedIndexIdentity,
              descriptor.relativePaths.index == published.relativePath,
              descriptor.indexMetadata.entryCount == published.entryCount,
              descriptor.indexMetadata.schemaVersion == published.schemaVersion else {
            return false
        }
        let indexURL = applicationSupportRootURL.appendingPathComponent(published.relativePath)
        do {
            guard try safeRegular(indexURL, bytes: published.indexFileSize),
                  try sha256(indexURL) == published.indexSHA256 else { return false }
            var database: OpaquePointer?
            guard sqlite3_open_v2(
                indexURL.path, &database,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
            ) == SQLITE_OK, let database else { return false }
            defer { sqlite3_close(database) }
            sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
            guard quickCheck(database),
                  try metadataValue(database, "dictionary_id") == descriptor.dictionaryID,
                  try metadataValue(database, "resource_id") == resource.resourceID,
                  try metadataValue(database, "source_sha256") == resource.payloadSHA256,
                  try metadataValue(database, "index_publication_id") ==
                    published.indexPublicationID,
                  try metadataValue(database, "open_resource_schema_version") ==
                    String(published.schemaVersion),
                  try metadataValue(database, "entry_count") == String(published.entryCount)
            else { return false }
            return true
        } catch {
            return false
        }
    }

    static func lookup(descriptor: DictionaryDescriptor, query: String,
                       applicationSupportRootURL: URL) throws -> ManagedDictionaryRuntimeOutcome {
        guard DictionaryFormatterIdentifier.supportsOpenResourceSQLite(
                descriptor.formatterIdentifier
              ), descriptor.sourceKind == .openResource,
              descriptor.storageOwnership == .appManagedOpenResource,
              descriptor.queryLevel == .fallback, descriptor.enabled,
              descriptor.state == .ready,
              let metadata = descriptor.openResourceMetadata,
              let published = descriptor.publishedIndexIdentity,
              descriptor.relativePaths.index == published.relativePath else {
            return .identityMismatch
        }
        let indexURL = applicationSupportRootURL.appendingPathComponent(published.relativePath)
        guard try safeRegular(indexURL, bytes: published.indexFileSize),
              try sha256(indexURL) == published.indexSHA256 else {
            return .identityMismatch
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(indexURL.path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return .identityMismatch }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        guard try metadataValue(database, "dictionary_id") == descriptor.dictionaryID,
              try metadataValue(database, "source_sha256") == metadata.payloadSHA256,
              try metadataValue(database, "index_publication_id") ==
                published.indexPublicationID else { return .identityMismatch }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, """
            SELECT display_headword,part_of_speech,chinese_definition
            FROM entries WHERE normalized_headword=?1 ORDER BY id LIMIT 8
            """, -1, &statement, nil) == SQLITE_OK else { return .identityMismatch }
        defer { sqlite3_finalize(statement) }
        let normalized = FreeDictStarDictInstallationCoordinator.normalizeHeadword(query)
        sqlite3_bind_text(statement, 1, normalized, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var blocks: [GenericMDictBlock] = []
        var plain: [String] = []
        var matched = query
        while sqlite3_step(statement) == SQLITE_ROW {
            let headword = string(statement, 0)
            let part = string(statement, 1)
            let definition = string(statement, 2)
            matched = headword
            let text = part.isEmpty ? definition : "\(part)：\(definition)"
            plain.append(text)
            blocks.append(GenericMDictBlock(
                kind: .paragraph, level: 0,
                runs: [GenericMDictTextRun(text: text, bold: false, italic: false, code: false)]
            ))
        }
        guard !blocks.isEmpty else { return .miss }
        return .hit(ManagedDictionaryQueryHit(
            dictionaryID: descriptor.dictionaryID,
            displayName: descriptor.displayName,
            matchedHeadword: matched,
            blocks: blocks,
            plainText: plain.joined(separator: "\n"),
            truncated: false,
            sourcePriority: descriptor.queryLevel.rank,
            dictionaryOrder: descriptor.sortPosition
        ))
    }

    static func reverseDescriptor(descriptor: DictionaryDescriptor,
                                  applicationSupportRootURL: URL)
        throws -> ReverseIndexDescriptor {
        guard let published = descriptor.publishedIndexIdentity,
              let source = descriptor.indexMetadata.sourceSHA256,
              let indexPath = descriptor.relativePaths.index,
              DictionaryFormatterIdentifier.supportsOpenResourceSQLite(
                descriptor.formatterIdentifier
              ) else { throw FreeDictResourceError.integrityFailure }
        let url = applicationSupportRootURL.appendingPathComponent(indexPath)
        guard try safeRegular(url, bytes: published.indexFileSize),
              try sha256(url) == published.indexSHA256 else {
            throw FreeDictResourceError.integrityFailure
        }
        return ReverseIndexDescriptor(
            fileURL: url,
            identity: ReverseIndexIdentity(
                schemaVersion: ReverseIndexIdentity.openResourceSchemaVersion,
                dictionaryID: descriptor.dictionaryID,
                dictionaryName: descriptor.displayName,
                sourceSHA256: source,
                indexPublicationID: published.indexPublicationID,
                queryPriority: descriptor.queryLevel.rank,
                sortPosition: descriptor.sortPosition
            )
        )
    }

    private static func metadataValue(_ database: OpaquePointer, _ key: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT value FROM metadata WHERE key=?1 LIMIT 1", -1, &statement, nil) == SQLITE_OK
        else { throw FreeDictResourceError.integrityFailure }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw FreeDictResourceError.integrityFailure
        }
        return string(statement, 0)
    }

    private static func quickCheck(_ database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) ==
                SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW && string(statement, 0) == "ok"
    }

    private static func safeRegular(_ url: URL, bytes: UInt64) throws -> Bool {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return false }
        return value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) &&
            value.st_nlink == 1 && UInt64(value.st_size) == bytes
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func string(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}
#endif
