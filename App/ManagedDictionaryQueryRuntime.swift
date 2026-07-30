import Foundation

actor LiveManagedDictionaryQueryRuntime: ManagedDictionaryQueryRuntime {
    static let maximumRawHTMLBytes = 512 * 1024
    static let cacheMaximumBytes = 1024 * 1024
    static let cacheMaximumEntries = 16

    private struct RuntimeIdentity: Equatable {
        let generation: UInt64
        let descriptorUpdatedAt: Date
        let sourceSHA256: String
        let sourceFileSize: UInt64
        let indexFileSize: UInt64
        let indexPublicationID: String
        let indexSHA256: String
    }

    private final class Runtime {
        let identity: RuntimeIdentity
        let core: DictionaryCoreBridge

        init(identity: RuntimeIdentity, core: DictionaryCoreBridge) {
            self.identity = identity
            self.core = core
        }
    }

    private let validator: ManagedDictionaryRuntimeValidator
    private let formatter = GenericMDictEntryFormatter()
    /// Generation is part of the cache identity.  Lifecycle operations drain leases before
    /// invalidating this cache, so an old runtime cannot be reused by a newly published index.
    private var runtimes: [RuntimeKey: Runtime] = [:]

    private struct RuntimeKey: Hashable {
        let dictionaryID: String
        let generation: UInt64
        let indexPublicationID: String
        let indexSHA256: String
    }

    init(applicationSupportRootURL: URL =
         DictionaryImportService.defaultApplicationSupportRootURL(),
         expectedSchemaVersion: Int = Int(liveDictionaryIndexSchemaVersion)) {
        validator = ManagedDictionaryRuntimeValidator(
            applicationSupportRootURL: applicationSupportRootURL,
            expectedSchemaVersion: expectedSchemaVersion
        )
    }

    func reset() { runtimes.removeAll() }

    /// Legacy broad removal is retained only for callers that have already drained every
    /// generation, such as explicit lifecycle invalidation.
    func remove(dictionaryID: String) { removeAll(dictionaryID: dictionaryID) }

    func remove(dictionaryID: String, generation: UInt64) {
        runtimes = runtimes.filter {
            $0.key.dictionaryID != dictionaryID ||
                $0.key.generation != generation
        }
    }

    func removeAll(dictionaryID: String) {
        runtimes = runtimes.filter { $0.key.dictionaryID != dictionaryID }
    }

    func lookup(descriptor: DictionaryDescriptor,
                generation: UInt64,
                query: String) async -> ManagedDictionaryRuntimeOutcome {
        guard !Task.isCancelled else { return .miss }
        do {
            guard let persistent = descriptor.publishedIndexIdentity else {
                return .identityMismatch
            }
            let runtime: Runtime
            let key = RuntimeKey(
                dictionaryID: descriptor.dictionaryID,
                generation: generation,
                indexPublicationID: persistent.indexPublicationID,
                indexSHA256: persistent.indexSHA256
            )
            if let expectedIdentity = Self.identity(for: descriptor, generation: generation),
               let existing = runtimes[key],
               existing.identity == expectedIdentity {
                runtime = existing
            } else {
                let plan = try validator.validate(descriptor)
                guard !Task.isCancelled else { return .miss }
                let identity = RuntimeIdentity(
                    generation: generation,
                    descriptorUpdatedAt: plan.descriptorUpdatedAt,
                    sourceSHA256: plan.sourceSHA256,
                    sourceFileSize: plan.sourceFileSize,
                    indexFileSize: plan.indexFileSize,
                    indexPublicationID: plan.indexPublicationID,
                    indexSHA256: plan.indexSHA256
                )
                let core = DictionaryCoreBridge(
                    managedReadOnlyWithRootPath: plan.managedRootURL.path,
                    sourceRelativePath: plan.sourceRelativePath,
                    indexRelativePath: plan.indexRelativePath,
                    dictionaryID: plan.dictionaryID,
                    publicationID: plan.indexPublicationID,
                    indexSHA256: plan.indexSHA256,
                    indexFileSize: plan.indexFileSize,
                    sourceSHA256: plan.sourceSHA256,
                    sourceFileSize: plan.sourceFileSize,
                    schemaVersion: plan.schemaVersion,
                    entryCount: plan.entryCount,
                    cacheMaximumBytes: UInt(Self.cacheMaximumBytes),
                    cacheMaximumEntries: UInt(Self.cacheMaximumEntries)
                )
                guard core.isReady else { return .identityMismatch }
                runtime = Runtime(identity: identity, core: core)
                runtimes[key] = runtime
            }
            let raw = runtime.core.lookup(
                query, maximumHTMLBytes: UInt(Self.maximumRawHTMLBytes)
            )
            if let error = raw["error"] as? String, !error.isEmpty {
                runtimes[key] = nil
                return .identityMismatch
            }
            guard raw["found"] as? Bool == true,
                  let html = raw["html"] as? String,
                  !html.isEmpty else { return .miss }
            let sanitized = formatter.sanitizeHTML(html)
            let blocks = sanitized.blocks.compactMap(Self.block)
            let plainText = sanitized.plainText.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
            guard !plainText.isEmpty else { return .unavailable }
            let matched = (raw["matchedHeadword"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .hit(ManagedDictionaryQueryHit(
                dictionaryID: descriptor.dictionaryID,
                displayName: descriptor.displayName,
                matchedHeadword: matched?.isEmpty == false ? matched! : query,
                blocks: blocks,
                plainText: plainText,
                truncated: sanitized.truncated || (raw["htmlTruncated"] as? Bool == true)
            ))
        } catch is CancellationError {
            return .miss
        } catch {
            runtimes = runtimes.filter {
                $0.key.dictionaryID != descriptor.dictionaryID ||
                    $0.key.generation != generation
            }
            return .identityMismatch
        }
    }

    private static func identity(for descriptor: DictionaryDescriptor,
                                 generation: UInt64) -> RuntimeIdentity? {
        guard let sourceSHA256 = descriptor.indexMetadata.sourceSHA256,
              let sourceFileSize = descriptor.indexMetadata.sourceFileSize,
              let indexFileSize = descriptor.indexMetadata.indexFileSize,
              let published = descriptor.publishedIndexIdentity else { return nil }
        return RuntimeIdentity(
            generation: generation,
            descriptorUpdatedAt: descriptor.updatedAt,
            sourceSHA256: sourceSHA256.lowercased(),
            sourceFileSize: sourceFileSize,
            indexFileSize: indexFileSize,
            indexPublicationID: published.indexPublicationID,
            indexSHA256: published.indexSHA256
        )
    }

    private static func block(_ value: [String: Any]) -> GenericMDictBlock? {
        guard let rawKind = value["kind"] as? String,
              let kind = GenericMDictBlockKind(rawValue: rawKind),
              let rawRuns = value["runs"] as? [[String: Any]] else { return nil }
        let runs = rawRuns.compactMap { run -> GenericMDictTextRun? in
            guard let text = run["text"] as? String, !text.isEmpty else { return nil }
            return GenericMDictTextRun(
                text: text,
                bold: run["bold"] as? Bool == true,
                italic: run["italic"] as? Bool == true,
                code: run["code"] as? Bool == true
            )
        }
        guard !runs.isEmpty else { return nil }
        return GenericMDictBlock(
            kind: kind,
            level: (value["level"] as? NSNumber)?.intValue ?? 0,
            runs: runs
        )
    }
}
