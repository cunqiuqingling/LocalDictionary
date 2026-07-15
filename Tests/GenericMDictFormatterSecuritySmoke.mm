#import <Foundation/Foundation.h>

#import "../App/GenericMDictEntryFormatter.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"Generic formatter smoke failed: %@", message);
    exit(1);
  }
}

int main() {
  @autoreleasepool {
    GenericMDictEntryFormatter *formatter = [[GenericMDictEntryFormatter alloc] init];
    NSString *html = @"<html><head><style>.x{background:url(file:///tmp/x)}</style>"
        "<script>evilScript()</script></head><body><h1>Prompt &amp; response</h1>"
        "<p onclick='evil()'>Safe <strong>bold</strong> and <em>italic</em>.</p>"
        "<div hidden>hiddenSecret</div><iframe src='https://invalid.example/'>frameSecret</iframe>"
        "<object data='file:///tmp/secret'>objectSecret</object>"
        "<a href='javascript:evil()'>Visible reference text</a>"
        "<img src='data:image/png;base64,AAAA'><ul><li>First item</li></ul>"
        "<pre><code>let value = 1</code></pre></body></html>";
    GenericMDictSanitizationResult *result = [formatter sanitizeHTML:html];
    require([result.plainText containsString:@"Prompt & response"], @"entities");
    require([result.plainText containsString:@"Safe bold and italic"], @"basic text");
    require([result.plainText containsString:@"Visible reference text"], @"anchor text");
    require([result.plainText containsString:@"First item"], @"list");
    require([result.plainText containsString:@"let value = 1"], @"code");
    require(![result.plainText containsString:@"evilScript"], @"script removed");
    require(![result.plainText containsString:@"hiddenSecret"], @"hidden removed");
    require(![result.plainText containsString:@"frameSecret"], @"iframe removed");
    require(![result.plainText containsString:@"objectSecret"], @"object removed");
    require(![result.plainText containsString:@"javascript:"], @"javascript removed");
    require(![result.plainText containsString:@"file:///"], @"file URL removed");
    require(![result.plainText containsString:@"data:image"], @"data URL removed");

    GenericMDictSanitizationResult *invalid = [formatter sanitizeHTML:@""];
    require([invalid.plainText containsString:@"无法安全解析"],
            @"parse failure has an explicit safe result");

    NSMutableString *large = [NSMutableString stringWithString:@"<p>"];
    for (NSUInteger index = 0; index < 600000; ++index) [large appendString:@"x"];
    [large appendString:@"</p>"];
    require([formatter sanitizeHTML:large].truncated, @"large body limited");

    NSMutableString *deep = [NSMutableString string];
    for (NSUInteger index = 0; index < 70; ++index) [deep appendString:@"<div>"];
    [deep appendString:@"deep text"];
    for (NSUInteger index = 0; index < 70; ++index) [deep appendString:@"</div>"];
    require([formatter sanitizeHTML:deep].truncated, @"deep DOM limited");
    NSLog(@"Generic MDict formatter security smoke: PASS");
  }
  return 0;
}
