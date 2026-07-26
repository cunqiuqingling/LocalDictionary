import CryptoKit
import Darwin
import Foundation
import SQLite3

struct DictionaryIndexingHooks: Sendable {
    let availableCapacity: @Sendable (URL) throws -> UInt64
    let beforePublish: @Sendable () throws -> Void

    static let live = DictionaryIndexingHooks(
        availableCapacity: { url in
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ])
            if let capacity = values.volumeAvailableCapacityForImportantUsage,
               capacity >= 0 {
                return UInt64(capacity)
            }
            let attributes = try FileManager().attributesOfFileSystem(forPath: url.path)
            return (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        },
        beforePublish: {}
    )
}

/// Pure file/index work. The worker owns no AppKit object, Catalog store, or
/// mutable shared FileManager and receives only immutable Sendable values.
struct ManagedDictionaryIndexWorker: Sendable {
    let buildIndex: DictionaryIndexBuildFunction
    let hooks: DictionaryIndexingHooks

    func prepare(
        plan: DictionaryIndexPlan,
        cancellationToken: DictionaryIndexCancellationToken
    ) -> DictionaryIndexWorkerOutcome {
        let fileManager = FileManager()
        do {
            try checkCancellation(cancellationToken)
            try validateSource(plan, fileManager: fileManager)
            let initialDigest = try sha256(of: plan.sourceURL,
                                           cancellationToken: cancellationToken)
            guard initialDigest == plan.expectedSourceSHA256 else {
                throw DictionaryIndexError.sourceChanged
            }

            try fileManager.createDirectory(at: plan.indexDirectoryURL,
                                            withIntermediateDirectories: true)
            let required = requiredCapacity(sourceSize: plan.expectedSourceSize)
            let available = try hooks.availableCapacity(plan.indexDirectoryURL)
            guard available >= required else {
                throw DictionaryIndexError.insufficientDiskSpace(required: required,
                                                                 available: available)
            }

            cleanupBuildArtifacts(plan, fileManager: fileManager)
            try checkCancellation(cancellationToken)
            switch buildIndex(plan.sourceURL, plan.candidateIndexURL, cancellationToken) {
            case .cancelled:
                cleanupBuildArtifacts(plan, fileManager: fileManager)
                return .cancelled
            case .failure(let reason):
                cleanupBuildArtifacts(plan, fileManager: fileManager)
                return .failed(.builderFailed(reason))
            case .success:
                break
            }

            try checkCancellation(cancellationToken)
            let validated = try validateSQLite(at: plan.candidateIndexURL,
                                               schemaVersion: plan.expectedSchemaVersion)
            let finalDigest = try sha256(of: plan.sourceURL,
                                         cancellationToken: cancellationToken)
            guard finalDigest == initialDigest else {
                throw DictionaryIndexError.sourceChanged
            }
            try checkCancellation(cancellationToken)
            try hooks.beforePublish()

            return .prepared(DictionaryIndexPreparedResult(
                dictionaryID: plan.dictionaryID,
                candidateIndexURL: plan.candidateIndexURL,
                finalIndexURL: plan.finalIndexURL,
                relativeIndexPath: plan.relativeIndexPath,
                schemaVersion: plan.expectedSchemaVersion,
                entryCount: validated.entryCount,
                indexFileSize: validated.fileSize,
                sourceFileSize: plan.expectedSourceSize,
                sourceSHA256: finalDigest,
                indexedAt: Date()
            ))
        } catch is CancellationError {
            cleanupBuildArtifacts(plan, fileManager: fileManager)
            return .cancelled
        } catch let error as DictionaryIndexError {
            cleanupBuildArtifacts(plan, fileManager: fileManager)
            return .failed(error)
        } catch {
            cleanupBuildArtifacts(plan, fileManager: fileManager)
            return .failed(.builderFailed("索引建立失败。"))
        }
    }

    func discardPrepared(_ prepared: DictionaryIndexPreparedResult) {
        let fileManager = FileManager()
        try? fileManager.removeItem(at: prepared.candidateIndexURL)
        try? fileManager.removeItem(at: URL(fileURLWithPath:
            prepared.candidateIndexURL.path + ".building"))
    }

