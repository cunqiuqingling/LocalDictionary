import Foundation

let liveDictionaryIndexBuilder: DictionaryIndexBuildFunction = {
    sourceURL, indexURL, cancellationToken in
    let result = LocalDictionaryBuildIndex(
        sourceURL.path,
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
