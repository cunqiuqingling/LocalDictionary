import Foundation

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
    let sourcePriority: Int
    let dictionaryOrder: Int64

    init(dictionaryID: String, displayName: String, matchedHeadword: String,
         blocks: [GenericMDictBlock], plainText: String, truncated: Bool,
         sourcePriority: Int = DictionaryQueryLevel.normal.rank,
         dictionaryOrder: Int64 = 0) {
        self.dictionaryID = dictionaryID
        self.displayName = displayName
        self.matchedHeadword = matchedHeadword
        self.blocks = blocks
        self.plainText = plainText
        self.truncated = truncated
        self.sourcePriority = sourcePriority
        self.dictionaryOrder = dictionaryOrder
    }

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
    case identityMismatch
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
    func removeAll(dictionaryID: String) async {
        await remove(dictionaryID: dictionaryID)
    }
}

private struct ManagedDictionaryQueryCandidate: Sendable {
    let dictionaryID: String
    let generation: UInt64
    let runtimeIdentity: ManagedDictionaryRuntimeIdentity
    let sourceKind: DictionarySourceKind
    let storageOwnership: DictionaryStorageOwnership
    let queryLevel: DictionaryQueryLevel
    let outcome: ManagedDictionaryRuntimeOutcome
    let release: ManagedDictionaryLeaseRelease
    let originalOrder: Int
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
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .empty }
        // `preferredMatched` is retained for source compatibility only. A hit in a legacy
        // dictionary no longer suppresses imported/open-resource dictionaries: all enabled,
        // query-capable descriptors participate in the single user-defined order.
        _ = preferredMatched
        let eligible = catalog.sortedDictionaries.filter {
            Self.isManagedLocalEligible($0) || Self.isOpenResourceEligible($0)
        }.prefix(Self.maximumDictionariesPerQuery * 2)
        let candidates = await collectTierCandidates(eligible, query: clean, orderBase: 0)

        // This is the entire public lookup's final suspension. Every lease release and precise
        // generation eviction has completed before this coherent coordinator snapshot.
        let finalSnapshots = await lifecycleCoordinator.queryValidationSnapshots(
            for: candidates.map(\.dictionaryID)
        )
        return finalizeBatch(candidates, lifecycleSnapshots: finalSnapshots)
    }

    /// Chinese planning is intentionally aggregate-first: every enabled local source that
    /// advertises direct Chinese lookup is queried, including fallback open resources. The
    /// English planner's normal-tier early exit must not suppress CC-CEDICT or another exact
    /// Chinese source.
    func lookupChinese(_ query: String) async -> ManagedDictionaryQueryBatch {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .empty }
        let eligible = catalog.sortedDictionaries.filter {
            $0.capabilities.chineseLookup &&
                (Self.isManagedLocalEligible($0) || Self.isOpenResourceEligible($0))
        }.prefix(Self.maximumDictionariesPerQuery * 2)
        let candidates = await collectTierCandidates(
            eligible, query: clean, orderBase: 0
        )
        let finalSnapshots = await lifecycleCoordinator.queryValidationSnapshots(
            for: candidates.map(\.dictionaryID)
        )
        return finalizeBatch(candidates, lifecycleSnapshots: finalSnapshots)
    }

    private func collectTierCandidates(
        _ descriptors: ArraySlice<DictionaryDescriptor>,
        query: String,
        orderBase: Int
    ) async -> [ManagedDictionaryQueryCandidate] {
        var candidates: [ManagedDictionaryQueryCandidate] = []
        for (offset, descriptor) in descriptors.enumerated() {
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
                let release = await lifecycleCoordinator.releaseForFinalValidation(lease)
                if let drainedGeneration = generationNeedingEviction(release) {
                    await runtime.remove(dictionaryID: descriptor.dictionaryID,
                                         generation: drainedGeneration)
                }
                if case .identityMismatch = outcome {
                    await suspendIdentityMismatch(
                        dictionaryID: descriptor.dictionaryID
                    )
                }
                candidates.append(ManagedDictionaryQueryCandidate(
                    dictionaryID: descriptor.dictionaryID,
                    generation: lease.generation,
                    runtimeIdentity: ManagedDictionaryRuntimeIdentity(descriptor),
                    sourceKind: descriptor.sourceKind,
                    storageOwnership: descriptor.storageOwnership,
                    queryLevel: descriptor.queryLevel,
                    outcome: outcome,
                    release: release,
                    originalOrder: orderBase + offset
                ))
            } catch is CancellationError {
                break
            } catch {
                // A draining, stale, or malformed fallback dictionary is isolated from the next
                // descriptor and never escalates into automatic AI.
                continue
            }
        }
        return candidates
    }

    private func generationNeedingEviction(_ release: ManagedDictionaryLeaseRelease) -> UInt64? {
        guard let drainedGeneration = release.drainedGeneration,
              let snapshot = release.postReleaseSnapshot,
              snapshot.generation != drainedGeneration || !release.resultMayPublish
        else { return nil }
        return drainedGeneration
    }

    private func suspendIdentityMismatch(dictionaryID: String) async {
        guard let permit = try? await lifecycleCoordinator.acquireExclusiveOperation(
            for: dictionaryID, operation: .runtimeInvalidation
        ) else { return }
        await runtime.removeAll(dictionaryID: dictionaryID)
        await lifecycleCoordinator.complete(
            permit, disposition: .suspended(incrementGeneration: true)
        )
    }

    /// Synchronous batch publication linearization point. The caller must return this value
    /// immediately after the final coordinator snapshot, without another actor suspension.
    private func finalizeBatch(
        _ candidates: [ManagedDictionaryQueryCandidate],
        lifecycleSnapshots: [String: ManagedDictionaryLifecycleSnapshot]
    ) -> ManagedDictionaryQueryBatch {
        var hits: [ManagedDictionaryQueryHit] = []
        var unavailable: [String] = []
        for candidate in candidates.sorted(by: { $0.originalOrder < $1.originalOrder }) {
            guard isStillEligible(
                candidate, lifecycleSnapshot: lifecycleSnapshots[candidate.dictionaryID]
            ) else { continue }
            switch candidate.outcome {
            case .hit(let hit):
                guard hit.dictionaryID == candidate.dictionaryID else { continue }
                hits.append(hit)
            case .miss: break
            case .unavailable: unavailable.append(candidate.dictionaryID)
            case .identityMismatch: unavailable.append(candidate.dictionaryID)
            }
        }
        return ManagedDictionaryQueryBatch(
            hits: hits,
            unavailableDictionaryIDs: unavailable,
            skippedBecausePreferredMatched: false
        )
    }

    private func isStillEligible(
        _ candidate: ManagedDictionaryQueryCandidate,
        lifecycleSnapshot: ManagedDictionaryLifecycleSnapshot?
    ) -> Bool {
        guard candidate.release.wasReleased,
              candidate.release.lease.dictionaryID == candidate.dictionaryID,
              candidate.release.lease.generation == candidate.generation,
              let descriptor = catalog.dictionaries.first(where: {
                  $0.dictionaryID == candidate.dictionaryID
              }),
              Self.isManagedLocalEligible(descriptor) || Self.isOpenResourceEligible(descriptor),
              descriptor.sourceKind == candidate.sourceKind,
              descriptor.storageOwnership == candidate.storageOwnership,
              descriptor.queryLevel == candidate.queryLevel,
              ManagedDictionaryRuntimeIdentity(descriptor) == candidate.runtimeIdentity,
              let lifecycleSnapshot,
              lifecycleSnapshot.dictionaryID == candidate.dictionaryID,
              lifecycleSnapshot.runtimeIdentity == candidate.runtimeIdentity,
              lifecycleSnapshot.allowsCurrentGenerationResult ||
                releaseMayPublishAcrossQueuedExclusive(
                    candidate.release, lifecycleSnapshot: lifecycleSnapshot
                ),
              lifecycleSnapshot.generation == candidate.generation else {
            return false
        }
        return true
    }

    private func releaseMayPublishAcrossQueuedExclusive(
        _ release: ManagedDictionaryLeaseRelease,
        lifecycleSnapshot: ManagedDictionaryLifecycleSnapshot
    ) -> Bool {
        release.resultMayPublish && lifecycleSnapshot.phase == .exclusive
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
            (DictionaryFormatterIdentifier.supportsGenericMDictV1(
                descriptor.formatterIdentifier
            ) || DictionaryFormatterIdentifier.supportsOpenResourceSQLite(
                descriptor.formatterIdentifier
            ))
    }
}

