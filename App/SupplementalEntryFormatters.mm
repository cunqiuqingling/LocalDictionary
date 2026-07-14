#import "SupplementalEntryFormatters.h"

#import <AppKit/AppKit.h>
#include <libxml/HTMLparser.h>
#include <libxml/tree.h>

#include <algorithm>
#include <set>
#include <sstream>
#include <string>
#include <vector>

@implementation Century21Sense

- (instancetype)initWithDefinition:(NSString *)definition
                             labels:(NSArray<NSString *> *)labels
                           examples:(NSArray<NSString *> *)examples
                             number:(NSUInteger)number
                   indentationLevel:(NSUInteger)indentationLevel {
  self = [super init];
  if (self) {
    _definition = [definition copy];
    _labels = [labels copy];
    _examples = [examples copy];
    _number = number;
    _indentationLevel = indentationLevel;
  }
  return self;
}

@end

@implementation Century21PartOfSpeechSection

- (instancetype)initWithPartOfSpeech:(NSString *)partOfSpeech
                              senses:(NSArray<Century21Sense *> *)senses {
  self = [super init];
  if (self) {
    _partOfSpeech = [partOfSpeech copy];
    _senses = [senses copy];
  }
  return self;
}

@end

@implementation SupplementalStructuredEntry

- (instancetype)initWithHeadword:(NSString *)headword
                       phonetics:(NSArray<NSString *> *)phonetics
                    partsOfSpeech:(NSArray<NSString *> *)partsOfSpeech
                     definitions:(NSArray<NSString *> *)definitions
                        examples:(NSArray<NSString *> *)examples
                          source:(NSString *)source {
  return [self initWithHeadword:headword
                      phonetics:phonetics
                   partsOfSpeech:partsOfSpeech
                    definitions:definitions
                       examples:examples
                          source:source
           partOfSpeechSections:@[]
                  semanticEntry:[[DictionarySemanticEntry alloc]
                      initWithInflections:@[]
                      partOfSpeechSections:@[]
                      entryLevelRelations:@[]
                      derivatives:@[]]];
}

- (instancetype)initWithHeadword:(NSString *)headword
                       phonetics:(NSArray<NSString *> *)phonetics
                    partsOfSpeech:(NSArray<NSString *> *)partsOfSpeech
                     definitions:(NSArray<NSString *> *)definitions
                        examples:(NSArray<NSString *> *)examples
                          source:(NSString *)source
            partOfSpeechSections:
                (NSArray<Century21PartOfSpeechSection *> *)partOfSpeechSections {
  return [self initWithHeadword:headword
                      phonetics:phonetics
                   partsOfSpeech:partsOfSpeech
                    definitions:definitions
                       examples:examples
                         source:source
           partOfSpeechSections:partOfSpeechSections
                  semanticEntry:[[DictionarySemanticEntry alloc]
                      initWithInflections:@[]
                      partOfSpeechSections:@[]
                      entryLevelRelations:@[]
                      derivatives:@[]]];
}

- (instancetype)initWithHeadword:(NSString *)headword
                       phonetics:(NSArray<NSString *> *)phonetics
                    partsOfSpeech:(NSArray<NSString *> *)partsOfSpeech
                     definitions:(NSArray<NSString *> *)definitions
                        examples:(NSArray<NSString *> *)examples
                          source:(NSString *)source
            partOfSpeechSections:
                (NSArray<Century21PartOfSpeechSection *> *)partOfSpeechSections
                   semanticEntry:(DictionarySemanticEntry *)semanticEntry {
  self = [super init];
  if (self) {
    _headword = [headword copy];
    _phonetics = [phonetics copy];
    _partsOfSpeech = [partsOfSpeech copy];
    _definitions = [definitions copy];
    _examples = [examples copy];
    _source = [source copy];
    _partOfSpeechSections = [partOfSpeechSections copy];
    _semanticEntry = semanticEntry;
  }
  return self;
}

@end

@implementation SupplementalFormatResult

- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString
                          structuredEntry:(SupplementalStructuredEntry *)structuredEntry
                                  metrics:(NSDictionary<NSString *, NSNumber *> *)metrics {
  self = [super init];
  if (self) {
    _attributedString = [attributedString copy];
    _structuredEntry = structuredEntry;
    _metrics = [metrics copy];
  }
  return self;
}

@end

namespace {
std::string lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
    return character < 128 ? static_cast<char>(std::tolower(character))
                           : static_cast<char>(character);
  });
  return value;
}

std::string nodeName(xmlNodePtr node) {
  return node && node->name
             ? lower(reinterpret_cast<const char *>(node->name))
             : std::string();
}

NSString *string(const xmlChar *value) {
  if (!value) return @"";
  return [[NSString alloc] initWithUTF8String:reinterpret_cast<const char *>(value)] ?: @"";
}

std::string attribute(xmlNodePtr node, const char *name) {
  xmlChar *value = xmlGetProp(node, BAD_CAST name);
  if (!value) return {};
  std::string result(reinterpret_cast<const char *>(value));
  xmlFree(value);
  return lower(result);
}

std::set<std::string> classes(xmlNodePtr node) {
  std::set<std::string> result;
  const std::string raw = attribute(node, "class");
  std::istringstream input(raw);
  for (std::string item; input >> item;) result.insert(item);
  return result;
}

bool hasClass(xmlNodePtr node, const std::string &value) {
  return classes(node).count(lower(value)) != 0;
}

bool isInvisible(xmlNodePtr node) {
  static const std::set<std::string> invisible = {
      "script", "style", "link", "head", "noscript", "template", "iframe",
      "object", "audio", "video", "source", "img", "svg"};
  return invisible.count(nodeName(node)) != 0;
}

bool isBlock(const std::string &name) {
  static const std::set<std::string> blocks = {
      "div", "p", "li", "ul", "ol", "section", "article", "table", "tr",
      "h1", "h2", "h3", "h4", "h5", "h6", "hr"};
  return blocks.count(name) != 0;
}

