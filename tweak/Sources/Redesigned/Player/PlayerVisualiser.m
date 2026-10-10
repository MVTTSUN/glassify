// Player redesign: the Visualizer background, the song drawn behind the player in the cover's colors, over the
// Fluid field held still (PlayerField.x keeps the field Fluid for this choice, as for Animated, so the ⋯ menu moves
// between the three without a restart). It is drawn one of two ways, as the Player page's picker says
// (SGRKeyVisualiserShader): Hills, below, or a Metal shader, built in or the user's own (SGRShaderSource.h), drawn
// by SGRShaderView.m from the same sound through SGRSpectrum.h's snapshot: 32 bands, the loudness and the beats.
//
// The sound is Spotify's output as it plays, read on the render thread through the audio effects' notify
// (SGAudioSetOutputReader, Shared/AudioEffects/AudioEffects.h) into SGRSpectrum.m's bands. Here, on the main
// thread, a display link reads the bands, brings them to a share of the song's own loudness (the loudest band of
// the last few seconds at the top, so a quiet track moves as much as a loud one), eases each band up quickly
// and down slowly, and draws two soft hills across the foot of the screen, mirrored about its middle, the bass
// in the middle and the treble at either edge: a slow one behind, a quicker one in front. Each is a gradient of
// the cover's colors (SGRPalette's flow colors, kept dark enough that white text on them stays over 5.5:1)
// masked by a shape layer, so the render server does the drawing and the app only hands it two paths a frame.
//
// A shader gets the bands brought to the song's loudness the same way, eased more quickly, the loudness, a beat that
// jumps to 1 and fades over a fifth of a second, the Intensity slider and the cover's first four flow colors, and
// draws at half the screen's pixels. A shader is compiled when it is first shown (the hills or the last shader stay
// until it is in, then it fades in over them); one that does not compile or that the GPU stops gives the hills back.
//
// It moves only while it is in a window, Spotify is in front, the player is not opening or closing and the song
// plays; a pause lets the bands settle and the link stops (a shader's clock with it), and nothing is read from
// the sound while it is stopped. At most 60 frames a second, 30 while the lyrics, which have a link of their own,
// are open and it is blurred behind them, and in the Player page's picker; in Low Power Mode with Reduce in Low
// Power Mode on (SGRKeyVisualiserLowPower, on until switched off) 20, a shader at a third of the screen's pixels;
// with Reduce Motion 15, with every band easing over seconds and no beat. While the player opens or closes the
// link is down, and comes back only once the animation is over: a link at 60 would hold the transition's 120 Hz
// down with it.
//
// ponytail: the hills follow what the output is handed, which a Bluetooth headset plays a fifth of a second or
// so later. Music Haptics schedules for the output latency; do the same here if the beat looks early on AirPods.
//
// Threading: main thread only, but for the reader, which runs on the render thread.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AudioEffects/AudioEffects.h"
#import "Shared/Player/PlayerEvents.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Player.h"
#import "SGRShaderView.h"
#import "SGRSpectrum.h"

