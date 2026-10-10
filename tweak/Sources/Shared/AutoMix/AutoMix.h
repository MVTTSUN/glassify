// AutoMix (Mod Settings > Player > AutoMix), under either look: each song blended into the next on playlists,
// albums and radio, beat-matched or as a crossfade. It is Spotify's own player core doing the blending: the mod
// only sets the core's preferences per context, and builds no mixer of its own.
//
//     AutoMix.x           Spotify's preferences object found, the core's three preferences written as each context
//                         starts, what Spotify's own settings held before kept and given back, and the flags that keep
//                         Spotify's own Crossfade and Automix rows on show
//     AutoMixSettings.m   the AutoMix page
//
// What Spotify 9.1.90 has (strings and disassembly of its binary):
// - Crossfade: -[SPTPreferencesImplementation setAudioCrossfade:] and -setAudioCrossfadeTime: write the core's
//   prefs audio.crossfade_v2 and audio.crossfade.time_v2 through -prefsSetBool:val: / -prefsSetInt:val:, and the
//   time is in milliseconds: Spotify's own slider writes its seconds times 1000 and its readers divide by 1000.
// - Automix: -setAudioAutomix: writes the core's audio.automix. With it on, the core works out a transition for
//   each pair of songs (automix: calculateAutoTransition, presets PRESET_TYPE_BEATMATCHED_FADE and _CUT) from
//   the songs' beats and cue points, and falls back to the crossfade where the two do not beat-match ("Using
//   fallback transition due to low beatmatchability", "Using normal crossfade fallback transition").
// - Where the core offers Automix is its own remote config (core-automix.automix_enabled, and core-player's
//   enable_auto_transitions_everywhere, enable_heuristic_transitions and automix_mode_for_user_playlists), which
//   the C++ core resolves from the account's config itself. The mod's flag registry reaches only the app's
//   provider (ios-…), so those stay Spotify's: Beat-matched mixes where Spotify's server offers it and crossfades
//   everywhere else.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>

// The switch, off until switched on. Read as it is used, so it applies at once.
#define SGKeyAutoMix @"spotifyglass.automix"
// How songs are blended, an SGAutoMixMode.
#define SGKeyAutoMixMode @"spotifyglass.automix.mode"
// The crossfade's length in whole seconds, 1 to 12 (Spotify's own range), 6 unless set.
#define SGKeyAutoMixSeconds @"spotifyglass.automix.seconds"
// AutoMix on playlists, albums and radio alone, on until switched off; off, on everything Spotify plays.
#define SGKeyAutoMixOnlyLists @"spotifyglass.automix.onlyLists"
// What Spotify's own settings held before AutoMix took them over: a dictionary of crossfade, ms and automix.
#define SGKeyAutoMixSpotifys @"spotifyglass.automix.spotifys"

typedef NS_ENUM(NSInteger, SGAutoMixMode) {
    SGAutoMixBeatMatched,   // Spotify's Automix, the crossfade where it cannot mix
    SGAutoMixCrossfade,     // the crossfade alone
};

// The row's readout on the Player page: Off, Beat-matched or Crossfade with its length.
NSString *SGAutoMixSummary(void);
// Writes the settings into Spotify's preferences now, for the context playing; the page calls it on every change.
void SGAutoMixSettingsChanged(void);
UIViewController *SGAutoMixSettingsPage(void);
