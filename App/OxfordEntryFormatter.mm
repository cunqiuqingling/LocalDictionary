#import "OxfordEntryFormatter.h"

#import <AppKit/AppKit.h>
#include <libxml/HTMLparser.h>
#include <libxml/tree.h>

#include <set>
#include <sstream>
#include <string>
#include <vector>

@implementation OxfordStructuredEntry

- (instancetype)initWithHeadword:(NSString *)headword
                       phonetics:(NSArray<NSString *> *)phonetics
                    partsOfSpeech:(NSArray<NSString *> *)partsOfSpeech
                     definitions:(NSArray<NSString *> *)definitions
                        examples:(NSArray<NSString *> *)examples
                          source:(NSString *)source {
  DictionarySemanticEntry *semanticEntry = [[DictionarySemanticEntry alloc]
      initWithInflections:@[]
      partOfSpeechSections:@[]
      entryLevelRelations:@[]
      derivatives:@[]];
  return [self initWithHeadword:headword
                      phonetics:phonetics
                   partsOfSpeech:partsOfSpeech
                    definitions:definitions
                       examples:examples
                         source:source
                  semanticEntry:semanticEntry];
}

- (instancetype)initWithHeadword:(NSString *)headword
                       phonetics:(NSArray<NSString *> *)phonetics
                    partsOfSpeech:(NSArray<NSString *> *)partsOfSpeech
                     definitions:(NSArray<NSString *> *)definitions
                        examples:(NSArray<NSString *> *)examples
                          source:(NSString *)source
                   semanticEntry:(DictionarySemanticEntry *)semanticEntry {
  self = [super init];
  if (self) {
    _headword = [headword copy];
    _phonetics = [phonetics copy];
    _partsOfSpeech = [partsOfSpeech copy];
    _definitions = [definitions copy];
    _examples = [examples copy];
    _source = [source copy];
    _semanticEntry = semanticEntry;
  }
  return self;
}

@end

@implementation OxfordFormatResult

- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString
                                  metrics:(NSDictionary<NSString *, NSNumber *> *)metrics
                          structuredEntry:(OxfordStructuredEntry *)structuredEntry {
  self = [super init];
  if (self) {
    _attributedString = [attributedString copy];
    _metrics = [metrics copy];
    _structuredEntry = structuredEntry;
  }
  return self;
}

@end

namespace {
std::string nodeName(xmlNodePtr node) {
  return node && node->name ? reinterpret_cast<const char *>(node->name) : "";
}

NSString *string(const xmlChar *value) {
  if (!value) return @"";
  return [[NSString alloc] initWithUTF8String:reinterpret_cast<const char *>(value)] ?: @"";
}

std::set<std::string> classes(xmlNodePtr node) {
  std::set<std::string> result;
  xmlChar *value = xmlGetProp(node, BAD_CAST "class");
  if (!value) return result;
  std::istringstream input(reinterpret_cast<const char *>(value));
  for (std::string item; input >> item;) result.insert(item);
  xmlFree(value);
  return result;
}

bool setContains(const std::set<std::string> &values, const std::string &value) {
  return values.find(value) != values.end();
}

bool hasClass(xmlNodePtr node, const std::string &value) {
  return setContains(classes(node), value);
}

bool hasAnyClass(xmlNodePtr node, const std::set<std::string> &values) {
  const auto nodeClasses = classes(node);
  for (const auto &value : values) {
    if (setContains(nodeClasses, value)) return true;
  }
  return false;
}

bool isInvisible(xmlNodePtr node) {
  static const std::set<std::string> elementNames = {
      "script", "style", "link", "head", "img", "audio", "video",
      "source", "object", "iframe", "noscript"};
  static const std::set<std::string> hiddenClasses = {
      "ast", "de_c", "de_e", "Media", "oalecd8e_show_all", "pracpron",
      "swung-dash", "symbols-drsym", "symbols-para_square", "symbols-xsym",
      "wr", "z_phon-us"};
  return setContains(elementNames, nodeName(node)) || hasAnyClass(node, hiddenClasses);
}

bool isBlockElement(const std::string &name) {
  static const std::set<std::string> blocks = {
      "p", "div", "li", "ul", "ol", "section", "article", "tr",
      "h1", "h2", "h3", "h4", "h5", "h6"};
  return setContains(blocks, name);
}

bool isSemanticNode(xmlNodePtr node) {
  static const std::set<std::string> semanticClasses = {
      "h", "infl", "ei-g", "pos-g", "n-g", "def-g", "x-g", "xr-g",
      "dr-g", "derived", "id-g", "ids-g", "pv-g", "pvs-g", "title",
      "subhead", "collsubhead", "langbanksubhead", "para", "cf"};
  return hasAnyClass(node, semanticClasses);
}

bool hasSemanticDescendant(xmlNodePtr node) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE) continue;
    if (isSemanticNode(current) || hasSemanticDescendant(current->children)) return true;
  }
  return false;
}