enum { kBands = SGRSpectrumBands, kPoints = 2 * kBands - 1, kFine = SGRSpectrumFineBands };
_Static_assert(kFine == sizeof(((SGRShaderUniforms *)0)->bands) / sizeof(float), "a shader gets every band of the snapshot");
// The loudness a band is drawn against: the loudest band of late at the top, kRange dB under it at the floor,
// the top falling kPeakFall dB a second after a loud passage and never under kPeakFloor, so silence stays flat.
static const float kRange = 40, kPeakFall = 4, kPeakFloor = -60;
// A rise toward the treble, in dB a band (three bands an octave), since music has less there: a tuning knob.
static const float kTilt = 0.6f;
// How quickly a band eases toward its level, up and down, in seconds; the hill behind is slower. With Reduce
// Motion both ease over kStillEase.
static const double kFrontUp = 0.08, kFrontDown = 0.4, kBackUp = 0.3, kBackDown = 0.9, kStillEase = 3;
// No new bands for this long reads as silence (a pause, a stall, a tap that never ran).
static const double kStale = 0.3;
// The hills' height at their tallest and at rest, as shares of the screen's height; the one behind is taller.
static const CGFloat kFrontHeight = 0.24, kBackHeight = 0.3, kRestHeight = 0.012;
// Below this every band has settled (under 2 pt at the top of the front hill), and a paused song's link can stop.
static const float kSettled = 0.02f;
// Each band shares this much with either neighbor, twice over, so one loud band is a hill and not a spike.
static const float kSpread = 0.25f;
static const NSTimeInterval kTransitionSlack = 0.05;
// The shaders' bands: the tilt over 32 bands across nine octaves, as the hills' over 24 across eight, and quicker
// easing, as a shader draws the bands themselves rather than a smooth outline of them.
static const float kFineTilt = 0.5f;
static const double kFineUp = 0.05, kFineDown = 0.3;
// The loudness drawn against its own peak, kLoudRange dB under it at 0; a beat fades over kBeatFade seconds.
static const float kLoudRange = 30;
static const double kLoudUp = 0.1, kLoudDown = 0.5, kBeatFade = 0.18;
// The shaders' brightness ceiling as relative luminance: white text keeps 5.5:1 over it, 8:1 with Increase Contrast.
static const float kCeiling = 0.14f, kContrastCeiling = 0.07f;
// The share of the screen's pixels a shader draws, and in Low Power Mode with Reduce on.
static const CGFloat kRenderScale = 0.5, kReducedRenderScale = 0.34;

#pragma mark - settings

NSNotificationName const SGRVisualiserSettingsDidChangeNotification = @"SGRVisualiserSettingsDidChangeNotification";

static void settingsChanged(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGRVisualiserSettingsDidChangeNotification object:nil];
}

void SGRVisualiserSettingsChanged(void) {
    settingsChanged();
}

NSString *SGRVisualiserShader(void) {
    NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:SGRKeyVisualiserShader];
    // A custom one deleted reads as Hills.
    return stored.length && SGRShaderName(stored) ? stored : SGRShaderHills;
}

void SGRSetVisualiserShader(NSString *identifier) {
    if ([identifier isEqualToString:SGRVisualiserShader()]) return;
    [NSUserDefaults.standardUserDefaults setObject:identifier forKey:SGRKeyVisualiserShader];
    SGLog(@"redesign player: visualizer shader %@", identifier);
    settingsChanged();
}

// Read on every frame, so kept here rather than asked of the defaults each time.
static NSInteger sg_intensity;

NSInteger SGRVisualiserIntensity(void) {
    if (!sg_intensity) sg_intensity = MIN(200, MAX(25, SGInt(SGRKeyVisualiserIntensity, 100)));
    return sg_intensity;
}

void SGRSetVisualiserIntensity(NSInteger percent) {
    sg_intensity = MIN(200, MAX(25, percent));
    SGSetInt(SGRKeyVisualiserIntensity, sg_intensity);
    settingsChanged();
}

#pragma mark - the cover's colors

// Every view on screen shows the same cover (the player's and the Player page's picker of up to a dozen), so its
// colors are worked out once and handed to each.
static NSString *sg_paletteOf;
static NSArray<UIColor *> *sg_paletteColors;
static NSMutableArray<void (^)(NSArray<UIColor *> *)> *sg_paletteWaiting;

static void paletteFor(UIImage *image, NSString *identity, void (^done)(NSArray<UIColor *> *colors)) {
    if (!identity) identity = [NSString stringWithFormat:@"%p", image];
    if ([identity isEqualToString:sg_paletteOf]) {
        if (sg_paletteColors) done(sg_paletteColors);
        else [sg_paletteWaiting addObject:done];
        return;
    }
    sg_paletteOf = identity;
    sg_paletteColors = nil;
    sg_paletteWaiting = [NSMutableArray arrayWithObject:done];
    SGRPaletteRequest request = {CGSizeZero, NO, YES, YES, NO};
    [SGRPalette paletteForImage:image request:request completion:^(SGRPalette *palette) {
        if (![identity isEqualToString:sg_paletteOf]) return;
        NSArray<void (^)(NSArray<UIColor *> *)> *waiting = sg_paletteWaiting;
        sg_paletteWaiting = nil;
        if (palette.flowColors.count < 5) {
            sg_paletteOf = nil;
            return;
        }
        sg_paletteColors = palette.flowColors;
        for (void (^each)(NSArray<UIColor *> *) in waiting) each(sg_paletteColors);
    }];
}

