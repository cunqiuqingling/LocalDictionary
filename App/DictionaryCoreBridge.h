#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^DictionaryIndexCancellationCheck)(void);
typedef BOOL (^DictionaryReverseEntryHandler)(
    NSString *headword, NSString *plainHTML, BOOL truncated);

FOUNDATION_EXPORT NSInteger LocalDictionaryIndexSchemaVersion(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *LocalDictionaryBuildIndex(
    NSString *dictionaryPath,
    NSString *indexPath,
    DictionaryIndexCancellationCheck cancellationCheck);

@interface LocalDictionaryManagedSourceCapability : NSObject {
 @private
  void *_managedSourceStorage;
}

@property(nonatomic, readonly) unsigned long long sourceFileSize;
@property(nonatomic, copy, readonly) NSString *sourceSHA256;
@property(nonatomic, readonly, getter=isValidForPublication)
    BOOL validForPublication;

@end

@interface LocalDictionarySealedIndexCapability : NSObject {
 @private
  void *_sealedIndexStorage;
}

@property(nonatomic, copy, readonly) NSString *candidatePath;
@property(nonatomic, copy, readonly) NSString *publicationID;
@property(nonatomic, copy, readonly) NSString *indexSHA256;
@property(nonatomic, readonly) unsigned long long indexFileSize;
@property(nonatomic, readonly, getter=isSealed) BOOL sealed;

@end

FOUNDATION_EXPORT NSDictionary<NSString *, id> *
LocalDictionaryCreateManagedIndexCandidate(
    NSString *managedRootPath,
    NSString *indexDirectoryRelativePath,
    NSString *publicationID);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *
LocalDictionaryBuildManagedIndex(
    LocalDictionaryManagedSourceCapability *sourceCapability,
    LocalDictionarySealedIndexCapability *indexCapability,
    NSString *dictionaryID,
    NSString *sourceSHA256,
    unsigned long long sourceFileSize,
    DictionaryIndexCancellationCheck cancellationCheck);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *
LocalDictionarySealManagedIndex(
    LocalDictionarySealedIndexCapability *indexCapability,
    NSString *dictionaryID,
    NSString *sourceSHA256,
    unsigned long long sourceFileSize,
    NSInteger schemaVersion,
    unsigned long long entryCount);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *
LocalDictionaryPublishManagedIndex(
    LocalDictionarySealedIndexCapability *indexCapability);

FOUNDATION_EXPORT void LocalDictionaryDiscardManagedIndex(
    LocalDictionarySealedIndexCapability *indexCapability);
FOUNDATION_EXPORT BOOL LocalDictionaryCommitManagedIndex(
    LocalDictionarySealedIndexCapability *indexCapability);

FOUNDATION_EXPORT BOOL LocalDictionaryValidatePublishedIndex(
    NSString *managedRootPath,
    NSString *indexRelativePath,
    NSString *dictionaryID,
    NSString *publicationID,
    NSString *indexSHA256,
    unsigned long long indexFileSize,
    NSString *sourceSHA256,
    unsigned long long sourceFileSize,
    NSInteger schemaVersion,
    unsigned long long entryCount);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *
LocalDictionaryOpenManagedSource(
    NSString *managedRootPath,
    NSString *sourceRelativePath,
    unsigned long long expectedSourceSize,
    NSString *expectedSourceSHA256,
    DictionaryIndexCancellationCheck cancellationCheck);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *
LocalDictionaryBuildIndexFromManagedSource(
    LocalDictionaryManagedSourceCapability *sourceCapability,
    NSString *indexPath,
    DictionaryIndexCancellationCheck cancellationCheck);

#ifdef __cplusplus
class DictionaryBridgeStorage;
#endif

@interface DictionaryCoreBridge : NSObject {
 @private
#ifdef __cplusplus
  DictionaryBridgeStorage *_storage;
#else
  void *_storage;
#endif
}

@property(nonatomic, readonly, getter=isReady) BOOL ready;
@property(nonatomic, copy, readonly) NSString *lastError;
@property(nonatomic, copy, readonly) NSString *sourceSHA256;
@property(nonatomic, copy, readonly) NSString *indexSHA256;

- (instancetype)initWithDictionaryPath:(NSString *)dictionaryPath
                             indexPath:(NSString *)indexPath;
- (instancetype)initWithDictionaryPath:(NSString *)dictionaryPath
                              indexPath:(NSString *)indexPath
                     cacheMaximumBytes:(NSUInteger)cacheMaximumBytes
                   cacheMaximumEntries:(NSUInteger)cacheMaximumEntries;
- (instancetype)initReadOnlyWithDictionaryPath:(NSString *)dictionaryPath
                                      indexPath:(NSString *)indexPath
                             cacheMaximumBytes:(NSUInteger)cacheMaximumBytes
                           cacheMaximumEntries:(NSUInteger)cacheMaximumEntries;
- (instancetype)initLegacyReadOnlyWithDictionaryPath:(NSString *)dictionaryPath
                                            indexPath:(NSString *)indexPath
                                         dictionaryID:(NSString *)dictionaryID
                                  formatterIdentifier:(NSString *)formatterIdentifier
                                   cacheMaximumBytes:(NSUInteger)cacheMaximumBytes
                                 cacheMaximumEntries:(NSUInteger)cacheMaximumEntries;
- (instancetype)initManagedReadOnlyWithRootPath:(NSString *)managedRootPath
                             sourceRelativePath:(NSString *)sourceRelativePath
                              indexRelativePath:(NSString *)indexRelativePath
                                   dictionaryID:(NSString *)dictionaryID
                                  publicationID:(NSString *)publicationID
                                    indexSHA256:(NSString *)indexSHA256
                                  indexFileSize:(unsigned long long)indexFileSize
                                   sourceSHA256:(NSString *)sourceSHA256
                                 sourceFileSize:(unsigned long long)sourceFileSize
                                  schemaVersion:(NSInteger)schemaVersion
                                     entryCount:(unsigned long long)entryCount
                              cacheMaximumBytes:(NSUInteger)cacheMaximumBytes
                            cacheMaximumEntries:(NSUInteger)cacheMaximumEntries;
- (NSDictionary<NSString *, id> *)lookup:(NSString *)query;
- (NSDictionary<NSString *, id> *)lookup:(NSString *)query
                         maximumHTMLBytes:(NSUInteger)maximumHTMLBytes;
- (NSDictionary<NSString *, id> *)enumerateEntriesForReverseIndex:
        (NSUInteger)maximumHTMLBytes
    cancellationCheck:(DictionaryIndexCancellationCheck)cancellationCheck
               handler:(DictionaryReverseEntryHandler)handler;

@end

NS_ASSUME_NONNULL_END
