#import "DictionarySemanticModel.h"

@implementation DictionarySemanticExample
- (instancetype)initWithEnglish:(NSString *)english
                    translations:(NSArray<NSString *> *)translations {
  self = [super init];
  if (self) {
    _english = [english copy];
    _translations = [translations copy];
  }
  return self;
}
@end

@implementation DictionarySemanticRelationGroup
- (instancetype)initWithKind:(NSString *)kind
                        title:(NSString *)title
                       values:(NSArray<NSString *> *)values {
  self = [super init];
  if (self) {
    _kind = [kind copy];
    _title = [title copy];
    _values = [values copy];
  }
  return self;
}
@end

@implementation DictionarySemanticSense
- (instancetype)initWithNumber:(NSString *)number
                         labels:(NSArray<NSString *> *)labels
              definitionEnglish:(NSString *)definitionEnglish
              definitionChinese:(NSArray<NSString *> *)definitionChinese
                grammarPatterns:(NSArray<NSString *> *)grammarPatterns
                       examples:(NSArray<DictionarySemanticExample *> *)examples
                      relations:(NSArray<DictionarySemanticRelationGroup *> *)relations
                      subsenses:(NSArray<DictionarySemanticSense *> *)subsenses {
  self = [super init];
  if (self) {
    _number = [number copy];
    _labels = [labels copy];
    _definitionEnglish = [definitionEnglish copy];
    _definitionChinese = [definitionChinese copy];
    _grammarPatterns = [grammarPatterns copy];
    _examples = [examples copy];
    _relations = [relations copy];
    _subsenses = [subsenses copy];
  }
  return self;
}
@end

@implementation DictionarySemanticDerivative
- (instancetype)initWithHeadword:(NSString *)headword
                     partOfSpeech:(NSString *)partOfSpeech
                   pronunciations:(NSArray<NSString *> *)pronunciations
                          summary:(NSString *)summary {
  return [self initWithHeadword:headword
                    partOfSpeech:partOfSpeech
                  pronunciations:pronunciations
                         summary:summary
                  sourceHeadword:@""
              sourcePartOfSpeech:@""];
}

- (instancetype)initWithHeadword:(NSString *)headword
                     partOfSpeech:(NSString *)partOfSpeech
                   pronunciations:(NSArray<NSString *> *)pronunciations
                          summary:(NSString *)summary
                   sourceHeadword:(NSString *)sourceHeadword
               sourcePartOfSpeech:(NSString *)sourcePartOfSpeech {
  self = [super init];
  if (self) {
    _headword = [headword copy];
    _partOfSpeech = [partOfSpeech copy];
    _pronunciations = [pronunciations copy];
    _summary = [summary copy];
    _sourceHeadword = [sourceHeadword copy];
    _sourcePartOfSpeech = [sourcePartOfSpeech copy];
  }
  return self;
}
@end

@implementation DictionarySemanticPartOfSpeechSection
- (instancetype)initWithPartOfSpeech:(NSString *)partOfSpeech
                       pronunciations:(NSArray<NSString *> *)pronunciations
                        grammarLabels:(NSArray<NSString *> *)grammarLabels
                               senses:(NSArray<DictionarySemanticSense *> *)senses
                            relations:(NSArray<DictionarySemanticRelationGroup *> *)relations
                           derivatives:(NSArray<DictionarySemanticDerivative *> *)derivatives {
  self = [super init];
  if (self) {
    _partOfSpeech = [partOfSpeech copy];
    _pronunciations = [pronunciations copy];
    _grammarLabels = [grammarLabels copy];
    _senses = [senses copy];
    _relations = [relations copy];
    _derivatives = [derivatives copy];
  }
  return self;
}
@end

@implementation DictionarySemanticEntry
- (instancetype)initWithInflections:(NSArray<NSString *> *)inflections
                partOfSpeechSections:
                    (NSArray<DictionarySemanticPartOfSpeechSection *> *)partOfSpeechSections
                 entryLevelRelations:
                    (NSArray<DictionarySemanticRelationGroup *> *)entryLevelRelations
                         derivatives:(NSArray<DictionarySemanticDerivative *> *)derivatives {
  self = [super init];
  if (self) {
    _inflections = [inflections copy];
    _partOfSpeechSections = [partOfSpeechSections copy];
    _entryLevelRelations = [entryLevelRelations copy];
    _derivatives = [derivatives copy];
  }
  return self;
}
@end