static simd_float4 colorVector(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return simd_make_float4((float)r, (float)g, (float)b, 1);
}

#pragma mark - the hills and the shaders

static NSUInteger sg_readers;

// The reader on while any view is moving, so nothing is analyzed while none is.
static void needReader(BOOL need) {
    if (need) {
        if (sg_readers++ == 0) {
            SGRSpectrumPrepare();
            SGAudioSetOutputReader(SGRSpectrumFeed);
        }
    } else if (sg_readers && --sg_readers == 0) {
        SGAudioSetOutputReader(NULL);
    }
}

static NSDictionary *noActions(void) {
    static NSDictionary *none;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNull *off = NSNull.null;
        none = @{@"bounds": off, @"position": off, @"frame": off, @"path": off, @"colors": off};
    });
    return none;
}

@interface SGRVisualiserView : UIView <SGPlayerStateObserver>
// `style` a shader's identifier for a picker's tile, or nil for the one the setting picks; `compact` for the
// Player page, at most 30 frames a second.
- (instancetype)initWithFrame:(CGRect)frame style:(NSString *)style compact:(BOOL)compact;
// Where the hills stand, in points from the top: the screen's foot in the player. 0 is the bounds' foot.
@property (nonatomic) CGFloat baseline;
// The height the hills are a share of; 0 is the bounds' height.
@property (nonatomic) CGFloat screenHeight;
@property (nonatomic, readonly) BOOL blurred;
- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated;
- (void)appear:(BOOL)animated;
- (void)disappear:(void (^)(void))done;
@end

@implementation SGRVisualiserView {
    UIView *_content;   // the hills or the shader, faded in and out as one
    UIView *_hills;     // the two fills, faded out under a shader
    CAGradientLayer *_backFill, *_frontFill;
    CAShapeLayer *_backShape, *_frontShape;
    UIVisualEffectView *_lyricsBlur;
    CADisplayLink *_link;
    BOOL _reading, _idle;
    float _front[kBands], _back[kBands], _peak;
    uint64_t _generation;
    CFTimeInterval _fresh, _last;
    // The shader: the one drawn, and the one compiling to take over from it (or from the hills).
    NSString *_fixedStyle, *_style, *_styleBody;
    SGRShaderView *_shader, *_incoming;
    BOOL _compact, _reduced;
    float _fine[kFine], _finePeak, _loudness, _loudnessPeak, _beat;
    uint64_t _beats;
    BOOL _beatsKnown;
    double _clock;
    simd_float4 _palette[4], _paletteFrom[4];
    CFTimeInterval _paletteStart;
}

// As PlayerMotion.x: what fades is the effect view's effect, never its alpha or an ancestor's.
static UIBlurEffect *blurEffect(void) {
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}

static CAGradientLayer *fill(CAShapeLayer *shape) {
    CAGradientLayer *layer = [CAGradientLayer layer];
    layer.actions = noActions();
    layer.startPoint = CGPointMake(0, 0.5);
    layer.endPoint = CGPointMake(1, 0.5);
    shape.actions = noActions();
    layer.mask = shape;
    return layer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame style:nil compact:NO];
}

