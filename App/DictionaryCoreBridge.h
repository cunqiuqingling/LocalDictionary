#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^DictionaryIndexCancellationCheck)(void);

FOUNDATION_EXPORT NSInteger LocalDictionaryIndexSchemaVersion(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *LocalDictionaryBuildIndex(
    NSString *dictionaryPath,
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
- (NSDictionary<NSString *, id> *)lookup:(NSString *)query;
- (NSDictionary<NSString *, id> *)lookup:(NSString *)query
                         maximumHTMLBytes:(NSUInteger)maximumHTMLBytes;

@end

NS_ASSUME_NONNULL_END
