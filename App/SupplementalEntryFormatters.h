#import <Foundation/Foundation.h>
#import "DictionarySemanticModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface Century21Sense : NSObject

@property(nonatomic, copy, readonly) NSString *definition;
@property(nonatomic, copy, readonly) NSArray<NSString *> *labels;
@property(nonatomic, copy, readonly) NSArray<NSString *> *examples;
@property(nonatomic, readonly) NSUInteger number;
@property(nonatomic, readonly) NSUInteger indentationLevel;

- (instancetype)initWithDefinition:(NSString *)definition
                             labels:(NSArray<NSString *> *)labels
                           examples:(NSArray<NSString *> *)examples
                             number:(NSUInteger)number
                   indentationLevel:(NSUInteger)indentationLevel;

@end

@interface Century21PartOfSpeechSection : NSObject

@property(nonatomic, copy, readonly) NSString *partOfSpeech;
@property(nonatomic, copy, readonly) NSArray<Century21Sense *> *senses;

- (instancetype)initWithPartOfSpeech:(NSString *)partOfSpeech
                              senses:(NSArray<Century21Sense *> *)senses;

@end

@interface SupplementalStructuredEntry : NSObject

@property(nonatomic, copy, readonly) NSString *headword;
@property(nonatomic, copy, readonly) NSArray<NSString *> *phonetics;
@property(nonatomic, copy, readonly) NSArray<NSString *> *partsOfSpeech;
@property(nonatomic, copy, readonly) NSArray<NSString *> *definitions;
@property(nonatomic, copy, readonly) NSArray<NSString *> *examples;
@property(nonatomic, copy, readonly) NSString *source;
@property(nonatomic, copy, readonly)
    NSArray<Century21PartOfSpeechSection *> *partOfSpeechSections;
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
            partOfSpeechSections:
                (NSArray<Century21PartOfSpeechSection *> *)partOfSpeechSections;

- (instancetype)initWithHeadword:(NSString *)headword
                       phonetics:(NSArray<NSString *> *)phonetics
                    partsOfSpeech:(NSArray<NSString *> *)partsOfSpeech
                     definitions:(NSArray<NSString *> *)definitions
                        examples:(NSArray<NSString *> *)examples
                          source:(NSString *)source
            partOfSpeechSections:
                (NSArray<Century21PartOfSpeechSection *> *)partOfSpeechSections
                   semanticEntry:(DictionarySemanticEntry *)semanticEntry;

@end

@interface SupplementalFormatResult : NSObject

@property(nonatomic, copy, readonly) NSAttributedString *attributedString;
@property(nonatomic, strong, readonly) SupplementalStructuredEntry *structuredEntry;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *metrics;

- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString
                          structuredEntry:(SupplementalStructuredEntry *)structuredEntry
                                  metrics:(NSDictionary<NSString *, NSNumber *> *)metrics;

@end

@interface Century21EntryFormatter : NSObject
- (SupplementalFormatResult *)formatHTML:(NSString *)html
                         matchedHeadword:(NSString *)matchedHeadword;
@end

@interface NewOxfordEntryFormatter : NSObject
- (SupplementalFormatResult *)formatHTML:(NSString *)html
                         matchedHeadword:(NSString *)matchedHeadword;
@end

@interface MedicalEntryFormatter : NSObject
- (SupplementalFormatResult *)formatHTML:(NSString *)html
                         matchedHeadword:(NSString *)matchedHeadword;
@end

@interface AffixRootEntryFormatter : NSObject
- (SupplementalFormatResult *)formatHTML:(NSString *)html
                         matchedHeadword:(NSString *)matchedHeadword;
@end

NS_ASSUME_NONNULL_END
