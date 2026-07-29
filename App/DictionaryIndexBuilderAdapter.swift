import Foundation

extension LocalDictionaryManagedSourceCapability: @unchecked Sendable {}

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
    sourceCapability, indexURL, cancellationToken in
    guard let managedSource =
        sourceCapability.storage as? LocalDictionaryManagedSourceCapability else {
        return .failure("索引源 capability 无效。")
    }
    let result = LocalDictionaryBuildIndexFromManagedSource(
        managedSource,
        indexURL.path,
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
            expectedSchemaVersion: expectedSchemaVersion,
            lifecycleCoordinator: lifecycleCoordinator
        )
    }
}
