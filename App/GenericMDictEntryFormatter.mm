#import "GenericMDictEntryFormatter.h"

#include <libxml/HTMLparser.h>
#include <libxml/tree.h>

#include <algorithm>
#include <set>
#include <string>

@implementation GenericMDictSanitizationResult

- (instancetype)initWithBlocks:(NSArray<NSDictionary<NSString *, id> *> *)blocks
                      plainText:(NSString *)plainText
                      truncated:(BOOL)truncated
                       nodeCount:(NSUInteger)nodeCount {
  self = [super init];
  if (self) {
    _blocks = [blocks copy];
    _plainText = [plainText copy];
    _truncated = truncated;
    _nodeCount = nodeCount;
  }
  return self;
}

@end

namespace {
constexpr NSUInteger kMaximumRawBytes = 512 * 1024;
constexpr NSUInteger kMaximumNodes = 12000;
constexpr NSUInteger kMaximumDepth = 48;
constexpr NSUInteger kMaximumCharacters = 32768;
constexpr NSUInteger kMaximumBlocks = 512;

std::string lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
    return character < 128 ? static_cast<char>(std::tolower(character))
                           : static_cast<char>(character);
  });
  return value;
}

std::string nodeName(xmlNodePtr node) {
  return node && node->name
      ? lower(reinterpret_cast<const char *>(node->name)) : std::string();
}

NSString *string(const xmlChar *value) {
  if (!value) return @"";
  return [[NSString alloc] initWithUTF8String:
      reinterpret_cast<const char *>(value)] ?: @"";
}

std::string attribute(xmlNodePtr node, const char *name) {
  xmlChar *value = xmlGetProp(node, BAD_CAST name);
  if (!value) return {};
  std::string result(reinterpret_cast<const char *>(value));
  xmlFree(value);
  return lower(result);
}

bool explicitlyHidden(xmlNodePtr node) {
  if (xmlHasProp(node, BAD_CAST "hidden")) return true;
  const std::string aria = attribute(node, "aria-hidden");
  if (aria == "true" || aria == "1") return true;
  std::string style = attribute(node, "style");
  style.erase(std::remove_if(style.begin(), style.end(), [](unsigned char value) {
    return std::isspace(value) != 0;
  }), style.end());
  return style.find("display:none") != std::string::npos ||
      style.find("visibility:hidden") != std::string::npos;
}

bool isDiscarded(const std::string &name) {
  static const std::set<std::string> discarded = {
      "script", "style", "link", "iframe", "object", "embed", "form",
      "input", "button", "video", "audio", "img", "svg", "canvas",
      "meta", "base", "source", "track", "noscript", "template", "head"};
  return discarded.count(name) != 0;
}

bool isHeading(const std::string &name) {
  return name.size() == 2 && name[0] == 'h' && name[1] >= '1' && name[1] <= '6';
}

bool isBlock(const std::string &name) {
  static const std::set<std::string> blocks = {
      "p", "div", "li", "blockquote", "pre", "section", "article",
      "header", "footer", "dt", "dd", "tr"};
  return blocks.count(name) != 0 || isHeading(name);
}

