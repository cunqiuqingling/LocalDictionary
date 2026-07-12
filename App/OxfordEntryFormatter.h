#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OxfordFormatResult : NSObject

@property(nonatomic, copy, readonly) NSAttributedString *attributedString;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *metrics;

- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString
                                  metrics:(NSDictionary<NSString *, NSNumber *> *)metrics;

@end

@interface OxfordEntryFormatter : NSObject

- (OxfordFormatResult *)formatHTML:(NSString *)html;

@end

NS_ASSUME_NONNULL_END
