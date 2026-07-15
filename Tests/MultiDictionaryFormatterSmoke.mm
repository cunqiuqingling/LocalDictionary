#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import "DictionaryCoreBridge.h"
#import "OxfordEntryFormatter.h"
#import "SupplementalEntryFormatters.h"
#include "SQLiteDictionaryCore.h"
#include <libxml/HTMLparser.h>
#include <libxml/tree.h>

#include <iostream>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace {
NSString *string(const std::string &value) {
  return [[NSString alloc] initWithBytes:value.data()
                                  length:value.size()
                                encoding:NSUTF8StringEncoding] ?: @"";
}

std::string utf8(NSString *value) {
  return value.UTF8String ? std::string(value.UTF8String) : std::string();
}

bool containsHan(NSArray<NSString *> *values) {
  NSCharacterSet *han = [NSCharacterSet characterSetWithRange:
      NSMakeRange(0x3400, 0x9FFF - 0x3400 + 1)];
  for (NSString *value in values) {
    if ([value rangeOfCharacterFromSet:han].location != NSNotFound) return true;
  }
  return false;
}

size_t rawClassCount(xmlNodePtr node, const char *className) {
  size_t count = 0;
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE) continue;
    xmlChar *raw = xmlGetProp(current, BAD_CAST "class");
    if (raw) {
      NSString *classes = [[NSString alloc]
          initWithUTF8String:reinterpret_cast<const char *>(raw)] ?: @"";
      NSArray<NSString *> *items = [classes componentsSeparatedByCharactersInSet:
          NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if ([items containsObject:[NSString stringWithUTF8String:className]]) ++count;
      xmlFree(raw);
    }
    count += rawClassCount(current->children, className);
  }
  return count;
}

std::pair<size_t, size_t> centuryRawCounts(NSString *html) {
  NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding];
  htmlDocPtr document = htmlReadMemory(static_cast<const char *>(data.bytes),
                                       static_cast<int>(data.length), nullptr, "UTF-8",
                                       HTML_PARSE_RECOVER | HTML_PARSE_NOERROR |
                                       HTML_PARSE_NOWARNING | HTML_PARSE_NONET |
                                       HTML_PARSE_COMPACT);
  if (!document) return {0, 0};
  xmlNodePtr root = xmlDocGetRootElement(document);
  const auto result = std::make_pair(rawClassCount(root, "pos"),
                                     rawClassCount(root, "def"));
  xmlFreeDoc(document);
  return result;
}

NSDictionary *serializedSource(NSString *name, NSArray<NSString *> *phonetics,
                               NSArray<NSString *> *parts,
                               NSArray<NSString *> *definitions,
                               NSArray<NSString *> *examples,
                               NSArray<Century21PartOfSpeechSection *> *sections = @[],
                               DictionarySemanticEntry *semanticEntry = nil);

NSDictionary *serializedRelation(DictionarySemanticRelationGroup *relation) {
  return @{ @"kind" : relation.kind, @"title" : relation.title,
            @"values" : relation.values };
}

NSDictionary *serializedDerivative(DictionarySemanticDerivative *derivative) {
  return @{ @"headword" : derivative.headword,
            @"partOfSpeech" : derivative.partOfSpeech,
            @"pronunciations" : derivative.pronunciations,
            @"summary" : derivative.summary,
            @"sourceHeadword" : derivative.sourceHeadword,
            @"sourcePartOfSpeech" : derivative.sourcePartOfSpeech };
}

NSDictionary *serializedSense(DictionarySemanticSense *sense) {
  NSMutableArray *examples = [NSMutableArray array];
  for (DictionarySemanticExample *example in sense.examples) {
    [examples addObject:@{ @"english" : example.english,
                           @"translations" : example.translations }];
  }
  NSMutableArray *relations = [NSMutableArray array];
  for (DictionarySemanticRelationGroup *relation in sense.relations) {
    [relations addObject:serializedRelation(relation)];
  }
  NSMutableArray *subsenses = [NSMutableArray array];
  for (DictionarySemanticSense *subsense in sense.subsenses) {
    [subsenses addObject:serializedSense(subsense)];
  }
  return @{ @"number" : sense.number, @"labels" : sense.labels,
            @"definitionEnglish" : sense.definitionEnglish,
            @"definitionChinese" : sense.definitionChinese,
            @"grammarPatterns" : sense.grammarPatterns,
            @"examples" : examples, @"relations" : relations,
            @"subsenses" : subsenses };
}

