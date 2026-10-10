// AutoMix: Spotify's player core set to blend songs, per context. AutoMix.h says what Spotify 9.1.90 has.
//
// The preferences object is _TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation, whose -init is
// Swift's unavailable init (it traps), so it is never made here: it is the instance Spotify uses, noted when
// Spotify makes one (-initWithScheduler:), asks its service for it (-[CorePreferencesServiceImpl preferences]) or
// reads or writes crossfade or Automix through it, and asked of the service when only that was seen. Its six
// accessors are ObjC on Spotify's @objc protocol SPTPreferences, so Spotify's own settings rows call them through
// objc_msgSend and the hooks see them.
//
// Each time the player reports a new track or context (Shared/Player/PlayerState.h), the context decides: a
// playlist (Liked Songs among them), an album, a station or radio gets AutoMix's three values, anything else
// with Only playlists, albums and radio on gets back what Spotify's own settings held before AutoMix, and
// podcast episodes and audiobook chapters always do. Only a value that differs is written. Spotify applies a
// preference as it changes, as its own settings rows do, and the core picks the transition as the song nears
// its end, so the values set as a context starts hold for its first transition. What Spotify's settings held is
// kept the first time AutoMix writes (SGKeyAutoMixSpotifys); a change made in Spotify's own settings while AutoMix
// is on is kept there as Spotify's own, for the other contexts, and is written back when AutoMix goes off.
//
// While AutoMix is on at launch, the app's flags for Spotify's Crossfade and Automix rows
// (ios-feature-settings.crossfade_enabled, .automix_enabled, both on by default in 9.1.90) are forced on after
// an override from the All flags page, so a server switching a row off cannot hide what AutoMix sets.
// Threading: the hooks may run on any thread and only note the object; everything else runs on the main thread.
#import <os/lock.h>
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "AutoMix.h"

@interface _TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation : NSObject
- (BOOL)audioCrossfade;
- (NSInteger)audioCrossfadeTime;
- (BOOL)audioAutomix;
- (void)setAudioCrossfade:(BOOL)on;
- (void)setAudioCrossfadeTime:(NSInteger)milliseconds;
- (void)setAudioAutomix:(BOOL)on;
@end
typedef _TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation SGCorePrefs;

@interface _TtC31Preferences_CorePreferencesImpl26CorePreferencesServiceImpl : NSObject
- (id)preferences;
@end

static NSString *const kPrefsClass = @"_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation";
static NSString *const kServiceClass = @"_TtC31Preferences_CorePreferencesImpl26CorePreferencesServiceImpl";
static NSString *const kCrossfadeRow = @"ios-feature-settings.crossfade_enabled";
static NSString *const kAutomixRow = @"ios-feature-settings.automix_enabled";
static const NSInteger kDefaultSeconds = 6, kLeastSeconds = 1, kMostSeconds = 12;

typedef struct {
    BOOL crossfade;
    NSInteger ms;   // audio.crossfade.time_v2; 0 leaves the stored length alone
    BOOL automix;
} SGMix;

static os_unfair_lock sg_lock = OS_UNFAIR_LOCK_INIT;
static __weak SGCorePrefs *sg_prefs;
static __weak id sg_service;
// Set while the mod writes, so the setter hooks tell its writes from Spotify's own settings rows.
static BOOL sg_writing;

#pragma mark - the settings

static BOOL autoMixOn(void) {
    return SGFlag(SGKeyAutoMix, NO);
}

static SGAutoMixMode mode(void) {
    return SGInt(SGKeyAutoMixMode, SGAutoMixBeatMatched) == SGAutoMixCrossfade ? SGAutoMixCrossfade : SGAutoMixBeatMatched;
}

static NSInteger seconds(void) {
    return MAX(kLeastSeconds, MIN(kMostSeconds, SGInt(SGKeyAutoMixSeconds, kDefaultSeconds)));
}

NSString *SGAutoMixSummary(void) {
    if (!autoMixOn()) return @"Off";
    return mode() == SGAutoMixBeatMatched ? @"Beat-matched" : [NSString stringWithFormat:@"Crossfade · %ld s", (long)seconds()];
}

// Beat-matched keeps the crossfade on: it is what the core falls back to where two songs do not beat-match.
static SGMix autoMixValues(void) {
    return (SGMix){YES, seconds() * 1000, mode() == SGAutoMixBeatMatched};
}

#pragma mark - Spotify's own settings, kept

