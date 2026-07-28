import CryptoKit
import Foundation
import SQLite3

enum GenericMDictBlockKind: String, Equatable, Sendable {
    case heading
    case paragraph
    case listItem
    case blockquote
    case preformatted
}

struct GenericMDictTextRun: Equatable, Sendable {
    let text: String
    let bold: Bool
    let italic: Bool
    let code: Bool
}

struct GenericMDictBlock: Equatable, Sendable {
    let kind: GenericMDictBlockKind
    let level: Int
    let runs: [GenericMDictTextRun]

    var text: String { runs.map(\.text).joined() }
}

struct ManagedDictionaryQueryHit: Equatable, Sendable {
    let dictionaryID: String
    let displayName: String
    let matchedHeadword: String
    let blocks: [GenericMDictBlock]
    let plainText: String
    let truncated: Bool

    var noteDefinitions: [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for block in blocks {
            let clean = Self.singleLine(block.text, maximum: 800)
            guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
            output.append(clean)
            if output.count == 5 { break }
        }
        if output.isEmpty {
            let fallback = Self.singleLine(plainText, maximum: 800)
            if !fallback.isEmpty { output.append(fallback) }
        }
        return output
    }

    var conciseChineseDefinitions: [String] {
        noteDefinitions.filter(Self.containsCJK).prefix(2).map { $0 }
    }

    private static func singleLine(_ value: String, maximum: Int) -> String {
        let clean = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard clean.count > maximum else { return clean }
        return String(clean.prefix(maximum - 1)) + "…"
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) ||
                (0x4E00...0x9FFF).contains(scalar.value) ||
                (0xF900...0xFAFF).contains(scalar.value)
        }
    }
}

struct ManagedDictionaryQueryBatch: Equatable, Sendable {
    let hits: [ManagedDictionaryQueryHit]
    let unavailableDictionaryIDs: [String]
    let skippedBecausePreferredMatched: Bool

    static let empty = ManagedDictionaryQueryBatch(
        hits: [], unavailableDictionaryIDs: [], skippedBecausePreferredMatched: false
    )
}

enum ManagedDictionaryRuntimeOutcome: Sendable {
    case hit(ManagedDictionaryQueryHit)
    case miss
    case unavailable
}

protocol ManagedDictionaryQueryRuntime: Sendable {
    func lookup(descriptor: DictionaryDescriptor,
                generation: UInt64,
                query: String) async -> ManagedDictionaryRuntimeOutcome
    func remove(dictionaryID: String) async
    func remove(dictionaryID: String, generation: UInt64) async
    func removeAll(dictionaryID: String) async
    func reset() async
}

extension ManagedDictionaryQueryRuntime {
    /// Compatibility defaults keep synthetic runtimes source-compatible. The live runtime
    /// overrides both methods with generation-aware behaviour; production stale-result paths use
    /// only the scoped operation below.
    func remove(dictionaryID: String, generation: UInt64) async {
        await remove(dictionaryID: dictionaryID)
    }

    func removeAll(dictionaryID: String) async {
        await remove(dictionaryID: dictionaryID)
    }
}

