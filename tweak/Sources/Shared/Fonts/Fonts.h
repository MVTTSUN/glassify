// One font for the whole app (Fonts.x), chosen on the Appearance page under either look, a font file of the
// user's own as one of the choices (FontImport.m), and a family downloaded from Google Fonts as another
// (FontDownload.m).
#import <UIKit/UIKit.h>

#define SGKeyAppFont @"spotifyglass.font"
// The imported family: its files' names in Application Support/Vitrine/Font, and the family name read from them.
// SGKeyAppFontFile is the single file of an import from before families, moved to the list on first use.
#define SGKeyAppFontFiles @"spotifyglass.font.files"
#define SGKeyAppFontName @"spotifyglass.font.name"
#define SGKeyAppFontFile @"spotifyglass.font.file"
// The family chosen under More fonts, by its name ("Avenir Next").
#define SGKeyAppFontFamily @"spotifyglass.font.family"
// The downloaded family chosen, by its name in the download catalog ("Inter").
#define SGKeyAppFontDownload @"spotifyglass.font.download"

typedef NS_ENUM(NSInteger, SGAppFont) {
    SGAppFontSpotify,   // Spotify's own, untouched
    SGAppFontSystem,    // San Francisco
    SGAppFontRounded,   // SF Rounded
    SGAppFontSerif,     // New York
    SGAppFontMono,      // SF Mono
    SGAppFontCustom,    // the family imported from Files
    SGAppFontFamily,    // a family iOS carries, named by SGKeyAppFontFamily
    SGAppFontDownloaded,   // a family downloaded from Google Fonts, named by SGKeyAppFontDownload
};

SGAppFont SGAppFontChosen(void);
NSArray<NSString *> *SGAppFontNames(void);   // the five built in, by SGAppFont
NSArray<NSString *> *SGAppFontFamilies(void);   // More fonts: the families this iPhone has of a fixed few
// Registers the imported files with Core Text for this process and answers the family name, or nil when no
// file is left or Core Text will not take them.
NSString *SGRegisterCustomFont(void);
// The family name the faces share, or nil when they differ, one has none, or there are none.
NSString *SGFontSingleFamily(NSArray<NSString *> *names);
// The family name of every face in a font file, "" for a face without one; empty when Core Text finds no font.
NSArray<NSString *> *SGFontFamiliesIn(NSURL *url);
// Application Support/Vitrine/Font, where imported and downloaded families are kept.
NSURL *SGFontFolder(void);

// Download (FontDownload.m): a fixed catalog of Google Fonts families, fetched from the google/fonts repository on
// GitHub into SGFontFolder()/Downloaded/<directory>/, one folder a family, and registered again at each launch.
NSArray<NSString *> *SGDownloadableFonts(void);   // the catalog's names, in order
BOOL SGFontDownloaded(NSString *name);
NSString *SGFontDownloadSize(NSString *name);   // "856 KB", what a download of it fetches
BOOL SGAnyFontDownloaded(void);
// Main thread. Progress from 0 to 1 while it runs, then done with the family name Core Text read from the files, or
// nil when a file failed or is no font. A family already downloading is not asked for again.
void SGDownloadFont(NSString *name, void (^progress)(double fraction), void (^done)(NSString *family));
// The share fetched of a family downloading, or a negative number when it is not.
double SGFontDownloadProgress(NSString *name);
// Registers a downloaded family's files with Core Text for this process, once, and answers its family name, or nil
// when it is not downloaded or Core Text will not take it.
NSString *SGRegisterDownloadedFont(NSString *name);
// The family's files unregistered and deleted (every family's for nil); Spotify's font comes back if it was chosen.
void SGDeleteDownloadedFont(NSString *name);

@class SGModRow;
NSArray<SGModRow *> *SGAppFontRows(void);   // the Font row, opening the page of choices
