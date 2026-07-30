import Foundation

extension LocalDictionaryManagedSourceCapability: @unchecked Sendable {}
extension LocalDictionarySealedIndexCapability: @unchecked Sendable {}

let liveDictionarySourceOpener: DictionaryIndexSourceOpenFunction = {
    managedRootURL, sourceRelativePath, expectedSize, expectedSHA256,
    cancellationToken in
    let result = LocalDictionaryOpenManagedSource(
        managedRootURL.path,
        sourceRelativePath,
        expectedSize,
        expectedSHA256,
        { cancellationToken.isCancelled }
    )
    if (result["cancelled"] as? Bool) == true { throw CancellationError() }
    guard (result["success"] as? Bool) == true,
          let capability =
            result["capability"] as? LocalDictionaryManagedSourceCapability else {
        throw DictionaryIndexError.sourceChanged
    }
    return DictionaryIndexSourceCapability(
        sourceFileSize: capability.sourceFileSize,
        sourceSHA256: capability.sourceSHA256,
        storage: capability,
        validation: { capability.isValidForPublication }
    )
}

let liveDictionaryIndexBuilder: DictionaryIndexBuildFunction = {
    sourceCapability, request, cancellationToken in
    guard let managedSource =
        sourceCapability.storage as? LocalDictionaryManagedSourceCapability,
          let candidate =
            request.candidateStorage as? LocalDictionarySealedIndexCapability else {
        return .failure("索引源 capability 无效。")
    }
    let result = LocalDictionaryBuildManagedIndex(
        managedSource,
        candidate,
        request.dictionaryID,
        request.sourceSHA256,
        request.sourceFileSize,
        { cancellationToken.isCancelled }
    )
    if (result["cancelled"] as? Bool) == true { return .cancelled }
    guard (result["success"] as? Bool) == true else {
        let message = result["error"] as? String ?? "索引核心无法处理此 MDX 文件。"
        return .failure(message)
    }
    let count = (result["entryCount"] as? NSNumber)?.uint64Value ?? 0
    return .success(DictionaryIndexBuildProduct(reportedEntryCount: count))
}

let liveDictionaryIndexCandidateFactory: DictionaryIndexCandidateFactory = { plan in
    let relativeDirectory = "Dictionaries/\(plan.dictionaryID)/index"
    let result = LocalDictionaryCreateManagedIndexCandidate(
        plan.managedRootURL.path, relativeDirectory, plan.publicationID
    )
    guard (result["success"] as? Bool) == true,
          let capability =
            result["capability"] as? LocalDictionarySealedIndexCapability,
          capability.candidatePath == plan.indexDirectoryURL
            .appendingPathComponent(plan.candidateName).path else {
        throw DictionaryIndexError.candidateCreationFailed
    }
    return DictionaryIndexCandidateCapability(
        publicationID: plan.publicationID,
        candidateIndexURL: URL(fileURLWithPath: capability.candidatePath),
        finalName: plan.finalName,
        storage: capability,
        seal: { entryCount in
            let sealed = LocalDictionarySealManagedIndex(
                capability, plan.dictionaryID, plan.expectedSourceSHA256,
                plan.expectedSourceSize, plan.expectedSchemaVersion, entryCount
            )
            guard (sealed["success"] as? Bool) == true,
                  let sha = sealed["indexSHA256"] as? String,
                  let size = (sealed["indexFileSize"] as? NSNumber)?.uint64Value,
                  !sha.isEmpty, size > 0 else {
                throw DictionaryIndexError.indexIdentityMismatch
            }
            return DictionaryIndexSealResult(
                entryCount: entryCount, indexFileSize: size, indexSHA256: sha
            )
        },
        publish: {
            let published = LocalDictionaryPublishManagedIndex(capability)
            guard (published["success"] as? Bool) == true,
                  published["finalName"] as? String == plan.finalName else {
                throw DictionaryIndexError.publicationFailed
            }
        },
        discard: { LocalDictionaryDiscardManagedIndex(capability) },
        commit: {
            guard LocalDictionaryCommitManagedIndex(capability) else {
                throw DictionaryIndexError.indexIdentityMismatch
            }
        }
    )
}

let liveDictionaryIndexSchemaVersion = LocalDictionaryIndexSchemaVersion()

extension ManagedDictionaryIndexCoordinator {
    convenience init(
        catalogStore: DictionaryCatalogStore,
        buildIndex: @escaping DictionaryIndexBuildFunction,
        expectedSchemaVersion: Int,
        lifecycleCoordinator: ManagedDictionaryLifecycleCoordinator
    ) {
        self.init(
            catalogStore: catalogStore,
            openSource: liveDictionarySourceOpener,
            buildIndex: buildIndex,
            createCandidate: liveDictionaryIndexCandidateFactory,
            expectedSchemaVersion: expectedSchemaVersion,
            lifecycleCoordinator: lifecycleCoordinator
        )
    }
}