actor ManagedDictionaryQueryService {
    static let maximumDictionariesPerQuery = 8
    static let genericFormatterIdentifier = DictionaryFormatterIdentifier.genericMDictV1

    private var catalog: DictionaryCatalog
    private let runtime: any ManagedDictionaryQueryRuntime
    nonisolated let lifecycleCoordinator: ManagedDictionaryLifecycleCoordinator

    init(catalog: DictionaryCatalog = .empty(),
         runtime: any ManagedDictionaryQueryRuntime,
         lifecycleCoordinator: ManagedDictionaryLifecycleCoordinator? = nil) {
        self.catalog = catalog
        self.runtime = runtime
        self.lifecycleCoordinator = lifecycleCoordinator ??
            ManagedDictionaryLifecycleCoordinator(catalog: catalog)
    }

    func replaceCatalog(_ catalog: DictionaryCatalog) async {
        self.catalog = catalog
        await lifecycleCoordinator.initialize(reconciledCatalog: catalog)
        // A Catalog transition may be draining an asynchronous lookup.  Do not close every
        // runtime here: keyed lifecycle operations invalidate their runtime only after their
        // exclusive permit has drained the old generation.  Generation is part of the runtime
        // cache key, so retaining an old entry cannot make it eligible for a new lookup.
    }

    /// Called only after an exclusive lifecycle permit has drained existing query leases.
    func invalidateRuntime(dictionaryID: String) async {
        await runtime.removeAll(dictionaryID: dictionaryID)
    }

    func commitCatalog(_ updatedCatalog: DictionaryCatalog) async {
        catalog = updatedCatalog
        await lifecycleCoordinator.initialize(reconciledCatalog: updatedCatalog)
    }

    func lookup(_ query: String,
                preferredMatched: Bool = false) async -> ManagedDictionaryQueryBatch {
        if preferredMatched {
            return ManagedDictionaryQueryBatch(
                hits: [], unavailableDictionaryIDs: [], skippedBecausePreferredMatched: true
            )
        }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .empty }
        let normal = catalog.sortedDictionaries.filter(Self.isManagedLocalEligible)
            .prefix(Self.maximumDictionariesPerQuery)
        let normalResult = await lookupTier(normal, query: clean)
        // Existing normal-tier aggregation is retained.  Fallback resources only run when that
        // entire tier misses, preserving preferred → managedLocal → openResource precedence.
        let fallbackResult: (hits: [ManagedDictionaryQueryHit], unavailable: [String])
        if normalResult.hits.isEmpty, !Task.isCancelled {
            let fallback = catalog.sortedDictionaries.filter(Self.isOpenResourceEligible)
                .prefix(Self.maximumDictionariesPerQuery)
            fallbackResult = await lookupTier(fallback, query: clean)
        } else {
            fallbackResult = ([], [])
        }
        return ManagedDictionaryQueryBatch(
            hits: normalResult.hits + fallbackResult.hits,
            unavailableDictionaryIDs: normalResult.unavailable + fallbackResult.unavailable,
            skippedBecausePreferredMatched: false
        )
    }

    private func lookupTier(_ descriptors: ArraySlice<DictionaryDescriptor>,
                            query: String) async -> (hits: [ManagedDictionaryQueryHit],
                                                     unavailable: [String]) {
        var hits: [ManagedDictionaryQueryHit] = []
        var unavailable: [String] = []
        for descriptor in descriptors {
            guard !Task.isCancelled else { break }
            guard let generation = await lifecycleCoordinator.generation(for: descriptor.dictionaryID)
            else { continue }
            do {
                let lease = try await lifecycleCoordinator.acquireQueryLease(
                    for: descriptor.dictionaryID, expectedGeneration: generation
                )
                let outcome = await runtime.lookup(descriptor: descriptor,
                                                   generation: lease.generation,
                                                   query: query)
                let lifecycleSnapshot = await lifecycleCoordinator.queryValidationSnapshot(
                    for: descriptor.dictionaryID
                )
                let eligible = isStillEligible(dictionaryID: descriptor.dictionaryID,
                                                expectedGeneration: generation,
                                                lifecycleSnapshot: lifecycleSnapshot)
                let release = await lifecycleCoordinator.release(lease)
                guard eligible else {
                    if release?.releasedLastLeaseForGeneration == true {
                        await runtime.remove(dictionaryID: descriptor.dictionaryID,
                                             generation: lease.generation)
                    }
                    continue
                }
                switch outcome {
                case .hit(let hit): hits.append(hit)
                case .miss: break
                case .unavailable: unavailable.append(descriptor.dictionaryID)
                }
            } catch is CancellationError {
                break
            } catch {
                // A draining, stale, or malformed fallback dictionary is isolated from the next
                // descriptor and never escalates into automatic AI.
                unavailable.append(descriptor.dictionaryID)
            }
        }
        return (hits, unavailable)
    }

    /// Must be called only after awaiting `queryValidationSnapshot`. It deliberately performs no
    /// further await, so the Catalog read and generation comparison are one query-actor turn.
    private func isStillEligible(dictionaryID: String,
                                 expectedGeneration: UInt64,
                                 lifecycleSnapshot: ManagedDictionaryLifecycleSnapshot?) -> Bool {
        guard let descriptor = catalog.dictionaries.first(where: { $0.dictionaryID == dictionaryID }),
              Self.isManagedLocalEligible(descriptor) || Self.isOpenResourceEligible(descriptor),
              let lifecycleSnapshot,
              lifecycleSnapshot.allowsCurrentGenerationResult,
              lifecycleSnapshot.generation == expectedGeneration else {
            return false
        }
        return true
    }

    private static func isManagedLocalEligible(_ descriptor: DictionaryDescriptor) -> Bool {
        descriptor.sourceKind == .managedLocal &&
            descriptor.storageOwnership == .appManagedImported &&
            descriptor.queryLevel == .normal && descriptor.enabled &&
            descriptor.state == .ready && DictionaryFormatterIdentifier.supportsGenericMDictV1(
                descriptor.formatterIdentifier
            )
    }

    private static func isOpenResourceEligible(_ descriptor: DictionaryDescriptor) -> Bool {
        descriptor.sourceKind == .openResource &&
            descriptor.storageOwnership == .appManagedOpenResource &&
            descriptor.queryLevel == .fallback && descriptor.enabled &&
            descriptor.state == .ready && descriptor.openResourceMetadata != nil &&
            DictionaryFormatterIdentifier.supportsGenericMDictV1(
                descriptor.formatterIdentifier
            )
    }
}

