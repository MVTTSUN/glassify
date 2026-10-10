// Player redesign: a volume slider under the controls, as the Music app has. On this iPhone it is MPVolumeView, as
// the HIG asks (sliders.md, playing-audio.md), so it is the system's volume: the hardware buttons move it, and while
// it is on screen the system's volume HUD stays away. No route button: the footer's Connect glyph is the route.
// While Spotify plays on a Connect device it is a slider of the mod's over Spotify's own Connect volume
// (PlayerConnectVolume.x), the speaker's, which follows it as the device or the hardware buttons change it;
// MPVolumeView then goes, so the buttons do what Spotify makes them do. With Spotify's volume objects not
// seen yet, MPVolumeView stays.
//
// It sits in Spotify's bottom stack, outside its arranged views, between the controls and the footer row, so the
// lyrics fade it with the rest of the stack (PlayerLyrics.x) and its touches stay inside the stack. The footer's
// lowerRow (PlayerFooter.x) places it after the moves, and keeps the controls where Spotify put them to make the room.
// While the lyrics' landscape screen is up (PlayerLandscape.x) the row is hidden, so the volume HUD comes back
// there.
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"

// The track's height, the glyphs' point size and the gap between a glyph and the track.
static const CGFloat kRowHeight = 34, kGlyphSize = 13, kGlyphGap = 10, kTrack = 4;
// Half the play button's height and half the footer glyphs': below this much room between them it does not fit.
static const CGFloat kButtonsHalf = 24, kGlyphsHalf = 14;
// The slider draws its track this far above its own middle (6.5px measured on the phone), so the glyphs go up with it.
static const CGFloat kTrackAbove = 2;

@interface SGRVolumeRow : UIView
@end

@implementation SGRVolumeRow {
    MPVolumeView *_volume;
    UISlider *_remote;   // the Connect device's
    UIImageView *_quiet, *_loud;
    BOOL _playsRemotely, _retryQueued;
    CFTimeInterval _settleUntil;   // the device's own volume is not shown over a value just set until then
}

static __weak SGRVolumeRow *sg_row;

static UIImage *trackImage(UIColor *color) {
    CGFloat side = kTrack;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [color setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:side / 2] fill];
    }];
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0, side / 2, 0, side / 2)];
}

static UIImage *thumbImage(void) {
    CGFloat side = 14;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.whiteColor setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, side, side)] fill];
    }];
}

static UIImageView *glyph(NSString *symbol) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:kGlyphSize weight:UIImageSymbolWeightSemibold];
    UIImageView *view = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]];
    view.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    view.contentMode = UIViewContentModeCenter;
    view.isAccessibilityElement = NO;
    return view;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _volume = [MPVolumeView new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _volume.showsRouteButton = NO;
#pragma clang diagnostic pop
    [_volume setMinimumVolumeSliderImage:trackImage(UIColor.whiteColor) forState:UIControlStateNormal];
    [_volume setMaximumVolumeSliderImage:trackImage([UIColor colorWithWhite:1 alpha:0.22]) forState:UIControlStateNormal];
    [_volume setVolumeThumbImage:thumbImage() forState:UIControlStateNormal];
    _remote = [UISlider new];
    [_remote setMinimumTrackImage:trackImage(UIColor.whiteColor) forState:UIControlStateNormal];
    [_remote setMaximumTrackImage:trackImage([UIColor colorWithWhite:1 alpha:0.22]) forState:UIControlStateNormal];
    [_remote setThumbImage:thumbImage() forState:UIControlStateNormal];
    _remote.accessibilityLabel = @"Volume";
    _remote.alpha = 0;
    _remote.userInteractionEnabled = NO;
    [_remote addTarget:self action:@selector(remoteMoved) forControlEvents:UIControlEventValueChanged];
    [_remote addTarget:self action:@selector(remoteReleased)
      forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    _quiet = glyph(@"speaker.fill");
    _loud = glyph(@"speaker.wave.3.fill");
    [self addSubview:_quiet];
    [self addSubview:_volume];
    [self addSubview:_remote];
    [self addSubview:_loud];
    // Spotify's objects post from their own threads; PlayerConnectVolume.x moves them onto the main queue.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:SGRConnectVolumeDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;
    sg_row = self;
    [self observe];
    [self refresh];
}

// Spotify's volume objects may not have been seen when the player first shows: looked for again every 2 s while
// the row is on screen, until both are observed.
- (void)observe {
    if (SGRConnectVolumeObserve() || _retryQueued) return;
    _retryQueued = YES;
    __weak SGRVolumeRow *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        SGRVolumeRow *row = weakSelf;
        if (!row) return;
        row->_retryQueued = NO;
        if (!row.window) return;
        [row observe];
        [row refresh];
    });
}

