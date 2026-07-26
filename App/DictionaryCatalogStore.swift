import Darwin
import Foundation

enum DictionaryCatalogLoadProvenance: Equatable, Sendable {
    case missing
    case loadedPrimary
    case loadedBackup
    case migratedFromV1
    case corrupt
    case unsupportedVersion
}

struct DictionaryCatalogLoadResult: Sendable {
    let catalog: DictionaryCatalog?
    let provenance: DictionaryCatalogLoadProvenance
}

enum DictionaryCatalogStoreError: LocalizedError {
    case catalogCorrupt
    case unsupportedCatalogVersion
    case corrupt
    case unsupportedVersion
    case unsupportedLegacyOpenResource
    case durabilityFailure
    case unsafePath
    case ioFailure

    var errorDescription: String? {
        switch self {
        case .catalogCorrupt: return "词典目录文件已损坏，已禁止写入。"
        case .unsupportedCatalogVersion: return "词典目录版本不受支持，已禁止写入。"
        case .corrupt: return "词典目录文件已损坏。"
        case .unsupportedVersion: return "词典目录版本不受支持。"
        case .unsupportedLegacyOpenResource: return "旧开放词典缺少可验证的安装身份。"
        case .durabilityFailure: return "词典目录未能安全写入磁盘。"
        case .unsafePath: return "词典目录路径不安全。"
        case .ioFailure: return "词典目录无法读写。"
        }
    }
}

@MainActor
final class DictionaryCatalogStore {
    static let catalogFileName = "catalog-v2.json"
    static let backupFileName = "catalog-v2.backup.json"
    static let legacyCatalogFileName = "catalog-v1.json"
    static let legacyBackupFileName = "catalog-v1.backup.json"

    let directoryURL: URL
    let catalogURL: URL
    let backupURL: URL
    let legacyCatalogURL: URL
    let legacyBackupURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL = DictionaryCatalogStore.defaultDirectoryURL(),
         fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.fileManager = fileManager
        catalogURL = self.directoryURL.appendingPathComponent(Self.catalogFileName)
        backupURL = self.directoryURL.appendingPathComponent(Self.backupFileName)
        legacyCatalogURL = self.directoryURL.appendingPathComponent(Self.legacyCatalogFileName)
        legacyBackupURL = self.directoryURL.appendingPathComponent(Self.legacyBackupFileName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    nonisolated static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("LocalDictionary/Catalog", isDirectory: true)
    }

    /// Read-only compatibility entry point. Mutation paths must use `mutate` so corruption and
    /// unsupported-version provenance can never be silently written back as an empty catalog.
    func load() -> DictionaryCatalog { loadResult().catalog ?? .empty() }

    func loadResult() -> DictionaryCatalogLoadResult {
        let primary = decodeV2(at: catalogURL)
        if case let .valid(catalog) = primary {
            return DictionaryCatalogLoadResult(catalog: catalog, provenance: .loadedPrimary)
        }
        let backup = decodeV2(at: backupURL)
        if case let .valid(catalog) = backup {
            return DictionaryCatalogLoadResult(catalog: catalog, provenance: .loadedBackup)
        }
        if primary == .missing && backup == .missing {
            let legacyPrimary = decodeV1(at: legacyCatalogURL)
            if case let .valid(catalog) = legacyPrimary {
                return migrationResult(for: catalog)
            }
            let legacyBackup = decodeV1(at: legacyBackupURL)
            if case let .valid(catalog) = legacyBackup {
                return migrationResult(for: catalog)
            }
            if legacyPrimary == .missing && legacyBackup == .missing {
                return DictionaryCatalogLoadResult(catalog: .empty(), provenance: .missing)
            }
            return DictionaryCatalogLoadResult(catalog: nil,
                                               provenance: hasUnsupported(legacyPrimary, legacyBackup)
                                               ? .unsupportedVersion : .corrupt)
        }
        return DictionaryCatalogLoadResult(catalog: nil,
                                           provenance: hasUnsupported(primary, backup)
                                           ? .unsupportedVersion : .corrupt)
    }