static NSDictionary *spotifys(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:SGKeyAutoMixSpotifys];
    return [stored isKindOfClass:NSDictionary.class] ? stored : nil;
}

static SGMix spotifysMix(NSDictionary *kept) {
    return (SGMix){[kept[@"crossfade"] boolValue], [kept[@"ms"] integerValue], [kept[@"automix"] boolValue]};
}

static void keepSpotifys(SGMix mix) {
    [NSUserDefaults.standardUserDefaults setObject:@{@"crossfade": @(mix.crossfade), @"ms": @(mix.ms), @"automix": @(mix.automix)}
                                            forKey:SGKeyAutoMixSpotifys];
}

static SGMix readMix(SGCorePrefs *prefs) {
    return (SGMix){[prefs audioCrossfade], [prefs audioCrossfadeTime], [prefs audioAutomix]};
}

// A change from Spotify's own settings row while AutoMix holds the kept values: it becomes Spotify's own.
static void spotifyWrote(void (^change)(SGMix *mix)) {
    if (sg_writing) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *kept = spotifys();
        if (!kept) return;
        SGMix mix = spotifysMix(kept);
        change(&mix);
        keepSpotifys(mix);
    });
}

#pragma mark - the preferences object

static BOOL usable(id prefs) {
    return [prefs respondsToSelector:@selector(audioCrossfade)] && [prefs respondsToSelector:@selector(audioCrossfadeTime)]
        && [prefs respondsToSelector:@selector(audioAutomix)] && [prefs respondsToSelector:@selector(setAudioCrossfade:)]
        && [prefs respondsToSelector:@selector(setAudioCrossfadeTime:)] && [prefs respondsToSelector:@selector(setAudioAutomix:)];
}

static void apply(void);

// Any thread. A new object is written to on the main thread, once the player has reported (see apply).
static void notePrefs(id prefs) {
    if (!prefs) return;
    os_unfair_lock_lock(&sg_lock);
    BOOL fresh = sg_prefs != prefs;
    if (fresh) sg_prefs = prefs;
    os_unfair_lock_unlock(&sg_lock);
    if (!fresh) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        SGLog(@"automix: Spotify's preferences %p", prefs);
        apply();
    });
}

static SGCorePrefs *prefs(void) {
    os_unfair_lock_lock(&sg_lock);
    SGCorePrefs *found = sg_prefs;
    id service = sg_service;
    os_unfair_lock_unlock(&sg_lock);
    if (!found && [service respondsToSelector:@selector(preferences)]) {
        found = [service preferences];
        os_unfair_lock_lock(&sg_lock);
        sg_prefs = found;
        os_unfair_lock_unlock(&sg_lock);
    }
    return usable(found) ? found : nil;
}

#pragma mark - writing

static void writeMix(SGCorePrefs *prefs, SGMix want, NSString *why) {
    SGMix now = readMix(prefs);
    BOOL length = want.ms > 0 && now.ms != want.ms;
    if (!length && now.crossfade == want.crossfade && now.automix == want.automix) return;
    sg_writing = YES;
    if (now.crossfade != want.crossfade) [prefs setAudioCrossfade:want.crossfade];
    if (length) [prefs setAudioCrossfadeTime:want.ms];
    if (now.automix != want.automix) [prefs setAudioAutomix:want.automix];
    sg_writing = NO;
    SGLog(@"automix: %@: crossfade %d, %ld ms, automix %d", why, want.crossfade, (long)(want.ms ?: now.ms), want.automix);
}

// 1 for a context AutoMix blends, 0 for one it leaves to Spotify's own settings, -1 while nothing has played.
static int covers(SPTPlayerState *state) {
    if (!state) return -1;
    NSString *track = SGURIString(state.track.URI) ?: @"";
    if ([track hasPrefix:@"spotify:episode:"] || [track hasPrefix:@"spotify:chapter:"] || [track hasPrefix:@"spotify:audiobook:"]) return 0;
    if (!SGEnabled(SGKeyAutoMixOnlyLists)) return 1;
    NSString *context = SGURIString(state.contextURI) ?: @"";
    for (NSString *prefix in @[@"spotify:playlist:", @"spotify:album:", @"spotify:station:", @"spotify:radio:"]) {
        if ([context hasPrefix:prefix]) return 1;
    }
    // spotify:user:<id>:playlist:<id>, the older form, and Liked Songs (spotify:user:<id>:collection, with an
    // artist's songs in it after it), but not Your Episodes, which is a collection too.
    if ([context hasPrefix:@"spotify:user:"] && [context containsString:@":playlist:"]) return 1;
    BOOL collection = [context hasPrefix:@"spotify:collection"] || ([context hasPrefix:@"spotify:user:"] && [context containsString:@":collection"]);
    return collection && ![context containsString:@"episode"] && ![context containsString:@"podcast"] ? 1 : 0;
}

