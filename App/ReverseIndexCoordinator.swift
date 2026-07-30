import CryptoKit
import Foundation

extension DictionaryCoreBridge: @unchecked Sendable {}

enum ReverseDictionarySourceBacking: @unchecked Sendable {
    case legacy(dictionaryURL: URL, core: DictionaryCoreBridge)
    case managed(descriptor: DictionaryDescriptor)
}

struct ReverseDictionarySource: @unchecked Sendable {
    let dictionaryID: String
    let dictionaryName: String
    let queryPriority: Int
    let sortPosition: Int64
    let backing: ReverseDictionarySourceBacking

    init(dictionaryID: String, dictionaryName: String, dictionaryURL: URL,
         queryPriority: Int, sortPosition: Int64, core: DictionaryCoreBridge) {
        self.dictionaryID = dictionaryID
        self.dictionaryName = dictionaryName
        self.queryPriority = queryPriority
        self.sortPosition = sortPosition
        backing = .legacy(dictionaryURL: dictionaryURL, core: core)
    }

    init(managed descriptor: DictionaryDescriptor) {
        dictionaryID = descriptor.dictionaryID
        dictionaryName = descriptor.displayName
        queryPriority = descriptor.queryLevel.rank
        sortPosition = descriptor.sortPosition
        backing = .managed(descriptor: descriptor)
    }
}

struct ReverseIndexBuildProgress: Equatable, Sendable {
    let dictionaryID: String
    let dictionaryName: String
    let processedEntries: UInt64
}

@MainActor
final class ReverseIndexCoordinator {
    private(set) var currentTask: Task<[ReverseIndexDescriptor], Error>?
    private let rootURL: URL

    init(rootURL: URL = DictionaryImportService.defaultApplicationSupportRootURL()
        .appendingPathComponent("ReverseIndexes", isDirectory: true)) {
        self.rootURL = rootURL
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    func build(_ sources: [ReverseDictionarySource],
               progress: @escaping @MainActor @Sendable
                   (ReverseIndexBuildProgress) -> Void)
        async throws -> [ReverseIndexDescriptor] {
        guard currentTask == nil else { throw ReverseIndexError.writeFailed }
        let rootURL = self.rootURL
        let task = Task.detached(priority: .utility) {
            let managedValidator = ManagedDictionaryRuntimeValidator(
                applicationSupportRootURL:
                    DictionaryImportService.defaultApplicationSupportRootURL(),
                expectedSchemaVersion: Int(liveDictionaryIndexSchemaVersion)
            )
            var descriptors: [ReverseIndexDescriptor] = []
            for source in sources.sorted(by: {
                if $0.queryPriority != $1.queryPriority {
                    return $0.queryPriority < $1.queryPriority
                }
                if $0.sortPosition != $1.sortPosition {
                    return $0.sortPosition < $1.sortPosition
                }
                return $0.dictionaryID < $1.dictionaryID
            }) {
                try Task.checkCancellation()
                let core: DictionaryCoreBridge
                let sourceSHA: String
                let publication: String
                switch source.backing {
                case .legacy(let dictionaryURL, let legacyCore):
                    guard legacyCore.isReady else { continue }
                    sourceSHA = try Self.sha256(dictionaryURL)
                    publication = "legacy-\(sourceSHA.prefix(24))"
                    core = legacyCore
                case .managed(let descriptor):
                    let plan = try managedValidator.validate(descriptor)
                    let managedCore = DictionaryCoreBridge(
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
                        cacheMaximumBytes: 1024 * 1024,
                        cacheMaximumEntries: 16
                    )
                    guard managedCore.isReady else { continue }
                    core = managedCore
                    sourceSHA = plan.sourceSHA256
                    publication = plan.indexPublicationID
                }
                let identity = ReverseIndexIdentity(
                    dictionaryID: source.dictionaryID,
                    dictionaryName: source.dictionaryName,
                    sourceSHA256: sourceSHA,
                    indexPublicationID: publication,
                    queryPriority: source.queryPriority,
                    sortPosition: source.sortPosition
                )
                let destination = rootURL.appendingPathComponent(
                    "\(Self.safeFileComponent(source.dictionaryID)).reverse.sqlite"
                )
                let writer = try ReverseIndexStreamingWriter(
                    destinationURL: destination, identity: identity
                )
                let formatter = GenericMDictEntryFormatter()
                var processed: UInt64 = 0
                let result = core.enumerateEntries(
                    forReverse: 512 * 1024,
                    cancellationCheck: { Task.isCancelled },
                    handler: { headword, html, _ in
                        if Task.isCancelled { return false }
                        let sanitized = formatter.sanitizeHTML(html)
                        do {
                            try writer.append(ReverseIndexEntry(
                                headword: headword, plainText: sanitized.plainText
                            ))
                            processed += 1
                            if processed % 256 == 0 {
                                let snapshot = ReverseIndexBuildProgress(
                                    dictionaryID: source.dictionaryID,
                                    dictionaryName: source.dictionaryName,
                                    processedEntries: processed
                                )
                                Task { @MainActor in progress(snapshot) }
                            }
                            return true
                        } catch {
                            return false
                        }
                    }
                )
                if result["cancelled"] as? Bool == true || Task.isCancelled {
                    writer.abort()
                    throw ReverseIndexError.cancelled
                }
                guard result["success"] as? Bool == true else {
                    writer.abort()
                    continue
                }
                _ = try writer.finish()
                descriptors.append(ReverseIndexDescriptor(
                    fileURL: destination, identity: identity
                ))
            }
            return descriptors
        }
        currentTask = task
        defer { currentTask = nil }
        return try await task.value
    }

    private nonisolated static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: 1024 * 1024)
            guard let data, !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func safeFileComponent(_ source: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let value = source.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "_"
        }
        return String(value.prefix(128))
    }
}