    /// Applies a short, durable read-modify-write transaction.  The closure runs while the
    /// process lock is held and therefore must not perform download, copying, indexing, or query
    /// work.  It always starts from the latest durable Catalog.
    @discardableResult
    func mutate<T>(_ body: (inout DictionaryCatalog, DictionaryCatalogLoadProvenance) throws -> T)
        throws -> (catalog: DictionaryCatalog, value: T) {
        try withMutationLock {
            let loaded = loadResult()
            let current = try mutableCatalog(from: loaded)
            var updated = current
            let value = try body(&updated, loaded.provenance)
            if updated != current {
                try saveLocked(updated, previous: current, provenance: loaded.provenance)
            }
            return (updated, value)
        }
    }

    /// Compatibility save for callers not yet able to express a delta.  It still obtains the
    /// same lock and refuses corrupt or unsupported state; new code should prefer `mutate`.
    func save(_ catalog: DictionaryCatalog) throws {
        _ = try mutate { current, _ in
            current = catalog
        }
    }

    /// A short cross-process critical section.  It is intentionally separate from loading so the
    /// install coordinator can reload, validate uniqueness, publish and save atomically.
    func withMutationLock<T>(_ body: () throws -> T) throws -> T {
        try ensureDirectory()
        let directoryFD = try openDirectory()
        defer { Darwin.close(directoryFD) }
        let lockFD = "catalog-mutation.lock".withCString {
            Darwin.openat(directoryFD, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard lockFD >= 0 else { throw mappedError() }
        defer { Darwin.close(lockFD) }
        var metadata = stat()
        guard Darwin.fstat(lockFD, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              (metadata.st_mode & mode_t(0o022)) == 0 else { throw DictionaryCatalogStoreError.unsafePath }
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        guard Darwin.fcntl(lockFD, F_SETLKW, &lock) != -1 else {
            throw DictionaryCatalogStoreError.ioFailure
        }
        defer {
            var unlock = Darwin.flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            _ = Darwin.fcntl(lockFD, F_SETLK, &unlock)
        }
        return try body()
    }

    private func mutableCatalog(from result: DictionaryCatalogLoadResult) throws -> DictionaryCatalog {
        guard let catalog = result.catalog else {
            switch result.provenance {
            case .corrupt: throw DictionaryCatalogStoreError.catalogCorrupt
            case .unsupportedVersion: throw DictionaryCatalogStoreError.unsupportedCatalogVersion
            default: throw DictionaryCatalogStoreError.ioFailure
            }
        }
        return catalog
    }

    /// Writes a new primary while preserving the immediately preceding valid v2 primary as the
    /// backup.  A v1/missing first commit intentionally has no synthetic backup; a loaded v2
    /// backup remains untouched while it serves as the previous valid state.
    private func saveLocked(_ catalog: DictionaryCatalog,
                            previous: DictionaryCatalog,
                            provenance: DictionaryCatalogLoadProvenance) throws {
        let validated = try catalog.validated()
        let newData = try encoder.encode(validated)
        try ensureDirectory()
        let directoryFD = try openDirectory()
        defer { Darwin.close(directoryFD) }
        let operation = UUID().uuidString.lowercased()
        let temporaryPrimary = ".\(Self.catalogFileName).\(operation).tmp"
        let temporaryBackup = ".\(Self.backupFileName).\(operation).tmp"
        defer {
            unlinkAt(directoryFD, temporaryPrimary)
            unlinkAt(directoryFD, temporaryBackup)
        }

        if provenance == .loadedPrimary {
            let previousData = try encoder.encode(previous.validated())
            try writeExclusive(previousData, directoryFD: directoryFD, component: temporaryBackup)
            try replace(directoryFD: directoryFD, source: temporaryBackup,
                        destination: Self.backupFileName)
            try synchronize(directoryFD)
        }

        try writeExclusive(newData, directoryFD: directoryFD, component: temporaryPrimary)
        try replace(directoryFD: directoryFD, source: temporaryPrimary,
                    destination: Self.catalogFileName)
        try synchronize(directoryFD)
    }

    private enum Decoded<T: Equatable>: Equatable {
        case missing
        case valid(T)
        case corrupt
        case unsupported
    }

    private func decodeV2(at url: URL) -> Decoded<DictionaryCatalog> {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .corrupt }
        guard let catalog = try? decoder.decode(DictionaryCatalog.self, from: data) else { return .corrupt }
        do { return .valid(try catalog.validated()) }
        catch DictionaryCatalogValidationError.unsupportedSchemaVersion { return .unsupported }
        catch { return .corrupt }
    }

    private struct CatalogV1: Codable, Equatable {
        let schemaVersion: Int
        let createdAt: Date
        let updatedAt: Date
        let dictionaries: [DescriptorV1]
    }

    private struct DescriptorV1: Codable, Equatable {
        let dictionaryID: String
        let displayName: String
        let sourceKind: DictionarySourceKind
        let queryLevel: DictionaryQueryLevel
        let sortPosition: Int64
        let enabled: Bool
        let state: DictionaryState
        let indexMetadata: DictionaryIndexMetadata
        let formatterIdentifier: String
        let capabilities: DictionaryCapabilities
        let relativePaths: DictionaryRelativePaths
        let createdAt: Date
        let updatedAt: Date
    }

    private func decodeV1(at url: URL) -> Decoded<CatalogV1> {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let catalog = try? decoder.decode(CatalogV1.self, from: data) else { return .corrupt }
        return catalog.schemaVersion == 1 ? .valid(catalog) : .unsupported
    }

    private func migrationResult(for legacy: CatalogV1) -> DictionaryCatalogLoadResult {
        do {
            let dictionaries = try legacy.dictionaries.map { legacyDescriptor -> DictionaryDescriptor in
                guard legacyDescriptor.sourceKind != .openResource,
                      let ownership = DictionaryOwnershipPolicy.defaultOwnership(for: legacyDescriptor.sourceKind) else {
                    throw DictionaryCatalogStoreError.unsupportedLegacyOpenResource
                }
                return DictionaryDescriptor(dictionaryID: legacyDescriptor.dictionaryID,
                                            displayName: legacyDescriptor.displayName,
                                            sourceKind: legacyDescriptor.sourceKind,
                                            queryLevel: legacyDescriptor.queryLevel,
                                            sortPosition: legacyDescriptor.sortPosition,
                                            enabled: legacyDescriptor.enabled,
                                            state: legacyDescriptor.state,
                                            indexMetadata: legacyDescriptor.indexMetadata,
                                            formatterIdentifier: legacyDescriptor.formatterIdentifier,
                                            capabilities: legacyDescriptor.capabilities,
                                            relativePaths: legacyDescriptor.relativePaths,
                                            createdAt: legacyDescriptor.createdAt,
                                            updatedAt: legacyDescriptor.updatedAt,
                                            storageOwnership: ownership,
                                            openResourceMetadata: nil)
            }
            let catalog = DictionaryCatalog(schemaVersion: DictionaryCatalog.currentSchemaVersion,
                                            createdAt: legacy.createdAt, updatedAt: legacy.updatedAt,
                                            dictionaries: dictionaries)
            return DictionaryCatalogLoadResult(catalog: try catalog.validated(), provenance: .migratedFromV1)
        } catch DictionaryCatalogStoreError.unsupportedLegacyOpenResource {
            return DictionaryCatalogLoadResult(catalog: nil, provenance: .unsupportedVersion)
        } catch { return DictionaryCatalogLoadResult(catalog: nil, provenance: .corrupt) }
    }

    private func hasUnsupported<T: Equatable>(_ left: Decoded<T>, _ right: Decoded<T>) -> Bool {
        if case .unsupported = left { return true }
        if case .unsupported = right { return true }
        return false
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var metadata = stat()
        guard lstat(directoryURL.path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (metadata.st_mode & mode_t(S_IFLNK)) == 0,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & mode_t(0o022)) == 0 else { throw DictionaryCatalogStoreError.unsafePath }
    }

    private func openDirectory() throws -> Int32 {
        let descriptor = directoryURL.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw mappedError() }
        return descriptor
    }

    private func writeExclusive(_ data: Data, directoryFD: Int32, component: String) throws {
        let descriptor = component.withCString {
            Darwin.openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw mappedError() }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { throw DictionaryCatalogStoreError.ioFailure }
            }
        }
        try synchronize(descriptor)
    }

    private func replace(directoryFD: Int32, source: String, destination: String) throws {
        let result = source.withCString { sourceName in
            destination.withCString { destinationName in Darwin.renameat(directoryFD, sourceName, directoryFD, destinationName) }
        }
        guard result == 0 else { throw mappedError() }
    }

    private func synchronize(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else { throw DictionaryCatalogStoreError.durabilityFailure }
    }

    private func unlinkAt(_ directoryFD: Int32, _ component: String) {
        _ = component.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
    }

    private func mappedError() -> DictionaryCatalogStoreError {
        switch errno {
        case ELOOP, ENOTDIR: return .unsafePath
        default: return .ioFailure
        }
    }
}