NSDictionary *serializedSemanticEntry(DictionarySemanticEntry *entry) {
  NSMutableArray *sections = [NSMutableArray array];
  for (DictionarySemanticPartOfSpeechSection *section in entry.partOfSpeechSections) {
    NSMutableArray *senses = [NSMutableArray array];
    for (DictionarySemanticSense *sense in section.senses) {
      [senses addObject:serializedSense(sense)];
    }
    NSMutableArray *relations = [NSMutableArray array];
    for (DictionarySemanticRelationGroup *relation in section.relations) {
      [relations addObject:serializedRelation(relation)];
    }
    NSMutableArray *derivatives = [NSMutableArray array];
    for (DictionarySemanticDerivative *derivative in section.derivatives) {
      [derivatives addObject:serializedDerivative(derivative)];
    }
    [sections addObject:@{ @"partOfSpeech" : section.partOfSpeech,
                           @"pronunciations" : section.pronunciations,
                           @"grammarLabels" : section.grammarLabels,
                           @"senses" : senses, @"relations" : relations,
                           @"derivatives" : derivatives }];
  }
  NSMutableArray *relations = [NSMutableArray array];
  for (DictionarySemanticRelationGroup *relation in entry.entryLevelRelations) {
    [relations addObject:serializedRelation(relation)];
  }
  NSMutableArray *derivatives = [NSMutableArray array];
  for (DictionarySemanticDerivative *derivative in entry.derivatives) {
    [derivatives addObject:serializedDerivative(derivative)];
  }
  return @{ @"inflections" : entry.inflections,
            @"partOfSpeechSections" : sections,
            @"entryLevelRelations" : relations,
            @"derivatives" : derivatives };
}

NSDictionary *serializedSource(NSString *name, NSArray<NSString *> *phonetics,
                               NSArray<NSString *> *parts,
                               NSArray<NSString *> *definitions,
                               NSArray<NSString *> *examples,
                               NSArray<Century21PartOfSpeechSection *> *sections,
                               DictionarySemanticEntry *semanticEntry) {
  NSMutableDictionary *source = [@{
    @"phonetics" : phonetics,
    @"partsOfSpeech" : parts,
    @"definitions" : definitions,
    @"examples" : examples,
    @"source" : name
  } mutableCopy];
  if (sections.count > 0) {
    NSMutableArray *serializedSections = [NSMutableArray array];
    for (Century21PartOfSpeechSection *section in sections) {
      NSMutableArray *senses = [NSMutableArray array];
      for (Century21Sense *sense in section.senses) {
        [senses addObject:@{
          @"definition" : sense.definition,
          @"labels" : sense.labels,
          @"examples" : sense.examples,
          @"number" : @(sense.number),
          @"indentationLevel" : @(sense.indentationLevel)
        }];
      }
      [serializedSections addObject:@{
        @"partOfSpeech" : section.partOfSpeech,
        @"senses" : senses
      }];
    }
    source[@"partOfSpeechSections"] = serializedSections;
  }
  if (semanticEntry.partOfSpeechSections.count > 0 ||
      semanticEntry.entryLevelRelations.count > 0 ||
      semanticEntry.derivatives.count > 0 || semanticEntry.inflections.count > 0) {
    source[@"semanticEntry"] = serializedSemanticEntry(semanticEntry);
  }
  return source;
}

NSDictionary *serializedEntry(NSString *headword, NSArray<NSDictionary *> *sources) {
  NSDictionary *first = sources.firstObject;
  NSArray *remaining = sources.count > 1
                           ? [sources subarrayWithRange:NSMakeRange(1, sources.count - 1)]
                           : @[];
  NSMutableDictionary *entry = [@{
    @"headword" : headword,
    @"phonetics" : first[@"phonetics"] ?: @[],
    @"partsOfSpeech" : first[@"partsOfSpeech"] ?: @[],
    @"definitions" : first[@"definitions"] ?: @[],
    @"examples" : first[@"examples"] ?: @[],
    @"source" : first[@"source"] ?: @"",
    @"additionalSources" : remaining
  } mutableCopy];
  if (first[@"partOfSpeechSections"]) {
    entry[@"partOfSpeechSections"] = first[@"partOfSpeechSections"];
  }
  if (first[@"semanticEntry"]) {
    entry[@"semanticEntry"] = first[@"semanticEntry"];
  }
  return entry;
}

int fail(const std::string &message) {
  std::cerr << "MultiDictionaryFormatterSmoke: " << message << "\n";
  return 1;
}

size_t semanticSenseCount(NSArray<DictionarySemanticSense *> *senses) {
  size_t count = 0;
  for (DictionarySemanticSense *sense in senses) {
    ++count;
    count += semanticSenseCount(sense.subsenses);
  }
  return count;
}

