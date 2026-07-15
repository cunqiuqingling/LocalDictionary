import Foundation

actor LiveManagedDictionaryQueryRuntime: ManagedDictionaryQueryRuntime {
    static let maximumRawHTMLBytes = 512 * 1024
    static let cacheMaximumBytes = 1024 * 1024
    static let cacheMaximumEntries = 16

    private struct RuntimeIdentity: Equatable {
        let descriptorUpdatedAt: Date
        let sourceSHA256: String
        let sourceFileSize: UInt64
        let indexFileSize: UInt64
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
    private var runtimes: [String: Runtime] = [:]

    init(applicationSupportRootURL: URL =
         DictionaryImportService.defaultApplicationSupportRootURL(),
         expectedSchemaVersion: Int = Int(liveDictionaryIndexSchemaVersion)) {
        validator = ManagedDictionaryRuntimeValidator(
            applicationSupportRootURL: applicationSupportRootURL,
            expectedSchemaVersion: expectedSchemaVersion
        )
    }

    func reset() { runtimes.removeAll() }

    func lookup(descriptor: DictionaryDescriptor,
                query: String) async -> ManagedDictionaryRuntimeOutcome {
        guard !Task.isCancelled else { return .miss }
        do {
            let runtime: Runtime
            if let expectedIdentity = Self.identity(for: descriptor),
               let existing = runtimes[descriptor.dictionaryID],
               existing.identity == expectedIdentity {
                runtime = existing
            } else {
                let plan = try validator.validate(descriptor)
                guard !Task.isCancelled else { return .miss }
                let identity = RuntimeIdentity(
                    descriptorUpdatedAt: plan.descriptorUpdatedAt,
                    sourceSHA256: plan.sourceSHA256,
                    sourceFileSize: plan.sourceFileSize,
                    indexFileSize: plan.indexFileSize
                )
                let core = DictionaryCoreBridge(
                    readOnlyWithDictionaryPath: plan.sourceURL.path,
                    indexPath: plan.indexURL.path,
                    cacheMaximumBytes: UInt(Self.cacheMaximumBytes),
                    cacheMaximumEntries: UInt(Self.cacheMaximumEntries)
                )
                guard core.isReady else { return .unavailable }
                runtime = Runtime(identity: identity, core: core)
                runtimes[plan.dictionaryID] = runtime
            }
            let raw = runtime.core.lookup(
                query, maximumHTMLBytes: UInt(Self.maximumRawHTMLBytes)
            )
            if let error = raw["error"] as? String, !error.isEmpty {
                runtimes[descriptor.dictionaryID] = nil
                return .unavailable
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
            runtimes[descriptor.dictionaryID] = nil
            return .unavailable
        }
    }

    private static func identity(for descriptor: DictionaryDescriptor) -> RuntimeIdentity? {
        guard let sourceSHA256 = descriptor.indexMetadata.sourceSHA256,
              let sourceFileSize = descriptor.indexMetadata.sourceFileSize,
              let indexFileSize = descriptor.indexMetadata.indexFileSize else { return nil }
        return RuntimeIdentity(
            descriptorUpdatedAt: descriptor.updatedAt,
            sourceSHA256: sourceSHA256.lowercased(),
            sourceFileSize: sourceFileSize,
            indexFileSize: indexFileSize
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
