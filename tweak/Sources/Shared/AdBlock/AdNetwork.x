// Spotify's responses on their way in, through the URLSession delegates it reads them by:
// SPTDataLoaderService and HttpClientURLSession for the app's own requests, and
// SPTCoreURLSessionDataDelegate for the C++ core's, which fetch the ad config (ads/v2/config and
// ad-logic/state/config, device 2026-10-10). A request for an ad is answered
// empty, and feeds go through Feeds.m. The account's product state is never touched (Glassify drops
// Spoof Premium). The ad paths are EeveeSpotify's.
#import "Core/SGCore.h"
#import "AdBlock.h"

static BOOL ads;
static char kBufferKey, kPassKey, kCoreAdKey;

typedef NS_ENUM(NSInteger, SGNet) { SGNetPass, SGNetBlock, SGNetPatch };

static BOOL has(NSString *text, NSString *needle) {
    return [text containsString:needle];
}

// The feeds Home, Search and the page under the player are built from. casita/v1/feeds is the flat
// list of tab chips, not sections.
static BOOL isFeed(NSString *path) {
    if (has(path, @"/casita/v1/feeds")) return NO;
    return has(path, @"/browsita/") || has(path, @"/casita/") || has(path, @"/scrollsita/");
}

static NSString *const adPaths[] = {
    @"/ads/", @"/ad-logic/", @"/dac/view/v1/", @"/ad-slot/", @"/ad-inventory/", @"/ad-on-app-open", @"/sponsored/",
    @"/promoted/", @"/upsell/", @"/premium-upsell", @"/upsell-banner", @"/upsell-card", @"/referrals/upsell",
    @"/campaign/", @"/billboard/", @"/banner/", @"/interstitial/", @"/overlay/", @"/popup/", @"/pop-up/",
    @"/search-ad/", @"/home-ad/", @"/marquee/", @"/leavebehind", @"/leave-behind", @"/display-ad/", @"/fullbleed/",
    @"/leaderboard/", @"/ad-card/", @"/sponsored-content/", @"/sponsored-ad/", @"/native-ad/", @"/sponsored-shelf/",
    @"/sponsored-row/", @"/ad-shelf/", @"/ad-row/", @"/sponsored-item/", @"/ad-item/", @"/merchandising/",
    @"/upgrade-component/", @"/marketing/", @"/home-ads/", @"/search-ads/",
};

// Esperanto service names use dot/underscore-separated identifiers as well as URL
// path segments. A word-boundary regex alone would not split underscores. Match
// whole ad/slot tokens after /esperanto/, never the "ad" inside load or metadata.
static BOOL isEsperantoAd(NSString *path) {
    NSRange marker = [path rangeOfString:@"/esperanto/"];
    if (marker.location == NSNotFound) return NO;
    static NSRegularExpression *tokens;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tokens = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[/._-])(?:ads?|slots?)(?=$|[/._-])"
                                                          options:0 error:NULL];
    });
    NSString *route = [path substringFromIndex:NSMaxRange(marker)];
    return [tokens firstMatchInString:route options:0 range:NSMakeRange(0, route.length)] != nil;
}

static BOOL isAd(NSURL *url, NSString *path) {
    for (size_t i = 0; i < sizeof(adPaths) / sizeof(adPaths[0]); i++) {
        if (has(path, adPaths[i])) return YES;
    }
    if (isEsperantoAd(path)) return YES;
    NSString *host = url.host.lowercaseString ?: @"";
    return has(host, @"doubleclick") || has(host, @"googlesyndication") || [host hasPrefix:@"aet."]
        || [@[@"ad.spotify.com", @"ads.spotify.com", @"aet.spotify.com"] containsObject:host];
}

// The first thirty seconds are a fresh login's: signup/public and customize are part of it, and
// answering them broke first launch.
static SGNet classify(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    if (ads && isAd(url, path)) return SGNetBlock;
    if (ads && isFeed(path)) return SGNetPatch;
    return SGNetPass;
}

// A blocked request is answered with no bytes, so that nothing is retried.
static NSData *blockedReply(NSString *path) {
    return [NSData data];
}