NSString *singleLine(NSString *source) {
  NSArray<NSString *> *components = [source componentsSeparatedByCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSMutableArray<NSString *> *nonempty = [NSMutableArray array];
  for (NSString *component in components) {
    if (component.length > 0) [nonempty addObject:component];
  }
  return [nonempty componentsJoinedByString:@" "];
}

NSString *normalizedParagraph(NSString *source) {
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  NSString *standard = [[source stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
      stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
  for (NSString *line in [standard componentsSeparatedByString:@"\n"]) {
    NSString *clean = singleLine(line);
    if (clean.length > 0) [lines addObject:clean];
  }
  return [lines componentsJoinedByString:@"\n"];
}

NSString *limited(NSString *value, NSUInteger maximum) {
  NSString *clean = normalizedParagraph(value);
  if (clean.length <= maximum) return clean;
  NSRange range = [clean rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, maximum - 1)];
  return [[clean substringWithRange:range] stringByAppendingString:@"…"];
}

bool containsHan(NSString *value) {
  static NSCharacterSet *han = [NSCharacterSet characterSetWithRange:
      NSMakeRange(0x3400, 0x9FFF - 0x3400 + 1)];
  return [value rangeOfCharacterFromSet:han].location != NSNotFound;
}

void appendRawText(xmlNodePtr node, NSMutableString *output) {
  if (!node) return;
  if (node->type == XML_TEXT_NODE || node->type == XML_CDATA_SECTION_NODE) {
    [output appendString:string(node->content)];
    return;
  }
  if (node->type != XML_ELEMENT_NODE || isInvisible(node)) return;
  const std::string name = nodeName(node);
  if (name == "br" || name == "hr") {
    [output appendString:@"\n"];
    return;
  }
  const bool block = isBlock(name);
  if (block && output.length > 0 && ![output hasSuffix:@"\n"]) [output appendString:@"\n"];
  for (xmlNodePtr child = node->children; child; child = child->next) {
    appendRawText(child, output);
  }
  if (block && output.length > 0 && ![output hasSuffix:@"\n"]) [output appendString:@"\n"];
}

NSString *text(xmlNodePtr node) {
  NSMutableString *raw = [NSMutableString string];
  appendRawText(node, raw);
  return normalizedParagraph(raw);
}

NSString *directText(xmlNodePtr node) {
  NSMutableString *raw = [NSMutableString string];
  for (xmlNodePtr child = node ? node->children : nullptr; child; child = child->next) {
    if ((child->type == XML_TEXT_NODE || child->type == XML_CDATA_SECTION_NODE) &&
        child->content) {
      [raw appendString:string(child->content)];
    }
  }
  return singleLine(raw);
}

xmlNodePtr firstNamed(xmlNodePtr node, const std::string &name) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE) continue;
    if (nodeName(current) == name) return current;
    if (xmlNodePtr match = firstNamed(current->children, name)) return match;
  }
  return nullptr;
}

void nodesNamed(xmlNodePtr node, const std::string &name,
                std::vector<xmlNodePtr> &result) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE) continue;
    if (nodeName(current) == name) result.push_back(current);
    nodesNamed(current->children, name, result);
  }
}

void nodesWithClass(xmlNodePtr node, const std::string &className,
                    std::vector<xmlNodePtr> &result) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE) continue;
    if (hasClass(current, className)) result.push_back(current);
    nodesWithClass(current->children, className, result);
  }
}

xmlNodePtr firstWithClass(xmlNodePtr node, const std::string &className) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE) continue;
    if (hasClass(current, className)) return current;
    if (xmlNodePtr match = firstWithClass(current->children, className)) return match;
  }
  return nullptr;
}

struct StyledLine {
  NSString *value = @"";
  std::set<std::string> colors;
};

class LineCollector {
 public:
  std::vector<StyledLine> lines;

  void collect(xmlNodePtr node) { collectNode(node, {}); flush(); }
  void collectOne(xmlNodePtr node) { collectSingleNode(node, {}); flush(); }

 private:
  NSMutableString *current_ = [NSMutableString string];
  std::set<std::string> colors_;

  void collectSingleNode(xmlNodePtr current, const std::string &inheritedColor) {
    if (!current) return;
    if (current->type == XML_TEXT_NODE || current->type == XML_CDATA_SECTION_NODE) {
      NSString *value = string(current->content);
      if (value.length > 0) {
        [current_ appendString:value];
        if (!inheritedColor.empty() && singleLine(value).length > 0) {
          colors_.insert(inheritedColor);
        }
      }
      return;
    }
    if (current->type != XML_ELEMENT_NODE || isInvisible(current)) return;
    const std::string name = nodeName(current);
    if (name == "br" || name == "hr") {
      flush();
      return;
    }
    const bool block = isBlock(name);
    if (block) flush();
    std::string color = inheritedColor;
    const std::string ownColor = attribute(current, "color");
    if (!ownColor.empty()) color = ownColor;
    collectNode(current->children, color);
    if (block) flush();
  }

  void flush() {
    NSString *value = singleLine(current_);
    if (value.length > 0) lines.push_back({value, colors_});
    [current_ setString:@""];
    colors_.clear();
  }

  void collectNode(xmlNodePtr node, const std::string &inheritedColor) {
    for (xmlNodePtr current = node; current; current = current->next) {
      if (current->type == XML_TEXT_NODE || current->type == XML_CDATA_SECTION_NODE) {
        NSString *value = string(current->content);
        if (value.length > 0) {
          [current_ appendString:value];
          if (!inheritedColor.empty() && singleLine(value).length > 0) {
            colors_.insert(inheritedColor);
          }
        }
        continue;
      }
      if (current->type != XML_ELEMENT_NODE || isInvisible(current)) continue;
      const std::string name = nodeName(current);
      if (name == "br" || name == "hr") {
        flush();
        continue;
      }
      const bool block = isBlock(name);
      if (block) flush();
      std::string color = inheritedColor;
      const std::string ownColor = attribute(current, "color");
      if (!ownColor.empty()) color = ownColor;
      collectNode(current->children, color);
      if (block) flush();
    }
  }
};

bool hasColor(const StyledLine &line, const std::string &color) {
  return line.colors.count(lower(color)) != 0;
}

NSMutableParagraphStyle *paragraph(CGFloat before, CGFloat after,
                                   CGFloat indentation = 0,
                                   CGFloat lineSpacing = 2) {
  NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
  style.paragraphSpacingBefore = before;
  style.paragraphSpacing = after;
  style.firstLineHeadIndent = indentation;
  style.headIndent = indentation;
  style.lineSpacing = lineSpacing;
  style.lineBreakMode = NSLineBreakByWordWrapping;
  return style;
}

NSFont *italicFont(CGFloat size) {
  return [[NSFontManager sharedFontManager]
      convertFont:[NSFont systemFontOfSize:size]
      toHaveTrait:NSItalicFontMask];
}

class Builder {
 public:
  NSMutableAttributedString *output = [[NSMutableAttributedString alloc] init];

