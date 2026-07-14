#import <Foundation/Foundation.h>
#import "DictionarySemanticModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface OxfordStructuredEntry : NSObject

@property(nonatomic, copy, readonly) NSString *headword;
@property(nonatomic, copy, readonly) NSArray<NSString *> *phonetics;
@property(nonatomic, copy, readonly) NSArray<NSString *> *partsOfSpeech;
@property(nonatomic, copy, readonly) NSArray<NSString *> *definitions;
@property(nonatomic, copy, readonly) NSArray<NSString *> *examples;
@property(nonatomic, copy, readonly) NSString *source;
@property(nonatomic, strong, readonly) DictionarySemanticEntry *semanticEntry;

- (instancetype)initWithHeadword:(NSString *)headword
                       phonetics:(NSArray<NSString *> *)phonetics
                    partsOfSpeech:(NSArray<NSString *> *)partsOfSpeech
                     definitions:(NSArray<NSString *> *)definitions
                        examples:(NSArray<NSString *> *)examples
                          source:(NSString *)source;

- (instancetype)initWithHeadword:(NSString *)headword
                       phonetics:(NSArray<NSString *> *)phonetics
                    partsOfSpeech:(NSArray<NSString *> *)partsOfSpeech
                     definitions:(NSArray<NSString *> *)definitions
                        examples:(NSArray<NSString *> *)examples
                          source:(NSString *)source
                   semanticEntry:(DictionarySemanticEntry *)semanticEntry;

@end

@interface OxfordFormatResult : NSObject

@property(nonatomic, copy, readonly) NSAttributedString *attributedString;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *metrics;
@property(nonatomic, strong, readonly) OxfordStructuredEntry *structuredEntry;

- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString
                                  metrics:(NSDictionary<NSString *, NSNumber *> *)metrics
                          structuredEntry:(OxfordStructuredEntry *)structuredEntry;

@end

@interface OxfordEntryFormatter : NSObject

- (OxfordFormatResult *)formatHTML:(NSString *)html;

@end

NS_ASSUME_NONNULL_END