static NSData *patched(NSURL *url, NSData *body) {
    return SGStripFeed(body);
}

#pragma mark - the delegate's three calls

// Data handed to the delegate by the mod goes through its hooked didReceiveData like Spotify's own,
// with the pass mark on the task so the hook lets it by.
static void deliver(id<NSURLSessionDataDelegate> delegate, NSURLSession *session, NSURLSessionTask *task, NSData *data) {
    objc_setAssociatedObject(task, &kPassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [delegate URLSession:session dataTask:(NSURLSessionDataTask *)task didReceiveData:data];
    objc_setAssociatedObject(task, &kPassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// YES when the data is not the delegate's to see yet: dropped for a blocked request, kept back for
// one whose reply is rewritten when it finishes.
static BOOL holds(NSURLSessionTask *task, NSData *data) {
    if (objc_getAssociatedObject(task, &kPassKey)) return NO;
    switch (classify(task.currentRequest.URL)) {
        case SGNetBlock:
            return YES;
        case SGNetPatch: {
            NSMutableData *buffer = objc_getAssociatedObject(task, &kBufferKey);
            if (!buffer) objc_setAssociatedObject(task, &kBufferKey, (buffer = [NSMutableData data]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [buffer appendData:data];
            return YES;
        }
        default:
            return NO;
    }
}

static void complete(id<NSURLSessionDataDelegate> delegate, NSURLSession *session, NSURLSessionTask *task, NSError *error, void (^finish)(NSError *)) {
    NSURL *url = task.currentRequest.URL;
    NSString *path = url.path.lowercaseString ?: @"";
    NSMutableData *buffer = objc_getAssociatedObject(task, &kBufferKey);
    objc_setAssociatedObject(task, &kBufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGAdBlockSawOne(@"Requests");
    switch (classify(url)) {
        case SGNetBlock:
            SGAdBlockCountOne(@"Requests");
            SGLog(@"answered %@ empty", path);
            deliver(delegate, session, task, blockedReply(path));
            finish(nil);
            return;
        case SGNetPatch:
            if (error) {
                finish(error);
                return;
            }
            // Nothing to rewrite: a body of no bytes. The delegate is told of a body either way, since a
            // completion with none hangs some readers.
            if (!buffer) {
                deliver(delegate, session, task, [NSData data]);
                finish(nil);
                return;
            }
            deliver(delegate, session, task, patched(url, buffer) ?: buffer);
            finish(nil);
            return;
        default:
            finish(error);
    }
}

%hook SPTDataLoaderService
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (!holds(task, data)) %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    complete((id)self, session, task, error, ^(NSError *passed) { %orig(session, task, passed); });
}
%end

%hook _TtC26Connectivity_HttpClientKit20HttpClientURLSession
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (!holds(task, data)) %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    complete((id)self, session, task, error, ^(NSError *passed) { %orig(session, task, passed); });
}
%end

// The C++ core's requests: most of Spotify's traffic, the access point lookup among it. Only its ad
// requests are touched. Each gets an empty 200 of the mod's own in place of the server's headers and
// body. A failed request keeps its error.
%hook SPTCoreURLSessionDataDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    NSURL *url = task.currentRequest.URL;
    if (ads && isAd(url, url.path.lowercaseString ?: @"")) {
        objc_setAssociatedObject(task, &kCoreAdKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/2.0" headerFields:@{}];
    }
    %orig(session, task, response, handler);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (!objc_getAssociatedObject(task, &kCoreAdKey) || objc_getAssociatedObject(task, &kPassKey)) %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!error && objc_getAssociatedObject(task, &kCoreAdKey)) {
        SGAdBlockSawOne(@"Requests");
        SGAdBlockCountOne(@"Requests");
        SGLog(@"answered the core's %@ empty", task.currentRequest.URL.path);
        deliver((id)self, session, task, [NSData data]);
    }
    %orig;
}
%end

%ctor {
    ads = SGHidden(SGKeyHideAds);
    if (!ads) return;
    %init;
    SGRequireClasses(@[@"SPTDataLoaderService", @"_TtC26Connectivity_HttpClientKit20HttpClientURLSession",
                       @"SPTCoreURLSessionDataDelegate"]);
}
