// Home redesign: a cover's average color, for the glass of the shortcut tiles (HomeTiles.m) and the Top picks
// cards (HomeTopPickCard.m). Worked out off the main thread, the picture drawn small on a serial queue of its own
// (which decodes it there, never on the main thread) and its pixels averaged by their alpha, then kept by the
// picture's URL, so a cell reused for a cover seen before, or the same cover in another tile, costs nothing.
//
// The URL is the image loader's: -[SPTImageLoaderImplementation dispatchSuccessCallbackWithImage:forURL:startTime:
// context:] hands every picture Spotify loads to its requester with the URL it came from (the selector is in
// 9.1.90's binary), and the hook keeps which picture came from which URL for as long as the picture lives. A
// picture the image view did not take from the loader as it came (one redrawn on the way) has no URL: its color is
// kept by the picture itself while it lives, and the first one of each kind says so in the log.
//
// Threading: SGRHomeCoverColor on the main thread only, its callback on the main thread. The URL table is read and
// written under a lock, since the loader may call back on any thread.
#import <os/lock.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

// The side the picture is drawn at before its pixels are averaged.
enum { kSampleSide = 16 };
// Covers kept by URL.
static const NSUInteger kCachedColors = 600;

static os_unfair_lock sg_urlLock = OS_UNFAIR_LOCK_INIT;
static NSMapTable<UIImage *, NSString *> *sg_urls;

static void remember(UIImage *image, NSURL *url) {
    if (![image isKindOfClass:UIImage.class] || ![url isKindOfClass:NSURL.class]) return;
    NSString *key = url.absoluteString;
    if (!key.length) return;
    os_unfair_lock_lock(&sg_urlLock);
    if (!sg_urls) sg_urls = [NSMapTable weakToStrongObjectsMapTable];
    [sg_urls setObject:key forKey:image];
    os_unfair_lock_unlock(&sg_urlLock);
}

static NSString *urlOf(UIImage *image) {
    os_unfair_lock_lock(&sg_urlLock);
    NSString *key = [sg_urls objectForKey:image];
    os_unfair_lock_unlock(&sg_urlLock);
    return key;
}

%hook SPTImageLoaderImplementation
- (void)dispatchSuccessCallbackWithImage:(id)image forURL:(id)url startTime:(id)startTime context:(id)context {
    remember(image, url);
    %orig;
}
%end

// Background queue: the average of the picture's pixels, weighted by their alpha; nil for a picture with no bitmap
// or nothing opaque in it.
static UIColor *averageOf(UIImage *image) {
    CGImageRef cg = image.CGImage;
    if (!cg) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    uint8_t pixels[kSampleSide * kSampleSide * 4] = {0};
    CGContextRef context = CGBitmapContextCreate(pixels, kSampleSide, kSampleSide, 8, kSampleSide * 4, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, kSampleSide, kSampleSide), cg);
    CGContextRelease(context);
    double red = 0, green = 0, blue = 0, weight = 0;
    for (size_t i = 0; i < kSampleSide * kSampleSide; i++) {
        const uint8_t *p = pixels + i * 4;
        // Premultiplied: the channels already carry the alpha they are weighted by.
        red += p[0];
        green += p[1];
        blue += p[2];
        weight += p[3];
    }
    if (weight < 1) return nil;
    return [UIColor colorWithRed:red / weight green:green / weight blue:blue / weight alpha:1];
}

static dispatch_queue_t workQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("spotifyglass.redesign.home.covers", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

UIColor *SGRHomeCoverColor(UIImage *image, void (^later)(UIColor *color)) {
    if (!image) return nil;
    static NSCache<NSString *, UIColor *> *byURL;
    static NSMapTable<UIImage *, UIColor *> *byImage;
    static NSMutableDictionary<NSString *, NSMutableArray *> *waiting;
    if (!byURL) {
        byURL = [NSCache new];
        byURL.countLimit = kCachedColors;
        byImage = [NSMapTable weakToStrongObjectsMapTable];
        waiting = [NSMutableDictionary dictionary];
    }
    NSString *url = urlOf(image);
    UIColor *known = url ? [byURL objectForKey:url] : [byImage objectForKey:image];
    if (known) return known;

    static dispatch_once_t keyedByURL, keyedByImage;
    if (url) dispatch_once(&keyedByURL, ^{ SGLog(@"redesign home: cover colors kept by URL"); });
    else dispatch_once(&keyedByImage, ^{ SGLog(@"redesign home: a cover without a URL from the image loader, its color kept by the picture"); });

    // One look at a picture however many views ask for it meanwhile; the picture is held until it is done, so its
    // address names it until then.
    NSString *key = url ?: [NSString stringWithFormat:@"%p", (__bridge void *)image];
    NSMutableArray *callbacks = waiting[key];
    if (callbacks) {
        if (later) [callbacks addObject:later];
        return nil;
    }
    callbacks = [NSMutableArray array];
    if (later) [callbacks addObject:later];
    waiting[key] = callbacks;
    dispatch_async(workQueue(), ^{
        UIColor *color;
        @autoreleasepool {
            color = averageOf(image);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (color && url) [byURL setObject:color forKey:url];
            else if (color) [byImage setObject:color forKey:image];
            NSArray *done = waiting[key];
            [waiting removeObjectForKey:key];
            for (void (^callback)(UIColor *) in done) callback(color);
        });
    });
    return nil;
}

// The color with its relative luminance brought down to `ceiling` at most, its hue and saturation kept, so white text
// on it keeps (1.05 / (ceiling + 0.05)) to 1.
UIColor *SGRHomeDarkened(UIColor *color, CGFloat ceiling) {
    CGFloat rgb[3] = {0}, alpha = 1;
    if (![color getRed:&rgb[0] green:&rgb[1] blue:&rgb[2] alpha:&alpha]) return color;
    CGFloat linear[3];
    for (int i = 0; i < 3; i++) {
        CGFloat c = MIN(MAX(rgb[i], 0), 1);
        linear[i] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
    }
    CGFloat luminance = 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
    if (luminance <= ceiling) return color;
    CGFloat scale = ceiling / luminance;
    for (int i = 0; i < 3; i++) {
        CGFloat c = linear[i] * scale;
        rgb[i] = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055;
    }
    return [UIColor colorWithRed:rgb[0] green:rgb[1] blue:rgb[2] alpha:alpha];
}

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGEnabled(SGRKeyHomeTopPicks) && !SGEnabled(SGRKeyHomeGlassShortcuts)) return;
    %init;
    SGRequireClasses(@[@"SPTImageLoaderImplementation"]);
}