- (instancetype)initWithFrame:(CGRect)frame style:(NSString *)style compact:(BOOL)compact {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    _fixedStyle = [style copy];
    _compact = compact;
    _peak = _finePeak = _loudnessPeak = kPeakFloor;
    for (int i = 0; i < 4; i++) _palette[i] = _paletteFrom[i] = simd_make_float4(0.25f, 0.25f, 0.25f, 1);
    _content = [[UIView alloc] initWithFrame:frame];
    _hills = [[UIView alloc] initWithFrame:frame];
    _backShape = [CAShapeLayer layer];
    _backFill = fill(_backShape);
    _backFill.opacity = 0.55f;
    [_hills.layer addSublayer:_backFill];
    _frontShape = [CAShapeLayer layer];
    _frontFill = fill(_frontShape);
    [_hills.layer addSublayer:_frontFill];
    [_content addSubview:_hills];
    [self addSubview:_content];
    _lyricsBlur = [[UIVisualEffectView alloc] initWithEffect:nil];
    _lyricsBlur.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self addSubview:_lyricsBlur];
    [self applyColors:@[UIColor.darkGrayColor, UIColor.darkGrayColor, UIColor.darkGrayColor, UIColor.darkGrayColor, UIColor.darkGrayColor]];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                                      NSProcessInfoPowerStateDidChangeNotification, UIAccessibilityReduceMotionStatusDidChangeNotification]) {
        [center addObserver:self selector:@selector(updateMotionSoon) name:name object:nil];
    }
    [center addObserver:self selector:@selector(artworkChanged) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    // Posted on the main thread only (the settings above and the Player page).
    [center addObserver:self selector:@selector(settingsChanged) name:SGRVisualiserSettingsDidChangeNotification object:nil];
    SGRObservePlayerTransition(self, ^(id owner) { [owner updateMotion]; }, ^(id owner) { [owner updateMotion]; });
    SGAddPlayerStateObserver(self);
    [self applyStyle];
    [self artworkChanged];
    [self draw];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_link invalidate];
    if (_reading) needReader(NO);
}

#pragma mark - color

// Bottom left, the whole cover and bottom right in front, the top two behind, so the hills read as the cover's
// lower half under its upper.
- (void)applyColors:(NSArray<UIColor *> *)colors {
    if (colors.count < 5) return;
    _frontFill.colors = @[(id)colors[2].CGColor, (id)colors[4].CGColor, (id)colors[3].CGColor];
    _backFill.colors = @[(id)colors[0].CGColor, (id)colors[1].CGColor];
}

// A shader's four colors: the cover's quarters, crossing over from those it had as the hills' do.
- (void)paletteNow:(simd_float4 *)palette {
    float k = _paletteStart ? (float)MIN(1, MAX(0, (CACurrentMediaTime() - _paletteStart) / SGRCrossfade)) : 1;
    k = k * k * (3 - 2 * k);
    for (int i = 0; i < 4; i++) palette[i] = simd_mix(_paletteFrom[i], _palette[i], simd_make_float4(k, k, k, k));
}

- (void)artworkChanged {
    NSString *identity = nil;
    UIImage *image = SGRNowPlayingArtwork(NULL, &identity);
    if (!image) return;
    __weak SGRVisualiserView *weakSelf = self;
    paletteFor(image, identity, ^(NSArray<UIColor *> *colors) { [weakSelf takeColors:colors]; });
}

- (void)takeColors:(NSArray<UIColor *> *)colors {
    // Moving, a shader crosses over in step with its frames; otherwise it takes them at once in one frame.
    [self paletteNow:_paletteFrom];
    for (int i = 0; i < 4; i++) _palette[i] = colorVector(colors[i]);
    _paletteStart = self.window && _link ? CACurrentMediaTime() : 0;
    if (!_link) [self renderShader];
    if (!self.window) {
        [self applyColors:colors];
        return;
    }
    // The colors cross over as the field's do.
    [CATransaction begin];
    [CATransaction setAnimationDuration:SGRCrossfade];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    for (CAGradientLayer *layer in @[_frontFill, _backFill]) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"colors"];
        fade.fromValue = (layer.presentationLayer ?: layer).colors;
        [layer addAnimation:fade forKey:@"colors"];
    }
    [self applyColors:colors];
    [CATransaction commit];
}

#pragma mark - which shader

- (BOOL)drawsShader {
    return _shader != nil || _incoming != nil;
}

- (void)settingsChanged {
    [self applyStyle];
    [self updateMotion];
    if (!_link) {
        [self draw];
        [self renderShader];
    }
}

// The style the setting or the tile asks for, made: the hills at once, a shader once it has compiled.
- (void)applyStyle {
    NSString *style = _fixedStyle ?: SGRVisualiserShader(), *body = SGRShaderBody(style);
    // A custom one saved again is made again from its new body.
    if ([style isEqualToString:_style] && (body == _styleBody || [body isEqualToString:_styleBody])) return;
    _style = style;
    _styleBody = body;
    [_incoming removeFromSuperview];
    _incoming = nil;
    if ([style isEqualToString:SGRShaderHills]) {
        [self showHills];
        return;
    }
    SGRShaderView *view = [[SGRShaderView alloc] initWithFrame:self.bounds];
    view.alpha = 0;
    view.renderScale = _reduced ? kReducedRenderScale : kRenderScale;
    [_content addSubview:view];
    _incoming = view;
    __weak SGRVisualiserView *weakSelf = self;
    __weak SGRShaderView *weakView = view;
    view.arrived = ^{ [weakSelf promote:weakView]; };
    view.failed = ^(NSString *error) { [weakSelf shaderFailed:weakView]; };
    view.shader = style;
}

