#import <Foundation/Foundation.h>

#import "OxfordEntryFormatter.h"
#include "SQLiteDictionaryCore.h"

#include <iostream>
#include <string>
#include <vector>

namespace {
NSString *string(const std::string &value) {
  return [[NSString alloc] initWithBytes:value.data()
                                  length:value.size()
                                encoding:NSUTF8StringEncoding] ?: @"";
}

bool containsChinese(NSArray<NSString *> *values) {
  NSCharacterSet *han = [NSCharacterSet characterSetWithRange:NSMakeRange(0x4E00, 0x9FFF - 0x4E00)];
  for (NSString *value in values) {
    if ([value rangeOfCharacterFromSet:han].location != NSNotFound) return true;
  }
  return false;
}

int fail(const char *message) {
  std::cerr << "OxfordStructuredEntrySmoke: " << message << "\n";
  return 1;
}
}  // namespace

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 3) return fail("expected config and output paths");
    NSData *configData = [NSData dataWithContentsOfFile:string(argv[1])];
    if (!configData) return fail("cannot read local config");
    NSDictionary *config = [NSJSONSerialization JSONObjectWithData:configData options:0 error:nil];
    NSString *dictionaryPath = config[@"primaryDictionary"];
    NSString *indexPath = config[@"indexPath"];
    if (dictionaryPath.length == 0 || indexPath.length == 0) return fail("invalid local config");

    const std::vector<std::string> words = {"supercilious", "conscientious", "incredulous"};
    NSMutableArray<NSDictionary *> *serialized = [NSMutableArray array];
    OxfordEntryFormatter *formatter = [[OxfordEntryFormatter alloc] init];
    NSUInteger totalExamples = 0;

    try {
      localdict::SQLiteDictionaryCore core(dictionaryPath.UTF8String, indexPath.UTF8String);
      core.open(false);
      for (const auto &word : words) {
        const auto result = core.lookup(word);
        if (!result.found || result.html.empty()) return fail("real dictionary lookup missed");
        OxfordFormatResult *formatted = [formatter formatHTML:string(result.html)];
        OxfordStructuredEntry *entry = formatted.structuredEntry;
        if (entry.headword.length == 0 || entry.phonetics.count == 0 ||
            entry.definitions.count == 0) {
          std::cerr << "word=" << word << " headword=" << entry.headword.length
                    << " phonetics=" << entry.phonetics.count
                    << " definitions=" << entry.definitions.count
                    << " examples=" << entry.examples.count << "\n";
          return fail("required structured field is empty");
        }
        if (!containsChinese(entry.definitions)) return fail("Chinese definition missing");
        if (entry.definitions.count > 5 || entry.examples.count > 3) {
          return fail("export limits exceeded");
        }
        totalExamples += entry.examples.count;
        [serialized addObject:@{
          @"headword" : entry.headword,
          @"phonetics" : entry.phonetics,
          @"partsOfSpeech" : entry.partsOfSpeech,
          @"definitions" : entry.definitions,
          @"examples" : entry.examples,
          @"source" : entry.source
        }];
      }
    } catch (const std::exception &error) {
      return fail(error.what());
    }
    if (totalExamples == 0) return fail("all real examples missing");

    NSError *error = nil;
    NSData *output = [NSJSONSerialization dataWithJSONObject:serialized options:0 error:&error];
    if (!output || ![output writeToFile:string(argv[2]) options:NSDataWritingAtomic error:&error]) {
      return fail("cannot write ignored structured fixture");
    }
    std::cout << "OxfordStructuredEntrySmoke: 3/3 real entries passed\n";
    return 0;
  }
}