struct ManagedDictionaryRuntimePlan: Sendable {
    let dictionaryID: String
    let displayName: String
    let sourceURL: URL
    let indexURL: URL
    let sourceSHA256: String
    let sourceFileSize: UInt64
    let indexFileSize: UInt64
    let descriptorUpdatedAt: Date
}

enum ManagedDictionaryRuntimeValidationError: LocalizedError, Sendable {
    case ineligible
    case unsafePath
    case missingFile
    case sourceChanged
    case indexChanged
    case invalidSQLite
    case schemaMismatch

    var errorDescription: String? {
        switch self {
        case .ineligible: return "该词典当前不能参与查询。"
        case .unsafePath: return "托管词典路径无效。"
        case .missingFile: return "托管词典文件不可用。"
        case .sourceChanged: return "托管 MDX 与索引记录不一致。"
        case .indexChanged: return "托管词典索引已发生变化。"
        case .invalidSQLite: return "托管词典索引无法只读打开。"
        case .schemaMismatch: return "托管词典索引版本不兼容。"
        }
    }
}

struct ManagedDictionaryRuntimeValidator: Sendable {
    let applicationSupportRootURL: URL
    let expectedSchemaVersion: Int

    func validate(_ descriptor: DictionaryDescriptor) throws -> ManagedDictionaryRuntimePlan {
        guard Self.isQueryEligible(descriptor),
              DictionaryFormatterIdentifier.supportsGenericMDictV1(
                descriptor.formatterIdentifier
              ) else {
            throw ManagedDictionaryRuntimeValidationError.ineligible
        }
        guard descriptor.indexMetadata.schemaVersion == expectedSchemaVersion,
              let expectedDigest = descriptor.indexMetadata.sourceSHA256,
              !expectedDigest.isEmpty,
              let expectedSourceSize = descriptor.indexMetadata.sourceFileSize,
              let expectedIndexSize = descriptor.indexMetadata.indexFileSize,
              let sourcePath = descriptor.relativePaths.dictionary,
              let indexPath = descriptor.relativePaths.index else {
            throw ManagedDictionaryRuntimeValidationError.schemaMismatch
        }
        if descriptor.sourceKind == .openResource,
           sourcePath != "Dictionaries/\(descriptor.dictionaryID)/payload.mdx" {
            throw ManagedDictionaryRuntimeValidationError.unsafePath
        }
        let sourceURL = try managedSourceURL(relativePath: sourcePath,
                                             dictionaryID: descriptor.dictionaryID)
        let indexURL = try managedIndexURL(relativePath: indexPath,
                                           dictionaryID: descriptor.dictionaryID)
        let fileManager = FileManager()
        let sourceValues = try regularFileValues(sourceURL, fileManager: fileManager)
        let indexValues = try regularFileValues(indexURL, fileManager: fileManager)
        guard let sourceSize = sourceValues.fileSize, sourceSize >= 0,
              UInt64(sourceSize) == expectedSourceSize else {
            throw ManagedDictionaryRuntimeValidationError.sourceChanged
        }
        guard let indexSize = indexValues.fileSize, indexSize >= 0,
              UInt64(indexSize) == expectedIndexSize,
              expectedIndexSize > 0 else {
            throw ManagedDictionaryRuntimeValidationError.indexChanged
        }
        guard try sha256(sourceURL) == expectedDigest.lowercased() else {
            throw ManagedDictionaryRuntimeValidationError.sourceChanged
        }
        try validateSQLite(indexURL)
        return ManagedDictionaryRuntimePlan(
            dictionaryID: descriptor.dictionaryID,
            displayName: descriptor.displayName,
            sourceURL: sourceURL,
            indexURL: indexURL,
            sourceSHA256: expectedDigest.lowercased(),
            sourceFileSize: expectedSourceSize,
            indexFileSize: expectedIndexSize,
            descriptorUpdatedAt: descriptor.updatedAt
        )
    }