// The shader compiled: drawn once and faded in over what was there.
- (void)promote:(SGRShaderView *)view {
    if (!view || view != _incoming) return;
    _incoming = nil;
    SGRShaderView *old = _shader;
    _shader = view;
    [self renderShader];
    void (^swap)(void) = ^{
        view.alpha = 1;
        old.alpha = 0;
        self->_hills.alpha = 0;
    };
    if (self.window) SGRAnimate(SGRMotionFade, swap, ^(BOOL finished) { [old removeFromSuperview]; });
    else {
        swap();
        [old removeFromSuperview];
    }
    [self updateMotion];
}

// A shader that did not compile, or that the GPU stopped: the hills come back in its place.
- (void)shaderFailed:(SGRShaderView *)view {
    if (!view || (view != _incoming && view != _shader)) return;
    if (view == _incoming && _shader) {
        // The last shader stays; the choice that failed is not drawn.
        [view removeFromSuperview];
        _incoming = nil;
        return;
    }
    [self showHills];
}

- (void)showHills {
    SGRShaderView *shader = _shader, *incoming = _incoming;
    _shader = _incoming = nil;
    [incoming removeFromSuperview];
    void (^swap)(void) = ^{
        shader.alpha = 0;
        self->_hills.alpha = 1;
    };
    if (self.window && shader) SGRAnimate(SGRMotionFade, swap, ^(BOOL finished) { [shader removeFromSuperview]; });
    else {
        swap();
        [shader removeFromSuperview];
    }
    [self draw];
}

#pragma mark - showing

- (void)setBaseline:(CGFloat)baseline {
    if (baseline == _baseline) return;
    _baseline = baseline;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _content.frame = bounds;
    _hills.frame = bounds;
    _shader.frame = bounds;
    _incoming.frame = bounds;
    _lyricsBlur.frame = bounds;
    _backFill.frame = bounds;
    _frontFill.frame = bounds;
    _backShape.frame = bounds;
    _frontShape.frame = bounds;
    [self draw];
    // A still shader drawn again at its new size, once it has laid out.
    if (_shader && !_link) [self performSelector:@selector(renderShader) withObject:nil afterDelay:0];
}

- (void)appear:(BOOL)animated {
    _content.alpha = 0;
    if (animated) SGRAnimate(SGRMotionFade, ^{ self->_content.alpha = 1; }, nil);
    else _content.alpha = 1;
}

- (void)disappear:(void (^)(void))done {
    SGRAnimate(SGRMotionFade, ^{
        self->_content.alpha = 0;
        self->_lyricsBlur.effect = nil;
    }, ^(BOOL finished) { done(); });
}

- (BOOL)blurred {
    return _lyricsBlur.effect != nil;
}

- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated {
    void (^apply)(void) = ^{ self->_lyricsBlur.effect = blurred ? blurEffect() : nil; };
    if (animated) SGRAnimate(SGRMotionFade, apply, nil);
    else apply();
    [self updateMotion];
}

#pragma mark - moving

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self updateMotion];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateMotion];
}

// The power state is reported off the main thread.
- (void)updateMotionSoon {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateMotion]; });
}

- (BOOL)settled {
    if (self.drawsShader) {
        for (int band = 0; band < kFine; band++) if (_fine[band] > kSettled) return NO;
        return _loudness <= kSettled && _beat <= kSettled;
    }
    for (int band = 0; band < kBands; band++) if (_front[band] > kSettled || _back[band] > kSettled) return NO;
    return YES;
}