void appendRawText(xmlNodePtr node, NSMutableString *output,
                   const std::set<std::string> &excludedClasses) {
  if (!node) return;
  if (node->type == XML_TEXT_NODE || node->type == XML_CDATA_SECTION_NODE) {
    [output appendString:string(node->content)];
    return;
  }
  if (node->type != XML_ELEMENT_NODE || isInvisible(node) ||
      hasAnyClass(node, excludedClasses)) {
    return;
  }

  const std::string name = nodeName(node);
  if (name == "br") {
    [output appendString:@"\n"];
    return;
  }
  const bool block = isBlockElement(name);
  if (block && output.length > 0 && ![output hasSuffix:@"\n"]) {
    [output appendString:@"\n"];
  }
  for (xmlNodePtr child = node->children; child; child = child->next) {
    appendRawText(child, output, excludedClasses);
  }
  if (block && output.length > 0 && ![output hasSuffix:@"\n"]) {
    [output appendString:@"\n"];
  }
}

NSString *normalize(NSString *source) {
  NSMutableString *output = [NSMutableString string];
  NSCharacterSet *whitespace = [NSCharacterSet whitespaceCharacterSet];
  bool pendingSpace = false;
  bool pendingLineBreak = false;
  for (NSUInteger index = 0; index < source.length; ++index) {
    const unichar character = [source characterAtIndex:index];
    if (character == '\n' || character == '\r') {
      pendingLineBreak = true;
      pendingSpace = false;
      continue;
    }
    if ([whitespace characterIsMember:character]) {
      pendingSpace = true;
      continue;
    }
    if (pendingLineBreak && output.length > 0 && ![output hasSuffix:@"\n"]) {
      [output appendString:@"\n"];
    } else if (pendingSpace && output.length > 0 && ![output hasSuffix:@"\n"] &&
               ![output hasSuffix:@" "]) {
      [output appendString:@" "];
    }
    pendingLineBreak = false;
    pendingSpace = false;
    [output appendFormat:@"%C", character];
  }
  return [output stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSString *canonicalHeadword(NSString *source) {
  return [[normalize(source) stringByReplacingOccurrencesOfString:@"·" withString:@""]
      stringByReplacingOccurrencesOfString:@"•" withString:@""];
}

NSString *text(xmlNodePtr node,
               const std::set<std::string> &excludedClasses = {}) {
  NSMutableString *raw = [NSMutableString string];
  appendRawText(node, raw, excludedClasses);
  return normalize(raw);
}

xmlNodePtr firstWithClass(xmlNodePtr node, const std::string &className) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE) continue;
    if (hasClass(current, className)) return current;
    if (xmlNodePtr match = firstWithClass(current->children, className)) return match;
  }
  return nullptr;
}

void nodesWithClass(xmlNodePtr node, const std::string &className,
                    std::vector<xmlNodePtr> &result) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE) continue;
    if (hasClass(current, className)) {
      result.push_back(current);
      continue;
    }
    nodesWithClass(current->children, className, result);
  }
}

void nodesWithClassExcluding(xmlNodePtr node, const std::string &className,
                             const std::string &excludedClass,
                             std::vector<xmlNodePtr> &result) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE || hasClass(current, excludedClass)) continue;
    if (hasClass(current, className)) {
      result.push_back(current);
      continue;
    }
    nodesWithClassExcluding(current->children, className, excludedClass, result);
  }
}

NSFont *italicFont(CGFloat size) {
  NSFont *base = [NSFont systemFontOfSize:size];
  return [[NSFontManager sharedFontManager] convertFont:base
                                             toHaveTrait:NSItalicFontMask];
}

NSColor *mutedLabelColor(CGFloat alpha) {
  // Adding alpha to a dynamic system color resolves it immediately in the
  // current appearance. The resulting fixed black stayed black after a switch
  // to Dark Aqua. Keep the existing visual hierarchy with semantic dynamic
  // colors instead.
  return alpha < 0.65 ? NSColor.tertiaryLabelColor
                      : NSColor.secondaryLabelColor;
}

NSMutableParagraphStyle *paragraph(CGFloat spacingBefore, CGFloat spacingAfter,
                                   CGFloat indentation, CGFloat lineSpacing = 2) {
  NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
  style.paragraphSpacingBefore = spacingBefore;
  style.paragraphSpacing = spacingAfter;
  style.firstLineHeadIndent = indentation;
  style.headIndent = indentation;
  style.tailIndent = 0;
  style.lineSpacing = lineSpacing;
  style.lineBreakMode = NSLineBreakByWordWrapping;
  return style;
}

