#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DictionarySemanticExample : NSObject
@property(nonatomic, copy, readonly) NSString *english;
@property(nonatomic, copy, readonly) NSArray<NSString *> *translations;
- (instancetype)initWithEnglish:(NSString *)english
                    translations:(NSArray<NSString *> *)translations;
@end

@interface DictionarySemanticRelationGroup : NSObject
@property(nonatomic, copy, readonly) NSString *kind;
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, copy, readonly) NSArray<NSString *> *values;
- (instancetype)initWithKind:(NSString *)kind
                        title:(NSString *)title
                       values:(NSArray<NSString *> *)values;
@end

@interface DictionarySemanticSense : NSObject
@property(nonatomic, copy, readonly) NSString *number;
@property(nonatomic, copy, readonly) NSArray<NSString *> *labels;
@property(nonatomic, copy, readonly) NSString *definitionEnglish;
@property(nonatomic, copy, readonly) NSArray<NSString *> *definitionChinese;
@property(nonatomic, copy, readonly) NSArray<NSString *> *grammarPatterns;
@property(nonatomic, copy, readonly) NSArray<DictionarySemanticExample *> *examples;
@property(nonatomic, copy, readonly)
    NSArray<DictionarySemanticRelationGroup *> *relations;
@property(nonatomic, copy, readonly) NSArray<DictionarySemanticSense *> *subsenses;
- (instancetype)initWithNumber:(NSString *)number
                         labels:(NSArray<NSString *> *)labels
              definitionEnglish:(NSString *)definitionEnglish
              definitionChinese:(NSArray<NSString *> *)definitionChinese
                grammarPatterns:(NSArray<NSString *> *)grammarPatterns
                       examples:(NSArray<DictionarySemanticExample *> *)examples
                      relations:(NSArray<DictionarySemanticRelationGroup *> *)relations
                      subsenses:(NSArray<DictionarySemanticSense *> *)subsenses;
@end

@interface DictionarySemanticDerivative : NSObject
@property(nonatomic, copy, readonly) NSString *headword;
@property(nonatomic, copy, readonly) NSString *partOfSpeech;
@property(nonatomic, copy, readonly) NSArray<NSString *> *pronunciations;
@property(nonatomic, copy, readonly) NSString *summary;
@property(nonatomic, copy, readonly) NSString *sourceHeadword;
@property(nonatomic, copy, readonly) NSString *sourcePartOfSpeech;
- (instancetype)initWithHeadword:(NSString *)headword
                     partOfSpeech:(NSString *)partOfSpeech
                   pronunciations:(NSArray<NSString *> *)pronunciations
                          summary:(NSString *)summary;
- (instancetype)initWithHeadword:(NSString *)headword
                     partOfSpeech:(NSString *)partOfSpeech
                   pronunciations:(NSArray<NSString *> *)pronunciations
                          summary:(NSString *)summary
                   sourceHeadword:(NSString *)sourceHeadword
               sourcePartOfSpeech:(NSString *)sourcePartOfSpeech;
@end

@interface DictionarySemanticPartOfSpeechSection : NSObject
@property(nonatomic, copy, readonly) NSString *partOfSpeech;
@property(nonatomic, copy, readonly) NSArray<NSString *> *pronunciations;
@property(nonatomic, copy, readonly) NSArray<NSString *> *grammarLabels;
@property(nonatomic, copy, readonly) NSArray<DictionarySemanticSense *> *senses;
@property(nonatomic, copy, readonly)
    NSArray<DictionarySemanticRelationGroup *> *relations;
@property(nonatomic, copy, readonly) NSArray<DictionarySemanticDerivative *> *derivatives;
- (instancetype)initWithPartOfSpeech:(NSString *)partOfSpeech
                       pronunciations:(NSArray<NSString *> *)pronunciations
                        grammarLabels:(NSArray<NSString *> *)grammarLabels
                               senses:(NSArray<DictionarySemanticSense *> *)senses
                            relations:(NSArray<DictionarySemanticRelationGroup *> *)relations
                           derivatives:(NSArray<DictionarySemanticDerivative *> *)derivatives;
@end

@interface DictionarySemanticEntry : NSObject
@property(nonatomic, copy, readonly) NSArray<NSString *> *inflections;
@property(nonatomic, copy, readonly)
    NSArray<DictionarySemanticPartOfSpeechSection *> *partOfSpeechSections;
@property(nonatomic, copy, readonly)
    NSArray<DictionarySemanticRelationGroup *> *entryLevelRelations;
@property(nonatomic, copy, readonly) NSArray<DictionarySemanticDerivative *> *derivatives;
- (instancetype)initWithInflections:(NSArray<NSString *> *)inflections
                partOfSpeechSections:
                    (NSArray<DictionarySemanticPartOfSpeechSection *> *)partOfSpeechSections
                 entryLevelRelations:
                    (NSArray<DictionarySemanticRelationGroup *> *)entryLevelRelations
                         derivatives:(NSArray<DictionarySemanticDerivative *> *)derivatives;
@end

NS_ASSUME_NONNULL_END
