// Follow the cover (Appearance, an accent preset): the native player's lit controls in the cover's color instead of the
// accent, the native look's copy of Redesigned/Player/PlayerCoverAccent.x.
//
// The color: once a track, the now playing artwork Spotify hands the system (MPNowPlayingInfoCenter, as the Live
// Activity reads it) drawn at 24 by 24 off the main thread, its colorful pixels sorted by hue into twelve buckets
// weighted by saturation and brightness, and the heaviest bucket's average, made bright and clear enough to read on
// black (a relative luminance of at least kMinLuminance, past 5:1). A cover with too little color gives the accent
// back. The now playing info catches up with a new track a moment after the player, so it is asked a few times after
// a change, and nothing is read while Spotify is in the background; it is read again once Spotify is back.
//
// The paint: Accent.x swaps the accent in where a color is made, and the shuffle and repeat images, the repeat dot and
// the like's Lottie shapes never ask again, so the player paints them itself over Spotify's bottom stack
// (id=npv.bottomStackView, in Spotify 9.1.90's strings): an image drawn in the accent is tinted from its own shape,
// a background or a shape layer in the accent takes the color, and every original is kept to give back. It paints
// when the color changes, when the footer unit lays out and when one of the stack's buttons does, which is when
// Spotify hands a button its new state.
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Settings/SGModPage.h"
#import "Shared/Player/PlayerState.h"
#import "Appearance.h"

static NSString *const kBottomStack = @"npv.bottomStackView";
// The delays after a track change at which the now playing info is asked for its artwork.
static const double kReadDelays[] = {0.3, 1.2, 3};
// Under this share of the cover's pixels in its heaviest hue, weighted, the cover counts as gray.
static const double kMinColourShare = 0.04;
static const double kMinLuminance = 0.2;

static NSInteger sg_cover = -1;   // 0xRRGGBB while a cover gives one, else -1
static __weak UIView *sg_stack;   // the bottom stack last painted
static char kOriginalKey, kTintedKey, kAccentImageKey, kOriginalFillKey, kOriginalStrokeKey, kOriginalAnimationsKey;
static NSString *const kPaintedKey = @"spotifyglass.native.coverPainted";

BOOL SGAccentFollowsCover(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGHidden(SGKeyAccentFollowsCover); });
    return on;
}

static void unpack(NSInteger rgb, CGFloat *r, CGFloat *g, CGFloat *b) {
    *r = ((rgb >> 16) & 0xFF) / 255.0;
    *g = ((rgb >> 8) & 0xFF) / 255.0;
    *b = (rgb & 0xFF) / 255.0;
}

static UIColor *coverColor(void) {
    CGFloat r, g, b;
    unpack(sg_cover, &r, &g, &b);
    return [UIColor colorWithRed:r green:g blue:b alpha:1];
}

#pragma mark - the cover's color

static double linear(double channel) {
    return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4);
}

static double luminance(double r, double g, double b) {
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
}

// Hue 0 to 1 and saturation and brightness of a color of 0 to 1 channels.
static void hsv(double r, double g, double b, double *h, double *s, double *v) {
    double high = MAX(r, MAX(g, b)), low = MIN(r, MIN(g, b)), range = high - low;
    *v = high;
    *s = high > 0 ? range / high : 0;
    if (range <= 0) {
        *h = 0;
        return;
    }
    double hue = high == r ? fmod((g - b) / range, 6) : high == g ? (b - r) / range + 2 : (r - g) / range + 4;
    *h = hue / 6 < 0 ? hue / 6 + 1 : hue / 6;
}

// The hue kept, its saturation held between 0.45 and 0.85 and its brightness at 0.9 or more, then mixed with white
// until it is light enough on black: a deep blue stays blue rather than going dark.
static NSInteger readable(double r, double g, double b) {
    double h, s, v;
    hsv(r, g, b, &h, &s, &v);
    UIColor *bright = [UIColor colorWithHue:h saturation:MIN(0.85, MAX(0.45, s)) brightness:MAX(0.9, v) alpha:1];
    CGFloat br, bg, bb, ba;
    if (![bright getRed:&br green:&bg blue:&bb alpha:&ba]) return -1;
    double white = 0;
    while (white < 1 && luminance(br + (1 - br) * white, bg + (1 - bg) * white, bb + (1 - bb) * white) < kMinLuminance) white += 0.04;
    white = MIN(white, 1);
    r = br + (1 - br) * white;
    g = bg + (1 - bg) * white;
    b = bb + (1 - bb) * white;
    return ((NSInteger)lround(r * 255) << 16) | ((NSInteger)lround(g * 255) << 8) | (NSInteger)lround(b * 255);
}

