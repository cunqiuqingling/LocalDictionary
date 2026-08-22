#import <AppKit/AppKit.h>

#import "DictionaryAppearanceTextAdapter.h"
#import "GenericMDictEntryFormatter.h"
#import "OxfordEntryFormatter.h"
#import "SupplementalEntryFormatters.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
  }
}

static NSColor *colorAt(NSAttributedString *value, NSUInteger location) {
  return [value attribute:NSForegroundColorAttributeName
                  atIndex:location
           effectiveRange:nil];
}

static BOOL allForegroundColorsAreDynamic(NSAttributedString *value) {
  __block BOOL result = YES;
  [value enumerateAttribute:NSForegroundColorAttributeName
                    inRange:NSMakeRange(0, value.length)
                    options:0
                 usingBlock:^(id color, NSRange range, BOOL *stop) {
    if ([color isKindOfClass:NSColor.class] &&
        ((NSColor *)color).type != NSColorTypeCatalog &&
        ((NSColor *)color).alphaComponent > 0) {
      result = NO;
      *stop = YES;
    }
  }];
  return result;
}

int main(void) {
  @autoreleasepool {
    NSAppearance *light = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NSAppearance *dark = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    require(light != nil && dark != nil, @"system appearances are available");

    NSDictionary *blackAttributes = @{
      NSForegroundColorAttributeName: NSColor.blackColor,
      NSFontAttributeName: [NSFont systemFontOfSize:14]
    };
    NSAttributedString *fixedBlack = [[NSAttributedString alloc]
        initWithString:@"definition" attributes:blackAttributes];
    NSAttributedString *lightBlack =
        [DictionaryAppearanceTextAdapter attributedStringByAdapting:fixedBlack
                                                       forAppearance:light];
    NSAttributedString *darkBlack =
        [DictionaryAppearanceTextAdapter attributedStringByAdapting:fixedBlack
                                                       forAppearance:dark];
    require(colorAt(lightBlack, 0).type != NSColorTypeCatalog,
            @"readable fixed black remains intact in light appearance");
    require(colorAt(darkBlack, 0).type == NSColorTypeCatalog,
            @"fixed black maps to a dynamic system color in dark appearance");

    NSAttributedString *missingForeground = [[NSAttributedString alloc]
        initWithString:@"locally assembled offline result"
             attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:14]}];
    NSAttributedString *filledForeground =
        [DictionaryAppearanceTextAdapter attributedStringByAdapting:missingForeground
                                                       forAppearance:dark];
    require(colorAt(filledForeground, 0).type == NSColorTypeCatalog,
            @"missing foreground receives dynamic label color before NSTextStorage defaults black");

    NSAttributedString *fixedWhite = [[NSAttributedString alloc]
        initWithString:@"definition"
             attributes:@{NSForegroundColorAttributeName: NSColor.whiteColor}];
    NSAttributedString *lightWhite =
        [DictionaryAppearanceTextAdapter attributedStringByAdapting:fixedWhite
                                                       forAppearance:light];
    require(colorAt(lightWhite, 0).type == NSColorTypeCatalog,
            @"fixed white maps to a dynamic system color in light appearance");

    NSAttributedString *accent = [[NSAttributedString alloc]
        initWithString:@"source"
             attributes:@{NSForegroundColorAttributeName: NSColor.systemBlueColor}];
    NSAttributedString *adaptedAccent =
        [DictionaryAppearanceTextAdapter attributedStringByAdapting:accent
                                                       forAppearance:dark];
    require([colorAt(adaptedAccent, 0) isEqual:NSColor.systemBlueColor],
            @"dynamic title emphasis color remains intact");

    NSString *oxfordHTML = @"<div class='entry'>"
        "<span class='h'>prompt</span><span class='ei-g'>/prɒmpt/</span>"
        "<div class='p-g'><span class='pos-g'>verb</span>"
        "<div class='n-g'><span class='n'>1</span>"
        "<span class='def-g'>to cause action<span class='oalecd8e_chn'>促使行动</span></span>"
        "<span class='x-g'><span class='x'>They prompted a reply.</span>"
        "<span class='oalecd8e_chn'>他们促成了答复。</span></span>"
        "</div></div></div>";
    OxfordFormatResult *oxford = [[[OxfordEntryFormatter alloc] init]
        formatHTML:oxfordHTML];
    require(oxford.attributedString.length > 0,
            @"Oxford synthetic entry renders");
    require(allForegroundColorsAreDynamic(oxford.attributedString),
            @"Oxford pronunciation, definitions, and examples use dynamic colors");
    require([[DictionaryAppearanceTextAdapter
        attributedStringByAdapting:oxford.attributedString
                      forAppearance:dark].string containsString:@"促使行动"],
            @"appearance adaptation does not alter Oxford content");

    NSArray *formatters = @[
      [[Century21EntryFormatter alloc] init],
      [[NewOxfordEntryFormatter alloc] init],
      [[MedicalEntryFormatter alloc] init],
      [[AffixRootEntryFormatter alloc] init]
    ];
    NSString *safeHTML = @"<div><b>sample</b><p>definition 释义</p>"
        "<p><i>Example sentence.</i></p></div>";
    for (id formatter in formatters) {
      SupplementalFormatResult *result = [formatter formatHTML:safeHTML
                                                matchedHeadword:@"sample"];
      require(result.attributedString.length > 0,
              @"supplemental formatter renders");
      require(allForegroundColorsAreDynamic(result.attributedString),
              @"supplemental formatter uses dynamic text colors");
    }

    GenericMDictSanitizationResult *generic = [[[GenericMDictEntryFormatter alloc] init]
        sanitizeHTML:@"<style>p{color:#000}</style><p style='color:#000'>safe text</p>"];
    require([generic.plainText isEqualToString:@"safe text"],
            @"generic sanitizer keeps safe text");
    for (NSDictionary *block in generic.blocks) {
      for (NSDictionary *run in block[@"runs"]) {
        require(run[@"color"] == nil && run[@"style"] == nil,
                @"generic sanitizer never restores HTML/CSS colors");
      }
    }

    puts("C1 dark appearance attributed-text smoke: PASS");
  }
  return 0;
}
