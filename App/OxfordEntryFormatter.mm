#import "OxfordEntryFormatter.h"

#import <AppKit/AppKit.h>
#include <libxml/HTMLparser.h>
#include <libxml/tree.h>

#include <set>
#include <sstream>
#include <string>
#include <vector>

@implementation OxfordFormatResult

- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString
                                  metrics:(NSDictionary<NSString *, NSNumber *> *)metrics {
  self = [super init];
  if (self) {
    _attributedString = [attributedString copy];
    _metrics = [metrics copy];
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

NSFont *italicFont(CGFloat size) {
  NSFont *base = [NSFont systemFontOfSize:size];
  return [[NSFontManager sharedFontManager] convertFont:base
                                             toHaveTrait:NSItalicFontMask];
}

NSColor *mutedLabelColor(CGFloat alpha) {
  return [NSColor.labelColor colorWithAlphaComponent:alpha];
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

class Formatter {
 public:
  NSMutableAttributedString *output = [[NSMutableAttributedString alloc] init];
  NSMutableDictionary<NSString *, NSNumber *> *metrics = [@{
    @"headwords" : @0,
    @"phonetics" : @0,
    @"partsOfSpeech" : @0,
    @"definitions" : @0,
    @"chinese" : @0,
    @"examples" : @0,
    @"sections" : @0,
    @"derived" : @0,
    @"synonyms" : @0
  } mutableCopy];

  void render(xmlNodePtr root) {
    xmlNodePtr entry = firstWithClass(root, "entry");
    renderNode(entry ?: root);
    while (output.length > 0 &&
           [[output.string substringFromIndex:output.length - 1] isEqualToString:@"\n"]) {
      [output deleteCharactersInRange:NSMakeRange(output.length - 1, 1)];
    }
  }

 private:
  std::set<std::string> emittedSections_;

  void increment(NSString *key) {
    metrics[key] = @(metrics[key].integerValue + 1);
  }

  void appendParagraph(NSString *value, NSFont *font, NSColor *color,
                       NSMutableParagraphStyle *style) {
    NSString *clean = normalize(value);
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

  void appendSection(NSString *title, const std::string &key) {
    if (setContains(emittedSections_, key)) return;
    emittedSections_.insert(key);
    appendParagraph(title, [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
                    NSColor.labelColor, paragraph(9, 4, 0));
    increment(@"sections");
  }

  void renderChildren(xmlNodePtr node) {
    for (xmlNodePtr child = node ? node->children : nullptr; child; child = child->next) {
      renderNode(child);
    }
  }

  void renderDefinition(xmlNodePtr node, NSString *number = nil) {
    NSString *english = text(node, {"oalecd8e_chn"});
    if (number.length > 0) {
      english = english.length > 0 ? [NSString stringWithFormat:@"%@  %@", number, english]
                                   : number;
    }
    appendParagraph(english, [NSFont systemFontOfSize:14], NSColor.labelColor,
                    paragraph(3, 3, 0, 3));
    if (english.length > 0) increment(@"definitions");

    std::vector<xmlNodePtr> translations;
    nodesWithClass(node->children, "oalecd8e_chn", translations);
    for (xmlNodePtr translation : translations) {
      NSString *value = text(translation);
      if (value.length == 0) continue;
      appendParagraph(value, [NSFont systemFontOfSize:14], mutedLabelColor(0.78),
                      paragraph(0, 7, 18, 2));
      increment(@"chinese");
    }
  }

  void renderExample(xmlNodePtr node) {
    xmlNodePtr englishNode = firstWithClass(node->children, "x");
    NSString *english = englishNode ? text(englishNode, {"oalecd8e_chn"}) : @"";
    if (english.length > 0) {
      appendParagraph(english, italicFont(13), mutedLabelColor(0.72),
                      paragraph(1, 2, 18, 2));
      increment(@"examples");
    }
    std::vector<xmlNodePtr> translations;
    nodesWithClass(node->children, "oalecd8e_chn", translations);
    for (xmlNodePtr translation : translations) {
      NSString *value = text(translation);
      if (value.length == 0) continue;
      appendParagraph(value, [NSFont systemFontOfSize:13], mutedLabelColor(0.68),
                      paragraph(0, 5, 28, 2));
      increment(@"chinese");
    }
  }

  void renderCrossReference(xmlNodePtr node) {
    NSString *title = @"参见";
    std::string key = "reference";
    if (firstWithClass(node->children, "symbols-synsym")) {
      title = @"同义词";
      key = "synonym";
      increment(@"synonyms");
    } else if (firstWithClass(node->children, "symbols-oppsym")) {
      title = @"反义词";
      key = "opposite";
    }
    appendSection(title, key);
    NSString *value = text(node, {"symbols-synsym", "symbols-oppsym", "symbols-xrsym"});
    appendParagraph(value, [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
                    NSColor.linkColor, paragraph(0, 5, 18));
  }

  void renderDerivative(xmlNodePtr node) {
    appendSection(@"派生词", "derived");
    xmlNodePtr derivative = firstWithClass(node->children, "dr");
    if (derivative) {
      appendParagraph(text(derivative),
                      [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold],
                      NSColor.labelColor, paragraph(2, 3, 0));
      increment(@"derived");
    }
    xmlNodePtr top = firstWithClass(node->children, "top-g");
    if (top) {
      for (xmlNodePtr child = top->children; child; child = child->next) {
        if (hasClass(child, "dr")) continue;
        renderNode(child);
      }
    }
    for (xmlNodePtr child = node->children; child; child = child->next) {
      if (child == top) continue;
      renderNode(child);
    }
  }

  void renderNumberedSense(xmlNodePtr node) {
    xmlNodePtr numberNode = firstWithClass(node->children, "z_n");
    NSString *number = numberNode ? text(numberNode) : nil;
    bool usedNumber = false;
    for (xmlNodePtr child = node->children; child; child = child->next) {
      if (hasClass(child, "z_n")) continue;
      if (hasClass(child, "def-g")) {
        renderDefinition(child, usedNumber ? nil : number);
        usedNumber = true;
      } else {
        renderNode(child);
      }
    }
  }

  void renderNode(xmlNodePtr node) {
    if (!node || node->type != XML_ELEMENT_NODE || isInvisible(node)) return;
    const auto nodeClasses = classes(node);
    const std::string name = nodeName(node);

    if (setContains(nodeClasses, "h")) {
      appendParagraph(text(node), [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold],
                      NSColor.labelColor, paragraph(0, 5, 0, 2));
      increment(@"headwords");
      return;
    }
    if (setContains(nodeClasses, "infl")) {
      appendParagraph(text(node), [NSFont systemFontOfSize:13], mutedLabelColor(0.55),
                      paragraph(0, 3, 0));
      return;
    }
    if (setContains(nodeClasses, "ei-g")) {
      appendParagraph(text(node), [NSFont systemFontOfSize:14], mutedLabelColor(0.72),
                      paragraph(0, 6, 0));
      increment(@"phonetics");
      return;
    }
    if (setContains(nodeClasses, "pos-g")) {
      appendParagraph(text(node),
                      [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
                      NSColor.labelColor, paragraph(3, 5, 0));
      increment(@"partsOfSpeech");
      return;
    }
    if (setContains(nodeClasses, "n-g")) {
      renderNumberedSense(node);
      return;
    }
    if (setContains(nodeClasses, "def-g")) {
      renderDefinition(node);
      return;
    }
    if (setContains(nodeClasses, "x-g")) {
      renderExample(node);
      return;
    }
    if (setContains(nodeClasses, "xr-g")) {
      renderCrossReference(node);
      return;
    }
    if (setContains(nodeClasses, "dr-g")) {
      renderDerivative(node);
      return;
    }
    if (setContains(nodeClasses, "derived")) {
      appendSection(@"派生词", "derived");
      appendParagraph(text(node, {"de_c", "de_e"}), [NSFont systemFontOfSize:13],
                      mutedLabelColor(0.72), paragraph(0, 5, 18));
      increment(@"derived");
      return;
    }
    if (setContains(nodeClasses, "id-g") || setContains(nodeClasses, "ids-g")) {
      appendSection(@"习语与搭配", "idioms");
      renderChildren(node);
      return;
    }
    if (setContains(nodeClasses, "pv-g") || setContains(nodeClasses, "pvs-g")) {
      appendSection(@"短语与搭配", "phrases");
      renderChildren(node);
      return;
    }
    if (setContains(nodeClasses, "title") || setContains(nodeClasses, "subhead") ||
        setContains(nodeClasses, "collsubhead") ||
        setContains(nodeClasses, "langbanksubhead")) {
      appendParagraph(text(node), [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
                      NSColor.labelColor, paragraph(8, 4, 0));
      increment(@"sections");
      return;
    }
    if (setContains(nodeClasses, "para") || setContains(nodeClasses, "cf")) {
      appendParagraph(text(node), [NSFont systemFontOfSize:13], mutedLabelColor(0.72),
                      paragraph(1, 4, 18));
      return;
    }

    if (name == "h1" || name == "h2" || name == "h3" || name == "h4" ||
        name == "h5" || name == "h6") {
      appendParagraph(text(node), [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
                      NSColor.labelColor, paragraph(8, 4, 0));
      increment(@"sections");
      return;
    }
    if (name == "li") {
      NSString *value = text(node);
      appendParagraph([NSString stringWithFormat:@"• %@", value],
                      [NSFont systemFontOfSize:13], NSColor.labelColor,
                      paragraph(1, 3, 18));
      return;
    }
    if (name == "ul" || name == "ol") {
      renderChildren(node);
      return;
    }
    if (name == "p") {
      appendParagraph(text(node), [NSFont systemFontOfSize:14], NSColor.labelColor,
                      paragraph(2, 5, 0));
      return;
    }
    if (name == "div" || name == "section" || name == "article") {
      if (hasSemanticDescendant(node->children)) {
        renderChildren(node);
      } else {
        appendParagraph(text(node), [NSFont systemFontOfSize:14], NSColor.labelColor,
                        paragraph(2, 5, 0));
      }
      return;
    }
    renderChildren(node);
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
    return [[OxfordFormatResult alloc] initWithAttributedString:
              [[NSAttributedString alloc] initWithString:@"词条格式解析失败"]
                                                    metrics:@{ @"parseFailed" : @YES }];
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
                                                       metrics:formatter.metrics];
}

@end
