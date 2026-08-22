import CryptoKit
import Darwin
import Foundation
import SQLite3

struct ReverseIndexStoredState: Equatable, Sendable {
    let dictionaryID: String
    let stage: ReverseIndexBuildStage
    let descriptor: ReverseIndexDescriptor?
    let builtAt: Date?
    let fileSize: UInt64?
    let failureReason: String?
    var entryCount: UInt64? = nil
    var glossCount: UInt64? = nil
    var lastValidatedAt: Date? = nil
}

enum ReverseIndexInventory {
    static func inspect(
        sources: [ReverseDictionarySource],
        rootURL: URL = DictionaryImportService.defaultApplicationSupportRootURL()
            .appendingPathComponent("ReverseIndexes", isDirectory: true)
    ) -> [ReverseIndexStoredState] {
        sources.map { source in
            if case .internalOpenResource(let descriptor) = source.backing {
                if source.reverseCapability == .nativeChineseLookup {
                    return ReverseIndexStoredState(
                        dictionaryID: source.dictionaryID, stage: .ready,
                        descriptor: nil,
                        builtAt: descriptor.indexMetadata.indexedAt,
                        fileSize: descriptor.indexMetadata.indexFileSize,
                        failureReason: nil
                    )
                }
                if source.reverseCapability == .notApplicable {
                    return ReverseIndexStoredState(
                        dictionaryID: source.dictionaryID, stage: .notApplicable,
                        descriptor: nil, builtAt: nil, fileSize: nil,
                        failureReason: nil
                    )
                }
                guard source.reverseCapability == .derivedReady else {
                    return ReverseIndexStoredState(
                        dictionaryID: source.dictionaryID, stage: .notApplicable,
                        descriptor: nil, builtAt: nil, fileSize: nil,
                        failureReason: source.reverseCapability.displayName
                    )
                }
                do {
                    let value = try OpenResourceSQLiteRuntime.reverseDescriptor(
                        descriptor: descriptor,
                        applicationSupportRootURL:
                            DictionaryImportService.defaultApplicationSupportRootURL()
                    )
                    return ReverseIndexStoredState(
                        dictionaryID: source.dictionaryID, stage: .ready,
                        descriptor: value,
                        builtAt: descriptor.indexMetadata.indexedAt,
                        fileSize: descriptor.indexMetadata.indexFileSize,
                        failureReason: nil,
                        entryCount: descriptor.indexMetadata.entryCount,
                        glossCount: descriptor.indexMetadata.entryCount,
                        lastValidatedAt: descriptor.indexMetadata.indexedAt
                    )
                } catch {
                    return ReverseIndexStoredState(
                        dictionaryID: source.dictionaryID, stage: .stale,
                        descriptor: nil, builtAt: nil, fileSize: nil,
                        failureReason: ReverseIndexError.stale.errorDescription
                    )
                }
            }
            let url = rootURL.appendingPathComponent(
                "\(safeFileComponent(source.dictionaryID)).reverse.sqlite"
            )
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ReverseIndexStoredState(
                    dictionaryID: source.dictionaryID, stage: .notBuilt,
                    descriptor: nil, builtAt: nil, fileSize: nil, failureReason: nil
                )
            }
            do {
                let identity = try readIdentity(at: url)
                guard identity.dictionaryID == source.dictionaryID,
                      identity.dictionaryName == source.dictionaryName,
                      identity.queryPriority == source.queryPriority,
                      identity.sortPosition == source.sortPosition else {
                    throw ReverseIndexError.stale
                }
                try validate(identity: identity, source: source)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let counts = try readMetadata(
                    at: url, keys: ["entry_count", "applicable_entry_count"]
                )
                return ReverseIndexStoredState(
                    dictionaryID: source.dictionaryID, stage: .ready,
                    descriptor: ReverseIndexDescriptor(fileURL: url, identity: identity),
                    builtAt: attributes[.modificationDate] as? Date,
                    fileSize: (attributes[.size] as? NSNumber)?.uint64Value,
                    failureReason: nil,
                    entryCount: counts["entry_count"].flatMap(UInt64.init),
                    glossCount: counts["applicable_entry_count"].flatMap(UInt64.init),
                    lastValidatedAt: attributes[.modificationDate] as? Date
                )
            } catch {
                return ReverseIndexStoredState(
                    dictionaryID: source.dictionaryID, stage: .stale,
                    descriptor: nil, builtAt: nil, fileSize: nil,
                    failureReason: (error as? LocalizedError)?.errorDescription ??
                        ReverseIndexError.stale.errorDescription
                )
            }
        }
    }

    private static func validate(identity: ReverseIndexIdentity,
                                 source: ReverseDictionarySource) throws {
        switch source.backing {
        case .legacy(let legacy):
            try validateLegacyForwardBinding(legacy)
            let indexSHA = try sha256File(legacy.indexURL)
            guard identity.indexPublicationID == "legacy-forward-v1-\(indexSHA)" else {
                throw ReverseIndexError.stale
            }
        case .managed(let descriptor):
            guard let publication = descriptor.publishedIndexIdentity,
                  identity.sourceSHA256 == publication.sourceSHA256,
                  identity.indexPublicationID == publication.indexPublicationID else {
                throw ReverseIndexError.stale
            }
        case .internalOpenResource:
            break
        }
    }

    /// Legacy forward indexes already bind the source's size, timestamps, inode and device.
    /// Rechecking that binding avoids reading the private MDX body during app startup while the
    /// reverse sidecar remains bound to the SHA-256 captured by the fd-bound build operation.
    private static func validateLegacyForwardBinding(
        _ identity: LegacyReverseDictionaryIdentity
    ) throws {
        var status = stat()
        guard lstat(identity.dictionaryURL.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            throw ReverseIndexError.stale
        }
        let values = try readMetadata(
            at: identity.indexURL,
            keys: ["schema_version", "source_name", "source_size",
                   "source_mtime_seconds", "source_mtime_nanoseconds",
                   "source_inode", "source_device"]
        )
        guard values["schema_version"] == String(liveDictionaryIndexSchemaVersion),
              values["source_name"] == identity.dictionaryURL.lastPathComponent,
              values["source_size"] == String(status.st_size),
              values["source_mtime_seconds"] == String(status.st_mtimespec.tv_sec),
              values["source_mtime_nanoseconds"] == String(status.st_mtimespec.tv_nsec),
              values["source_inode"] == String(status.st_ino),
              values["source_device"] == String(status.st_dev) else {
            throw ReverseIndexError.stale
        }
    }

    private static func readIdentity(at url: URL) throws -> ReverseIndexIdentity {
        let values = try readMetadata(
            at: url,
            keys: ["reverse_schema_version", "dictionary_id", "dictionary_name",
                   "source_sha256", "index_publication_id", "query_priority",
                   "sort_position"]
        )
        guard let schemaText = values["reverse_schema_version"],
              let schemaVersion = Int(schemaText),
              schemaVersion == ReverseIndexIdentity.schemaVersion,
              let dictionaryID = values["dictionary_id"], !dictionaryID.isEmpty,
              let dictionaryName = values["dictionary_name"], !dictionaryName.isEmpty,
              let sourceSHA = values["source_sha256"],
              OpenResourceInstallationMetadata.isSHA256(sourceSHA),
              let publication = values["index_publication_id"], !publication.isEmpty,
              let priorityText = values["query_priority"],
              let priority = Int(priorityText),
              let positionText = values["sort_position"],
              let position = Int64(positionText) else {
            throw ReverseIndexError.corrupt
        }
        return ReverseIndexIdentity(
            schemaVersion: schemaVersion,
            dictionaryID: dictionaryID, dictionaryName: dictionaryName,
            sourceSHA256: sourceSHA, indexPublicationID: publication,
            queryPriority: priority, sortPosition: position
        )
    }

    private static func readMetadata(at url: URL, keys: [String]) throws
        -> [String: String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw ReverseIndexError.corrupt
        }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT value FROM metadata WHERE key=?1 LIMIT 1", -1,
            &statement, nil) == SQLITE_OK else { throw ReverseIndexError.corrupt }
        defer { sqlite3_finalize(statement) }
        var output: [String: String] = [:]
        for key in keys {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, key, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(statement) == SQLITE_ROW,
               let value = sqlite3_column_text(statement, 0) {
                output[key] = String(cString: value)
            }
        }
        return output
    }

    private static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func safeFileComponent(_ source: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        return String(source.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : Character("_")
        }.prefix(128))
    }
}