void collectOwned(xmlNodePtr node, const std::string &target,
                  const std::set<std::string> &barriers,
                  std::vector<xmlNodePtr> &result) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE || isInvisible(current)) continue;
    if (hasAnyClass(current, barriers)) continue;
    if (hasClass(current, target)) {
      result.push_back(current);
      continue;
    }
    collectOwned(current->children, target, barriers, result);
  }
}

int firstInDocumentOrder(xmlNodePtr node, xmlNodePtr first, xmlNodePtr second) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current == first) return 1;
    if (current == second) return -1;
    const int childResult = firstInDocumentOrder(current->children, first, second);
    if (childResult != 0) return childResult;
  }
  return 0;
}

NSString *localizedPartOfSpeech(NSString *source) {
  NSString *value = normalize(source).lowercaseString;
  const std::pair<NSString *, NSString *> mappings[] = {
      {@"adjective", @"形容词"}, {@"adverb", @"副词"},
      {@"noun", @"名词"}, {@"verb", @"动词"},
      {@"pronoun", @"代词"}, {@"preposition", @"介词"},
      {@"conjunction", @"连词"}, {@"determiner", @"限定词"}};
  for (const auto &mapping : mappings) {
    if ([value containsString:mapping.first]) return mapping.second;
  }
  if ([value hasPrefix:@"adj."] || [value isEqualToString:@"adj"]) return @"形容词";
  if ([value hasPrefix:@"adv."] || [value isEqualToString:@"adv"]) return @"副词";
  if ([value hasPrefix:@"n."] || [value isEqualToString:@"n"]) return @"名词";
  if ([value hasPrefix:@"v."] || [value isEqualToString:@"v"]) return @"动词";
  return normalize(source);
}

class Formatter {
 public:
  NSMutableAttributedString *output = [[NSMutableAttributedString alloc] init];
  NSString *headword = @"";
  NSMutableArray<NSString *> *phonetics = [NSMutableArray array];
  NSMutableArray<NSString *> *partsOfSpeech = [NSMutableArray array];
  NSMutableArray<NSString *> *definitions = [NSMutableArray array];
  NSMutableArray<NSString *> *examples = [NSMutableArray array];
  NSMutableArray<NSString *> *inflections = [NSMutableArray array];
  NSMutableArray<DictionarySemanticPartOfSpeechSection *> *semanticSections =
      [NSMutableArray array];
  NSMutableArray<DictionarySemanticRelationGroup *> *entryRelations =
      [NSMutableArray array];
  NSMutableArray<DictionarySemanticDerivative *> *entryDerivatives =
      [NSMutableArray array];
  NSMutableDictionary<NSString *, NSNumber *> *metrics = [@{
    @"headwords" : @0, @"phonetics" : @0, @"partsOfSpeech" : @0,
    @"definitions" : @0, @"chinese" : @0, @"examples" : @0,
    @"sections" : @0, @"derived" : @0, @"synonyms" : @0
  } mutableCopy];

  void render(xmlNodePtr root) {
    xmlNodePtr entry = firstWithClass(root, "entry");
    if (!entry) entry = root;
    renderHeader(entry);

    std::vector<xmlNodePtr> sections;
    collectOwned(entry->children, "p-g", {}, sections);
    for (xmlNodePtr section : sections) renderPartOfSpeech(section);
    if (sections.empty()) renderPartOfSpeech(entry);

    if (!sections.empty()) {
      collectAndRenderRelations(entry, {"p-g", "n-g", "sn-g", "dr-g"},
                                entryRelations, 0);
      collectAndRenderDerivatives(entry, {"p-g", "n-g", "sn-g"},
                                  entryDerivatives, true);
    }

    if (semanticSections.count == 0) {
      NSString *fallback = text(entry, {"h", "infl", "ei-g", "pos-g", "dr-g"});
      if (fallback.length > 0) {
        appendParagraph(fallback, [NSFont systemFontOfSize:14], NSColor.labelColor,
                        paragraph(3, 5, 0));
        appendUnique(definitions, fallback, 5);
      }
    }
    trimOutput();
  }

  OxfordStructuredEntry *structuredEntry() const {
    DictionarySemanticEntry *semantic = [[DictionarySemanticEntry alloc]
        initWithInflections:inflections
        partOfSpeechSections:semanticSections
        entryLevelRelations:entryRelations
        derivatives:entryDerivatives];
    return [[OxfordStructuredEntry alloc] initWithHeadword:headword
                                                phonetics:phonetics
                                             partsOfSpeech:partsOfSpeech
                                              definitions:definitions
                                                 examples:examples
                                                   source:@"Oxford"
                                            semanticEntry:semantic];
  }