  void add(NSString *value, NSFont *font, NSColor *color,
           NSMutableParagraphStyle *style) {
    NSString *clean = normalizedParagraph(value);
    if (clean.length == 0) return;
    if (output.length > 0 && ![output.string hasSuffix:@"\n"]) {
      [output appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    }
    NSDictionary *attributes = @{
      NSFontAttributeName : font,
      NSForegroundColorAttributeName : color,
      NSParagraphStyleAttributeName : style
    };
    [output appendAttributedString:[[NSAttributedString alloc] initWithString:clean
                                                                   attributes:attributes]];
    [output appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                   attributes:attributes]];
  }

  void source(NSString *value) {
    add(value, [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold],
        NSColor.controlAccentColor, paragraph(12, 7));
  }

  void headword(NSString *value) {
    add(value, [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold],
        NSColor.labelColor, paragraph(0, 5));
  }

  void section(NSString *value) {
    add(value, [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
        NSColor.labelColor, paragraph(9, 4));
  }

  void finish() {
    while (output.length > 0 && [output.string hasSuffix:@"\n"]) {
      [output deleteCharactersInRange:NSMakeRange(output.length - 1, 1)];
    }
  }
};

struct EntryData {
  NSString *headword = @"";
  NSString *source = @"";
  NSMutableArray<NSString *> *phonetics = [NSMutableArray array];
  NSMutableArray<NSString *> *partsOfSpeech = [NSMutableArray array];
  NSMutableArray<NSString *> *definitions = [NSMutableArray array];
  NSMutableArray<NSString *> *examples = [NSMutableArray array];
  NSArray<Century21PartOfSpeechSection *> *partOfSpeechSections = @[];
  DictionarySemanticEntry *semanticEntry = [[DictionarySemanticEntry alloc]
      initWithInflections:@[]
      partOfSpeechSections:@[]
      entryLevelRelations:@[]
      derivatives:@[]];
};

void appendUnique(NSMutableArray<NSString *> *values, NSString *value,
                  NSUInteger maximumCount, NSUInteger maximumCharacters) {
  NSString *clean = limited(value, maximumCharacters);
  if (clean.length == 0 || values.count >= maximumCount ||
      [values containsObject:clean]) return;
  [values addObject:clean];
}

SupplementalFormatResult *result(Builder &builder, EntryData &data,
                                 CFAbsoluteTime started) {
  builder.finish();
  SupplementalStructuredEntry *entry = [[SupplementalStructuredEntry alloc]
      initWithHeadword:data.headword
             phonetics:data.phonetics
          partsOfSpeech:data.partsOfSpeech
           definitions:data.definitions
              examples:data.examples
                source:data.source
  partOfSpeechSections:data.partOfSpeechSections
         semanticEntry:data.semanticEntry];
  const bool residual =
      [builder.output.string rangeOfString:@"<script" options:NSCaseInsensitiveSearch].location !=
          NSNotFound ||
      [builder.output.string rangeOfString:@"class=" options:NSCaseInsensitiveSearch].location !=
          NSNotFound;
  NSDictionary *metrics = @{
    @"characters" : @(builder.output.string.length),
    @"definitions" : @(data.definitions.count),
    @"examples" : @(data.examples.count),
    @"formatMilliseconds" : @((CFAbsoluteTimeGetCurrent() - started) * 1000.0),
    @"residualMarkup" : @(residual)
  };
  return [[SupplementalFormatResult alloc] initWithAttributedString:builder.output
                                                    structuredEntry:entry
                                                            metrics:metrics];
}

SupplementalFormatResult *parseFailure(NSString *source, NSString *headword,
                                       CFAbsoluteTime started) {
  Builder builder;
  EntryData data;
  data.source = source;
  data.headword = singleLine(headword);
  return result(builder, data, started);
}

htmlDocPtr parse(NSString *html) {
  NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding];
  return htmlReadMemory(static_cast<const char *>(data.bytes),
                        static_cast<int>(data.length), nullptr, "UTF-8",
                        HTML_PARSE_RECOVER | HTML_PARSE_NOERROR |
                            HTML_PARSE_NOWARNING | HTML_PARSE_NONET |
                            HTML_PARSE_COMPACT);
}

void collectBeforeSection(xmlNodePtr node, const std::string &name,
                          std::vector<xmlNodePtr> &result, bool &stopped) {
  for (xmlNodePtr current = node; current && !stopped; current = current->next) {
    if (current->type != XML_ELEMENT_NODE || isInvisible(current)) continue;
    NSString *value = text(current);
    if (nodeName(current) == "b" &&
        ([value isEqualToString:@"派生"] || [value isEqualToString:@"语源"])) {
      stopped = true;
      return;
    }
    if (nodeName(current) == name) result.push_back(current);
    collectBeforeSection(current->children, name, result, stopped);
  }
}

NSString *withoutPrefix(NSString *value, NSString *prefix) {
  NSString *clean = normalizedParagraph(value);
  if (prefix.length == 0 || clean.length < prefix.length) return clean;
  if ([clean compare:prefix options:(NSCaseInsensitiveSearch | NSAnchoredSearch)
              range:NSMakeRange(0, prefix.length)] == NSOrderedSame) {
    return [[clean substringFromIndex:prefix.length]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  }
  return clean;
}

bool hasClassPrefix(xmlNodePtr node, const std::string &prefix) {
  for (const auto &item : classes(node)) {
    if (item.rfind(prefix, 0) == 0) return true;
  }
  return false;
}

xmlNodePtr nearestAncestorNamed(xmlNodePtr node, const std::string &name) {
  for (xmlNodePtr current = node ? node->parent : nullptr; current;
       current = current->parent) {
    if (current->type == XML_ELEMENT_NODE && nodeName(current) == name) return current;
  }
  return nullptr;
}

xmlNodePtr centuryPartOfSpeechRoot(xmlNodePtr node) {
  for (xmlNodePtr current = node ? node->parent : nullptr; current;
       current = current->parent) {
    if (current->type == XML_ELEMENT_NODE && nodeName(current) == "li" &&
        hasClass(current, "wordgroup")) {
      return current;
    }
  }
  return nullptr;
}

NSUInteger centurySenseNumber(xmlNodePtr definition) {
  xmlNodePtr listItem = nearestAncestorNamed(definition, "li");
  xmlNodePtr list = listItem ? listItem->parent : nullptr;
  if (!list || (nodeName(list) != "ol" && !hasClass(list, "ol"))) return 0;
  NSUInteger number = 0;
  for (xmlNodePtr sibling = list->children; sibling; sibling = sibling->next) {
    if (sibling->type != XML_ELEMENT_NODE || nodeName(sibling) != "li") continue;
    ++number;
    if (sibling == listItem) return number;
  }
  return 0;
}

NSUInteger centurySenseIndentation(xmlNodePtr definition, xmlNodePtr sectionRoot) {
  xmlNodePtr listItem = nearestAncestorNamed(definition, "li");
  NSUInteger listDepth = 0;
  for (xmlNodePtr current = listItem ? listItem->parent : nullptr;
       current && current != sectionRoot; current = current->parent) {
    const std::string name = nodeName(current);
    if (name == "ul" || name == "ol") ++listDepth;
  }
  return listDepth > 0 ? listDepth - 1 : 0;
}

void collectCenturySenseMetadata(xmlNodePtr node, xmlNodePtr senseListItem,
                                 NSMutableArray<NSString *> *labels,
                                 NSMutableArray<NSString *> *examples) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE || isInvisible(current)) continue;
    if (current != senseListItem && nodeName(current) == "li") continue;
    if (hasClass(current, "additional_en")) {
      appendUnique(examples, text(current), 8, 300);
      continue;
    }
    if (hasClass(current, "additional") || hasClassPrefix(current, "domain")) {
      appendUnique(labels, text(current), 8, 300);
      continue;
    }
    collectCenturySenseMetadata(current->children, senseListItem, labels, examples);
  }
}

