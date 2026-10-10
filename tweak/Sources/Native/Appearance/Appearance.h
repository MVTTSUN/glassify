// The native look's appearance: the AMOLED background (Amoled.x), the accent color in place of
// Spotify's green (Accent.x), Follow the cover (CoverAccent.x), the plain checkmark (PlainCheck.x), the soft
// top edge (EdgeEffect.x) and Repaint.x, which keeps what the native tweaks stripped transparent when Spotify
// repaints it. The switches are off until asked for.
#import <UIKit/UIKit.h>

#define SGKeyAmoled @"spotifyglass.amoled"
#define SGKeyAccent @"spotifyglass.accent"   // 0xRRGGBB; unset or negative keeps Spotify's own green
// The last color picked, kept while a preset is in place so Custom brings it back.
#define SGKeyAccentCustom @"spotifyglass.accent.custom"

UIColor *SGAccentColor(void);   // nil while Spotify's own green is kept
NSInteger SGAccentRGB(void);    // the color in effect, 0xRRGGBB, Spotify's green included

// Follow the cover (CoverAccent.x), the accent preset that paints the player's lit controls in a bright form of
// the cover's color, the accent above staying for a gray cover and everywhere else. Off until picked, read at launch.
#define SGKeyAccentFollowsCover @"spotifyglass.accent.followsCover"
BOOL SGAccentFollowsCover(void);

// Plain checkmark (PlainCheck.x): a saved song's circled tick as a plain checkmark in the accent. Off until switched
// on, read at launch.
#define SGKeyPlainCheck @"spotifyglass.plainCheck"
BOOL SGPlainCheckOn(void);
// The plain checkmark's view, a template image: Follow the cover sets its tint.
#define SGPlainCheckIdentifier @"spotifyglass.native.plainCheck"

@class SGModRow;
NSArray<SGModRow *> *SGNativeAppearanceRows(void);   // AMOLED and the accent color, for the Appearance page