// Moving while it may and there is something to show: the song playing, or the hills still settling after it
// stopped. While the player animates, it comes back once the animation is expected to be over.
- (void)updateMotion {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateMotion) object:nil];
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL may = self.window && front;
    _reduced = NSProcessInfo.processInfo.lowPowerModeEnabled && SGEnabled(SGRKeyVisualiserLowPower);
    _shader.renderScale = _incoming.renderScale = _reduced ? kReducedRenderScale : kRenderScale;
    NSTimeInterval wait = SGPlayerTransitionEnds() - CACurrentMediaTime();
    if (may && (wait > 0 || SGRPlayerIsTransitioning())) {
        may = NO;
        // Without an expected end, the transition's ended notification brings it back.
        if (wait > 0) [self performSelector:@selector(updateMotion) withObject:nil afterDelay:wait + kTransitionSlack inModes:@[NSRunLoopCommonModes]];
    }
    BOOL playing = !SGPlayerState().isPaused;
    [self setMoving:may && (playing || !self.settled)];
    [self setReading:may && playing];
}

- (void)setReading:(BOOL)reading {
    if (reading == _reading) return;
    _reading = reading;
    needReader(reading);
}

- (void)setMoving:(BOOL)moving {
    if (moving) {
        if (!_link) {
            _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
            [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            _last = 0;
        }
        // Calmer behind the lyrics, whose own link runs at the display's rate, and in the Player page's picker,
        // slower in Low Power Mode, and calmest with Reduce Motion. While a playing song sends nothing (a stall, or
        // no tap at all), a few frames a second watch for it.
        float most = _idle ? 4 : SGRReduceMotion() ? 15 : _reduced ? 20 : _lyricsBlur.effect || _compact ? 30 : 60;
        _link.preferredFrameRateRange = CAFrameRateRangeMake(most / 2, most, most);
    } else if (_link) {
        [_link invalidate];
        _link = nil;
    }
}

static float ease(float value, float target, double dt, double up, double down) {
    double tau = target > value ? up : down;
    return value + (target - value) * (float)(1 - exp(-dt / tau));
}

- (void)tick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    double dt = _last ? MIN(now - _last, 0.1) : link.duration;
    _last = now;
    if (self.drawsShader) {
        [self tickShader:dt now:now];
        return;
    }
    float levels[kBands];
    uint64_t generation = SGRSpectrumRead(levels);
    if (generation != _generation) {
        _generation = generation;
        _fresh = now;
    }
    BOOL silent = !_reading || now - _fresh > kStale;
    float loudest = kPeakFloor;
    for (int band = 0; band < kBands; band++) {
        levels[band] += kTilt * band;
        loudest = fmaxf(loudest, levels[band]);
    }
    if (!silent) _peak = fmaxf(fmaxf(loudest, _peak - kPeakFall * (float)dt), kPeakFloor);
    BOOL still = SGRReduceMotion();
    float targets[kBands];
    for (int band = 0; band < kBands; band++) targets[band] = silent ? 0 : fminf(1, fmaxf(0, (levels[band] - (_peak - kRange)) / kRange));
    for (int pass = 0; pass < 2; pass++) {
        float before = targets[0];
        for (int band = 0; band < kBands; band++) {
            float here = targets[band], next = targets[MIN(band + 1, kBands - 1)];
            targets[band] = kSpread * before + (1 - 2 * kSpread) * here + kSpread * next;
            before = here;
        }
    }
    for (int band = 0; band < kBands; band++) {
        float target = targets[band];
        _front[band] = ease(_front[band], target, dt, still ? kStillEase : kFrontUp, still ? kStillEase : kFrontDown);
        _back[band] = ease(_back[band], target, dt, still ? kStillEase : kBackUp, still ? kStillEase : kBackDown);
    }
    [self draw];
    BOOL idle = silent && self.settled;
    if (idle && !_idle) {
        // The last step down to rest, too small to see, so a settled hill is drawn exactly at rest.
        memset(_front, 0, sizeof _front);
        memset(_back, 0, sizeof _back);
        [self draw];
    }
    if (idle != _idle) {
        _idle = idle;
        [self updateMotion];
    }
}