    private func validateSource(_ plan: DictionaryIndexPlan,
                                fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: plan.sourceURL.path) else {
            throw DictionaryIndexError.sourceMissing
        }
        guard fileManager.isReadableFile(atPath: plan.sourceURL.path) else {
            throw DictionaryIndexError.sourceUnreadable
        }
        let values = try plan.sourceURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0,
              UInt64(size) == plan.expectedSourceSize else {
            throw DictionaryIndexError.sourceChanged
        }
    }

    private func requiredCapacity(sourceSize: UInt64) -> UInt64 {
        let doubled = sourceSize.multipliedReportingOverflow(by: 2)
        let base = doubled.overflow ? UInt64.max : doubled.partialValue
        return base.addingReportingOverflow(128 * 1024 * 1024).overflow
            ? UInt64.max
            : base + 128 * 1024 * 1024
    }

    private func sha256(of url: URL,
                        cancellationToken: DictionaryIndexCancellationToken) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try checkCancellation(cancellationToken)
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func validateSQLite(at url: URL,
                                schemaVersion: Int) throws -> (entryCount: UInt64,
                                                               fileSize: UInt64) {
        let fileManager = FileManager()
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize > 0 else { throw DictionaryIndexError.emptyIndex }

        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw DictionaryIndexError.invalidSQLite
        }
        defer { sqlite3_close(database) }

        guard queryText(database, sql: "PRAGMA integrity_check")?.lowercased() == "ok" else {
            throw DictionaryIndexError.integrityCheckFailed
        }
        guard queryText(database,
                        sql: "SELECT value FROM metadata WHERE key='schema_version' LIMIT 1")
                == String(schemaVersion) else {
            throw DictionaryIndexError.schemaMismatch
        }
        guard let value = queryText(database,
                                    sql: "SELECT COUNT(*) FROM entries"),
              let entryCount = UInt64(value) else {
            throw DictionaryIndexError.missingEntryCount
        }
        guard entryCount > 0 else { throw DictionaryIndexError.emptyIndex }
        return (entryCount, fileSize)
    }

    private func queryText(_ database: OpaquePointer, sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func checkCancellation(_ token: DictionaryIndexCancellationToken) throws {
        if token.isCancelled { throw CancellationError() }
    }

    private func cleanupBuildArtifacts(_ plan: DictionaryIndexPlan,
                                       fileManager: FileManager) {
        try? fileManager.removeItem(at: plan.candidateIndexURL)
        try? fileManager.removeItem(at: URL(fileURLWithPath:
            plan.candidateIndexURL.path + ".building"))
    }
}

@MainActor
final class ManagedDictionaryIndexCoordinator {
    typealias CatalogObserver = (DictionaryCatalog) -> Void

    private(set) var catalog: DictionaryCatalog
    private(set) var activity: DictionaryIndexActivity?
    var onCatalogChanged: CatalogObserver?

    private let catalogStore: DictionaryCatalogStore
    private let applicationSupportRootURL: URL
    private let worker: ManagedDictionaryIndexWorker
    private let expectedSchemaVersion: Int
    private var currentTask: Task<Void, Never>?
    private var cancellationToken: DictionaryIndexCancellationToken?
    private var failureMessages: [String: String] = [:]

    init(
        catalog: DictionaryCatalog = .empty(),
        catalogStore: DictionaryCatalogStore,
        applicationSupportRootURL: URL = DictionaryImportService.defaultApplicationSupportRootURL(),
        buildIndex: @escaping DictionaryIndexBuildFunction,
        expectedSchemaVersion: Int,
        hooks: DictionaryIndexingHooks = .live
    ) {
        self.catalog = catalog
        self.catalogStore = catalogStore
        self.applicationSupportRootURL = applicationSupportRootURL
        self.expectedSchemaVersion = expectedSchemaVersion
        worker = ManagedDictionaryIndexWorker(buildIndex: buildIndex, hooks: hooks)
    }