bool validateSemanticSenses(NSArray<DictionarySemanticSense *> *senses) {
  for (DictionarySemanticSense *sense in senses) {
    if (sense.definitionEnglish.length == 0 && sense.definitionChinese.count == 0 &&
        sense.examples.count == 0 && sense.relations.count == 0 &&
        sense.subsenses.count == 0) {
      return false;
    }
    for (DictionarySemanticExample *example in sense.examples) {
      if (example.english.length == 0 && example.translations.count == 0) return false;
    }
    for (DictionarySemanticRelationGroup *relation in sense.relations) {
      if (relation.title.length == 0 || relation.values.count == 0) return false;
    }
    if (!validateSemanticSenses(sense.subsenses)) return false;
  }
  return true;
}

bool validateRelationTitles(NSArray<DictionarySemanticRelationGroup *> *relations) {
  for (DictionarySemanticRelationGroup *relation in relations) {
    if (relation.title.length == 0 || [relation.title isEqualToString:@"参见"] ||
        relation.values.count == 0) return false;
  }
  return true;
}

bool validateSenseRelations(NSArray<DictionarySemanticSense *> *senses) {
  for (DictionarySemanticSense *sense in senses) {
    if (!validateRelationTitles(sense.relations) ||
        !validateSenseRelations(sense.subsenses)) return false;
  }
  return true;
}

bool hasLinkColor(NSAttributedString *value) {
  __block bool found = false;
  [value enumerateAttribute:NSForegroundColorAttributeName
                    inRange:NSMakeRange(0, value.length)
                    options:0
                 usingBlock:^(id color, NSRange, BOOL *stop) {
    if ([color isEqual:NSColor.linkColor]) {
      found = true;
      *stop = YES;
    }
  }];
  return found;
}

bool hasContinuousNumbers(DictionarySemanticPartOfSpeechSection *section) {
  NSInteger expected = 1;
  for (DictionarySemanticSense *sense in section.senses) {
    if (sense.number.length == 0) continue;
    if (sense.number.integerValue != expected) return false;
    ++expected;
  }
  return true;
}