// The cover's vibrant dominant color, RRGGBB, or -1 for a cover with too little color. Any thread.
static NSInteger vibrantColour(CGImageRef image) {
    enum { kSide = 24, kBuckets = 12 };
    uint8_t pixels[kSide * kSide * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, kSide * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return -1;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image);
    CGContextRelease(context);
    double weight[kBuckets] = {0}, red[kBuckets] = {0}, green[kBuckets] = {0}, blue[kBuckets] = {0};
    for (int i = 0; i < kSide * kSide; i++) {
        double r = pixels[i * 4] / 255.0, g = pixels[i * 4 + 1] / 255.0, b = pixels[i * 4 + 2] / 255.0, h, s, v;
        hsv(r, g, b, &h, &s, &v);
        if (s < 0.25 || v < 0.2) continue;
        int bucket = MIN(kBuckets - 1, (int)(h * kBuckets));
        double w = s * v;
        weight[bucket] += w;
        red[bucket] += r * w;
        green[bucket] += g * w;
        blue[bucket] += b * w;
    }
    // A hue split across two buckets still wins: each bucket counts half of its neighbors.
    int best = -1;
    double bestWeight = 0;
    for (int i = 0; i < kBuckets; i++) {
        double around = weight[i] + 0.5 * (weight[(i + 1) % kBuckets] + weight[(i + kBuckets - 1) % kBuckets]);
        if (weight[i] > 0 && around > bestWeight) {
            best = i;
            bestWeight = around;
        }
    }
    if (best < 0 || weight[best] < kMinColourShare * kSide * kSide) return -1;
    return readable(red[best] / weight[best], green[best] / weight[best], blue[best] / weight[best]);
}

#pragma mark - the paint

// Whether a color is the accent's: its hue within kHueNear, and colorful. Darker shades of it count (a pressed state).
static const CGFloat kHueNear = 0.05, kColorful = 0.35;
static BOOL accentLike(CGFloat r, CGFloat g, CGFloat b) {
    static CGFloat accentHue = -1;
    if (accentHue < 0) {
        CGFloat ar, ag, ab, s, v, a;
        unpack(SGAccentRGB(), &ar, &ag, &ab);
        [[UIColor colorWithRed:ar green:ag blue:ab alpha:1] getHue:&accentHue saturation:&s brightness:&v alpha:&a];
    }
    CGFloat h, s, v, a;
    if (![[UIColor colorWithRed:r green:g blue:b alpha:1] getHue:&h saturation:&s brightness:&v alpha:&a]) return NO;
    CGFloat d = fabs(h - accentHue);
    return MIN(d, 1 - d) < kHueNear && s > kColorful && v > 0.2;
}

static BOOL colorAccentLike(UIColor *color) {
    CGFloat r, g, b, a;
    return color && [color getRed:&r green:&g blue:&b alpha:&a] && a > 0.5 && accentLike(r, g, b);
}

static BOOL cgAccentLike(CGColorRef color) {
    if (!color || CGColorGetNumberOfComponents(color) != 4) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    return c[3] > 0.5 && accentLike(c[0], c[1], c[2]);
}

