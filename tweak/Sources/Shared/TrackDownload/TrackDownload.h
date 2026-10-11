// Download one song: Spotify's own offline download for a single track, not its album or a playlist. The song
// goes into Spotify's encrypted offline cache the way a downloaded playlist's songs do, under the account's own
// Premium; nothing leaves the app.
//
// Spotify's core keeps offline state per track already (spotify.offline_esperanto.proto.Offline: AddDownload takes
// one URI, GetItems answers per track), and the app reaches it through SPTOfflineManagerImplementation (9.1.90):
// -makeEntityAvailableOfflineWithURL: adds an entity, -resetEntityOfflineAvailabilityWithURL: takes it back out,
// -stateForTrackWithURL: reads a track's state, and SPTOfflineSyncStatusHelper's -isConsideredDownloaded: reads that
// state the way Spotify's own download buttons do. The UI only offers the entity kinds Spotify does; the call is
// handed a track URI instead.
//
// The manager is made deep in Spotify's dependency graph with C++ arguments, so it is not created here: it is the
// instance Spotify uses, noted as it is made (its -setScheduler: and -setObserversByURL:) or the first time Spotify asks it
// anything (any download button or offline badge does).
//
// Threading: main thread only.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SGTrackDownload) {
    SGTrackDownloadUnavailable,   // no manager seen yet, or not a track
    SGTrackDownloadNone,
    SGTrackDownloadPending,       // asked for, not complete yet
    SGTrackDownloadDone,
};

SGTrackDownload SGTrackDownloadState(NSString *trackURI);
// Asks Spotify to download the track, or to remove its download. A no-op while the state is Unavailable.
void SGTrackDownloadAdd(NSString *trackURI);
void SGTrackDownloadRemove(NSString *trackURI);