 private:
  void appendUnique(NSMutableArray<NSString *> *values, NSString *value,
                    NSUInteger maximumCount) {
    NSString *clean = normalize(value);
    if (clean.length == 0 || values.count >= maximumCount ||
        [values containsObject:clean]) return;
    [values addObject:clean];
  }

  void increment(NSString *key) {
    metrics[key] = @(metrics[key].integerValue + 1);
  }

  void trimOutput() {
    while (output.length > 0 && [output.string hasSuffix:@"\n"]) {
      [output deleteCharactersInRange:NSMakeRange(output.length - 1, 1)];
    }
  }

  void appendParagraph(NSString *value, NSFont *font, NSColor *color,
                       NSMutableParagraphStyle *style) {
    NSString *clean = normalize(value);
    if (clean.length == 0) return;
    if (output.length > 0 && ![output.string hasSuffix:@"\n"]) {
      [output appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    }
    NSDictionary *attributes = @{NSFontAttributeName: font,
                                 NSForegroundColorAttributeName: color,
                                 NSParagraphStyleAttributeName: style};
    [output appendAttributedString:[[NSAttributedString alloc] initWithString:clean
                                                                   attributes:attributes]];
    [output appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                   attributes:attributes]];
  }

  void renderHeader(xmlNodePtr entry) {
    xmlNodePtr headwordNode = firstWithClass(entry->children, "h");
    if (headwordNode) {
      headword = canonicalHeadword(text(headwordNode));
      appendParagraph(text(headwordNode),
                      [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold],
                      NSColor.labelColor, paragraph(0, 5, 0, 2));
      increment(@"headwords");
    }
    std::vector<xmlNodePtr> pronunciationNodes;
    collectOwned(entry->children, "ei-g", {"p-g", "dr-g", "n-g"},
                 pronunciationNodes);
    for (xmlNodePtr node : pronunciationNodes) {
      NSString *value = text(node);
      appendUnique(phonetics, value, 4);
      appendParagraph(value, [NSFont systemFontOfSize:14], mutedLabelColor(0.72),
                      paragraph(0, 4, 0));
      increment(@"phonetics");
    }
    std::vector<xmlNodePtr> inflectionNodes;
    collectOwned(entry->children, "infl", {"p-g", "dr-g", "n-g"},
                 inflectionNodes);
    for (xmlNodePtr node : inflectionNodes) {
      NSString *value = text(node);
      appendUnique(inflections, value, 12);
      appendParagraph(value, [NSFont systemFontOfSize:12.5], mutedLabelColor(0.58),
                      paragraph(0, 3, 0));
    }
  }

  NSArray<NSString *> *ownedTextValues(xmlNodePtr root, const std::string &className,
                                       const std::set<std::string> &barriers,
                                       NSUInteger maximum = 12) {
    std::vector<xmlNodePtr> nodes;
    collectOwned(root->children, className, barriers, nodes);
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    for (xmlNodePtr node : nodes) appendUnique(values, text(node), maximum);
    return values;
  }

  DictionarySemanticRelationGroup *relation(xmlNodePtr node) {
    NSString *kind = @"relatedReference";
    NSString *title = @"相关参考";
    if (firstWithClass(node->children, "symbols-synsym")) {
      kind = @"synonymComparison";
      title = @"同义词辨析";
      increment(@"synonyms");
    } else if (firstWithClass(node->children, "symbols-oppsym")) {
      kind = @"antonymComparison";
      title = @"反义词辨析";
    }
    xmlNodePtr crossReferenceSymbol = firstWithClass(node->children, "symbols-xrsym");
    NSString *marker = crossReferenceSymbol ? text(crossReferenceSymbol) : @"";
    NSString *value = text(node, {"symbols-synsym", "symbols-oppsym", "symbols-xrsym"});
    NSString *classificationText = normalize(
        [NSString stringWithFormat:@"%@ %@", marker, value]);
    NSString *lower = classificationText.lowercaseString;
    if ([kind isEqualToString:@"relatedReference"]) {
      if ([lower containsString:@"collocation"] || [lower containsString:@"搭配"]) {
        kind = @"collocationReference";
        title = @"搭配参考";
      } else if ([marker isEqualToString:@"="] || [value hasPrefix:@"="]) {
        kind = @"relatedWords";
        title = @"相关词";
        if (value.length > 0 && ![value hasPrefix:@"="]) {
          value = [@"= " stringByAppendingString:value];
        }
      } else if ([lower hasPrefix:@"see "] || [lower hasPrefix:@"see also"] ||
                 [lower containsString:@"参见"] || [lower containsString:@"另见"]) {
        kind = @"seeAlso";
        title = @"另见";
      }
    }
    return [[DictionarySemanticRelationGroup alloc]
        initWithKind:kind title:title values:value.length > 0 ? @[value] : @[]];
  }

