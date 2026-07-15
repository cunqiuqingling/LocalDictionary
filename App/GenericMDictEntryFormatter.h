#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GenericMDictSanitizationResult : NSObject

@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, id> *> *blocks;
@property(nonatomic, copy, readonly) NSString *plainText;
@property(nonatomic, readonly) BOOL truncated;
@property(nonatomic, readonly) NSUInteger nodeCount;

- (instancetype)initWithBlocks:(NSArray<NSDictionary<NSString *, id> *> *)blocks
                      plainText:(NSString *)plainText
                      truncated:(BOOL)truncated
                       nodeCount:(NSUInteger)nodeCount;

@end

@interface GenericMDictEntryFormatter : NSObject

- (GenericMDictSanitizationResult *)sanitizeHTML:(NSString *)html;

@end

NS_ASSUME_NONNULL_END
