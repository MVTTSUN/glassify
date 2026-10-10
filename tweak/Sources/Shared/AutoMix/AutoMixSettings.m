// The AutoMix page, opened from the Player page under either look: the switch, how songs are blended, the
// crossfade's length and where AutoMix works. Everything but the two flags of Spotify's own rows applies at once
// (SGAutoMixSettingsChanged writes Spotify's preferences for the context playing).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "AutoMix.h"

static NSString *const kInfo = @"Spotify's own player blends the songs: AutoMix turns its Crossfade and Automix on for the music "
    @"you choose below and gives Spotify's own settings back everywhere else and when it is off.";

UIViewController *SGAutoMixSettingsPage(void) {
    void (^changed)(BOOL) = ^(BOOL on) { SGAutoMixSettingsChanged(); };

    SGModRow *on = SGOptionRow(@"AutoMix", nil, SGKeyAutoMix);
    on.info = kInfo;
    on.changed = changed;

    SGModRow *mode = SGChoiceRow(@"Transitions", nil, SGKeyAutoMixMode, @[@"Beat-matched", @"Crossfade"], SGAutoMixBeatMatched);
    mode.choiceNotes = @[
        @"Spotify's Automix lines the next song's beat up with the one ending, where Spotify has analysed both and offers it. Other songs crossfade.",
        @"Every song fades into the next over the length set below.",
    ];
    mode.choiceFooter = @"Which songs Spotify can beat-match is decided by its servers, not by the app.";
    mode.chosen = ^(NSInteger index) { SGAutoMixSettingsChanged(); };
    mode.waitsOn = SGKeyAutoMix;

    SGModRow *length = SGSliderRow(@"Crossfade", nil, 1, 12, 1,
        ^double { return MAX(1, MIN(12, SGInt(SGKeyAutoMixSeconds, 6))); },
        ^(double value) {
            SGSetInt(SGKeyAutoMixSeconds, lround(value));
            SGAutoMixSettingsChanged();
        },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%ld s", lround(value)]; });
    length.waitsOn = SGKeyAutoMix;

    SGModRow *only = SGSwitchRow(@"Only playlists, albums and radio", nil, SGKeyAutoMixOnlyLists);
    only.changed = changed;
    only.waitsOn = SGKeyAutoMix;

    return [[SGModPage alloc] initWithTitle:@"AutoMix" intro:@"Applies at once." sections:@[
        SGNotedSection(nil, @[on, mode, length],
            @"Blends each song into the next. Beat-matched falls back to the crossfade where two songs do not match, so the length counts in both."),
        SGNotedSection(nil, @[only],
            @"On, AutoMix blends playlists (Liked Songs too), albums and radio, and autoplay after them; an artist's page, search "
            @"results and the like keep Spotify's own Crossfade and Automix settings. Off, it blends everything. Podcasts and "
            @"audiobooks are never mixed."),
    ] footer:@"While AutoMix is on it sets Spotify's own Crossfade and Automix settings each time music starts, and keeps what "
             @"you set there for the rest. Spotify's own Crossfade and Automix rows are kept on show from the next restart."];
}