enum class CenturyEventKind { partOfSpeech, definition };

struct CenturyEvent {
  CenturyEventKind kind;
  xmlNodePtr node;
};

void collectCenturyEvents(xmlNodePtr node, std::vector<CenturyEvent> &events) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE || isInvisible(current)) continue;
    if (hasClass(current, "pos")) {
      events.push_back({CenturyEventKind::partOfSpeech, current});
    } else if (hasClass(current, "def")) {
      events.push_back({CenturyEventKind::definition, current});
    }
    collectCenturyEvents(current->children, events);
  }
}

struct MutableCenturySection {
  NSString *partOfSpeech = @"";
  xmlNodePtr root = nullptr;
  NSMutableArray<Century21Sense *> *senses = [NSMutableArray array];
};

NSString *newOxfordPartOfSpeech(xmlNodePtr node) {
  static NSSet<NSString *> *known = [NSSet setWithArray:@[
    @"noun", @"verb", @"adjective", @"adverb", @"preposition", @"conjunction",
    @"pronoun", @"determiner", @"exclamation", @"modal verb", @"auxiliary verb"
  ]];
  std::vector<xmlNodePtr> italicNodes;
  if (node && node->type == XML_ELEMENT_NODE && nodeName(node) == "ita") {
    italicNodes.push_back(node);
  } else {
    nodesNamed(node ? node->children : nullptr, "ita", italicNodes);
  }
  for (xmlNodePtr italicNode : italicNodes) {
    NSString *value = singleLine(text(italicNode)).lowercaseString;
    if ([known containsObject:value]) return value;
  }
  return @"";
}

NSString *newOxfordMarker(xmlNodePtr node) {
  if (nodeName(node) != "b") return @"";
  NSString *value = singleLine(text(node));
  if ([value isEqualToString:@"派生"]) return @"derivatives";
  if ([value isEqualToString:@"语源"]) return @"origin";
  if ([value isEqualToString:@"用法"]) return @"usage";
  return @"";
}

NSString *newOxfordRelationKind(NSString *title) {
  NSString *value = singleLine(title).lowercaseString;
  if ([value containsString:@"synonym"] || [value containsString:@"同义"]) {
    return @"synonym";
  }
  if ([value containsString:@"antonym"] || [value containsString:@"opposite"] ||
      [value containsString:@"反义"]) return @"antonym";
  if ([value containsString:@"collocation"] || [value containsString:@"搭配"]) {
    return @"collocation";
  }
  if ([value containsString:@"grammar"] || [value containsString:@"语法"] ||
      [value containsString:@"usage"] || [value containsString:@"用法"]) {
    return @"grammar";
  }
  if ([value containsString:@"see"] || [value containsString:@"compare"] ||
      [value containsString:@"参见"] || [value containsString:@"另见"] ||
      [value containsString:@"比较"]) {
    return @"crossReference";
  }
  return @"related";
}

NSString *newOxfordRelationTitle(NSString *title) {
  NSString *kind = newOxfordRelationKind(title);
  if ([kind isEqualToString:@"synonym"]) return @"同义词辨析";
  if ([kind isEqualToString:@"antonym"]) return @"反义词辨析";
  if ([kind isEqualToString:@"collocation"]) return @"搭配参考";
  if ([kind isEqualToString:@"crossReference"]) return @"另见";
  return singleLine(title);
}

NSString *localizedNewOxfordPartOfSpeech(NSString *source) {
  NSString *value = singleLine(source).lowercaseString;
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
  return singleLine(source);
}

struct MutableNewOxfordSection {
  NSString *partOfSpeech = @"";
  NSMutableArray<DictionarySemanticSense *> *senses = [NSMutableArray array];
  NSMutableArray<DictionarySemanticRelationGroup *> *relations = [NSMutableArray array];
  NSMutableArray<DictionarySemanticDerivative *> *derivatives = [NSMutableArray array];
};

class NewOxfordSemanticParser {
 public:
  EntryData &data;
  Builder &builder;
  NSMutableArray<NSString *> *inflections = [NSMutableArray array];
  NSMutableArray<DictionarySemanticRelationGroup *> *entryRelations =
      [NSMutableArray array];
  NSMutableArray<DictionarySemanticDerivative *> *entryDerivatives =
      [NSMutableArray array];
  std::vector<MutableNewOxfordSection> sections;

  NewOxfordSemanticParser(EntryData &data, Builder &builder)
      : data(data), builder(builder) {}

