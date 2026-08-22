#import "DictionaryAppearanceTextAdapter.h"

namespace {

CGFloat linearComponent(CGFloat value) {
  return value <= 0.04045 ? value / 12.92
                          : pow((value + 0.055) / 1.055, 2.4);
}

CGFloat relativeLuminance(NSColor *color) {
  NSColor *converted = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (!converted) return -1;
  return 0.2126 * linearComponent(converted.redComponent) +
      0.7152 * linearComponent(converted.greenComponent) +
      0.0722 * linearComponent(converted.blueComponent);
}

CGFloat compositedLuminance(NSColor *foreground, CGFloat backgroundLuminance) {
  CGFloat foregroundLuminance = relativeLuminance(foreground);
  if (foregroundLuminance < 0) return -1;
  return foregroundLuminance * foreground.alphaComponent +
      backgroundLuminance * (1 - foreground.alphaComponent);
}

CGFloat contrastRatio(CGFloat first, CGFloat second) {
  if (first < 0 || second < 0) return 21;
  const CGFloat lighter = MAX(first, second);
  const CGFloat darker = MIN(first, second);
  return (lighter + 0.05) / (darker + 0.05);
}

bool shouldPreserveColor(NSColor *color) {
  // Catalog colors include label/secondary/accent system colors and remain
  // appearance-aware. Pattern colors are not dictionary text colors and are
  // left untouched rather than flattened.
  return color.type == NSColorTypeCatalog || color.type == NSColorTypePattern;
}

bool isLowContrastFixedColor(NSColor *color, NSAppearance *appearance) {
  if (shouldPreserveColor(color) || color.alphaComponent == 0) return false;
  __block NSColor *resolvedForeground = nil;
  __block NSColor *resolvedBackground = nil;
  [appearance performAsCurrentDrawingAppearance:^{
    resolvedForeground = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    resolvedBackground =
        [NSColor.textBackgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  }];
  if (!resolvedForeground || !resolvedBackground) return false;
  const CGFloat background = relativeLuminance(resolvedBackground);
  const CGFloat foreground = compositedLuminance(resolvedForeground, background);
  return contrastRatio(foreground, background) < 3.0;
}

}  // namespace

@implementation DictionaryAppearanceTextAdapter

+ (NSAttributedString *)attributedStringByAdapting:
                            (NSAttributedString *)attributedString
                                      forAppearance:(NSAppearance *)appearance {
  if (attributedString.length == 0) return [attributedString copy];
  NSMutableAttributedString *result =
      [[NSMutableAttributedString alloc] initWithAttributedString:attributedString];
  NSRange fullRange = NSMakeRange(0, result.length);
  // NSTextStorage supplies a fixed black default when an attributed run has no explicit
  // foreground color.  Fill those gaps before adapting imported fixed colors so every production
  // rendering path (including locally assembled translation/status strings) is appearance-aware.
  [result enumerateAttribute:NSForegroundColorAttributeName
                     inRange:fullRange
                     options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
    (void)stop;
    if (!value) {
      [result addAttribute:NSForegroundColorAttributeName
                     value:NSColor.labelColor
                     range:range];
    }
  }];
  [result enumerateAttribute:NSForegroundColorAttributeName
                     inRange:fullRange
                     options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
    (void)stop;
    NSColor *color = [value isKindOfClass:NSColor.class] ? value : nil;
    if (!color || !isLowContrastFixedColor(color, appearance)) return;
    [result addAttribute:NSForegroundColorAttributeName
                   value:NSColor.labelColor
                   range:range];
  }];
  return result;
}

@end