NSString *collapsedWhitespace(NSString *value) {
  NSArray<NSString *> *components = [value componentsSeparatedByCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSMutableArray<NSString *> *nonempty = [NSMutableArray array];
  for (NSString *component in components) {
    if (component.length > 0) [nonempty addObject:component];
  }
  return [nonempty componentsJoinedByString:@" "];
}

class Collector {
 public:
  NSMutableArray<NSDictionary<NSString *, id> *> *blocks = [NSMutableArray array];
  BOOL truncated = NO;
  NSUInteger node_count = 0;

  void collect(xmlNodePtr node) {
    visitSiblings(node, 0, false, false, false, false);
    flush();
  }

  NSString *plainText() const {
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *block in blocks) {
      NSMutableString *line = [NSMutableString string];
      for (NSDictionary<NSString *, id> *run in block[@"runs"] ?: @[]) {
        NSString *text = run[@"text"];
        if (text.length > 0) [line appendString:text];
      }
      NSString *clean = [line stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if (clean.length > 0) [values addObject:clean];
    }
    return [values componentsJoinedByString:@"\n"];
  }

 private:
  NSMutableArray<NSDictionary<NSString *, id> *> *runs_ = nil;
  NSString *kind_ = @"paragraph";
  NSUInteger level_ = 0;
  NSUInteger character_count_ = 0;
  bool preformatted_ = false;

  void begin(NSString *kind, NSUInteger level, bool preformatted) {
    flush();
    kind_ = kind;
    level_ = level;
    preformatted_ = preformatted;
    runs_ = [NSMutableArray array];
    if ([kind isEqualToString:@"listItem"]) append(@"• ", false, false, false);
  }

  void flush() {
    if (!runs_ || runs_.count == 0) {
      runs_ = nil;
      return;
    }
    NSMutableString *text = [NSMutableString string];
    for (NSDictionary<NSString *, id> *run in runs_) [text appendString:run[@"text"]];
    if ([[text stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]] length] == 0) {
      runs_ = nil;
      return;
    }
    if (blocks.count >= kMaximumBlocks) {
      truncated = YES;
      runs_ = nil;
      return;
    }
    [blocks addObject:@{@"kind": kind_, @"level": @(level_), @"runs": [runs_ copy]}];
    runs_ = nil;
  }

  void append(NSString *source, bool bold, bool italic, bool code) {
    if (source.length == 0 || character_count_ >= kMaximumCharacters) {
      if (source.length > 0) truncated = YES;
      return;
    }
    if (!runs_) begin(@"paragraph", 0, false);
    NSString *value = preformatted_ ? source : collapsedWhitespace(source);
    if (value.length == 0) return;
    if (!preformatted_ && runs_.count > 0) {
      NSString *previous = runs_.lastObject[@"text"];
      if (![previous hasSuffix:@" "] && ![previous hasSuffix:@"\n"] &&
          ![value hasPrefix:@" "] && ![value hasPrefix:@"\n"] &&
          ![@",.;:!?)]}，。；：！？" containsString:[value substringToIndex:1]]) {
        value = [@" " stringByAppendingString:value];
      }
    }
    const NSUInteger remaining = kMaximumCharacters - character_count_;
    if (value.length > remaining) {
      NSRange range = [value rangeOfComposedCharacterSequencesForRange:
          NSMakeRange(0, remaining)];
      value = [value substringWithRange:range];
      truncated = YES;
    }
    if (value.length == 0) return;
    [runs_ addObject:@{@"text": value, @"bold": @(bold), @"italic": @(italic),
                       @"code": @(code)}];
    character_count_ += value.length;
  }

  void visitSiblings(xmlNodePtr node, NSUInteger depth, bool bold,
                     bool italic, bool code, bool preformatted) {
    for (xmlNodePtr current = node; current && !truncated; current = current->next) {
      visit(current, depth, bold, italic, code, preformatted);
    }
  }

  void visit(xmlNodePtr node, NSUInteger depth, bool bold,
             bool italic, bool code, bool preformatted) {
    if (!node || truncated) return;
    ++node_count;
    if (node_count > kMaximumNodes || depth > kMaximumDepth) {
      truncated = YES;
      return;
    }
    if (node->type == XML_TEXT_NODE || node->type == XML_CDATA_SECTION_NODE) {
      append(string(node->content), bold, italic, code);
      return;
    }
    if (node->type != XML_ELEMENT_NODE) return;
    const std::string name = nodeName(node);
    if (isDiscarded(name) || explicitlyHidden(node)) return;
    if (name == "br") {
      append(@"\n", bold, italic, code);
      return;
    }
    if (name == "hr") {
      flush();
      return;
    }

    const bool next_bold = bold || name == "strong" || name == "b";
    const bool next_italic = italic || name == "em" || name == "i";
    const bool next_code = code || name == "code" || name == "pre";
    const bool next_pre = preformatted || name == "pre";
    if (isBlock(name)) {
      NSString *kind = @"paragraph";
      NSUInteger level = 0;
      if (isHeading(name)) {
        kind = @"heading";
        level = static_cast<NSUInteger>(name[1] - '0');
      } else if (name == "li") {
        kind = @"listItem";
      } else if (name == "blockquote") {
        kind = @"blockquote";
      } else if (name == "pre") {
        kind = @"preformatted";
      }
      begin(kind, level, next_pre);
      visitSiblings(node->children, depth + 1, next_bold, next_italic,
                    next_code, next_pre);
      flush();
      return;
    }
    visitSiblings(node->children, depth + 1, next_bold, next_italic,
                  next_code, next_pre);
  }
};
}  // namespace

@implementation GenericMDictEntryFormatter

- (GenericMDictSanitizationResult *)sanitizeHTML:(NSString *)html {
  NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  BOOL rawTruncated = data.length > kMaximumRawBytes;
  if (rawTruncated) data = [data subdataWithRange:NSMakeRange(0, kMaximumRawBytes)];
  NSString *limited = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!limited) limited = @"";
  const char *bytes = limited.UTF8String ?: "";
  htmlDocPtr document = htmlReadMemory(bytes, static_cast<int>(strlen(bytes)), nullptr,
      "UTF-8", HTML_PARSE_RECOVER | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING |
      HTML_PARSE_NONET | HTML_PARSE_COMPACT);
  if (!document) {
    NSArray *blocks = @[@{@"kind": @"paragraph", @"level": @0,
        @"runs": @[@{@"text": @"无法安全解析该词条正文。", @"bold": @NO,
                       @"italic": @NO, @"code": @NO}]}];
    return [[GenericMDictSanitizationResult alloc]
        initWithBlocks:blocks plainText:@"无法安全解析该词条正文。"
        truncated:YES nodeCount:0];
  }
  Collector collector;
  collector.collect(xmlDocGetRootElement(document));
  xmlFreeDoc(document);
  return [[GenericMDictSanitizationResult alloc]
      initWithBlocks:collector.blocks plainText:collector.plainText()
      truncated:(rawTruncated || collector.truncated)
      nodeCount:collector.node_count];
}

@end
