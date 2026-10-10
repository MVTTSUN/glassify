// Player redesign: Spotify Connect's own volume, for the volume row (PlayerVolume.m) while Spotify plays on
// another device. MPVolumeView is this iPhone's volume; the speaker's is Spotify's, set the way its device
// picker sets it.
//
// From the 9.1.90 binary (Headers/SPTConnectVolumeAPI.h):
//   Connect_VolumeImpl.VolumeImpl conforms to SPTConnectVolumeAPI: connectVolume (0 to 1), add:/remove: of
//     SPTConnectVolumeObserver, setVolume:assumingPreviousVolume:reason:. The device picker's VolumeAPIUpdater
//     clamps its value to 0...1 and calls it with connectVolume as the previous volume and "DevicePickerUIImpl"
//     as the reason (the objc stub at 0x109bac6b0, called from 0x103bd82f4); the hardware buttons' path passes
//     "volumeUpPressed" and "volumeDownPressed".
//   Connect_AggregatorImpl.ConnectAggregatorManager conforms to SPTConnectAggregatorLegacyAPI: isPlayingRemotely
//     (22 objc callers), addStateObserver: of SPTConnectAggregatorStateObserver.
// Neither is reachable from a view, so each is remembered from the first call Spotify makes on it through
// objc_msgSend (its callers hold the protocol, so every call does): add: and connectVolume on the volume,
// addObserver:, addStateObserver: and isPlayingRemotely on the aggregator. Until both are seen the row stays
// the system's.
//
// The observer of the mod's takes both protocols at runtime (class_addProtocol with the runtime's own
// protocols, so no second definition of them goes into the dylib) and moves every call onto the main queue.
//
// Threading: the hooks run on any thread and only store weak references; everything else is main thread.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Headers/SPTConnectVolumeAPI.h"
#import "Player.h"

NSString *const SGRConnectVolumeDidChangeNotification = @"SGRConnectVolumeDidChangeNotification";

// Spotify's own reason for the device picker's slider is "DevicePickerUIImpl"; the mod names itself.
static NSString *const kReason = @"GlassifyPlayerVolume";
// Spotify drops a set that comes too soon after the last ("Not sending setVolume because too soon"): a drag
// sends at most this often, and the value it ends on is sent again once if the device did not take it.
static const NSTimeInterval kSendInterval = 0.12, kSettleCheck = 0.6;

static __weak id<SPTConnectVolumeAPI> sg_volume;
static __weak id<SPTConnectAggregatorLegacyAPI> sg_aggregator;

static void remember(__weak id *slot, id object) {
    if (object && !*slot) *slot = object;
}

#pragma mark - the observer

@interface SGRConnectVolumeObserver : NSObject
@end

@implementation SGRConnectVolumeObserver

static void changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SGRConnectVolumeDidChangeNotification object:nil];
    });
}

- (void)connectVolumeDidChangeToValue:(double)value {
    changed();
}

- (void)remoteMediaSessionVolumeDidChangeToValue:(double)value {
    changed();
}

- (void)aggregator:(id)aggregator didUpdateAggregatorState:(id)state {
    changed();
}

@end

static SGRConnectVolumeObserver *sg_observer;
static __weak id sg_observedVolume, sg_observedAggregator;

static SGRConnectVolumeObserver *observer(void) {
    if (sg_observer) return sg_observer;
    Class cls = SGRConnectVolumeObserver.class;
    for (NSString *name in @[@"SPTConnectVolumeObserver", @"SPTConnectAggregatorStateObserver"]) {
        Protocol *protocol = objc_getProtocol(name.UTF8String);
        if (protocol && !class_conformsToProtocol(cls, protocol)) class_addProtocol(cls, protocol);
    }
    sg_observer = [SGRConnectVolumeObserver new];
    return sg_observer;
}

BOOL SGRConnectVolumeObserve(void) {
    id<SPTConnectVolumeAPI> volume = sg_volume;
    id<SPTConnectAggregatorLegacyAPI> aggregator = sg_aggregator;
    if (volume && volume != sg_observedVolume && [volume respondsToSelector:@selector(add:)]) {
        sg_observedVolume = volume;
        [volume add:observer()];
        SGLog(@"redesign player: Connect volume observed (%@)", NSStringFromClass([volume class]));
    }
    if (aggregator && aggregator != sg_observedAggregator && [aggregator respondsToSelector:@selector(addStateObserver:)]) {
        sg_observedAggregator = aggregator;
        [aggregator addStateObserver:observer()];
        SGLog(@"redesign player: Connect devices observed (%@)", NSStringFromClass([aggregator class]));
    }
    return sg_observedVolume != nil && sg_observedAggregator != nil;
}

#pragma mark - reading and setting

BOOL SGRConnectPlaysRemotely(void) {
    id<SPTConnectAggregatorLegacyAPI> aggregator = sg_aggregator;
    id<SPTConnectVolumeAPI> volume = sg_volume;
    if (!aggregator || !volume || ![aggregator respondsToSelector:@selector(isPlayingRemotely)]) return NO;
    return [aggregator isPlayingRemotely];
}

double SGRConnectVolume(void) {
    id<SPTConnectVolumeAPI> volume = sg_volume;
    if (![volume respondsToSelector:@selector(connectVolume)]) return NAN;
    return MIN(1, MAX(0, volume.connectVolume));
}

static double sg_target = NAN;
static CFTimeInterval sg_lastSend;
static BOOL sg_sendQueued;

static void send(void) {
    id<SPTConnectVolumeAPI> volume = sg_volume;
    if (isnan(sg_target) || ![volume respondsToSelector:@selector(setVolume:assumingPreviousVolume:reason:)]) return;
    sg_lastSend = CACurrentMediaTime();
    BOOL taken = [volume setVolume:sg_target assumingPreviousVolume:volume.connectVolume reason:kReason];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign player: Connect volume set to %.0f%% (%@)", sg_target * 100, taken ? @"taken" : @"not taken"); });
}

void SGRConnectSetVolume(double value, BOOL final) {
    sg_target = MIN(1, MAX(0, value));
    CFTimeInterval since = CACurrentMediaTime() - sg_lastSend;
    if (final || since >= kSendInterval) {
        send();
    } else if (!sg_sendQueued) {
        sg_sendQueued = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kSendInterval - since) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            sg_sendQueued = NO;
            send();
        });
    }
    if (!final) return;
    double target = sg_target;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSettleCheck * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sg_target != target || fabs(SGRConnectVolume() - target) < 0.01) return;
        send();
    });
}

#pragma mark - remembering Spotify's objects

%hook _TtC18Connect_VolumeImpl10VolumeImpl
- (void)add:(id)volumeObserver {
    remember((__weak id *)&sg_volume, self);
    %orig;
}
- (double)connectVolume {
    remember((__weak id *)&sg_volume, self);
    return %orig;
}
%end

%hook _TtC22Connect_AggregatorImpl24ConnectAggregatorManager
- (void)addObserver:(id)aggregatorObserver {
    remember((__weak id *)&sg_aggregator, self);
    %orig;
}
- (void)addStateObserver:(id)stateObserver {
    remember((__weak id *)&sg_aggregator, self);
    %orig;
}
- (BOOL)isPlayingRemotely {
    remember((__weak id *)&sg_aggregator, self);
    return %orig;
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGRPlayerVolumeOn()) return;
    %init;
    SGRequireClasses(@[@"_TtC18Connect_VolumeImpl10VolumeImpl", @"_TtC22Connect_AggregatorImpl24ConnectAggregatorManager"]);
}
