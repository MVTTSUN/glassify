// Player redesign: the DJ plays in the redesigned player, with its look and its ⋯ menu.
//
// Spotify lays its player out by a mode (PlayerFree.x): the modes are asked in turn by their identifiers,
// -[SPTNowPlayingMode isActiveFor:productState:], and the first that answers YES lays the player out. In 9.1.90
// the DJ is a mode of its own, Endless_DJMusicImpl.DJMNowPlayingMode, identifier 2 (its -identifier returns 2 at
// 0x101f17f34), asked long before NowPlayingMusicPremiumMode (11, whose isActiveFor: returns YES at 0x105615610).
// It builds its own units from its own module (DJMHeaderElementsUnitViewController, DJMHeadUnitViewController,
// DJMInformationUnitViewController, DJMDurationElementsUnit, DJMFooterUnitViewController), its ⋯ opens its own
// DJMContextMenuPresenter, and none of the redesign's hooks reach them: they are on NowPlaying_ModesImpl's units.
// So the DJ came in as Spotify's own player over the redesign's field.
//
// While the redesign runs the DJ mode stands aside, as the Reinvented Free mode does, and the DJ's tracks fall
// to the music mode for the account, built from the units the redesign styles: its header, controls, footer and
// the system ⋯ menu. The DJ button of its own player goes with its units, so its jump comes to the ⋯ menu
// (PlayerMenu.m): Endless_AIDJAPI.SPTAIDJService's provideJumpableWithControlling: builds the jumpable from the
// player alone, and jumpWithCompletion: is the DJ's own jump (Headers/SPTAIDJService.h). The service is
// remembered from Spotify's own calls on it (playlistURI: 21 objc callers, providePredicates: 11,
// provideJumpableWithControlling: 6).
//
// Read from the binary only; no DJ player has been recorded in trees/clean/.
#import "Core/SGCore.h"
#import "Headers/SPTAIDJService.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Player.h"

static __weak id<SPTAIDJService> sg_service;
// What the DJ mode last answered, for when the service has not been seen; set on Spotify's thread.
static volatile BOOL sg_modeWanted;
// Held until the jump answers: nothing else keeps the jumpable alive.
static id<SPTAIDJJumpable> sg_jumping;

static void remember(id service) {
    if (service && !sg_service) sg_service = service;
}

BOOL SGRPlayerDJPlaying(void) {
    id<SPTAIDJService> service = sg_service;
    SPTPlayerState *state = SGPlayerState();
    if (state && [service respondsToSelector:@selector(providePredicates)]) {
        id<SPTAIDJPredicates> predicates = [service providePredicates];
        if ([predicates respondsToSelector:@selector(isFromAIDJWithState:)]) return [predicates isFromAIDJWithState:state];
    }
    return sg_modeWanted;
}

BOOL SGRPlayerDJCanJump(void) {
    return [sg_service respondsToSelector:@selector(provideJumpableWithControlling:)] && SGKaraokePlayer() != nil;
}

void SGRPlayerDJJump(void) {
    id<SPTAIDJService> service = sg_service;
    id player = SGKaraokePlayer();
    if (!player || ![service respondsToSelector:@selector(provideJumpableWithControlling:)]) return;
    id<SPTAIDJJumpable> jumpable = [service provideJumpableWithControlling:player];
    if (![jumpable respondsToSelector:@selector(jumpWithCompletion:)]) return;
    sg_jumping = jumpable;
    [jumpable jumpWithCompletion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sg_jumping == jumpable) sg_jumping = nil;
            SGLog(@"redesign player: DJ jump %@", error ? error.localizedDescription : @"done");
        });
    }];
}

%hook _TtC19Endless_DJMusicImpl17DJMNowPlayingMode
- (BOOL)isActiveFor:(id)playerState productState:(id)productState {
    BOOL active = %orig;
    sg_modeWanted = active;
    static dispatch_once_t once;
    if (active) dispatch_once(&once, ^{ SGLog(@"redesign player: DJ mode declined, the music mode takes the DJ"); });
    return NO;
}
%end

%hook _TtC16Endless_AIDJImpl11AIDJService
- (id)playlistURI {
    remember(self);
    return %orig;
}
- (id)providePredicates {
    remember(self);
    return %orig;
}
- (id)provideJumpableWithControlling:(id)player {
    remember(self);
    return %orig;
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGEnabled(SGRKeyPlayerDJ)) return;
    %init;
    SGRequireClasses(@[@"_TtC19Endless_DJMusicImpl17DJMNowPlayingMode", @"_TtC16Endless_AIDJImpl11AIDJService"]);
}