  void renderRelation(DictionarySemanticRelationGroup *group, CGFloat indent) {
    if (group.values.count == 0) return;
    appendParagraph(group.title,
                    [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
                    mutedLabelColor(0.78), paragraph(4, 1, indent));
    for (NSString *value in group.values) {
      appendParagraph(value, [NSFont systemFontOfSize:12.5],
                      NSColor.secondaryLabelColor,
                      paragraph(0, 3, indent + 14));
    }
  }

  void collectAndRenderRelations(
      xmlNodePtr root, const std::set<std::string> &barriers,
      NSMutableArray<DictionarySemanticRelationGroup *> *destination,
      CGFloat indent, bool renderNow = true,
      xmlNodePtr excludedNode = nullptr) {
    std::vector<xmlNodePtr> relationNodes;
    collectOwned(root->children, "xr-g", barriers, relationNodes);
    for (xmlNodePtr node : relationNodes) {
      if (node == excludedNode) continue;
      DictionarySemanticRelationGroup *group = relation(node);
      if (group.values.count == 0) continue;
      [destination addObject:group];
      if (renderNow) renderRelation(group, indent);
    }
  }

  DictionarySemanticExample *renderExample(xmlNodePtr node) {
    xmlNodePtr englishNode = firstWithClass(node->children, "x");
    NSString *english = englishNode ? text(englishNode, {"oalecd8e_chn"}) : @"";
    NSMutableArray<NSString *> *translations = [NSMutableArray array];
    std::vector<xmlNodePtr> translationNodes;
    nodesWithClass(node->children, "oalecd8e_chn", translationNodes);
    if (english.length > 0) {
      appendUnique(examples, english, 3);
      appendParagraph(english, italicFont(13), mutedLabelColor(0.72),
                      paragraph(1, 2, 18, 2));
      increment(@"examples");
    }
    for (xmlNodePtr translationNode : translationNodes) {
      NSString *value = text(translationNode);
      appendUnique(translations, value, 8);
      appendParagraph(value, [NSFont systemFontOfSize:13], mutedLabelColor(0.68),
                      paragraph(0, 4, 28, 2));
      increment(@"chinese");
    }
    return [[DictionarySemanticExample alloc] initWithEnglish:english
                                                  translations:translations];
  }

  DictionarySemanticSense *renderSense(xmlNodePtr node, bool subsense = false,
                                       bool includeMetadata = true,
                                       bool includeRelations = true) {
    std::vector<xmlNodePtr> numberNodes;
    collectOwned(node->children, "z_n", {"n-g", "sn-g"}, numberNodes);
    NSString *number = numberNodes.empty() ? @"" : text(numberNodes.front());
    NSArray<NSString *> *labels = includeMetadata ? ownedTextValues(
        node, "label-g", {"n-g", "sn-g", "def-g", "x-g", "xr-g"}) : @[];
    NSArray<NSString *> *grammar = includeMetadata ? ownedTextValues(
        node, "g", {"n-g", "sn-g", "def-g", "x-g", "xr-g"}) : @[];
    for (NSString *label in labels) {
      appendParagraph(label, [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
                      mutedLabelColor(0.72), paragraph(2, 1, subsense ? 28 : 14));
    }

    std::vector<xmlNodePtr> definitionNodes;
    collectOwned(node->children, "def-g", {"n-g", "sn-g", "x-g", "xr-g"},
                 definitionNodes);
    NSString *definitionEnglish = @"";
    NSMutableArray<NSString *> *definitionChinese = [NSMutableArray array];
    bool usedNumber = false;
    xmlNodePtr definingRelationNode = nullptr;
    DictionarySemanticRelationGroup *definingRelation = nil;
    if (definitionNodes.empty() && includeRelations) {
      std::vector<xmlNodePtr> candidateRelations;
      std::vector<xmlNodePtr> candidateExamples;
      collectOwned(node->children, "xr-g", {"n-g", "sn-g", "def-g", "x-g"},
                   candidateRelations);
      collectOwned(node->children, "x-g", {"n-g", "sn-g", "xr-g"},
                   candidateExamples);
      if (!candidateRelations.empty() &&
          (candidateExamples.empty() ||
           firstInDocumentOrder(node->children, candidateRelations.front(),
                                candidateExamples.front()) > 0)) {
        DictionarySemanticRelationGroup *candidate = relation(candidateRelations.front());
        if (![candidate.kind isEqualToString:@"synonymComparison"] &&
            ![candidate.kind isEqualToString:@"antonymComparison"] &&
            ![candidate.kind isEqualToString:@"collocationReference"] &&
            candidate.values.count > 0) {
          definingRelationNode = candidateRelations.front();
          definingRelation = candidate;
        }
      }
    }
    for (xmlNodePtr definitionNode : definitionNodes) {
      NSString *english = text(definitionNode, {"oalecd8e_chn", "x-g", "xr-g"});
      if (definitionEnglish.length == 0) definitionEnglish = english;
      NSString *display = english;
      if (!usedNumber && number.length > 0) {
        display = [NSString stringWithFormat:@"%@  %@", number, english];
        usedNumber = true;
      }
      appendParagraph(display, [NSFont systemFontOfSize:14], NSColor.labelColor,
                      paragraph(3, 2, subsense ? 18 : 0, 3));
      appendUnique(definitions, english, 5);
      increment(@"definitions");
      std::vector<xmlNodePtr> translations;
      nodesWithClassExcluding(definitionNode->children, "oalecd8e_chn", "x-g",
                              translations);
      for (xmlNodePtr translation : translations) {
        NSString *value = text(translation);
        appendUnique(definitionChinese, value, 12);
        appendUnique(definitions, value, 5);
        appendParagraph(value, [NSFont systemFontOfSize:14], mutedLabelColor(0.78),
                        paragraph(0, 5, subsense ? 36 : 18, 2));
        increment(@"chinese");
      }
    }
    if (definitionEnglish.length == 0 && definingRelation.values.count > 0) {
      definitionEnglish = [definingRelation.values componentsJoinedByString:@"；"];
      NSString *display = number.length > 0
          ? [NSString stringWithFormat:@"%@  %@", number, definitionEnglish]
          : definitionEnglish;
      appendParagraph(display, [NSFont systemFontOfSize:14], NSColor.labelColor,
                      paragraph(3, 2, subsense ? 18 : 0, 3));
      appendUnique(definitions, definitionEnglish, 5);
      increment(@"definitions");
      usedNumber = true;
    }
    for (NSString *patternValue in grammar) {
      appendParagraph(patternValue,
                      [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
                      mutedLabelColor(0.72), paragraph(1, 2, subsense ? 36 : 18));
    }

    NSMutableArray<DictionarySemanticExample *> *semanticExamples = [NSMutableArray array];
    std::vector<xmlNodePtr> exampleNodes;
    collectOwned(node->children, "x-g", {"n-g", "sn-g", "xr-g"}, exampleNodes);
    for (xmlNodePtr exampleNode : exampleNodes) {
      DictionarySemanticExample *example = renderExample(exampleNode);
      if (example.english.length > 0 || example.translations.count > 0) {
        [semanticExamples addObject:example];
      }
    }

    NSMutableArray<DictionarySemanticRelationGroup *> *relations = [NSMutableArray array];
    if (includeRelations) {
      collectAndRenderRelations(node, {"n-g", "sn-g", "def-g", "x-g"},
                                relations, subsense ? 36 : 18, false,
                                definingRelationNode);
    }

    NSMutableArray<DictionarySemanticSense *> *subsenses = [NSMutableArray array];
    std::vector<xmlNodePtr> subsenseNodes;
    collectOwned(node->children, "sn-g", {"n-g"}, subsenseNodes);
    for (xmlNodePtr subsenseNode : subsenseNodes) {
      [subsenses addObject:renderSense(subsenseNode, true)];
    }
    for (DictionarySemanticRelationGroup *group in relations) {
      renderRelation(group, subsense ? 36 : 18);
    }
    return [[DictionarySemanticSense alloc]
        initWithNumber:number labels:labels definitionEnglish:definitionEnglish
        definitionChinese:definitionChinese grammarPatterns:grammar
        examples:semanticExamples relations:relations subsenses:subsenses];
  }

  DictionarySemanticDerivative *derivative(xmlNodePtr node,
                                            NSString *sourcePartOfSpeech) {
    xmlNodePtr wordNode = firstWithClass(node->children, "dr");
    NSString *word = wordNode ? text(wordNode) : @"";
    xmlNodePtr partNode = firstWithClass(node->children, "pos-g");
    NSString *part = partNode ? text(partNode) : @"";
    NSArray<NSString *> *pronunciations =
        ownedTextValues(node, "ei-g", {"dr-g", "n-g"}, 4);
    NSString *summary = text(node, {"dr", "pos-g", "ei-g", "de_c", "de_e"});
    return [[DictionarySemanticDerivative alloc] initWithHeadword:word
                                                      partOfSpeech:part
                                                    pronunciations:pronunciations
                                                           summary:summary
                                                    sourceHeadword:headword
                                                sourcePartOfSpeech:sourcePartOfSpeech];
  }

  NSString *derivativeTitle(DictionarySemanticDerivative *item) {
    NSString *derivedPart = localizedPartOfSpeech(item.partOfSpeech);
    if (item.sourcePartOfSpeech.length > 0 && item.sourceHeadword.length > 0) {
      NSString *sourcePart = localizedPartOfSpeech(item.sourcePartOfSpeech);
      NSString *kind = derivedPart.length > 0
          ? [@"派生" stringByAppendingString:derivedPart] : @"派生词";
      return [NSString stringWithFormat:@"%@（由%@ %@ 派生）", kind,
                                        sourcePart, item.sourceHeadword];
    }
    return derivedPart.length > 0
        ? [@"派生" stringByAppendingString:derivedPart] : @"派生词";
  }

  void renderDerivativeGroup(NSArray<DictionarySemanticDerivative *> *derivatives,
                             bool entryLevel) {
    if (derivatives.count == 0) return;
    if (entryLevel) {
      appendParagraph(@"派生词",
                      [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
                      NSColor.labelColor, paragraph(10, 3, 0));
    }
    increment(@"sections");
    for (DictionarySemanticDerivative *item in derivatives) {
      if (!entryLevel) {
        appendParagraph(derivativeTitle(item),
                        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                        NSColor.secondaryLabelColor, paragraph(7, 2, 0));
      }
      appendParagraph(item.headword,
                      [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
                      NSColor.labelColor, paragraph(1, 1, 14));
      NSMutableArray<NSString *> *meta = [NSMutableArray array];
      if (item.partOfSpeech.length > 0) [meta addObject:item.partOfSpeech];
      [meta addObjectsFromArray:item.pronunciations];
      if (meta.count > 0) {
        appendParagraph([meta componentsJoinedByString:@"  "],
                        [NSFont systemFontOfSize:12.5], mutedLabelColor(0.68),
                        paragraph(0, 2, 28));
      }
      appendParagraph(item.summary, [NSFont systemFontOfSize:12.5],
                      mutedLabelColor(0.72), paragraph(0, 2, 28));
      increment(@"derived");
    }
  }

  void collectAndRenderDerivatives(
      xmlNodePtr root, const std::set<std::string> &barriers,
      NSMutableArray<DictionarySemanticDerivative *> *destination,
      bool renderAsGroup, NSString *sourcePartOfSpeech = @"") {
    std::vector<xmlNodePtr> nodes;
    collectOwned(root->children, "dr-g", barriers, nodes);
    NSMutableArray<DictionarySemanticDerivative *> *items = [NSMutableArray array];
    for (xmlNodePtr node : nodes) {
      DictionarySemanticDerivative *item = derivative(node, sourcePartOfSpeech);
      if (item.headword.length == 0 && item.summary.length == 0) continue;
      [destination addObject:item];
      [items addObject:item];
    }
    if (renderAsGroup) renderDerivativeGroup(items, sourcePartOfSpeech.length == 0);
  }

  void renderPartOfSpeech(xmlNodePtr section) {
    std::vector<xmlNodePtr> partNodes;
    collectOwned(section->children, "pos-g",
                 {"n-g", "sn-g", "dr-g", "id-g", "pv-g"}, partNodes);
    NSString *part = partNodes.empty() ? @"" : text(partNodes.front());
    appendUnique(partsOfSpeech, part, 8);
    if (part.length > 0) {
      appendParagraph(part, [NSFont systemFontOfSize:16.5 weight:NSFontWeightSemibold],
                      NSColor.labelColor, paragraph(10, 5, 0));
      increment(@"partsOfSpeech");
    }
    NSArray<NSString *> *pronunciations = ownedTextValues(
        section, "ei-g", {"n-g", "sn-g", "dr-g", "id-g", "pv-g"}, 4);
    NSArray<NSString *> *grammar = ownedTextValues(
        section, "g", {"n-g", "sn-g", "dr-g", "id-g", "pv-g"}, 8);
    for (NSString *value in pronunciations) {
      appendParagraph(value, [NSFont systemFontOfSize:13], mutedLabelColor(0.68),
                      paragraph(0, 3, 0));
    }
    for (NSString *value in grammar) {
      appendParagraph(value, [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
                      mutedLabelColor(0.68), paragraph(0, 3, 0));
    }

    NSMutableArray<DictionarySemanticSense *> *senses = [NSMutableArray array];
    std::vector<xmlNodePtr> senseNodes;
    collectOwned(section->children, "n-g",
                 {"p-g", "id-g", "ids-g", "pv-g", "pvs-g", "dr-g"},
                 senseNodes);
    for (xmlNodePtr senseNode : senseNodes) [senses addObject:renderSense(senseNode)];
    std::vector<xmlNodePtr> looseDefinitions;
    std::vector<xmlNodePtr> looseExamples;
    const std::set<std::string> looseBarriers = {
        "p-g", "n-g", "sn-g", "id-g", "ids-g", "pv-g", "pvs-g", "dr-g"};
    collectOwned(section->children, "def-g", looseBarriers, looseDefinitions);
    collectOwned(section->children, "x-g", looseBarriers, looseExamples);
    if (!looseDefinitions.empty() || !looseExamples.empty()) {
      [senses addObject:renderSense(section, false, false, false)];
    }

    NSMutableArray<DictionarySemanticRelationGroup *> *relations = [NSMutableArray array];
    collectAndRenderRelations(section,
                              {"p-g", "n-g", "sn-g", "id-g", "ids-g",
                               "pv-g", "pvs-g", "dr-g"},
                              relations, 0);
    struct AuxiliaryMapping {
      const char *containerClass;
      const char *itemClass;
      NSString *title;
    };
    const AuxiliaryMapping auxiliary[] = {
        {"ids-g", "id-g", @"习语与搭配"},
        {"pvs-g", "pv-g", @"短语与搭配"},
        {"coll-g", "cl", @"搭配"}};
    for (const auto &item : auxiliary) {
      std::vector<xmlNodePtr> nodes;
      collectOwned(section->children, item.containerClass,
                   {"p-g", "n-g", "sn-g", "dr-g"},
                   nodes);
      NSMutableArray<NSString *> *values = [NSMutableArray array];
      for (xmlNodePtr node : nodes) {
        std::vector<xmlNodePtr> itemNodes;
        collectOwned(node->children, item.itemClass, {}, itemNodes);
        if (itemNodes.empty()) appendUnique(values, text(node), 16);
        for (xmlNodePtr itemNode : itemNodes) {
          appendUnique(values, text(itemNode), 16);
        }
      }
      if (values.count == 0) continue;
      DictionarySemanticRelationGroup *group = [[DictionarySemanticRelationGroup alloc]
          initWithKind:[NSString stringWithUTF8String:item.containerClass]
          title:item.title values:values];
      [relations addObject:group];
      renderRelation(group, 0);
    }

    NSMutableArray<DictionarySemanticDerivative *> *derivatives = [NSMutableArray array];
    collectAndRenderDerivatives(section, {"p-g", "n-g", "sn-g"}, derivatives,
                                true, part);
    [semanticSections addObject:[[DictionarySemanticPartOfSpeechSection alloc]
        initWithPartOfSpeech:part pronunciations:pronunciations
        grammarLabels:grammar senses:senses relations:relations
        derivatives:derivatives]];
  }
};
}  // namespace

@implementation OxfordEntryFormatter

- (OxfordFormatResult *)formatHTML:(NSString *)html {
  const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding];
  htmlDocPtr document = htmlReadMemory(
      static_cast<const char *>(data.bytes), static_cast<int>(data.length), nullptr, "UTF-8",
      HTML_PARSE_RECOVER | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING | HTML_PARSE_NONET |
          HTML_PARSE_COMPACT);
  if (!document) {
    OxfordStructuredEntry *emptyEntry =
        [[OxfordStructuredEntry alloc] initWithHeadword:@""
                                             phonetics:@[]
                                          partsOfSpeech:@[]
                                           definitions:@[]
                                              examples:@[]
                                                source:@"Oxford"];
    return [[OxfordFormatResult alloc] initWithAttributedString:
              [[NSAttributedString alloc] initWithString:@"词条格式解析失败"]
                                                    metrics:@{ @"parseFailed" : @YES }
                                            structuredEntry:emptyEntry];
  }

  Formatter formatter;
  formatter.render(xmlDocGetRootElement(document));
  xmlFreeDoc(document);
  formatter.metrics[@"characters"] = @(formatter.output.string.length);
  formatter.metrics[@"formatMilliseconds"] =
      @((CFAbsoluteTimeGetCurrent() - started) * 1000.0);
  const bool residualMarkup =
      [formatter.output.string rangeOfString:@"<span" options:NSCaseInsensitiveSearch].location !=
          NSNotFound ||
      [formatter.output.string rangeOfString:@"class=" options:NSCaseInsensitiveSearch].location !=
          NSNotFound;
  formatter.metrics[@"residualMarkup"] = @(residualMarkup);
  return [[OxfordFormatResult alloc] initWithAttributedString:formatter.output
                                                       metrics:formatter.metrics
                                               structuredEntry:formatter.structuredEntry()];
}

@end
