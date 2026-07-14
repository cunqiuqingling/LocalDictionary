#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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
- (NSDictionary<NSString *, id> *)lookup:(NSString *)query;

@end

NS_ASSUME_NONNULL_END