struct ManagedDictionaryRuntimePlan: Sendable {
    let dictionaryID: String
    let displayName: String
    let managedRootURL: URL
    let sourceRelativePath: String
    let indexRelativePath: String
    let sourceURL: URL
    let indexURL: URL
    let indexPublicationID: String
    let indexSHA256: String
    let sourceSHA256: String
    let sourceFileSize: UInt64
    let indexFileSize: UInt64
    let schemaVersion: Int
    let entryCount: UInt64
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
              let expectedEntryCount = descriptor.indexMetadata.entryCount,
              let published = descriptor.publishedIndexIdentity,
              let sourcePath = descriptor.relativePaths.dictionary,
              let indexPath = descriptor.relativePaths.index else {
            throw ManagedDictionaryRuntimeValidationError.schemaMismatch
        }
        if descriptor.sourceKind == .openResource,
           sourcePath != "Dictionaries/\(descriptor.dictionaryID)/payload.mdx" {
            throw ManagedDictionaryRuntimeValidationError.unsafePath
        }
        let sourceURL = try managedSourceURL(
            relativePath: sourcePath, dictionaryID: descriptor.dictionaryID
        )
        let indexURL = try managedIndexURL(
            relativePath: indexPath, dictionaryID: descriptor.dictionaryID
        )
        guard published.relativePath == indexPath,
              published.schemaVersion == expectedSchemaVersion,
              published.entryCount == expectedEntryCount,
              published.indexFileSize == expectedIndexSize else {
            throw ManagedDictionaryRuntimeValidationError.schemaMismatch
        }
        guard published.sourceFileSize == expectedSourceSize,
              published.sourceSHA256 == expectedDigest.lowercased() else {
            throw ManagedDictionaryRuntimeValidationError.sourceChanged
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path),
              FileManager.default.fileExists(atPath: indexURL.path) else {
            throw ManagedDictionaryRuntimeValidationError.missingFile
        }
        return ManagedDictionaryRuntimePlan(
            dictionaryID: descriptor.dictionaryID,
            displayName: descriptor.displayName,
            managedRootURL: applicationSupportRootURL,
            sourceRelativePath: sourcePath,
            indexRelativePath: indexPath,
            sourceURL: sourceURL,
            indexURL: indexURL,
            indexPublicationID: published.indexPublicationID,
            indexSHA256: published.indexSHA256,
            sourceSHA256: expectedDigest.lowercased(),
            sourceFileSize: expectedSourceSize,
            indexFileSize: expectedIndexSize,
            schemaVersion: expectedSchemaVersion,
            entryCount: expectedEntryCount,
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

}
