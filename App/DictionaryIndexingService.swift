import Darwin
import Foundation

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
    let openSource: DictionaryIndexSourceOpenFunction
    let buildIndex: DictionaryIndexBuildFunction
    let createCandidate: DictionaryIndexCandidateFactory
    let hooks: DictionaryIndexingHooks

    func establishSource(
        plan: DictionaryIndexPlan,
        cancellationToken: DictionaryIndexCancellationToken
    ) -> DictionaryIndexSourceOpenOutcome {
        do {
            try checkCancellation(cancellationToken)
            let capability = try openSource(
                plan.managedRootURL,
                plan.sourceRelativePath,
                plan.expectedSourceSize,
                plan.expectedSourceSHA256,
                cancellationToken
            )
            guard capability.sourceFileSize == plan.expectedSourceSize,
                  capability.sourceSHA256 == plan.expectedSourceSHA256,
                  capability.isValidForPublication else {
                throw DictionaryIndexError.sourceChanged
            }
            try checkCancellation(cancellationToken)
            return .ready(capability)
        } catch is CancellationError {
            return .cancelled
        } catch let error as DictionaryIndexError {
            return .failed(error)
        } catch {
            return .failed(.sourceChanged)
        }
    }

    func prepare(
        plan: DictionaryIndexPlan,
        sourceCapability: DictionaryIndexSourceCapability,
        cancellationToken: DictionaryIndexCancellationToken
    ) -> DictionaryIndexWorkerOutcome {
        let fileManager = FileManager()
        var candidate: DictionaryIndexCandidateCapability?
        do {
            try checkCancellation(cancellationToken)
            guard sourceCapability.isValidForPublication else {
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

            try checkCancellation(cancellationToken)
            let createdCandidate = try createCandidate(plan)
            candidate = createdCandidate
            let request = DictionaryIndexBuildRequest(
                candidateIndexURL: createdCandidate.candidateIndexURL,
                dictionaryID: plan.dictionaryID,
                publicationID: plan.publicationID,
                sourceSHA256: plan.expectedSourceSHA256,
                sourceFileSize: plan.expectedSourceSize,
                candidateStorage: createdCandidate.storage
            )
            let product: DictionaryIndexBuildProduct
            switch buildIndex(sourceCapability, request, cancellationToken) {
            case .cancelled:
                createdCandidate.discard()
                return .cancelled
            case .failure(let reason):
                createdCandidate.discard()
                return .failed(.builderFailed(reason))
            case .success(let value):
                product = value
            }

            try checkCancellation(cancellationToken)
            guard sourceCapability.isValidForPublication else {
                throw DictionaryIndexError.sourceChanged
            }
            let validated = try createdCandidate.seal(
                entryCount: product.reportedEntryCount
            )
            try checkCancellation(cancellationToken)
            try hooks.beforePublish()
            guard sourceCapability.isValidForPublication else {
                throw DictionaryIndexError.sourceChanged
            }

            return .prepared(DictionaryIndexPreparedResult(
                dictionaryID: plan.dictionaryID,
                publicationID: plan.publicationID,
                relativeIndexPath: plan.relativeIndexPath,
                schemaVersion: plan.expectedSchemaVersion,
                entryCount: validated.entryCount,
                indexFileSize: validated.indexFileSize,
                indexSHA256: validated.indexSHA256,
                sourceFileSize: plan.expectedSourceSize,
                sourceSHA256: sourceCapability.sourceSHA256,
                sourceRelativePath: plan.sourceRelativePath,
                indexedAt: Date(),
                sourceCapability: sourceCapability,
                candidateCapability: createdCandidate
            ))
        } catch is CancellationError {
            candidate?.discard()
            return .cancelled
        } catch let error as DictionaryIndexError {
            candidate?.discard()
            return .failed(error)
        } catch {
            candidate?.discard()
            return .failed(.builderFailed("索引建立失败。"))
        }
    }

    func discardPrepared(_ prepared: DictionaryIndexPreparedResult) {
        prepared.candidateCapability.discard()
    }

    private func requiredCapacity(sourceSize: UInt64) -> UInt64 {
        let doubled = sourceSize.multipliedReportingOverflow(by: 2)
        let base = doubled.overflow ? UInt64.max : doubled.partialValue
        return base.addingReportingOverflow(128 * 1024 * 1024).overflow
            ? UInt64.max
            : base + 128 * 1024 * 1024
    }

    private func checkCancellation(_ token: DictionaryIndexCancellationToken) throws {
        if token.isCancelled { throw CancellationError() }
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
    private let lifecycleCoordinator: ManagedDictionaryLifecycleCoordinator
    private var runtimeInvalidator: @Sendable (String) async -> Void
    private var currentTask: Task<Void, Never>?
    private var cancellationToken: DictionaryIndexCancellationToken?
    private var failureMessages: [String: String] = [:]

    init(
        catalog: DictionaryCatalog = .empty(),
        catalogStore: DictionaryCatalogStore,
        applicationSupportRootURL: URL = DictionaryImportService.defaultApplicationSupportRootURL(),
        openSource: @escaping DictionaryIndexSourceOpenFunction,
        buildIndex: @escaping DictionaryIndexBuildFunction,
        createCandidate: @escaping DictionaryIndexCandidateFactory,
        expectedSchemaVersion: Int,
        hooks: DictionaryIndexingHooks = .live,
        lifecycleCoordinator: ManagedDictionaryLifecycleCoordinator =
            ManagedDictionaryLifecycleCoordinator(),
        runtimeInvalidator: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.catalog = catalog
        self.catalogStore = catalogStore
        self.applicationSupportRootURL = applicationSupportRootURL
        self.expectedSchemaVersion = expectedSchemaVersion
        worker = ManagedDictionaryIndexWorker(openSource: openSource,
                                              buildIndex: buildIndex,
                                              createCandidate: createCandidate,
                                              hooks: hooks)
        self.lifecycleCoordinator = lifecycleCoordinator
        self.runtimeInvalidator = runtimeInvalidator
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

    /// Installed during AppDelegate composition after the shared query service exists.  The
    /// coordinator has already drained leases before this callback is invoked.
    func setRuntimeInvalidator(_ invalidator: @escaping @Sendable (String) async -> Void) {
        runtimeInvalidator = invalidator
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

        failureMessages[dictionaryID] = nil
        activity = DictionaryIndexActivity(dictionaryID: dictionaryID, stage: .preparing)

        let token = DictionaryIndexCancellationToken()
        cancellationToken = token
        let worker = self.worker
        let lifecycleCoordinator = self.lifecycleCoordinator
        let runtimeInvalidator = self.runtimeInvalidator
        currentTask = Task { @MainActor [weak self] in
            let permit: ManagedDictionaryLifecyclePermit
            do {
                permit = try await lifecycleCoordinator.acquireExclusiveOperation(
                    for: dictionaryID, operation: .index
                )
            } catch {
                guard let self else { return }
                self.activity = nil
                self.cancellationToken = nil
                self.currentTask = nil
                return
            }
            guard let self else {
                await lifecycleCoordinator.complete(
                    permit, disposition: .suspended(incrementGeneration: true)
                )
                return
            }
            guard let plan = self.markIndexingAndMakePlan(dictionaryID: dictionaryID) else {
                await lifecycleCoordinator.complete(
                    permit, disposition: .suspended(incrementGeneration: false)
                )
                self.activity = nil
                self.cancellationToken = nil
                self.currentTask = nil
                return
            }
            self.activity = DictionaryIndexActivity(
                dictionaryID: dictionaryID, stage: .hashingSource
            )
            let sourceOutcome = await Task.detached(priority: .userInitiated) {
                worker.establishSource(plan: plan, cancellationToken: token)
            }.value
            let sourceCapability: DictionaryIndexSourceCapability
            switch sourceOutcome {
            case .ready(let capability):
                sourceCapability = capability
            case .cancelled:
                let disposition = await self.finish(
                    dictionaryID: dictionaryID, outcome: .cancelled
                )
                await lifecycleCoordinator.complete(permit, disposition: disposition)
                return
            case .failed(let error):
                let disposition = await self.finish(
                    dictionaryID: dictionaryID, outcome: .failed(error)
                )
                await lifecycleCoordinator.complete(permit, disposition: disposition)
                return
            }
            await runtimeInvalidator(dictionaryID)
            self.activity = DictionaryIndexActivity(
                dictionaryID: dictionaryID, stage: .buildingSQLite
            )
            let outcome = await Task.detached(priority: .userInitiated) {
                worker.prepare(plan: plan, sourceCapability: sourceCapability,
                               cancellationToken: token)
            }.value
            let disposition = await self.finish(dictionaryID: dictionaryID, outcome: outcome)
            await lifecycleCoordinator.complete(permit, disposition: disposition)
        }
        return .started
    }

    /// The lifecycle permit is acquired before this short transaction. The plan is derived from
    /// the same latest durable descriptor that is atomically moved to `.indexing`, so a plan
    /// captured while waiting for an old lease can never build a newly replaced descriptor.
    private func markIndexingAndMakePlan(dictionaryID: String) -> DictionaryIndexPlan? {
        let now = Date()
        do {
            let mutation = try catalogStore.mutate { latest, _ -> DictionaryIndexPlan in
                guard let index = latest.dictionaries.firstIndex(where: {
                    $0.dictionaryID == dictionaryID && isIndexable($0)
                }), (latest.dictionaries[index].state == .pendingIndex ||
                    latest.dictionaries[index].state == .failed) else {
                    throw DictionaryIndexError.catalogWriteFailed
                }
                let plan = try makePlan(for: latest.dictionaries[index])
                latest.dictionaries[index].state = .indexing
                latest.dictionaries[index].relativePaths.index = nil
                clearPublishedMetadata(&latest.dictionaries[index])
                latest.dictionaries[index].updatedAt = now
                latest.updatedAt = now
                return plan
            }
            catalog = mutation.catalog
            onCatalogChanged?(mutation.catalog)
            return mutation.value
        } catch let error as DictionaryIndexError {
            failureMessages[dictionaryID] = error.localizedDescription
            return nil
        } catch {
            failureMessages[dictionaryID] = DictionaryIndexError.catalogWriteFailed.localizedDescription
            return nil
        }
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
                        outcome: DictionaryIndexWorkerOutcome) async
        -> ManagedDictionaryLifecycleDisposition {
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
            return .suspended(incrementGeneration: true)
        }

        var updated = catalog
        let now = Date()
        var publication: DictionaryIndexCandidateCapability?
        var preparedSourceRelativePath: String?
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
            preparedSourceRelativePath = prepared.sourceRelativePath
            guard !cancellationTokenIsSet else {
                let worker = self.worker
                await Task.detached(priority: .utility) { worker.discardPrepared(prepared) }.value
                updated.dictionaries[index].state = .pendingIndex
                updated.dictionaries[index].relativePaths.index = nil
                clearPublishedMetadata(&updated.dictionaries[index])
                break
            }
            guard prepared.sourceCapability.isValidForPublication else {
                let worker = self.worker
                await Task.detached(priority: .utility) {
                    worker.discardPrepared(prepared)
                }.value
                updated.dictionaries[index].state = .failed
                updated.dictionaries[index].relativePaths.index = nil
                clearPublishedMetadata(&updated.dictionaries[index])
                failureMessages[dictionaryID] =
                    DictionaryIndexError.sourceChanged.localizedDescription
                break
            }
            do {
                try prepared.candidateCapability.publish()
                publication = prepared.candidateCapability
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
                updated.dictionaries[index].publishedIndexIdentity =
                    PublishedIndexIdentity(
                        indexPublicationID: prepared.publicationID,
                        indexSHA256: prepared.indexSHA256,
                        indexFileSize: prepared.indexFileSize,
                        sourceSHA256: prepared.sourceSHA256,
                        sourceFileSize: prepared.sourceFileSize,
                        schemaVersion: prepared.schemaVersion,
                        entryCount: prepared.entryCount,
                        indexedAt: prepared.indexedAt,
                        relativePath: prepared.relativeIndexPath
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
            let mutation = try catalogStore.mutate { latest, _ -> Bool in
                guard let latestIndex = latest.dictionaries.firstIndex(where: {
                    $0.dictionaryID == dictionaryID && isIndexable($0)
                }),
                latest.dictionaries[latestIndex].state == .indexing,
                preparedSourceRelativePath == nil ||
                    (latest.dictionaries[latestIndex].relativePaths.dictionary ==
                        preparedSourceRelativePath &&
                     latest.dictionaries[latestIndex].indexMetadata.sourceSHA256?.lowercased() ==
                        target.indexMetadata.sourceSHA256?.lowercased() &&
                     latest.dictionaries[latestIndex].indexMetadata.sourceFileSize ==
                        target.indexMetadata.sourceFileSize) else {
                    throw DictionaryIndexError.catalogWriteFailed
                }
                latest.dictionaries[latestIndex].state = target.state
                latest.dictionaries[latestIndex].relativePaths.index = target.relativePaths.index
                latest.dictionaries[latestIndex].indexMetadata = target.indexMetadata
                latest.dictionaries[latestIndex].publishedIndexIdentity =
                    target.publishedIndexIdentity
                latest.dictionaries[latestIndex].updatedAt = now
                latest.updatedAt = now
                return latest.dictionaries[latestIndex].enabled && target.state == .ready
            }
            catalog = mutation.catalog
            if let publication {
                do {
                    try publication.commit()
                } catch {
                    publication.discard()
                    failureMessages[dictionaryID] =
                        DictionaryIndexError.indexIdentityMismatch.localizedDescription
                    do {
                        let repaired = try catalogStore.mutate { latest, _ in
                            guard let latestIndex = latest.dictionaries.firstIndex(
                                where: { $0.dictionaryID == dictionaryID }
                            ) else { throw DictionaryIndexError.catalogWriteFailed }
                            latest.dictionaries[latestIndex].state = .pendingIndex
                            latest.dictionaries[latestIndex].relativePaths.index = nil
                            clearPublishedMetadata(&latest.dictionaries[latestIndex])
                            latest.dictionaries[latestIndex].updatedAt = Date()
                            latest.updatedAt = Date()
                        }
                        catalog = repaired.catalog
                        onCatalogChanged?(repaired.catalog)
                    } catch {
                        // The lifecycle remains suspended. Startup reconciliation
                        // will fail closed against the durable ready identity.
                    }
                    return .suspended(incrementGeneration: true)
                }
            }
            onCatalogChanged?(mutation.catalog)
            return mutation.value
                ? .available(incrementGeneration: true)
                : .suspended(incrementGeneration: true)
        } catch {
            publication?.discard()
            failureMessages[dictionaryID] =
                DictionaryIndexError.catalogWriteFailed.localizedDescription
            var inMemoryFallback = updated
            inMemoryFallback.dictionaries[index].state = .failed
            inMemoryFallback.dictionaries[index].relativePaths.index = nil
            clearPublishedMetadata(&inMemoryFallback.dictionaries[index])
            catalog = inMemoryFallback
            onCatalogChanged?(inMemoryFallback)
            return .suspended(incrementGeneration: true)
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
        let publicationID = UUID().uuidString.lowercased()
        let base = "Dictionaries/\(descriptor.dictionaryID)/index"
        let candidateName = ".dictionary.\(publicationID).candidate"
        let finalName = "dictionary.\(publicationID).sqlite"
        let relativeIndexPath = "\(base)/\(finalName)"
        let indexDirectoryURL = applicationSupportRootURL.appendingPathComponent(base,
                                                                                  isDirectory: true)
        return DictionaryIndexPlan(
            dictionaryID: descriptor.dictionaryID,
            publicationID: publicationID,
            managedRootURL: applicationSupportRootURL,
            sourceRelativePath: sourceRelativePath,
            expectedSourceSize: expectedSourceSize,
            expectedSourceSHA256: expectedSHA256,
            indexDirectoryURL: indexDirectoryURL,
            candidateName: candidateName,
            finalName: finalName,
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

    private func clearPublishedMetadata(_ descriptor: inout DictionaryDescriptor) {
        descriptor.indexMetadata.schemaVersion = nil
        descriptor.indexMetadata.entryCount = nil
        descriptor.indexMetadata.indexFileSize = nil
        descriptor.indexMetadata.indexedAt = nil
        descriptor.publishedIndexIdentity = nil
    }
}