    @discardableResult
    func recoverInterruptedTasks(in catalog: DictionaryCatalog) -> DictionaryCatalog {
        var updated = catalog
        var changed = false
        let now = Date()
        for index in updated.dictionaries.indices
        where isIndexable(updated.dictionaries[index]) &&
              updated.dictionaries[index].state == .indexing {
            updated.dictionaries[index].state = .pendingIndex
            updated.dictionaries[index].relativePaths.index = nil
            clearPublishedMetadata(&updated.dictionaries[index])
            updated.dictionaries[index].updatedAt = now
            changed = true
        }
        guard changed else { self.catalog = updated; return updated }
        do {
            let mutation = try catalogStore.mutate { latest, _ in
                for index in latest.dictionaries.indices where
                    isIndexable(latest.dictionaries[index]) &&
                    latest.dictionaries[index].state == .indexing {
                    latest.dictionaries[index].state = .pendingIndex
                    latest.dictionaries[index].relativePaths.index = nil
                    clearPublishedMetadata(&latest.dictionaries[index])
                    latest.dictionaries[index].updatedAt = now
                }
                latest.updatedAt = now
            }
            self.catalog = mutation.catalog
            return mutation.catalog
        } catch {
            self.catalog = catalog
            return catalog
        }
    }

    func synchronize(catalog: DictionaryCatalog) {
        self.catalog = catalog
    }

