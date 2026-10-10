// Spotify Connect's own volume and whether Spotify plays on another device, as 9.1.90's protocol lists
// type them (the extended method types of SPTConnectVolumeAPI and SPTConnectAggregatorLegacyAPI).
//
// SPTConnectVolumeAPI is Connect_VolumeImpl.VolumeImpl: the volume of the device playing, 0 to 1 (the device
// picker clamps its slider's value to that range before it sets it), and its observers, held as
// SPTConnectVolumeObserver (connectVolumeDidChangeToValue:, remoteMediaSessionVolumeDidChangeToValue:).
// SPTConnectAggregatorLegacyAPI is Connect_AggregatorImpl.ConnectAggregatorManager, whose state observers are
// SPTConnectAggregatorStateObserver (aggregator:didUpdateAggregatorState:).
#import <Foundation/Foundation.h>

@protocol SPTConnectVolumeAPI <NSObject>
@property (nonatomic, readonly) double connectVolume;
- (void)add:(id)observer;
- (void)remove:(id)observer;
// The device picker's own call (Connect_DevicePickerUIImpl.VolumeAPIUpdater): `previous` is connectVolume as read
// just before, `reason` names the caller for Spotify's log. NO when the volume loop did not take it.
- (BOOL)setVolume:(double)volume assumingPreviousVolume:(double)previous reason:(NSString *)reason;
@end

@protocol SPTConnectAggregatorLegacyAPI <NSObject>
- (BOOL)isPlayingRemotely;
- (void)addStateObserver:(id)observer;
@end