  void parseBody(xmlNodePtr body, NSString *matchedHeadword) {
    identifyHeader(body, matchedHeadword);
    enum class Mode { normal, derivatives, origin, usage };
    Mode mode = Mode::normal;
    NSString *pendingPart = @"";
    NSString *pendingHeading = @"";
    NSInteger currentSection = -1;
    NSString *derivativeWord = @"";
    NSString *derivativePart = @"";
    NSMutableArray<NSString *> *derivativePronunciations = [NSMutableArray array];
    NSMutableArray<NSString *> *derivativeSummary = [NSMutableArray array];

    auto flushDerivative = [&]() {
      if (derivativeWord.length == 0 && derivativeSummary.count == 0) return;
      DictionarySemanticDerivative *item = [[DictionarySemanticDerivative alloc]
          initWithHeadword:derivativeWord partOfSpeech:derivativePart
          pronunciations:derivativePronunciations
          summary:[derivativeSummary componentsJoinedByString:@" "]
          sourceHeadword:data.headword
          sourcePartOfSpeech:@""];
      [entryDerivatives addObject:item];
      derivativeWord = @"";
      derivativePart = @"";
      derivativePronunciations = [NSMutableArray array];
      derivativeSummary = [NSMutableArray array];
    };

    for (xmlNodePtr node = body->children; node; node = node->next) {
      if (node->type != XML_ELEMENT_NODE || isInvisible(node)) continue;
      const std::string name = nodeName(node);
      NSString *marker = newOxfordMarker(node);
      if (marker.length > 0) {
        flushDerivative();
        pendingHeading = @"";
        if ([marker isEqualToString:@"derivatives"]) mode = Mode::derivatives;
        if ([marker isEqualToString:@"origin"]) mode = Mode::origin;
        if ([marker isEqualToString:@"usage"]) mode = Mode::usage;
        continue;
      }
      if (name == "hr") {
        flushDerivative();
        mode = Mode::normal;
        pendingPart = @"";
        pendingHeading = @"";
        currentSection = -1;
        continue;
      }

      if (mode == Mode::derivatives) {
        if (name == "b") {
          flushDerivative();
          derivativeWord = singleLine(text(node));
          continue;
        }
        NSString *part = newOxfordPartOfSpeech(node);
        if (part.length > 0) {
          derivativePart = part;
          continue;
        }
        if (hasClass(node, "pron") || hasClass(node, "phonetics")) {
          appendUnique(derivativePronunciations, text(node), 4, 120);
          continue;
        }
        if (name == "ol" || name == "div" || name == "p") {
          appendUnique(derivativeSummary, text(node), 4, 500);
        } else if (name == "font" || name == "span") {
          appendUnique(derivativeSummary, text(node), 4, 500);
        }
        continue;
      }

      NSString *part = newOxfordPartOfSpeech(node);
      if (part.length > 0) {
        pendingPart = part;
        pendingHeading = @"";
        appendUnique(data.partsOfSpeech, part, 12, 80);
        continue;
      }
      if (name == "font" && pendingPart.length > 0) {
        NSString *value = singleLine(text(node));
        if (value.length > 0) appendUnique(inflections, value, 12, 240);
        continue;
      }
      if (name == "b") {
        NSString *value = singleLine(text(node));
        if (data.headword.length == 0) {
          data.headword = value;
        } else if (![value isEqualToString:data.headword]) {
          pendingHeading = value;
        }
        continue;
      }
      if (name != "ol") continue;

      if (mode == Mode::origin || mode == Mode::usage) {
        NSString *title = mode == Mode::origin ? @"语源" : @"用法";
        addListRelation(node, title, entryRelations);
        mode = Mode::normal;
        pendingHeading = @"";
        continue;
      }
      if (pendingPart.length > 0) {
        sections.push_back({pendingPart, [NSMutableArray array],
                            [NSMutableArray array], [NSMutableArray array]});
        currentSection = static_cast<NSInteger>(sections.size() - 1);
        parseSenseList(node, sections.back().senses);
        pendingPart = @"";
        pendingHeading = @"";
        continue;
      }
      if (currentSection >= 0) {
        NSString *title = pendingHeading.length > 0 ? pendingHeading : @"补充信息";
        addListRelation(node, title, sections[currentSection].relations);
        pendingHeading = @"";
      } else {
        NSString *title = pendingHeading.length > 0 ? pendingHeading : @"补充信息";
        addListRelation(node, title, entryRelations);
        pendingHeading = @"";
      }
    }
    flushDerivative();
    render();
  }

 private:
  void identifyHeader(xmlNodePtr body, NSString *matchedHeadword) {
    for (xmlNodePtr node = body->children; node; node = node->next) {
      if (node->type != XML_ELEMENT_NODE || isInvisible(node)) continue;
      if (nodeName(node) == "b" && newOxfordMarker(node).length == 0) {
        NSString *candidate = singleLine(text(node));
        if (candidate.length > 0 && candidate.length < 100) {
          data.headword = candidate;
          break;
        }
      }
    }
    if (data.headword.length == 0) data.headword = singleLine(matchedHeadword);
    std::vector<xmlNodePtr> pronunciationNodes;
    nodesWithClass(body, "phonetics", pronunciationNodes);
    for (xmlNodePtr node : pronunciationNodes) {
      NSString *value = text(node);
      if (hasClass(node, "us")) value = [@"US " stringByAppendingString:value];
      appendUnique(data.phonetics, value, 4, 120);
    }
  }

  void collectLinesWithoutNestedLists(xmlNodePtr item, LineCollector &collector,
                                      std::vector<xmlNodePtr> &nestedLists) {
    for (xmlNodePtr child = item ? item->children : nullptr; child; child = child->next) {
      if (child->type == XML_ELEMENT_NODE && nodeName(child) == "ol") {
        nestedLists.push_back(child);
        continue;
      }
      collector.collectOne(child);
    }
  }

  bool classifyRelationLine(NSString *value, NSString **kind, NSString **title) {
    NSString *lowerValue = singleLine(value).lowercaseString;
    if ([singleLine(value) hasPrefix:@"="]) {
      *title = @"相关词";
      *kind = @"relatedWords";
      return true;
    }
    const std::pair<NSString *, NSString *> markers[] = {
        {@"synonym", @"同义词辨析"}, {@"同义词", @"同义词辨析"},
        {@"antonym", @"反义词辨析"}, {@"opposite", @"反义词辨析"},
        {@"反义词", @"反义词辨析"}, {@"compare", @"另见"},
        {@"see ", @"另见"}, {@"参见", @"另见"},
        {@"grammar", @"语法"}, {@"usage", @"用法"},
        {@"collocation", @"搭配参考"}};
    for (const auto &marker : markers) {
      if ([lowerValue hasPrefix:marker.first]) {
        *title = marker.second;
        *kind = newOxfordRelationKind(marker.second);
        return true;
      }
    }
    return false;
  }