// Whether an image is drawn in the accent: the average of its opaque pixels, read once at 16 by 16 and kept on it.
static BOOL imageAccentLike(UIImage *image) {
    NSNumber *known = objc_getAssociatedObject(image, &kAccentImageKey);
    if (known) return known.boolValue;
    enum { kSide = 16 };
    uint8_t pixels[kSide * kSide * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, kSide * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    BOOL accent = NO;
    if (context && image.CGImage) {
        CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image.CGImage);
        double r = 0, g = 0, b = 0, n = 0;
        for (int i = 0; i < kSide * kSide; i++) {
            uint8_t alpha = pixels[i * 4 + 3];
            if (alpha < 128) continue;
            r += pixels[i * 4] / (double)alpha;
            g += pixels[i * 4 + 1] / (double)alpha;
            b += pixels[i * 4 + 2] / (double)alpha;
            n++;
        }
        accent = n >= 4 && accentLike(r / n, g / n, b / n);
    }
    if (context) CGContextRelease(context);
    objc_setAssociatedObject(image, &kAccentImageKey, @(accent), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return accent;
}

static void paintImageView(UIImageView *view) {
    UIImage *image = view.image, *tinted = objc_getAssociatedObject(view, &kTintedKey);
    UIImage *original = image == tinted ? objc_getAssociatedObject(view, &kOriginalKey) : image;
    if (!original) return;
    if (sg_cover < 0 || !imageAccentLike(original)) {
        if (image == tinted && tinted) view.image = original;
        objc_setAssociatedObject(view, &kTintedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (image == tinted && tinted) return;
    UIImage *made = [original imageWithTintColor:coverColor() renderingMode:UIImageRenderingModeAlwaysOriginal];
    objc_setAssociatedObject(view, &kOriginalKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kTintedKey, made, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.image = made;
}

static void paintBackground(UIView *view) {
    UIColor *original = objc_getAssociatedObject(view, &kOriginalKey);
    UIColor *current = view.backgroundColor;
    if (!original && !colorAccentLike(current)) return;
    if (!original) {
        original = current;
        objc_setAssociatedObject(view, &kOriginalKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.backgroundColor = sg_cover < 0 ? original : coverColor();
}

static void paintShape(CAShapeLayer *layer) {
    for (int stroke = 0; stroke < 2; stroke++) {
        void *key = stroke ? &kOriginalStrokeKey : &kOriginalFillKey;
        id original = objc_getAssociatedObject(layer, key);
        CGColorRef current = stroke ? layer.strokeColor : layer.fillColor;
        if (!original && !cgAccentLike(current)) continue;
        if (!original) {
            original = (__bridge id)current;
            objc_setAssociatedObject(layer, key, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGColorRef color = sg_cover < 0 ? (__bridge CGColorRef)original : coverColor().CGColor;
        if (stroke) layer.strokeColor = color;
        else layer.fillColor = color;
    }
}

// Lottie's Core Animation renderer colors a shape with a keyframe animation on fillColor or strokeColor, which shows
// over the layer's own value: those keyframes in the accent take the cover's color, the animations as Lottie made
// them kept by key to give back.
static void paintAnimations(CALayer *layer) {
    NSMutableDictionary<NSString *, CAAnimation *> *originals = objc_getAssociatedObject(layer, &kOriginalAnimationsKey);
    for (NSString *key in layer.animationKeys) {
        CAAnimation *animation = [layer animationForKey:key];
        if (![animation isKindOfClass:CAKeyframeAnimation.class]) continue;
        CAKeyframeAnimation *keyframes = (CAKeyframeAnimation *)animation;
        if (![keyframes.keyPath isEqualToString:@"fillColor"] && ![keyframes.keyPath isEqualToString:@"strokeColor"]) continue;
        // A layer copies what it is given, so a painted animation is told by the cover it carries, not by identity.
        NSNumber *painted = [animation valueForKey:kPaintedKey];
        CAKeyframeAnimation *base = keyframes;
        if (painted) {
            CAKeyframeAnimation *original = (CAKeyframeAnimation *)originals[key];
            if (!original) continue;
            if (sg_cover < 0) {
                [layer addAnimation:original forKey:key];
                [originals removeObjectForKey:key];
                continue;
            }
            if (painted.integerValue == sg_cover) continue;
            base = original;
        } else {
            if (sg_cover < 0) continue;
            if (!originals) {
                originals = [NSMutableDictionary dictionary];
                objc_setAssociatedObject(layer, &kOriginalAnimationsKey, originals, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            originals[key] = keyframes;
        }
        BOOL any = NO;
        NSMutableArray *values = [NSMutableArray arrayWithCapacity:base.values.count];
        for (id value in base.values) {
            BOOL accent = CFGetTypeID((__bridge CFTypeRef)value) == CGColorGetTypeID() && cgAccentLike((__bridge CGColorRef)value);
            any |= accent;
            [values addObject:accent ? (__bridge id)coverColor().CGColor : value];
        }
        if (!any) {
            [originals removeObjectForKey:key];
            continue;
        }
        CAKeyframeAnimation *made = [base copy];
        made.values = values;
        [made setValue:@(sg_cover) forKey:kPaintedKey];
        [layer addAnimation:made forKey:key];
    }
}

static void paintLayers(CALayer *layer) {
    if ([layer isKindOfClass:CAShapeLayer.class]) paintShape((CAShapeLayer *)layer);
    if (layer.animationKeys.count) paintAnimations(layer);
    for (CALayer *sublayer in layer.sublayers) paintLayers(sublayer);
}

static void paint(UIView *root) {
    if (!root) return;
    static Class lottie;
    if (!lottie) lottie = NSClassFromString(@"Lottie.LottieAnimationView");
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    SGForEachView(root, ^(UIView *view) {
        if ([view.accessibilityIdentifier isEqualToString:SGPlainCheckIdentifier]) view.tintColor = sg_cover < 0 ? SGColorRGB(SGAccentRGB()) : coverColor();
        else if ([view isKindOfClass:UIImageView.class]) paintImageView((UIImageView *)view);
        else if (lottie && [view isKindOfClass:lottie]) paintLayers(view.layer);
        else paintBackground(view);
    });
    [CATransaction commit];
}

static UIView *bottomStackAbove(UIView *view) {
    for (UIView *up = view; up; up = up.superview) {
        if ([up isKindOfClass:UIStackView.class] && [up.accessibilityIdentifier isEqualToString:kBottomStack]) return up;
    }
    return nil;
}

static void setCover(NSInteger rgb) {
    if (rgb == sg_cover) return;
    sg_cover = rgb;
    SGLog(@"accent: follow the cover %@", rgb < 0 ? @"gives the accent back (a gray cover)" : [NSString stringWithFormat:@"paints #%06lX", (long)rgb]);
    paint(sg_stack);
}

#pragma mark - reading the cover

static NSString *sg_track;          // the track whose cover was asked for
static NSUInteger sg_generation;    // bumped on every track change, so older reads stand down
static __weak id sg_artwork;        // the artwork object last read

// The artwork the now playing info holds for the playing track, read once per artwork object (Spotify hands over a
// placeholder first and the cover after it, a new object each time). Main thread.
static void readCover(void) {
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    SPTPlayerTrack *track = SGPlayerState().track;
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    if (!track.trackTitle.length || ![info[MPMediaItemPropertyTitle] isEqual:track.trackTitle]) return;
    MPMediaItemArtwork *artwork = info[MPMediaItemPropertyArtwork];
    if (![artwork isKindOfClass:MPMediaItemArtwork.class] || artwork == sg_artwork) return;
    UIImage *image = [artwork imageWithSize:CGSizeMake(64, 64)];
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return;
    sg_artwork = artwork;
    NSUInteger generation = sg_generation;
    CGImageRetain(cgImage);
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.native.coverAccent", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
    dispatch_async(queue, ^{
        NSInteger rgb = vibrantColour(cgImage);
        CGImageRelease(cgImage);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == sg_generation) setCover(rgb);
        });
    });
}

static void scheduleReads(void) {
    NSUInteger generation = ++sg_generation;
    for (size_t i = 0; i < sizeof(kReadDelays) / sizeof(kReadDelays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReadDelays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation == sg_generation) readCover();
        });
    }
}

@interface SGCoverAccentWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGCoverAccentWatcher
// Called for pause, play and shuffle too; only a new track asks for its cover.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *track = SGURIString(state.track.URI);
    if (!track.length || [track isEqualToString:sg_track]) return;
    sg_track = track;
    scheduleReads();
}
@end

#pragma mark - hooks

// The footer unit laid out: the bottom stack it is arranged in is found and painted.
%hook _TtC20NowPlaying_ModesImpl18FooterElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *stack = bottomStackAbove(((UIViewController *)self).viewIfLoaded);
    if (!stack) return;
    sg_stack = stack;
    paint(stack);
}
%end

// A button in the player's stack laid out: Spotify hands it a new state's icon or animation this way.
%hook UIButton
- (void)layoutSubviews {
    %orig;
    UIView *stack = sg_stack;
    if (stack && (sg_cover >= 0 || objc_getAssociatedObject(self, &kTintedKey)) && [(UIView *)self isDescendantOfView:stack]) paint((UIView *)self);
}
%end

%ctor {
    if (!SGNativeUI() || !SGAccentFollowsCover()) return;
    %init;
    static SGCoverAccentWatcher *watcher;
    watcher = [SGCoverAccentWatcher new];
    SGAddPlayerStateObserver(watcher);
    // Posted on the main thread: a cover that changed while Spotify was in the background is read on the way back.
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ scheduleReads(); });
    }];
    SGRequireClasses(@[@"_TtC20NowPlaying_ModesImpl18FooterElementsUnit"]);
}
