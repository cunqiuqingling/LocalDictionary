import Foundation

let livePublishedIndexVerifier: OwnedDictionaryPublishedIndexVerifier = {
    managedRootURL, descriptor in
    guard descriptor.state == .ready,
          let identity = descriptor.publishedIndexIdentity,
          descriptor.relativePaths.index == identity.relativePath else {
        return false
    }
    return LocalDictionaryValidatePublishedIndex(
        managedRootURL.path,
        identity.relativePath,
        descriptor.dictionaryID,
        identity.indexPublicationID,
        identity.indexSHA256,
        identity.indexFileSize,
        identity.sourceSHA256,
        identity.sourceFileSize,
        identity.schemaVersion,
        identity.entryCount
    )
}