  DictionarySemanticSense *parseSense(xmlNodePtr item, NSUInteger number) {
    LineCollector collector;
    std::vector<xmlNodePtr> nestedLists;
    collectLinesWithoutNestedLists(item, collector, nestedLists);
    NSMutableArray<NSString *> *englishDefinitions = [NSMutableArray array];
    NSMutableArray<NSString *> *chineseDefinitions = [NSMutableArray array];
    NSMutableArray<DictionarySemanticExample *> *semanticExamples = [NSMutableArray array];
    NSMutableArray<DictionarySemanticRelationGroup *> *relations = [NSMutableArray array];
    for (const StyledLine &line : collector.lines) {
      NSString *value = line.value;
      if (hasColor(line, "navy")) {
        [semanticExamples addObject:[[DictionarySemanticExample alloc]
            initWithEnglish:value translations:@[]]];
        appendUnique(data.examples, value, 3, 300);
      } else if (hasColor(line, "gray") || hasColor(line, "grey")) {
        if (semanticExamples.count > 0) {
          DictionarySemanticExample *last = semanticExamples.lastObject;
          NSMutableArray<NSString *> *translations = [last.translations mutableCopy];
          appendUnique(translations, value, 4, 300);
          semanticExamples[semanticExamples.count - 1] =
              [[DictionarySemanticExample alloc] initWithEnglish:last.english
                                                     translations:translations];
        } else {
          appendUnique(chineseDefinitions, value, 8, 500);
          appendUnique(data.definitions, value, 5, 500);
        }
      } else {
        NSString *kind = nil;
        NSString *title = nil;
        if (classifyRelationLine(value, &kind, &title)) {
          [relations addObject:[[DictionarySemanticRelationGroup alloc]
              initWithKind:kind title:title values:@[value]]];
        } else if (containsHan(value)) {
          appendUnique(chineseDefinitions, value, 8, 500);
          appendUnique(data.definitions, value, 5, 500);
        } else {
          appendUnique(englishDefinitions, value, 8, 500);
          appendUnique(data.definitions, value, 5, 500);
        }
      }
    }
    NSMutableArray<DictionarySemanticSense *> *subsenses = [NSMutableArray array];
    for (xmlNodePtr nested : nestedLists) parseSenseList(nested, subsenses);
    return [[DictionarySemanticSense alloc]
        initWithNumber:[NSString stringWithFormat:@"%lu", (unsigned long)number]
        labels:@[]
        definitionEnglish:[englishDefinitions componentsJoinedByString:@"\n"]
        definitionChinese:chineseDefinitions grammarPatterns:@[]
        examples:semanticExamples relations:relations subsenses:subsenses];
  }

  void parseSenseList(xmlNodePtr list,
                      NSMutableArray<DictionarySemanticSense *> *destination) {
    NSUInteger number = 0;
    for (xmlNodePtr child = list ? list->children : nullptr; child; child = child->next) {
      if (child->type != XML_ELEMENT_NODE || nodeName(child) != "li") continue;
      [destination addObject:parseSense(child, ++number)];
    }
  }

  void addListRelation(xmlNodePtr list, NSString *title,
                       NSMutableArray<DictionarySemanticRelationGroup *> *destination) {
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    for (xmlNodePtr child = list ? list->children : nullptr; child; child = child->next) {
      if (child->type != XML_ELEMENT_NODE || nodeName(child) != "li") continue;
      appendUnique(values, text(child), 24, 500);
    }
    if (values.count == 0) appendUnique(values, text(list), 1, 500);
    if (values.count == 0) return;
    NSString *displayTitle = newOxfordRelationTitle(title);
    [destination addObject:[[DictionarySemanticRelationGroup alloc]
        initWithKind:newOxfordRelationKind(title) title:displayTitle values:values]];
  }

