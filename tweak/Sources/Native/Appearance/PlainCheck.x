// Plain checkmark (Appearance): Spotify's circled tick on a saved song swapped for a plain checkmark in the accent, the
// native look's copy of Redesigned/Kit/SGRPlainCheck.x.
//
// The Add button (id=Components.UI.AddToButton, a UIButton; the identifier is in Spotify 9.1.90's strings) is
// Spotify's own component under either look: it draws its state with a Lottie animation in a
// StateMicroInteractionView<AddToButtonState>, a plus when the song is not saved and an accent circle with a tick
// when it is. Spotify marks a saved song's button selected, so the button's own selected state tells which. Saved,
// the animation goes transparent and a system checkmark stands in its place; not saved, Spotify's plus shows as it is.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Appearance.h"

static const CGFloat kCheckSize = 19;
static NSString *const kAddButton = @"Components.UI.AddToButton";
static char kCheckKey, kAnimationKey;

BOOL SGPlainCheckOn(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGHidden(SGKeyPlainCheck); });
    return on;
}

static UIView *animationIn(UIButton *button) {
    UIView *found = objc_getAssociatedObject(button, &kAnimationKey);
    if (found.superview) return found;
    static Class lottie;
    if (!lottie) lottie = NSClassFromString(@"Lottie.LottieAnimationView");
    found = nil;
    for (UIView *child in button.subviews) {
        for (UIView *inner in child.subviews) {
            if (lottie && [inner isKindOfClass:lottie]) found = inner;
        }
    }
    objc_setAssociatedObject(button, &kAnimationKey, found, OBJC_ASSOCIATION_ASSIGN);
    return found;
}

static void showState(UIButton *button) {
    UIView *animation = animationIn(button);
    if (!animation) return;
    UIImageView *check = objc_getAssociatedObject(button, &kCheckKey);
    BOOL saved = button.isSelected;
    if (saved && !check) {
        UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:kCheckSize weight:UIImageSymbolWeightBold];
        check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark" withConfiguration:configuration]];
        check.tintColor = SGColorRGB(SGAccentRGB());
        check.accessibilityIdentifier = SGPlainCheckIdentifier;
        check.contentMode = UIViewContentModeCenter;
        check.userInteractionEnabled = NO;
        check.isAccessibilityElement = NO;
        objc_setAssociatedObject(button, &kCheckKey, check, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (check && check.superview != button) [button addSubview:check];
    check.frame = button.bounds;
    check.alpha = saved ? 1 : 0;
    // Alpha, not hidden: Lottie's own state keeps running under it.
    animation.alpha = saved ? 0 : 1;
}

%hook UIButton
- (void)layoutSubviews {
    %orig;
    if ([self.accessibilityIdentifier isEqualToString:kAddButton]) showState(self);
}

- (void)setSelected:(BOOL)selected {
    %orig;
    if ([self.accessibilityIdentifier isEqualToString:kAddButton]) showState(self);
}
%end

%ctor {
    if (!SGNativeUI() || !SGPlainCheckOn()) return;
    %init;
}