    private static func isQueryEligible(_ descriptor: DictionaryDescriptor) -> Bool {
        let managedLocal = descriptor.sourceKind == .managedLocal &&
            descriptor.storageOwnership == .appManagedImported &&
            descriptor.queryLevel == .normal
        let openResource = descriptor.sourceKind == .openResource &&
            descriptor.storageOwnership == .appManagedOpenResource &&
            descriptor.queryLevel == .fallback && descriptor.openResourceMetadata != nil
        return (managedLocal || openResource) && descriptor.enabled &&
            descriptor.state == .ready &&
            DictionaryFormatterIdentifier.supportsGenericMDictV1(
                descriptor.formatterIdentifier
            )
    }

    private func managedSourceURL(relativePath: String,
                                  dictionaryID: String) throws -> URL {
        let components = try validatedRelativeComponents(relativePath,
                                                         dictionaryID: dictionaryID)
        let isManagedRootFile = components.count == 3
        let isManagedSourceFile = components.count == 4 && components[2] == "source"
        guard (isManagedRootFile || isManagedSourceFile),
              URL(fileURLWithPath: components.last!).pathExtension
                .caseInsensitiveCompare("mdx") == .orderedSame else {
            throw ManagedDictionaryRuntimeValidationError.unsafePath
        }

        let locations = try resolvedManagedLocations(dictionaryID: dictionaryID)
        let candidate = applicationSupportRootURL
            .appendingPathComponent(relativePath).standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let permittedParent: URL
        if isManagedRootFile {
            permittedParent = locations.dictionaryRoot
        } else {
            let sourceDirectory = locations.dictionaryRoot
                .appendingPathComponent("source", isDirectory: true)
                .resolvingSymlinksInPath()
            guard Self.isDirectDescendant(sourceDirectory,
                                          of: locations.dictionaryRoot) else {
                throw ManagedDictionaryRuntimeValidationError.unsafePath
            }
            permittedParent = sourceDirectory
        }
        guard Self.samePath(resolvedCandidate.deletingLastPathComponent(),
                            permittedParent) else {
            throw ManagedDictionaryRuntimeValidationError.unsafePath
        }
        return candidate
    }