    func start(dictionaryID: String) -> DictionaryIndexStartResult {
        guard currentTask == nil else { return .busy }
        guard let index = catalog.dictionaries.firstIndex(where: {
            $0.dictionaryID == dictionaryID && isIndexable($0)
        }) else { return .unavailable("找不到可建立索引的托管词典。") }
        guard catalog.dictionaries[index].state == .pendingIndex ||
              catalog.dictionaries[index].state == .failed else {
            return .unavailable("当前词典状态不允许建立索引。")
        }

        let plan: DictionaryIndexPlan
        do {
            plan = try makePlan(for: catalog.dictionaries[index])
        } catch let error as DictionaryIndexError {
            return .unavailable(error.localizedDescription)
        } catch {
            return .unavailable("无法创建安全的索引计划。")
        }

        let now = Date()
        let updated: DictionaryCatalog
        do {
            let mutation = try catalogStore.mutate { latest, _ in
                guard let latestIndex = latest.dictionaries.firstIndex(where: {
                    $0.dictionaryID == dictionaryID && isIndexable($0)
                }), (latest.dictionaries[latestIndex].state == .pendingIndex ||
                    latest.dictionaries[latestIndex].state == .failed) else {
                    throw DictionaryIndexError.catalogWriteFailed
                }
                latest.dictionaries[latestIndex].state = .indexing
                latest.dictionaries[latestIndex].relativePaths.index = nil
                clearPublishedMetadata(&latest.dictionaries[latestIndex])
                latest.dictionaries[latestIndex].updatedAt = now
                latest.updatedAt = now
            }
            updated = mutation.catalog
        } catch {
            return .unavailable(DictionaryIndexError.catalogWriteFailed.localizedDescription)
        }

        catalog = updated
        failureMessages[dictionaryID] = nil
        activity = DictionaryIndexActivity(dictionaryID: dictionaryID, stage: .buildingSQLite)
        onCatalogChanged?(updated)

        let token = DictionaryIndexCancellationToken()
        cancellationToken = token
        let worker = self.worker
        currentTask = Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                worker.prepare(plan: plan, cancellationToken: token)
            }.value
            guard let self else {
                if case .prepared(let prepared) = outcome {
                    await Task.detached(priority: .utility) {
                        worker.discardPrepared(prepared)
                    }.value
                }
                return
            }
            await self.finish(dictionaryID: dictionaryID, outcome: outcome)
        }
        return .started
    }

    func cancel(dictionaryID: String) {
        guard activity?.dictionaryID == dictionaryID else { return }
        cancellationToken?.cancel()
    }

    func cancelCurrentTask() { cancellationToken?.cancel() }

    func failureMessage(for dictionaryID: String) -> String? {
        failureMessages[dictionaryID]
    }

    private func finish(dictionaryID: String,
                        outcome: DictionaryIndexWorkerOutcome) async {
        defer {
            activity = nil
            cancellationToken = nil
            currentTask = nil
        }
        guard let index = catalog.dictionaries.firstIndex(where: {
            $0.dictionaryID == dictionaryID && isIndexable($0)
        }) else {
            if case .prepared(let prepared) = outcome {
                let worker = self.worker
                await Task.detached(priority: .utility) { worker.discardPrepared(prepared) }.value
            }
            return
        }

        var updated = catalog
        let now = Date()
        var publication: IndexPublication?
        switch outcome {
        case .cancelled:
            updated.dictionaries[index].state = .pendingIndex
            updated.dictionaries[index].relativePaths.index = nil
            clearPublishedMetadata(&updated.dictionaries[index])
        case .failed(let error):
            updated.dictionaries[index].state = .failed
            updated.dictionaries[index].relativePaths.index = nil
            clearPublishedMetadata(&updated.dictionaries[index])
            failureMessages[dictionaryID] = error.localizedDescription
        case .prepared(let prepared):
            guard !cancellationTokenIsSet else {
                let worker = self.worker
                await Task.detached(priority: .utility) { worker.discardPrepared(prepared) }.value
                updated.dictionaries[index].state = .pendingIndex
                updated.dictionaries[index].relativePaths.index = nil
                clearPublishedMetadata(&updated.dictionaries[index])
                break
            }
            do {
                publication = try publish(prepared)
                updated.dictionaries[index].state = .ready
                updated.dictionaries[index].relativePaths.index = prepared.relativeIndexPath
                updated.dictionaries[index].indexMetadata = DictionaryIndexMetadata(
                    schemaVersion: prepared.schemaVersion,
                    entryCount: prepared.entryCount,
                    indexFileSize: prepared.indexFileSize,
                    sourceFileSize: prepared.sourceFileSize,
                    sourceModifiedAt: updated.dictionaries[index].indexMetadata.sourceModifiedAt,
                    sourceSHA256: prepared.sourceSHA256,
                    indexedAt: prepared.indexedAt
                )
            } catch {
                let worker = self.worker
                await Task.detached(priority: .utility) {
                    worker.discardPrepared(prepared)
                }.value
                updated.dictionaries[index].state = .failed
                updated.dictionaries[index].relativePaths.index = nil
                clearPublishedMetadata(&updated.dictionaries[index])
                failureMessages[dictionaryID] = DictionaryIndexError.publicationFailed.localizedDescription
            }
        }

        updated.dictionaries[index].updatedAt = now
        updated.updatedAt = now
        do {
            let target = updated.dictionaries[index]
            let mutation = try catalogStore.mutate { latest, _ in
                guard let latestIndex = latest.dictionaries.firstIndex(where: {
                    $0.dictionaryID == dictionaryID && isIndexable($0)
                }) else { throw DictionaryIndexError.catalogWriteFailed }
                latest.dictionaries[latestIndex].state = target.state
                latest.dictionaries[latestIndex].relativePaths.index = target.relativePaths.index
                latest.dictionaries[latestIndex].indexMetadata = target.indexMetadata
                latest.dictionaries[latestIndex].updatedAt = now
                latest.updatedAt = now
            }
            if let publication { commit(publication) }
            catalog = mutation.catalog
            onCatalogChanged?(mutation.catalog)
        } catch {
            if let publication { rollback(publication) }
            failureMessages[dictionaryID] = DictionaryIndexError.catalogWriteFailed.localizedDescription
            var inMemoryFallback = updated
            inMemoryFallback.dictionaries[index].state = .failed
            inMemoryFallback.dictionaries[index].relativePaths.index = nil
            clearPublishedMetadata(&inMemoryFallback.dictionaries[index])
            catalog = inMemoryFallback
            onCatalogChanged?(inMemoryFallback)
        }
    }

    private var cancellationTokenIsSet: Bool { cancellationToken?.isCancelled == true }

    private func makePlan(for descriptor: DictionaryDescriptor) throws -> DictionaryIndexPlan {
        guard let sourceRelativePath = descriptor.relativePaths.dictionary,
              isManagedRelativePath(sourceRelativePath, dictionaryID: descriptor.dictionaryID),
              let expectedSHA256 = descriptor.indexMetadata.sourceSHA256,
              !expectedSHA256.isEmpty,
              let expectedSourceSize = descriptor.indexMetadata.sourceFileSize else {
            if descriptor.indexMetadata.sourceSHA256 == nil {
                throw DictionaryIndexError.sourceFingerprintMissing
            }
            throw DictionaryIndexError.unsafeCatalogPath
        }
        let base = "Dictionaries/\(descriptor.dictionaryID)/index"
        let relativeIndexPath = "\(base)/dictionary.sqlite"
        let sourceURL = applicationSupportRootURL.appendingPathComponent(sourceRelativePath)
        let indexDirectoryURL = applicationSupportRootURL.appendingPathComponent(base,
                                                                                  isDirectory: true)
        return DictionaryIndexPlan(
            dictionaryID: descriptor.dictionaryID,
            sourceURL: sourceURL,
            expectedSourceSize: expectedSourceSize,
            expectedSourceSHA256: expectedSHA256,
            indexDirectoryURL: indexDirectoryURL,
            candidateIndexURL: indexDirectoryURL
                .appendingPathComponent("dictionary.sqlite.building"),
            finalIndexURL: indexDirectoryURL.appendingPathComponent("dictionary.sqlite"),
            relativeIndexPath: relativeIndexPath,
            expectedSchemaVersion: expectedSchemaVersion
        )
    }

    private func isManagedRelativePath(_ path: String, dictionaryID: String) -> Bool {
        guard !path.isEmpty, !NSString(string: path).isAbsolutePath,
              !path.contains("\\") else { return false }
        let components = NSString(string: path).pathComponents
        return components.count >= 3 && components[0] == "Dictionaries" &&
            components[1] == dictionaryID && !components.contains("..") &&
            !components.contains(".")
    }

    private func isIndexable(_ descriptor: DictionaryDescriptor) -> Bool {
        DictionaryOwnershipPolicy.policy(
            for: descriptor.sourceKind,
            ownership: descriptor.storageOwnership
        )?.isIndexable == true
    }

    private struct IndexPublication {
        let finalURL: URL
        let backupURL: URL
        let hadExisting: Bool
    }

    private func publish(_ prepared: DictionaryIndexPreparedResult) throws -> IndexPublication {
        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: prepared.candidateIndexURL.path) else {
            throw DictionaryIndexError.publicationFailed
        }
        let backupURL = URL(fileURLWithPath: prepared.finalIndexURL.path + ".previous")
        try? fileManager.removeItem(at: backupURL)
        let hadExisting = fileManager.fileExists(atPath: prepared.finalIndexURL.path)
        if hadExisting {
            try renameAtomically(source: prepared.finalIndexURL, destination: backupURL)
        }
        do {
            try renameAtomically(source: prepared.candidateIndexURL,
                                 destination: prepared.finalIndexURL)
            synchronizeDirectory(prepared.finalIndexURL.deletingLastPathComponent())
            return IndexPublication(finalURL: prepared.finalIndexURL,
                                    backupURL: backupURL,
                                    hadExisting: hadExisting)
        } catch {
            try? fileManager.removeItem(at: prepared.finalIndexURL)
            if hadExisting { try? renameAtomically(source: backupURL,
                                                   destination: prepared.finalIndexURL) }
            throw DictionaryIndexError.publicationFailed
        }
    }

    private func commit(_ publication: IndexPublication) {
        try? FileManager().removeItem(at: publication.backupURL)
        synchronizeDirectory(publication.finalURL.deletingLastPathComponent())
    }

    private func rollback(_ publication: IndexPublication) {
        let fileManager = FileManager()
        try? fileManager.removeItem(at: publication.finalURL)
        if publication.hadExisting {
            try? renameAtomically(source: publication.backupURL,
                                  destination: publication.finalURL)
        } else {
            try? fileManager.removeItem(at: publication.backupURL)
        }
        synchronizeDirectory(publication.finalURL.deletingLastPathComponent())
    }

    private func renameAtomically(source: URL, destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func synchronizeDirectory(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fsync(descriptor)
    }

    private func clearPublishedMetadata(_ descriptor: inout DictionaryDescriptor) {
        descriptor.indexMetadata.schemaVersion = nil
        descriptor.indexMetadata.entryCount = nil
        descriptor.indexMetadata.indexFileSize = nil
        descriptor.indexMetadata.indexedAt = nil
    }
}
