// Spotify's DJ service (Endless_AIDJImpl.AIDJService, the Swift protocol Endless_AIDJAPI.SPTAIDJService), as
// 9.1.90's protocol lists type it. provideJumpableWithControlling: builds a jumpable from the player alone
// (a CompositeJumpable of a SignalJumpable and a SeekingJumpable); jumpWithCompletion: is the DJ's own
// "switch it up", the jump the DJ button asks for.
#import <Foundation/Foundation.h>

@protocol SPTAIDJJumpable <NSObject>
- (void)jumpWithCompletion:(void (^)(NSError *error))completion;
@end

@protocol SPTAIDJPredicates <NSObject>
// The state's context is the DJ's.
- (BOOL)isFromAIDJWithState:(id)state;
@end

@protocol SPTAIDJService <NSObject>
- (id<SPTAIDJPredicates>)providePredicates;
- (id<SPTAIDJJumpable>)provideJumpableWithControlling:(id)player;
@end
