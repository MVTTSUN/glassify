#import "Core/SGCore.h"
#import "TrackDownload.h"

@interface SPTOfflineManagerImplementation : NSObject
- (void)makeEntityAvailableOfflineWithURL:(NSURL *)url;
- (void)resetEntityOfflineAvailabilityWithURL:(NSURL *)url;
- (NSUInteger)stateForTrackWithURL:(NSURL *)url;
- (NSUInteger)availabilityForEntityWithURL:(NSURL *)url;
@end

@interface SPTOfflineSyncStatusHelper : NSObject
- (BOOL)isConsideredDownloaded:(NSInteger)state;
@end

static __weak SPTOfflineManagerImplementation *sg_manager;
// URIs asked for in this launch, so a track the core is still resolving reads Pending rather than None.
static NSMutableSet<NSString *> *sg_asked;

static NSURL *trackURL(NSString *uri) {
    return [uri hasPrefix:@"spotify:track:"] ? [NSURL URLWithString:uri] : nil;
}

static void note(SPTOfflineManagerImplementation *manager) {
    if (sg_manager == manager) return;
    sg_manager = manager;
    SGLog(@"track download: offline manager %p", manager);
}

%hook SPTOfflineManagerImplementation
// Set while the manager is made (9.1.90's initWithScheduler:offlineManager:syncManager:metadataModel: stores both), so
// it is noted at launch, before anything of Spotify's asks it about a download.
- (void)setScheduler:(id)scheduler {
    note(self);
    %orig;
}
- (void)setObserversByURL:(id)observers {
    note(self);
    %orig;
}
- (NSUInteger)availabilityForEntityWithURL:(NSURL *)url {
    note(self);
    return %orig;
}
- (NSUInteger)stateForTrackWithURL:(NSURL *)url {
    note(self);
    return %orig;
}
- (void)addObserver:(id)observer forURL:(NSURL *)url entity:(id)entity {
    note(self);
    %orig;
}
- (void)addObserver:(id)observer forURL:(NSURL *)url entity:(id)entity queue:(id)queue {
    note(self);
    %orig;
}
%end

SGTrackDownload SGTrackDownloadState(NSString *trackURI) {
    NSURL *url = trackURL(trackURI);
    SPTOfflineManagerImplementation *manager = sg_manager;
    if (!url || !manager) return SGTrackDownloadUnavailable;
    NSUInteger state = [manager stateForTrackWithURL:url];
    static SPTOfflineSyncStatusHelper *helper;
    if (!helper) helper = [objc_getClass("SPTOfflineSyncStatusHelper") new];
    if ([helper respondsToSelector:@selector(isConsideredDownloaded:)] && [helper isConsideredDownloaded:(NSInteger)state]) return SGTrackDownloadDone;
    if ([sg_asked containsObject:trackURI]) return SGTrackDownloadPending;
    // Any state but the first (not available offline) is Spotify working on it: waiting, downloading, an error.
    return state ? SGTrackDownloadPending : SGTrackDownloadNone;
}

void SGTrackDownloadAdd(NSString *trackURI) {
    NSURL *url = trackURL(trackURI);
    SPTOfflineManagerImplementation *manager = sg_manager;
    if (!url || !manager) return;
    if (!sg_asked) sg_asked = [NSMutableSet set];
    [sg_asked addObject:trackURI];
    SGLog(@"track download: add %@ (state %lu)", trackURI, (unsigned long)[manager stateForTrackWithURL:url]);
    [manager makeEntityAvailableOfflineWithURL:url];
}

void SGTrackDownloadRemove(NSString *trackURI) {
    NSURL *url = trackURL(trackURI);
    SPTOfflineManagerImplementation *manager = sg_manager;
    if (!url || !manager) return;
    [sg_asked removeObject:trackURI];
    SGLog(@"track download: remove %@", trackURI);
    [manager resetEntityOfflineAvailabilityWithURL:url];
}

%ctor {
    %init;
    SGRequireClasses(@[@"SPTOfflineManagerImplementation", @"SPTOfflineSyncStatusHelper"]);
}
