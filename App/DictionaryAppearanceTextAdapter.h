#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Applies a narrow contrast safety pass to fixed colors from dictionary
/// content. Dynamic system colors and readable emphasis colors are preserved.
@interface DictionaryAppearanceTextAdapter : NSObject

+ (NSAttributedString *)attributedStringByAdapting:
                            (NSAttributedString *)attributedString
                                      forAppearance:(NSAppearance *)appearance;

@end

NS_ASSUME_NONNULL_END
