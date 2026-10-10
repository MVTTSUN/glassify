// Home redesign: its rows on the Appearance page, under the redesign's own (App/Pages.m). Both are read at launch.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Home.h"

NSArray<SGModRow *> *SGRHomeAppearanceRows(void) {
    return @[
        SGWithSymbol(SGSwitchRow(@"Top picks", @"Home's first shelf drawn large, as the Music app's Top Picks", SGRKeyHomeTopPicks), @"rectangle.stack"),
        SGWithSymbol(SGSwitchRow(@"Shortcuts on glass", @"Home's shortcuts on glass tinted by their covers", SGRKeyHomeGlassShortcuts), @"square.grid.2x2"),
    ];
}