// Nothing is read or written before the player has reported a state: at launch the main thread must not wait
// on Spotify's core (AGENTS.md), and until something plays there is no transition to set up anyway.
static void apply(void) {
    NSDictionary *kept = spotifys();
    BOOL on = autoMixOn();
    if ((!on && !kept) || !SGPlayerState()) return;
    SGCorePrefs *found = prefs();
    if (!found) return;
    if (!on) {
        // Off: Spotify's own settings back, once.
        writeMix(found, spotifysMix(kept), @"off, Spotify's own settings back");
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyAutoMixSpotifys];
        return;
    }
    int covered = covers(SGPlayerState());
    if (covered < 0) return;
    if (!kept) {
        SGMix mine = readMix(found);
        keepSpotifys(mine);
        kept = spotifys();
        SGLog(@"automix: kept Spotify's own settings: crossfade %d, %ld ms, automix %d", mine.crossfade, (long)mine.ms, mine.automix);
    }
    if (covered) writeMix(found, autoMixValues(), mode() == SGAutoMixBeatMatched ? @"beat-matched" : @"crossfade");
    else writeMix(found, spotifysMix(kept), @"not a playlist, album or radio, Spotify's own settings");
}

void SGAutoMixSettingsChanged(void) {
    apply();
}

#pragma mark - the player

@interface SGAutoMixFollower : NSObject <SGPlayerStateObserver>
@end

@implementation SGAutoMixFollower
- (void)playerStateDidChange:(SPTPlayerState *)state {
    apply();
}
@end

static SGAutoMixFollower *sg_follower;

#pragma mark - hooks

%hook _TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation
- (id)initWithScheduler:(id)scheduler {
    id made = %orig;
    notePrefs(made);
    return made;
}
- (BOOL)audioCrossfade {
    notePrefs(self);
    return %orig;
}
- (NSInteger)audioCrossfadeTime {
    notePrefs(self);
    return %orig;
}
- (BOOL)audioAutomix {
    notePrefs(self);
    return %orig;
}
- (void)setAudioCrossfade:(BOOL)on {
    notePrefs(self);
    %orig;
    spotifyWrote(^(SGMix *mix) { mix->crossfade = on; });
}
// Spotify's own slider writes its seconds times 1000; logged so a device log shows the unit too.
- (void)setAudioCrossfadeTime:(NSInteger)milliseconds {
    notePrefs(self);
    %orig;
    if (!sg_writing) SGLog(@"automix: Spotify's own settings set the crossfade to %ld", (long)milliseconds);
    spotifyWrote(^(SGMix *mix) { mix->ms = milliseconds; });
}
- (void)setAudioAutomix:(BOOL)on {
    notePrefs(self);
    %orig;
    spotifyWrote(^(SGMix *mix) { mix->automix = on; });
}
%end

%hook _TtC31Preferences_CorePreferencesImpl26CorePreferencesServiceImpl
// Only noted: its preferences are asked for once the player has reported, not as Spotify starts.
- (id)init {
    id made = %orig;
    os_unfair_lock_lock(&sg_lock);
    sg_service = made;
    os_unfair_lock_unlock(&sg_lock);
    return made;
}
- (id)preferences {
    id found = %orig;
    notePrefs(found);
    return found;
}
%end

%ctor {
    // The rows' flags, after an override; the running app answers from the switch as it was at launch.
    BOOL onAtLaunch = autoMixOn();
    SGRegisterFlagForcer(NO, ^id(NSString *key) {
        if (!onAtLaunch) return nil;
        return [key isEqualToString:kCrossfadeRow] || [key isEqualToString:kAutomixRow] ? @YES : nil;
    }, ^id(NSString *key) {
        if (!autoMixOn()) return nil;
        return [key isEqualToString:kCrossfadeRow] || [key isEqualToString:kAutomixRow] ? @YES : nil;
    });
    // Installed whatever the switch says: turning AutoMix on or off from the page applies at once, and off
    // gives Spotify's settings back, which needs the object as well. Until then the hooks only note it.
    %init;
    SGRequireClasses(@[kPrefsClass, kServiceClass]);
    sg_follower = [SGAutoMixFollower new];
    SGAddPlayerStateObserver(sg_follower);
}