    private func managedIndexURL(relativePath: String,
                                 dictionaryID: String) throws -> URL {
        let components = try validatedRelativeComponents(relativePath,
                                                         dictionaryID: dictionaryID)
        guard components.count >= 4, components[2] == "index" else {
            throw ManagedDictionaryRuntimeValidationError.unsafePath
        }
        let locations = try resolvedManagedLocations(dictionaryID: dictionaryID)
        let indexDirectory = locations.dictionaryRoot
            .appendingPathComponent("index", isDirectory: true)
            .resolvingSymlinksInPath()
        guard Self.isDirectDescendant(indexDirectory, of: locations.dictionaryRoot) else {
            throw ManagedDictionaryRuntimeValidationError.unsafePath
        }
        let candidate = applicationSupportRootURL
            .appendingPathComponent(relativePath).standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard Self.isDescendant(resolvedCandidate, of: indexDirectory) else {
            throw ManagedDictionaryRuntimeValidationError.unsafePath
        }
        return candidate
    }

    private func validatedRelativeComponents(_ relativePath: String,
                                             dictionaryID: String) throws -> [String] {
        guard !relativePath.isEmpty,
              !NSString(string: relativePath).isAbsolutePath,
              !relativePath.contains("\\"),
              !relativePath.contains("://") else {
            throw ManagedDictionaryRuntimeValidationError.unsafePath
        }
        let components = relativePath.split(separator: "/",
                                            omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              components.count >= 3,
              components[0] == "Dictionaries",
              components[1] == dictionaryID else {
            throw ManagedDictionaryRuntimeValidationError.unsafePath
        }
        return components
    }

    private func resolvedManagedLocations(dictionaryID: String) throws
        -> (applicationSupportRoot: URL, dictionariesRoot: URL, dictionaryRoot: URL) {
        let applicationSupportRoot = applicationSupportRootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let dictionariesRoot = applicationSupportRootURL
            .appendingPathComponent("Dictionaries", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let dictionaryRoot = applicationSupportRootURL
            .appendingPathComponent("Dictionaries", isDirectory: true)
            .appendingPathComponent(dictionaryID, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isDirectDescendant(dictionariesRoot, of: applicationSupportRoot),
              Self.isDirectDescendant(dictionaryRoot, of: dictionariesRoot) else {
            throw ManagedDictionaryRuntimeValidationError.unsafePath
        }
        return (applicationSupportRoot, dictionariesRoot, dictionaryRoot)
    }

    private static func samePath(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.pathComponents == second.standardizedFileURL.pathComponents
    }

    private static func isDirectDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let directoryComponents = directory.standardizedFileURL.pathComponents
        return candidateComponents.count == directoryComponents.count + 1 &&
            candidateComponents.starts(with: directoryComponents)
    }

    private static func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let directoryComponents = directory.standardizedFileURL.pathComponents
        return candidateComponents.count > directoryComponents.count &&
            candidateComponents.starts(with: directoryComponents)
    }

    private func regularFileValues(_ url: URL, fileManager: FileManager) throws
        -> URLResourceValues {
        guard fileManager.fileExists(atPath: url.path),
              fileManager.isReadableFile(atPath: url.path) else {
            throw ManagedDictionaryRuntimeValidationError.missingFile
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ManagedDictionaryRuntimeValidationError.missingFile
        }
        return values
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { throw CancellationError() }
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func validateSQLite(_ url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw ManagedDictionaryRuntimeValidationError.invalidSQLite
        }
        defer { sqlite3_close(database) }
        guard sqlite3_db_readonly(database, "main") == 1 else {
            throw ManagedDictionaryRuntimeValidationError.invalidSQLite
        }
        guard query(database,
                    "SELECT value FROM metadata WHERE key='schema_version' LIMIT 1") ==
                String(expectedSchemaVersion) else {
            throw ManagedDictionaryRuntimeValidationError.schemaMismatch
        }
    }

    private func query(_ database: OpaquePointer, _ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
}