// The shader's frame: the snapshot's bands, loudness and beats brought to 0..1 and eased, then drawn. Idle, it is
// not drawn again, so a stall holds the last frame rather than stepping its clock a few times a second.
- (void)tickShader:(double)dt now:(CFTimeInterval)now {
    SGRSpectrumSnapshot snapshot;
    uint64_t generation = SGRSpectrumReadSnapshot(&snapshot);
    if (generation != _generation) {
        _generation = generation;
        _fresh = now;
    }
    BOOL silent = !_reading || now - _fresh > kStale, still = SGRReduceMotion();
    float loudest = kPeakFloor;
    for (int band = 0; band < kFine; band++) {
        snapshot.levels[band] += kFineTilt * band;
        loudest = fmaxf(loudest, snapshot.levels[band]);
    }
    if (!silent) {
        _finePeak = fmaxf(fmaxf(loudest, _finePeak - kPeakFall * (float)dt), kPeakFloor);
        _loudnessPeak = fmaxf(fmaxf(snapshot.rms, _loudnessPeak - kPeakFall * (float)dt), kPeakFloor);
    }
    for (int band = 0; band < kFine; band++) {
        float target = silent ? 0 : fminf(1, fmaxf(0, (snapshot.levels[band] - (_finePeak - kRange)) / kRange));
        _fine[band] = ease(_fine[band], target, dt, still ? kStillEase : kFineUp, still ? kStillEase : kFineDown);
    }
    float loudness = silent ? 0 : fminf(1, fmaxf(0, (snapshot.rms - (_loudnessPeak - kLoudRange)) / kLoudRange));
    _loudness = ease(_loudness, loudness, dt, still ? kStillEase : kLoudUp, still ? kStillEase : kLoudDown);
    // The first count read is where the song was, not a beat.
    if (!_beatsKnown || snapshot.beats == _beats) _beat *= (float)exp(-dt / kBeatFade);
    else if (!silent && !still) _beat = 1;
    _beatsKnown = YES;
    _beats = snapshot.beats;
    _clock = fmod(_clock + dt * (still ? 0.25 : 1), 3600);
    BOOL idle = silent && self.settled;
    if (idle && !_idle) {
        memset(_fine, 0, sizeof _fine);
        _loudness = _beat = 0;
    }
    if (!idle || !_idle) [self renderShader];
    if (idle != _idle) {
        _idle = idle;
        [self updateMotion];
    }
}

- (void)renderShader {
    if (!_shader.ready) return;
    SGRShaderUniforms uniforms = {0};
    uniforms.time = (float)_clock;
    [self paletteNow:uniforms.palette];
    memcpy(uniforms.bands, _fine, sizeof uniforms.bands);
    uniforms.rms = _loudness;
    uniforms.beat = _beat;
    uniforms.intensity = SGRVisualiserIntensity() / 100.0f;
    uniforms.ceiling = SGRIncreaseContrast() ? kContrastCeiling : kCeiling;
    [_shader render:uniforms];
}

#pragma mark - drawing

// A smooth line through the points (Catmull-Rom as cubic Béziers), closed down to the foot of the bounds.
static CGPathRef hillPath(const CGPoint *points, int count, CGFloat foot) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, points[0].x, foot);
    CGPathAddLineToPoint(path, NULL, points[0].x, points[0].y);
    for (int i = 0; i < count - 1; i++) {
        CGPoint before = points[MAX(i - 1, 0)], from = points[i], to = points[i + 1], after = points[MIN(i + 2, count - 1)];
        CGPathAddCurveToPoint(path, NULL, from.x + (to.x - before.x) / 6, from.y + (to.y - before.y) / 6,
                              to.x - (after.x - from.x) / 6, to.y - (after.y - from.y) / 6, to.x, to.y);
    }
    CGPathAddLineToPoint(path, NULL, points[count - 1].x, foot);
    CGPathCloseSubpath(path);
    return path;
}

// The bass in the middle, each band out to either side, the treble at the edges; a band's height eased in so
// quiet bands lie low and only the strong ones stand up.
static void shape(CAShapeLayer *layer, const float *bands, CGFloat width, CGFloat baseline, CGFloat foot, CGFloat tallest, CGFloat rest) {
    CGPoint points[kPoints];
    for (int i = 0; i < kPoints; i++) {
        float value = bands[abs(i - (kBands - 1))];
        CGFloat height = rest + (tallest - rest) * powf(value, 1.2f);
        points[i] = CGPointMake(width * i / (kPoints - 1), baseline - height);
    }
    CGPathRef path = hillPath(points, kPoints, foot);
    layer.path = path;
    CGPathRelease(path);
}

