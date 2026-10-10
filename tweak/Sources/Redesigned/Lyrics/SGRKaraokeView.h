// The redesign's Apple Music style lyrics view, always on, over Spotify's full screen lyrics page
// (KaraokePage.x) and in the redesigned player itself (Redesigned/Player/PlayerLyrics.x). A track
// without synced lyrics keeps Spotify's own lines, where there are any next to it. The lines and the
// clock are Shared/Lyrics/Lyrics.h's.
//
// It takes the whole of whatever it is put in and dims every other view in there while it has lines
// to show, so a host it shares with anything else needs a view of its own for it.
#import <UIKit/UIKit.h>
#import "Shared/Lyrics/Lyrics.h"

@interface SGRKaraokeView : UIView
// The Lyrics page's preview: `lines` played on a clock of its own, round and round every `length` ms, in
// the look the page sets. It takes no touches and asks nothing of the player, the sources, Genius or Sing.
- (instancetype)initWithSampleLines:(NSArray<SGKaraokeLine *> *)lines length:(NSInteger)length;
// Hides Spotify's own lyrics next to this view while it has lyrics to show, and brings them back when not.
- (void)syncSiblings;
// Called as a finger starts to scroll the lines, for a host that hides its controls then.
@property (nonatomic, copy) void (^browsingBegan)(void);
// Called as the lines, let alone after a scroll, start back to the line being sung (kBrowseHold on), before
// they move: a host that puts its controls back then has the stack follow the song in the room they leave.
// Not called for a tap on a line, which takes the stack there itself, nor for a song with no timing.
@property (nonatomic, copy) void (^browsingEnded)(void);
// Whether a tap at `point` (in this view) is the lines' own: a line to seek to, its meaning's bubble or the
// credit. A host's tap that brings its controls back leaves those to the lines.
- (BOOL)takesTapAt:(CGPoint)point;
// The pronunciation and translation button goes with the host's controls when they are hidden, and Sing's
// mic with it unless keepsSing is set.
@property (nonatomic) BOOL extrasHidden;
// The mic stays when the extras go, for a host that lets it take its own touches while its controls are
// hidden (the player's lines on their own, Redesigned/Player/PlayerLyrics.x), so Sing is always in reach.
@property (nonatomic) BOOL keepsSing;
@end