bool validateRenderedRelationOrder(NSString *rendered,
                                   NSArray<DictionarySemanticSense *> *senses,
                                   size_t &checked) {
  for (DictionarySemanticSense *sense in senses) {
    if (sense.examples.count > 0 && sense.relations.count > 0 &&
        sense.definitionEnglish.length > 0 &&
        ![sense.definitionEnglish containsString:@"\n"]) {
      NSRange definitionRange = [rendered rangeOfString:sense.definitionEnglish];
      if (definitionRange.location != NSNotFound) {
        NSUInteger cursor = NSMaxRange(definitionRange);
        bool eligible = true;
        for (DictionarySemanticExample *example in sense.examples) {
          if (example.english.length == 0) continue;
          NSRange exampleRange = [rendered rangeOfString:example.english
                                                 options:0
                                                   range:NSMakeRange(
                                                       cursor,
                                                       rendered.length - cursor)];
          if (exampleRange.location == NSNotFound) {
            eligible = false;
            break;
          }
          cursor = NSMaxRange(exampleRange);
        }
        if (eligible) {
          for (DictionarySemanticRelationGroup *relation in sense.relations) {
            for (NSString *value in relation.values) {
              if ([rendered componentsSeparatedByString:value].count != 2) continue;
              NSRange relationRange = [rendered rangeOfString:value];
              if (relationRange.location == NSNotFound || relationRange.location < cursor) {
                return false;
              }
              ++checked;
            }
          }
        }
      }
    }
    if (!validateRenderedRelationOrder(rendered, sense.subsenses, checked)) return false;
  }
  return true;
}
}  // namespace

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 3) return fail("expected local config and output JSON paths");
    NSData *configData = [NSData dataWithContentsOfFile:string(argv[1])];
    NSDictionary *config = configData
        ? [NSJSONSerialization JSONObjectWithData:configData options:0 error:nil]
        : nil;
    if (!config) return fail("cannot read local config");

    struct Source {
      NSString *name;
      NSString *dictionaryKey;
      NSString *indexKey;
      std::unique_ptr<localdict::SQLiteDictionaryCore> core;
    };
    std::vector<Source> sources;
    const std::pair<NSString *, std::pair<NSString *, NSString *>> sourceInfo[] = {
        {@"牛津高阶 8", {@"primaryDictionary", @"indexPath"}},
        {@"21世纪大英汉词典", {@"century21Dictionary", @"century21IndexPath"}},
        {@"新牛津英文", {@"newOxfordDictionary", @"newOxfordIndexPath"}},
        {@"英中医学辞海", {@"medicalDictionary", @"medicalIndexPath"}},
        {@"词根词缀", {@"affixRootDictionary", @"affixRootIndexPath"}}};

    try {
      for (const auto &info : sourceInfo) {
        NSString *dictionaryPath = config[info.second.first];
        NSString *indexPath = config[info.second.second];
        if (dictionaryPath.length == 0 || indexPath.length == 0) {
          return fail("missing fixed dictionary configuration");
        }
        auto core = std::make_unique<localdict::SQLiteDictionaryCore>(
            utf8(dictionaryPath), utf8(indexPath), 2 * 1024 * 1024, 32);
        core->open(false);
        sources.push_back({info.first, info.second.first, info.second.second, std::move(core)});
      }
    } catch (const std::exception &error) {
      return fail(error.what());
    }

    OxfordEntryFormatter *oxford = [[OxfordEntryFormatter alloc] init];
    Century21EntryFormatter *century = [[Century21EntryFormatter alloc] init];
    NewOxfordEntryFormatter *newOxford = [[NewOxfordEntryFormatter alloc] init];
    MedicalEntryFormatter *medical = [[MedicalEntryFormatter alloc] init];
    AffixRootEntryFormatter *rootFormatter = [[AffixRootEntryFormatter alloc] init];

    const std::vector<std::string> words = {
        "prompt", "charge", "assemble", "position", "harbour", "algorithm", "semiconductor", "nanotechnology", "machine learning",
        "interoperability", "sustainability", "hypertension", "pharmacokinetics",
        "metformin", "contraindication", "myocardial infarction", "pharmacology",
        "biotechnology", "biodegradable", "antihypertensive", "transcription"};
    NSMutableArray<NSDictionary *> *exportEntries = [NSMutableArray array];
    std::map<std::string, size_t> hitCounts;

    for (const auto &word : words) {
      NSMutableArray<NSDictionary *> *structuredSources = [NSMutableArray array];
      NSString *headword = string(word);
      for (size_t sourceIndex = 0; sourceIndex < sources.size(); ++sourceIndex) {
        const auto lookup = sources[sourceIndex].core->lookup(word);
        if (!lookup.found) {
          std::cout << "word=" << word << "|source="
                    << utf8(sources[sourceIndex].name) << "|found=0|ms="
                    << lookup.milliseconds << "\n";
          continue;
        }
        ++hitCounts[utf8(sources[sourceIndex].name)];
        NSString *html = string(lookup.html);
        NSString *matched = string(lookup.matched_headword);
        NSAttributedString *attributed = nil;
        NSArray<NSString *> *phonetics = @[];
        NSArray<NSString *> *parts = @[];
        NSArray<NSString *> *definitions = @[];
        NSArray<NSString *> *examples = @[];
        NSArray<Century21PartOfSpeechSection *> *partOfSpeechSections = @[];
        DictionarySemanticEntry *semanticEntry = nil;
        NSNumber *residual = @NO;
        NSString *parsedHeadword = @"";

        if (sourceIndex == 0) {
          OxfordFormatResult *formatted = [oxford formatHTML:html];
          attributed = formatted.attributedString;
          phonetics = formatted.structuredEntry.phonetics;
          parts = formatted.structuredEntry.partsOfSpeech;
          definitions = formatted.structuredEntry.definitions;
          examples = formatted.structuredEntry.examples;
          parsedHeadword = formatted.structuredEntry.headword;
          residual = formatted.metrics[@"residualMarkup"] ?: @NO;
          semanticEntry = formatted.structuredEntry.semanticEntry;
        } else {
          SupplementalFormatResult *formatted = nil;
          if (sourceIndex == 1) formatted = [century formatHTML:html matchedHeadword:matched];
          if (sourceIndex == 2) formatted = [newOxford formatHTML:html matchedHeadword:matched];
          if (sourceIndex == 3) formatted = [medical formatHTML:html matchedHeadword:matched];
          if (sourceIndex == 4) formatted = [rootFormatter formatHTML:html matchedHeadword:matched];
          attributed = formatted.attributedString;
          phonetics = formatted.structuredEntry.phonetics;
          parts = formatted.structuredEntry.partsOfSpeech;
          definitions = formatted.structuredEntry.definitions;
          examples = formatted.structuredEntry.examples;
          parsedHeadword = formatted.structuredEntry.headword;
          residual = formatted.metrics[@"residualMarkup"] ?: @NO;
          partOfSpeechSections = formatted.structuredEntry.partOfSpeechSections;
          if (sourceIndex == 2) semanticEntry = formatted.structuredEntry.semanticEntry;
        }
        if (attributed.length == 0 || residual.boolValue ||
            (sourceIndex != 0 && definitions.count == 0)) {
          return fail("empty, residual, or unstructured supplemental result for " + word +
                      " in " + utf8(sources[sourceIndex].name));
        }
        if ((sourceIndex == 1 || sourceIndex == 3 || sourceIndex == 4) &&
            !containsHan(definitions)) {
          return fail("Chinese structured content missing for " + word);
        }
        if (word == "assemble" && sourceIndex == 0) {
          NSString *part = parts.firstObject ?: @"";
          NSString *lowerPart = part.lowercaseString;
          if (![lowerPart containsString:@"verb"] && ![lowerPart hasPrefix:@"v"]) {
            return fail("assemble Oxford part of speech is not verb");
          }
          if (!containsHan(definitions)) {
            return fail("assemble Oxford inline Chinese definitions missing");
          }
          std::cout << "assembleInline=Oxford|pos=" << utf8(part)
                    << "|chineseDefinitions=present\n";
        }
        if (word == "position" && sourceIndex == 0 &&
            [attributed.string rangeOfString:@"harbour"
                                     options:NSCaseInsensitiveSearch].location == NSNotFound) {
          return fail("position Oxford example does not contain harbour anchor fixture");
        }
        if (word == "harbour" && sourceIndex == 0) {
          NSString *part = parts.firstObject ?: @"";
          if (![part.lowercaseString containsString:@"noun"] &&
              ![part.lowercaseString hasPrefix:@"n"]) {
            return fail("harbour Oxford part of speech is not noun");
          }
          if (!containsHan(definitions)) {
            return fail("harbour Oxford inline Chinese definitions missing");
          }
          std::cout << "harbourInline=Oxford|pos=noun|chineseDefinitions=present\n";
        }
        if (headword.length == 0 && parsedHeadword.length > 0) headword = parsedHeadword;
        [structuredSources addObject:serializedSource(sources[sourceIndex].name,
                                                      phonetics, parts,
                                                      definitions, examples,
                                                      partOfSpeechSections,
                                                      semanticEntry)];
        std::cout << "word=" << word << "|source="
                  << utf8(sources[sourceIndex].name) << "|found=1|chars="
                  << attributed.length << "|defs=" << definitions.count
                  << "|examples=" << examples.count << "|ms="
                  << lookup.milliseconds << "\n";
      }
      if (structuredSources.count == 0) return fail("all dictionaries missed " + word);
      if (word == "prompt" || word == "charge" || word == "hypertension" ||
          word == "pharmacology") {
        [exportEntries addObject:serializedEntry(headword, structuredSources)];
      }
    }

    const std::vector<std::string> groupingWords = {
        "prompt", "charge", "present", "record", "conduct", "issue"};
    double groupingFormatTotal = 0;
    for (const auto &word : groupingWords) {
      const auto lookup = sources[1].core->lookup(word);
      if (!lookup.found) return fail("Century21 grouping word missing: " + word);
      NSString *html = string(lookup.html);
      SupplementalFormatResult *formatted = [century formatHTML:html
                                                   matchedHeadword:string(lookup.matched_headword)];
      const auto rawCounts = centuryRawCounts(html);
      NSArray<Century21PartOfSpeechSection *> *sections =
          formatted.structuredEntry.partOfSpeechSections;
      size_t senseCount = 0;
      size_t metadataCount = 0;
      NSUInteger cursor = 0;
      NSString *rendered = formatted.attributedString.string;
      for (Century21PartOfSpeechSection *section in sections) {
        if (section.partOfSpeech.length > 0) {
          NSRange range = [rendered rangeOfString:section.partOfSpeech
                                         options:0
                                           range:NSMakeRange(cursor,
                                               rendered.length - cursor)];
          if (range.location == NSNotFound) {
            return fail("Century21 part-of-speech order failed: " + word);
          }
          cursor = NSMaxRange(range);
        }
        for (Century21Sense *sense in section.senses) {
          ++senseCount;
          metadataCount += sense.labels.count + sense.examples.count;
          NSString *prefix = sense.number > 0
              ? [NSString stringWithFormat:@"%lu. ", (unsigned long)sense.number]
              : @"• ";
          NSString *needle = [prefix stringByAppendingString:sense.definition];
          NSRange range = [rendered rangeOfString:needle
                                         options:0
                                           range:NSMakeRange(cursor,
                                               rendered.length - cursor)];
          if (range.location == NSNotFound) {
            return fail("Century21 sense order or numbering failed: " + word);
          }
          cursor = NSMaxRange(range);
        }
      }
      if (sections.count != rawCounts.first || senseCount != rawCounts.second ||
          metadataCount == 0 ||
          [formatted.metrics[@"residualMarkup"] boolValue] ||
          [rendered containsString:@"\n\n\n"]) {
        return fail("Century21 grouping count, metadata, or markup failed: " + word);
      }
      groupingFormatTotal += [formatted.metrics[@"formatMilliseconds"] doubleValue];
      std::cout << "century21Grouping=" << word
                << "|htmlChars=" << html.length
                << "|sections=" << sections.count
                << "|senses=" << senseCount
                << "|metadata=" << metadataCount
                << "|renderedChars=" << rendered.length
                << "|formatMs="
                << [formatted.metrics[@"formatMilliseconds"] doubleValue] << "\n";
    }
    std::cout << "Century21GroupingSmoke: 6/6 passed; averageFormatMs="
              << groupingFormatTotal / groupingWords.size() << "\n";

    const std::vector<std::string> hierarchyWords = {
        "prompt", "charge", "present", "record", "conduct",
        "issue", "run", "set", "take", "light"};
    double oxfordFormatTotal = 0;
    double newOxfordFormatTotal = 0;
    size_t oxfordRelationGroups = 0;
    size_t newOxfordRelationGroups = 0;
    size_t oxfordDerivatives = 0;
    size_t newOxfordDerivatives = 0;
    size_t orderedOxfordRelations = 0;
    size_t orderedNewOxfordRelations = 0;
    for (const auto &word : hierarchyWords) {
      const auto oxfordLookup = sources[0].core->lookup(word);
      const auto newOxfordLookup = sources[2].core->lookup(word);
      if (!oxfordLookup.found || !newOxfordLookup.found) {
        return fail("hierarchy test word missing: " + word);
      }
      OxfordFormatResult *oxfordFormatted =
          [oxford formatHTML:string(oxfordLookup.html)];
      SupplementalFormatResult *newOxfordFormatted =
          [newOxford formatHTML:string(newOxfordLookup.html)
                 matchedHeadword:string(newOxfordLookup.matched_headword)];
      const std::pair<NSString *, DictionarySemanticEntry *> formattedEntries[] = {
          {oxfordFormatted.attributedString.string,
           oxfordFormatted.structuredEntry.semanticEntry},
          {newOxfordFormatted.attributedString.string,
           newOxfordFormatted.structuredEntry.semanticEntry}};
      size_t hierarchySourceIndex = 0;
      for (const auto &formatted : formattedEntries) {
        if (formatted.first.length == 0 ||
            [formatted.first rangeOfString:@"class=" options:NSCaseInsensitiveSearch].location !=
                NSNotFound || formatted.second.partOfSpeechSections.count == 0) {
          return fail("invalid hierarchy rendering: " + word);
        }
        for (DictionarySemanticPartOfSpeechSection *section in
                 formatted.second.partOfSpeechSections) {
          if (section.partOfSpeech.length == 0 ||
              (section.senses.count == 0 && section.relations.count == 0 &&
               section.derivatives.count == 0) ||
              !validateSemanticSenses(section.senses)) {
            return fail("invalid part-of-speech ownership: " + word +
                        " source=" + std::to_string(hierarchySourceIndex) +
                        " senses=" + std::to_string(section.senses.count));
          }
          if (!validateRelationTitles(section.relations) ||
              !validateSenseRelations(section.senses)) {
            return fail("unclassified relation title: " + word +
                        " source=" + std::to_string(hierarchySourceIndex));
          }
        }
        ++hierarchySourceIndex;
      }
      if (hasLinkColor(oxfordFormatted.attributedString) ||
          hasLinkColor(newOxfordFormatted.attributedString)) {
        return fail("cross-reference retained link color: " + word);
      }
      for (DictionarySemanticPartOfSpeechSection *section in
               oxfordFormatted.structuredEntry.semanticEntry.partOfSpeechSections) {
        if (!validateRenderedRelationOrder(oxfordFormatted.attributedString.string,
                                           section.senses,
                                           orderedOxfordRelations)) {
          return fail("Oxford relation rendered before examples: " + word);
        }
      }
      for (DictionarySemanticPartOfSpeechSection *section in
               newOxfordFormatted.structuredEntry.semanticEntry.partOfSpeechSections) {
        if (!validateRenderedRelationOrder(newOxfordFormatted.attributedString.string,
                                           section.senses,
                                           orderedNewOxfordRelations)) {
          return fail("New Oxford relation rendered before examples: " + word);
        }
      }
      if (word == "charge") {
        DictionarySemanticEntry *oxfordEntry =
            oxfordFormatted.structuredEntry.semanticEntry;
        DictionarySemanticEntry *newOxfordEntry =
            newOxfordFormatted.structuredEntry.semanticEntry;
        if (oxfordEntry.partOfSpeechSections.count != 2 ||
            oxfordEntry.partOfSpeechSections[0].senses.count != 11 ||
            oxfordEntry.partOfSpeechSections[1].senses.count != 11 ||
            newOxfordEntry.partOfSpeechSections.count != 2 ||
            newOxfordEntry.partOfSpeechSections[0].senses.count != 6 ||
            newOxfordEntry.partOfSpeechSections[1].senses.count != 7) {
          return fail("charge sense count changed");
        }
        for (DictionarySemanticPartOfSpeechSection *section in
                 oxfordEntry.partOfSpeechSections) {
          if (!hasContinuousNumbers(section)) {
            return fail("Oxford charge numbering is discontinuous");
          }
          for (DictionarySemanticSense *sense in section.senses) {
            if (sense.definitionEnglish.length == 0 &&
                sense.definitionChinese.count == 0) {
              return fail("Oxford charge retained a definitionless sense");
            }
          }
        }
        for (DictionarySemanticPartOfSpeechSection *section in
                 newOxfordEntry.partOfSpeechSections) {
          if (!hasContinuousNumbers(section)) {
            return fail("New Oxford charge numbering is discontinuous");
          }
        }
        DictionarySemanticSense *second =
            oxfordEntry.partOfSpeechSections[0].senses[1];
        if (second.number.integerValue != 2 || second.definitionEnglish.length == 0) {
          return fail("Oxford charge sense 2 core definition was not restored");
        }
        std::cout << "chargeContinuity=Oxford:22(11+11),coreDefinitions:22;"
                     "NewOxford:13(6+7)\n";
      }
      if (word == "prompt") {
        DictionarySemanticEntry *entry = oxfordFormatted.structuredEntry.semanticEntry;
        bool foundPromptness = false;
        for (DictionarySemanticPartOfSpeechSection *section in
                 entry.partOfSpeechSections) {
          for (DictionarySemanticDerivative *derivative in section.derivatives) {
            NSString *derivedWord = [[derivative.headword.lowercaseString
                stringByReplacingOccurrencesOfString:@"·" withString:@""]
                stringByReplacingOccurrencesOfString:@"•" withString:@""];
            if ([derivedWord containsString:@"promptness"]) {
              foundPromptness = true;
              if (![derivative.sourceHeadword.lowercaseString containsString:@"prompt"] ||
                  ![derivative.sourcePartOfSpeech isEqualToString:section.partOfSpeech] ||
                  [section.partOfSpeech.lowercaseString containsString:@"noun"]) {
                return fail("promptness derivative ownership failed");
              }
            }
          }
        }
        NSString *rendered = oxfordFormatted.attributedString.string;
        if (!foundPromptness ||
            [rendered rangeOfString:@"派生名词"].location == NSNotFound ||
            [rendered rangeOfString:@"由形容词"].location == NSNotFound ||
            [rendered rangeOfString:@"prompt" options:NSCaseInsensitiveSearch].location ==
                NSNotFound) {
          return fail("promptness derivative relation label missing");
        }
      }
      for (DictionarySemanticPartOfSpeechSection *section in
               oxfordFormatted.structuredEntry.semanticEntry.partOfSpeechSections) {
        oxfordRelationGroups += section.relations.count;
        oxfordDerivatives += section.derivatives.count;
        for (DictionarySemanticSense *sense in section.senses) {
          oxfordRelationGroups += sense.relations.count;
        }
      }
      oxfordRelationGroups +=
          oxfordFormatted.structuredEntry.semanticEntry.entryLevelRelations.count;
      oxfordDerivatives += oxfordFormatted.structuredEntry.semanticEntry.derivatives.count;
      for (DictionarySemanticPartOfSpeechSection *section in
               newOxfordFormatted.structuredEntry.semanticEntry.partOfSpeechSections) {
        newOxfordRelationGroups += section.relations.count;
        newOxfordDerivatives += section.derivatives.count;
        for (DictionarySemanticSense *sense in section.senses) {
          newOxfordRelationGroups += sense.relations.count;
        }
      }
      newOxfordRelationGroups +=
          newOxfordFormatted.structuredEntry.semanticEntry.entryLevelRelations.count;
      newOxfordDerivatives +=
          newOxfordFormatted.structuredEntry.semanticEntry.derivatives.count;
      oxfordFormatTotal += [oxfordFormatted.metrics[@"formatMilliseconds"] doubleValue];
      newOxfordFormatTotal +=
          [newOxfordFormatted.metrics[@"formatMilliseconds"] doubleValue];
      std::cout << "hierarchy=" << word
                << "|oxfordSections="
                << oxfordFormatted.structuredEntry.semanticEntry.partOfSpeechSections.count
                << "|oxfordSenses=";
      size_t oxfordSenses = 0;
      for (DictionarySemanticPartOfSpeechSection *section in
               oxfordFormatted.structuredEntry.semanticEntry.partOfSpeechSections) {
        oxfordSenses += semanticSenseCount(section.senses);
      }
      size_t newOxfordSenses = 0;
      for (DictionarySemanticPartOfSpeechSection *section in
               newOxfordFormatted.structuredEntry.semanticEntry.partOfSpeechSections) {
        newOxfordSenses += semanticSenseCount(section.senses);
      }
      std::cout << oxfordSenses << "|newOxfordSections="
                << newOxfordFormatted.structuredEntry.semanticEntry.partOfSpeechSections.count
                << "|newOxfordSenses=" << newOxfordSenses << "\n";
    }
    if (oxfordRelationGroups == 0 || newOxfordRelationGroups == 0 ||
        oxfordDerivatives == 0 || newOxfordDerivatives == 0 ||
        orderedOxfordRelations == 0) {
      return fail("complex hierarchy fixtures did not exercise relations and derivatives");
    }
    std::cout << "OxfordNewOxfordHierarchySmoke: 10/10 passed; oxfordAverageFormatMs="
              << oxfordFormatTotal / hierarchyWords.size()
              << "; newOxfordAverageFormatMs="
              << newOxfordFormatTotal / hierarchyWords.size()
              << "; orderedOxfordSenseRelations=" << orderedOxfordRelations
              << "; orderedNewOxfordSenseRelations=" << orderedNewOxfordRelations
              << "\n";

    const std::vector<std::string> derivativeWords = {"immediate", "happy", "dark"};
    for (const auto &word : derivativeWords) {
      const auto oxfordLookup = sources[0].core->lookup(word);
      const auto newOxfordLookup = sources[2].core->lookup(word);
      if (!oxfordLookup.found || !newOxfordLookup.found) {
        return fail("derivative ownership test word missing: " + word);
      }
      OxfordFormatResult *oxfordFormatted =
          [oxford formatHTML:string(oxfordLookup.html)];
      SupplementalFormatResult *newOxfordFormatted =
          [newOxford formatHTML:string(newOxfordLookup.html)
                 matchedHeadword:string(newOxfordLookup.matched_headword)];
      size_t posOwned = 0;
      for (DictionarySemanticPartOfSpeechSection *section in
               oxfordFormatted.structuredEntry.semanticEntry.partOfSpeechSections) {
        posOwned += section.derivatives.count;
        for (DictionarySemanticDerivative *derivative in section.derivatives) {
          if (derivative.sourcePartOfSpeech.length == 0 ||
              ![derivative.sourcePartOfSpeech isEqualToString:section.partOfSpeech]) {
            return fail("Oxford POS derivative ownership failed: " + word);
          }
        }
      }
      for (DictionarySemanticDerivative *derivative in
               oxfordFormatted.structuredEntry.semanticEntry.derivatives) {
        if (derivative.sourcePartOfSpeech.length > 0) {
          return fail("Oxford entry derivative has false POS ownership: " + word);
        }
      }
      for (DictionarySemanticDerivative *derivative in
               newOxfordFormatted.structuredEntry.semanticEntry.derivatives) {
        if (derivative.sourcePartOfSpeech.length > 0) {
          return fail("New Oxford entry derivative has false POS ownership: " + word);
        }
      }
      std::cout << "derivativeOwnership=" << word
                << "|oxfordPOS=" << posOwned
                << "|oxfordEntry="
                << oxfordFormatted.structuredEntry.semanticEntry.derivatives.count
                << "|newOxfordEntry="
                << newOxfordFormatted.structuredEntry.semanticEntry.derivatives.count
                << "\n";
    }

    if (hitCounts["21世纪大英汉词典"] == 0 || hitCounts["新牛津英文"] == 0 ||
        hitCounts["英中医学辞海"] == 0 || hitCounts["词根词缀"] == 0) {
      return fail("one enabled supplemental dictionary never hit");
    }
    DictionaryCoreBridge *missing = [[DictionaryCoreBridge alloc]
        initWithDictionaryPath:@"/private/tmp/localdictionary-missing.mdx"
                     indexPath:@"/private/tmp/localdictionary-missing.sqlite"
            cacheMaximumBytes:2 * 1024 * 1024
          cacheMaximumEntries:32];
    NSDictionary *missingResult = [missing lookup:@"algorithm"];
    if (missing.isReady || [missingResult[@"error"] length] == 0) {
      return fail("missing dictionary was not isolated");
    }
    NSError *error = nil;
    NSData *output = [NSJSONSerialization dataWithJSONObject:exportEntries options:0 error:&error];
    if (!output || ![output writeToFile:string(argv[2]) options:NSDataWritingAtomic error:&error]) {
      return fail("cannot write ignored multi-source fixture");
    }
    std::cout << "MultiDictionaryFormatterSmoke: 21 queries passed; export fixtures="
              << exportEntries.count << "\n";
    return 0;
  }
}