- (void)draw {
    CGRect bounds = self.bounds;
    if (bounds.size.width <= 0) return;
    CGFloat baseline = _baseline > 0 ? _baseline : bounds.size.height;
    CGFloat screen = _screenHeight > 0 ? _screenHeight : bounds.size.height;
    CGFloat foot = MAX(baseline, bounds.size.height), rest = round(screen * kRestHeight);
    CGFloat gain = SGRVisualiserIntensity() / 100.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shape(_backShape, _back, bounds.size.width, baseline, foot, screen * kBackHeight * gain, rest * 1.5);
    shape(_frontShape, _front, bounds.size.width, baseline, foot, screen * kFrontHeight * gain, rest);
    [CATransaction commit];
}

@end

#pragma mark - in the player

static SGRVisualiserView *sg_view;

BOOL SGRPlayerVisualiserShowing(void) {
    return SGRPlayerBackground() == SGRPlayerBackgroundVisualiser;
}

UIView *SGRPlayerVisualiserPreview(void) {
    return [[SGRVisualiserView alloc] initWithFrame:CGRectZero style:nil compact:YES];
}

UIView *SGRPlayerVisualiserPreviewOf(NSString *shader) {
    return [[SGRVisualiserView alloc] initWithFrame:CGRectZero style:shader compact:YES];
}

// The hills from the top of the field to the foot of its bleed, standing on the screen's foot.
static void layOut(SGRArtworkField *field) {
    if (sg_view.superview != field) [field addSubview:sg_view];
    else if (field.subviews.lastObject != sg_view) [field bringSubviewToFront:sg_view];
    CGSize size = field.bounds.size;
    CGFloat screen = field.window.bounds.size.height ?: size.height;
    CGRect frame = CGRectMake(0, 0, size.width, MAX(size.height, screen) + field.bleed.bottom);
    if (!CGRectEqualToRect(sg_view.frame, frame)) sg_view.frame = frame;
    sg_view.baseline = screen;
    sg_view.screenHeight = screen;
}

void SGRPlayerVisualiserUpdate(void) {
    SGRArtworkField *field = SGRPlayerField();
    // Not over an Animated artwork clip still playing: the Player page can change the choice under it, which the
    // player takes up when it next starts.
    BOOL wanted = SGRPlayerVisualiserShowing() && field && !SGRPlayerMotionShowing();
    if (!wanted) {
        SGRVisualiserView *old = sg_view;
        sg_view = nil;
        if (old.window) [old disappear:^{ [old removeFromSuperview]; }];
        else [old removeFromSuperview];
        return;
    }
    BOOL made = !sg_view;
    if (made) sg_view = [[SGRVisualiserView alloc] initWithFrame:CGRectZero];
    layOut(field);
    if (made) {
        [sg_view setBlurred:SGRPlayerLyricsOpen() animated:NO];
        [sg_view appear:field.window != nil];
        SGLog(@"redesign player: visualizer on the field");
    } else {
        BOOL open = SGRPlayerLyricsOpen();
        if (open != sg_view.blurred) [sg_view setBlurred:open animated:sg_view.window != nil];
    }
}

#pragma mark - the ⋯ menu's switch

void SGRPlayerMenuSetBackground(SGRPlayerBackgroundKind kind) {
    SGRPlayerBackgroundKind current = SGRPlayerBackground();
    if (!SGPlayerMenuOffersAnimatedArtwork() || kind < SGRPlayerBackgroundFluid || kind == current) return;
    // Animated's own switch lets the clip go or looks it up, and calls back here.
    if (kind == SGRPlayerBackgroundAnimated || current == SGRPlayerBackgroundAnimated) SGPlayerMenuSetAnimatedArtwork(kind == SGRPlayerBackgroundAnimated);
    if (kind != SGRPlayerBackgroundAnimated) SGSetInt(SGRKeyPlayerBackground, kind);
    SGLog(@"redesign player: background switched to %@ from the menu", SGRPlayerBackgroundNames()[(NSUInteger)kind]);
    SGRPlayerHoldField();
    SGRPlayerVisualiserUpdate();
}