// Which of the two shows, and where the Connect slider stands.
- (void)refresh {
    BOOL remote = SGRConnectPlaysRemotely();
    double volume = remote ? SGRConnectVolume() : NAN;
    if (isnan(volume)) remote = NO;
    if (remote != _playsRemotely) {
        _playsRemotely = remote;
        SGLog(@"redesign player: volume row is %@", remote ? @"the Connect device's" : @"this iPhone's");
    }
    // Hidden rather than faded, so the system's HUD comes back with it gone: MPVolumeView keeps it away while it shows.
    BOOL landscape = SGRPlayerLandscapeShowing();
    if (_volume.hidden != (remote || landscape)) _volume.hidden = remote || landscape;
    _remote.alpha = remote && !landscape ? 1 : 0;
    _remote.userInteractionEnabled = remote && !landscape;
    _remote.accessibilityElementsHidden = !_remote.userInteractionEnabled;
    if (remote && !_remote.tracking && CACurrentMediaTime() >= _settleUntil) _remote.value = (float)volume;
}

- (void)remoteMoved {
    SGRConnectSetVolume(_remote.value, NO);
}

- (void)remoteReleased {
    _settleUntil = CACurrentMediaTime() + 1;
    SGRConnectSetVolume(_remote.value, YES);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat side = kRowHeight, middle = CGRectGetMidY(bounds), glyphs = middle - kTrackAbove;
    _quiet.frame = CGRectMake(0, glyphs - side / 2, side / 2 + kGlyphSize / 2, side);
    _loud.frame = CGRectMake(CGRectGetMaxX(bounds) - side / 2 - kGlyphSize, glyphs - side / 2, side / 2 + kGlyphSize, side);
    CGFloat left = CGRectGetMaxX(_quiet.frame) + kGlyphGap, right = CGRectGetMinX(_loud.frame) - kGlyphGap;
    // MPVolumeView draws its slider at the top of its bounds, not in the middle: it gets the slider's own height,
    // centered, so the track lines up with the glyphs (it sat 9pt above them).
    CGFloat sliderHeight = MIN(side, [_volume sizeThatFits:CGSizeMake(MAX(0, right - left), side)].height ?: side);
    _volume.frame = CGRectMake(left, round(middle - sliderHeight / 2), MAX(0, right - left), sliderHeight);
    // UISlider draws its track in its middle: the Connect slider goes up by what MPVolumeView's track sits above its own.
    _remote.frame = CGRectOffset(_volume.frame, 0, -kTrackAbove);
}

@end

static char kVolumeKey, kPlayKey;

// Read at launch, as the player's other switches are: the footer asks on every layout pass.
BOOL SGRPlayerVolumeOn(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGEnabled(SGRKeyPlayerVolume); });
    return on;
}

void SGRPlayerVolumeRefresh(void) {
    [sg_row refresh];
}

BOOL SGRPlayerPlaceVolume(UIView *stack, UIView *controls, UIView *row, CGFloat margin) {
    SGRVolumeRow *volume = objc_getAssociatedObject(stack, &kVolumeKey);
    if (!SGRPlayerVolumeOn() || !controls) {
        if (volume) volume.alpha = 0;
        return NO;
    }
    if (!volume) {
        volume = [SGRVolumeRow new];
        objc_setAssociatedObject(stack, &kVolumeKey, volume, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (volume.superview != stack) [stack addSubview:volume];
    // Halfway between the play button's bottom and the footer glyphs' top, each where it is drawn (convertRect: takes
    // the moves' transforms in): the controls' unit reaches above its buttons, so its own middle sat the row 16pt high.
    // Without the button, the unit's middle stands in for it.
    UIView *play = SGRFindByIdentifier(controls, @"SPTNowPlayingPlayButton", &kPlayKey);
    CGFloat above = play ? CGRectGetMaxY([play convertRect:play.bounds toView:stack])
                         : controls.center.y + controls.transform.ty + kButtonsHalf;
    CGFloat below = [row convertPoint:CGPointMake(CGRectGetMidX(row.bounds), CGRectGetMidY(row.bounds)) toView:stack].y - kGlyphsHalf;
    CGFloat height = kRowHeight, room = below - above;
    CGRect frame = CGRectMake(margin, round((above + below - height) / 2), MAX(0, stack.bounds.size.width - 2 * margin), height);
    if (!CGRectEqualToRect(volume.frame, frame)) volume.frame = frame;
    // The lyrics fade the stack's views by their alpha and bring back only the ones they faded.
    // The track and thumb are 14pt of the row's 34: it fits with the glyphs' and buttons' own clearance around it.
    BOOL fits = room >= height * 0.6;
    if (!fits) volume.alpha = 0;
    else if (volume.alpha < 0.01 && controls.alpha > 0.99) volume.alpha = 1;
    return fits;
}