  void renderRelation(DictionarySemanticRelationGroup *relation, CGFloat indent) {
    builder.add(relation.title,
                [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
                NSColor.secondaryLabelColor, paragraph(4, 1, indent));
    for (NSString *value in relation.values) {
      builder.add(value, [NSFont systemFontOfSize:12.5],
                  NSColor.secondaryLabelColor,
                  paragraph(0, 3, indent + 16));
    }
  }

  void renderSense(DictionarySemanticSense *sense, NSUInteger fallbackNumber,
                   CGFloat indent = 0) {
    NSString *number = sense.number.length > 0
        ? sense.number : [NSString stringWithFormat:@"%lu", (unsigned long)fallbackNumber];
    NSArray<NSString *> *englishParts =
        [sense.definitionEnglish componentsSeparatedByString:@"\n"];
    bool numbered = false;
    for (NSString *definition in englishParts) {
      if (singleLine(definition).length == 0) continue;
      NSString *display = numbered ? definition
          : [NSString stringWithFormat:@"%@. %@", number, definition];
      builder.add(display, [NSFont systemFontOfSize:14], NSColor.labelColor,
                  paragraph(3, 2, indent));
      numbered = true;
    }
    for (NSString *definition in sense.definitionChinese) {
      NSString *display = (!numbered && definition == sense.definitionChinese.firstObject)
          ? [NSString stringWithFormat:@"%@. %@", number, definition] : definition;
      builder.add(display, [NSFont systemFontOfSize:14], NSColor.secondaryLabelColor,
                  paragraph(0, 4, indent + 18));
      numbered = true;
    }
    for (NSString *pattern in sense.grammarPatterns) {
      builder.add(pattern, [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
                  NSColor.secondaryLabelColor, paragraph(1, 2, indent + 18));
    }
    for (DictionarySemanticExample *example in sense.examples) {
      builder.add(example.english, italicFont(13), NSColor.secondaryLabelColor,
                  paragraph(1, 2, indent + 18));
      for (NSString *translation in example.translations) {
        builder.add(translation, [NSFont systemFontOfSize:13],
                    NSColor.tertiaryLabelColor, paragraph(0, 3, indent + 28));
      }
    }
    NSUInteger subsenseNumber = 0;
    for (DictionarySemanticSense *subsense in sense.subsenses) {
      renderSense(subsense, ++subsenseNumber, indent + 18);
    }
    for (DictionarySemanticRelationGroup *relation in sense.relations) {
      renderRelation(relation, indent + 18);
    }
  }

  void renderDerivatives(NSArray<DictionarySemanticDerivative *> *derivatives) {
    if (derivatives.count == 0) return;
    builder.section(@"派生词");
    for (DictionarySemanticDerivative *item in derivatives) {
      if (item.sourcePartOfSpeech.length > 0 && item.sourceHeadword.length > 0) {
        NSString *derivedPart = localizedNewOxfordPartOfSpeech(item.partOfSpeech);
        NSString *sourcePart = localizedNewOxfordPartOfSpeech(item.sourcePartOfSpeech);
        NSString *kind = derivedPart.length > 0
            ? [@"派生" stringByAppendingString:derivedPart] : @"派生词";
        builder.add([NSString stringWithFormat:@"%@（由%@ %@ 派生）", kind,
                                               sourcePart, item.sourceHeadword],
                    [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                    NSColor.secondaryLabelColor, paragraph(3, 1));
      }
      builder.add(item.headword,
                  [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
                  NSColor.labelColor, paragraph(2, 1, 14));
      NSMutableArray<NSString *> *meta = [NSMutableArray array];
      if (item.partOfSpeech.length > 0) [meta addObject:item.partOfSpeech];
      [meta addObjectsFromArray:item.pronunciations];
      builder.add([meta componentsJoinedByString:@"  "],
                  [NSFont systemFontOfSize:12.5], NSColor.secondaryLabelColor,
                  paragraph(0, 2, 28));
      builder.add(item.summary, [NSFont systemFontOfSize:12.5],
                  NSColor.secondaryLabelColor, paragraph(0, 3, 28));
    }
  }

  void render() {
    builder.source(data.source);
    builder.headword(data.headword);
    if (data.phonetics.count > 0) {
      builder.add([data.phonetics componentsJoinedByString:@"    "],
                  [NSFont systemFontOfSize:14], NSColor.secondaryLabelColor,
                  paragraph(0, 4));
    }
    for (NSString *inflection in inflections) {
      builder.add(inflection, [NSFont systemFontOfSize:12.5],
                  NSColor.tertiaryLabelColor, paragraph(0, 2));
    }
    NSMutableArray<DictionarySemanticPartOfSpeechSection *> *semanticSections =
        [NSMutableArray array];
    for (const MutableNewOxfordSection &section : sections) {
      builder.add(section.partOfSpeech,
                  [NSFont systemFontOfSize:16.5 weight:NSFontWeightSemibold],
                  NSColor.labelColor, paragraph(10, 5));
      NSUInteger senseNumber = 0;
      for (DictionarySemanticSense *sense in section.senses) {
        renderSense(sense, ++senseNumber);
      }
      for (DictionarySemanticRelationGroup *relation in section.relations) {
        renderRelation(relation, 0);
      }
      renderDerivatives(section.derivatives);
      [semanticSections addObject:[[DictionarySemanticPartOfSpeechSection alloc]
          initWithPartOfSpeech:section.partOfSpeech pronunciations:@[]
          grammarLabels:@[] senses:section.senses relations:section.relations
          derivatives:section.derivatives]];
    }
    renderDerivatives(entryDerivatives);
    for (DictionarySemanticRelationGroup *relation in entryRelations) {
      renderRelation(relation, 0);
    }
    data.semanticEntry = [[DictionarySemanticEntry alloc]
        initWithInflections:inflections partOfSpeechSections:semanticSections
        entryLevelRelations:entryRelations derivatives:entryDerivatives];
  }
};
}  // namespace

@implementation Century21EntryFormatter

- (SupplementalFormatResult *)formatHTML:(NSString *)html
                         matchedHeadword:(NSString *)matchedHeadword {
  const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  htmlDocPtr document = parse(html);
  if (!document) return parseFailure(@"21世纪大英汉词典", matchedHeadword, started);
  xmlNodePtr root = xmlDocGetRootElement(document);

  EntryData data;
  data.source = @"21世纪大英汉词典";
  std::vector<xmlNodePtr> headings;
  nodesNamed(root, "h4", headings);
  for (xmlNodePtr heading : headings) {
    if (hasClass(heading, "wordgroup")) {
      data.headword = directText(heading);
      if (data.headword.length > 0) break;
    }
  }
  if (data.headword.length == 0) data.headword = singleLine(matchedHeadword);

  std::vector<xmlNodePtr> phonetics;
  nodesWithClass(root, "phonetic", phonetics);

  std::vector<CenturyEvent> events;
  collectCenturyEvents(root, events);
  std::vector<MutableCenturySection> sections;
  MutableCenturySection *currentSection = nullptr;
  for (const CenturyEvent &event : events) {
    if (event.kind == CenturyEventKind::partOfSpeech) {
      sections.push_back({text(event.node), centuryPartOfSpeechRoot(event.node),
                          [NSMutableArray array]});
      currentSection = &sections.back();
      appendUnique(data.partsOfSpeech, currentSection->partOfSpeech, 8, 80);
      continue;
    }
    if (!currentSection) {
      sections.push_back({@"", nullptr, [NSMutableArray array]});
      currentSection = &sections.back();
    }
    NSString *definition = text(event.node);
    if (definition.length == 0) continue;
    xmlNodePtr senseListItem = nearestAncestorNamed(event.node, "li");
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSMutableArray<NSString *> *examples = [NSMutableArray array];
    if (senseListItem) {
      collectCenturySenseMetadata(senseListItem, senseListItem, labels, examples);
    }
    Century21Sense *sense = [[Century21Sense alloc]
        initWithDefinition:definition
                    labels:labels
                  examples:examples
                    number:centurySenseNumber(event.node)
          indentationLevel:centurySenseIndentation(event.node, currentSection->root)];
    [currentSection->senses addObject:sense];
    appendUnique(data.definitions, definition, 5, 500);
    for (NSString *example in examples) appendUnique(data.examples, example, 3, 300);
  }

  Builder builder;
  builder.source(data.source);
  builder.headword(data.headword);
  for (xmlNodePtr node : phonetics) {
    NSString *value = text(node);
    appendUnique(data.phonetics, value, 4, 120);
    builder.add(value, [NSFont systemFontOfSize:14], NSColor.secondaryLabelColor,
                paragraph(0, 4));
  }
  NSMutableArray<Century21PartOfSpeechSection *> *structuredSections =
      [NSMutableArray array];
  for (const MutableCenturySection &section : sections) {
    if (section.partOfSpeech.length > 0) {
      builder.add(section.partOfSpeech,
                  [NSFont systemFontOfSize:15.5 weight:NSFontWeightSemibold],
                  NSColor.labelColor, paragraph(8, 4));
    }
    for (Century21Sense *sense in section.senses) {
      NSString *prefix = sense.number > 0
          ? [NSString stringWithFormat:@"%lu. ", (unsigned long)sense.number]
          : @"• ";
      const CGFloat indentation = 18 + (sense.indentationLevel * 18);
      builder.add([prefix stringByAppendingString:sense.definition],
                  [NSFont systemFontOfSize:14], NSColor.labelColor,
                  paragraph(1, 4, indentation));
      for (NSString *label in sense.labels) {
        builder.add(label, [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
                    NSColor.secondaryLabelColor,
                    paragraph(0, 2, indentation + 18));
      }
      for (NSString *example in sense.examples) {
        builder.add(example, italicFont(13), NSColor.secondaryLabelColor,
                    paragraph(0, 3, indentation + 18));
      }
    }
    if (section.partOfSpeech.length > 0 || section.senses.count > 0) {
      [structuredSections addObject:[[Century21PartOfSpeechSection alloc]
          initWithPartOfSpeech:section.partOfSpeech
                       senses:section.senses]];
    }
  }
  data.partOfSpeechSections = structuredSections;
  if (data.definitions.count == 0) {
    NSString *fallback = withoutPrefix(text(root), data.headword);
    appendUnique(data.definitions, fallback, 5, 500);
    builder.add(fallback, [NSFont systemFontOfSize:14], NSColor.labelColor,
                paragraph(2, 5));
  }
  xmlFreeDoc(document);
  return result(builder, data, started);
}

@end

@implementation NewOxfordEntryFormatter

- (SupplementalFormatResult *)formatHTML:(NSString *)html
                         matchedHeadword:(NSString *)matchedHeadword {
  const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  htmlDocPtr document = parse(html);
  if (!document) return parseFailure(@"新牛津英文", matchedHeadword, started);
  xmlNodePtr root = xmlDocGetRootElement(document);
  xmlNodePtr body = firstNamed(root, "body");
  if (!body) body = root;

  EntryData data;
  data.source = @"新牛津英文";
  Builder builder;
  NewOxfordSemanticParser parser(data, builder);
  parser.parseBody(body, matchedHeadword);

  if (data.definitions.count == 0) {
    NSString *fallback = withoutPrefix(text(body), data.headword);
    appendUnique(data.definitions, fallback, 5, 500);
    builder.add(fallback, [NSFont systemFontOfSize:14], NSColor.labelColor,
                paragraph(2, 5));
  }
  xmlFreeDoc(document);
  return result(builder, data, started);
}

@end

@implementation MedicalEntryFormatter

- (SupplementalFormatResult *)formatHTML:(NSString *)html
                         matchedHeadword:(NSString *)matchedHeadword {
  const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  htmlDocPtr document = parse(html);
  if (!document) return parseFailure(@"英中医学辞海", matchedHeadword, started);
  xmlNodePtr root = xmlDocGetRootElement(document);
  LineCollector collector;
  collector.collect(root);

  EntryData data;
  data.source = @"英中医学辞海";
  for (const StyledLine &line : collector.lines) {
    if (hasColor(line, "darkcyan")) {
      data.headword = line.value;
      break;
    }
  }
  if (data.headword.length == 0) data.headword = singleLine(matchedHeadword);
  for (const StyledLine &line : collector.lines) {
    if (hasColor(line, "blue")) appendUnique(data.phonetics, line.value, 4, 120);
  }

  Builder builder;
  builder.source(data.source);
  builder.headword(data.headword);
  if (data.phonetics.count > 0) {
    builder.add([data.phonetics componentsJoinedByString:@"    "],
                [NSFont systemFontOfSize:14], NSColor.secondaryLabelColor,
                paragraph(0, 5));
  }

  bool definitionSection = false;
  bool relatedSection = false;
  bool afterRelatedTerm = false;
  for (const StyledLine &line : collector.lines) {
    NSString *value = line.value;
    if ([value isEqualToString:data.headword] || [data.phonetics containsObject:value]) continue;
    if (value.length == 1 && [value containsString:@"»"]) continue;
    if ([value containsString:@"习惯用语"]) {
      if (!relatedSection) {
        builder.section(@"相关医学术语");
        relatedSection = true;
      }
      continue;
    }
    if (hasColor(line, "maroon")) {
      if (!relatedSection) {
        builder.section(@"相关医学术语");
        relatedSection = true;
      }
      builder.add(value, [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                  NSColor.labelColor, paragraph(4, 2, 8));
      afterRelatedTerm = true;
      continue;
    }
    if (!definitionSection && !relatedSection) {
      builder.section(@"医学定义");
      definitionSection = true;
    }
    NSString *clean = [[value stringByReplacingOccurrencesOfString:@"»" withString:@""]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (clean.length == 0) continue;
    if (containsHan(clean)) appendUnique(data.definitions, clean, 5, 500);
    if (hasColor(line, "navy")) {
      builder.add(clean, [NSFont systemFontOfSize:14],
                  relatedSection ? NSColor.secondaryLabelColor : NSColor.labelColor,
                  paragraph(0, 3, relatedSection ? 18 : 0));
    } else {
      builder.add(clean, [NSFont systemFontOfSize:13], NSColor.secondaryLabelColor,
                  paragraph(0, 4, (relatedSection || afterRelatedTerm) ? 24 : 18));
    }
    afterRelatedTerm = false;
  }
  if (data.definitions.count == 0) {
    NSString *fallback = withoutPrefix(text(root), data.headword);
    appendUnique(data.definitions, fallback, 5, 500);
  }
  xmlFreeDoc(document);
  return result(builder, data, started);
}

@end

@implementation AffixRootEntryFormatter

- (SupplementalFormatResult *)formatHTML:(NSString *)html
                         matchedHeadword:(NSString *)matchedHeadword {
  const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  htmlDocPtr document = parse(html);
  if (!document) return parseFailure(@"词根词缀", matchedHeadword, started);
  xmlNodePtr root = xmlDocGetRootElement(document);

  EntryData data;
  data.source = @"词根词缀";
  data.headword = singleLine(matchedHeadword);

  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  if (xmlNodePtr titles = firstWithClass(root, "javascript_tittle_box")) {
    for (xmlNodePtr child = titles->children; child; child = child->next) {
      if (child->type != XML_ELEMENT_NODE) continue;
      NSString *value = text(child);
      if (value.length > 0) [labels addObject:value];
    }
  }

  std::vector<xmlNodePtr> sections;
  nodesWithClass(root, "dict_content_display", sections);
  if (data.headword.length == 0 && !sections.empty()) {
    xmlNodePtr firstSpan = firstNamed(sections.front()->children, "span");
    data.headword = firstSpan ? text(firstSpan) : @"";
  }

  Builder builder;
  builder.source(data.source);
  builder.headword(data.headword);
  builder.section(@"构词与词源");
  for (size_t index = 0; index < sections.size(); ++index) {
    NSString *value = withoutPrefix(text(sections[index]), data.headword);
    if (value.length == 0) continue;
    NSString *label = index < labels.count ? labels[index]
                                           : [NSString stringWithFormat:@"来源 %lu",
                                                (unsigned long)index + 1];
    builder.add(label, [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                NSColor.labelColor, paragraph(index == 0 ? 1 : 7, 2, 8));
    builder.add(limited(value, 8000), [NSFont systemFontOfSize:13],
                NSColor.secondaryLabelColor, paragraph(0, 5, 18));
    appendUnique(data.definitions,
                 [NSString stringWithFormat:@"%@：%@", label, value], 5, 500);
  }
  if (sections.empty()) {
    NSString *fallback = withoutPrefix(text(root), data.headword);
    builder.add(fallback, [NSFont systemFontOfSize:13], NSColor.secondaryLabelColor,
                paragraph(0, 5, 18));
    appendUnique(data.definitions, fallback, 5, 500);
  }
  xmlFreeDoc(document);
  return result(builder, data, started);
}

@end
