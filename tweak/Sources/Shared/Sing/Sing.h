// Sing: a song's vocals turned down while it plays, from a mic button on the redesigned player's lyrics
// (Redesigned/Lyrics/SGRSingButton.m) and the Sing page (Sing on Mod Settings' main page, and Lyrics > Karaoke),
// under either look: the work is on Spotify's sound.
//
//     SGSingModel.m       the voice model: downloaded, each file checked against its size and SHA-256, loaded; the
//                         light model made from it, and which of the two runs
//     SGSingLight.m       the light model: the full one's 6-bit palettes cut to 4 bits on the iPhone
//     SGSingLoader.m      the model in memory: a CPU copy, then a Neural Engine one beside it, each load with a deadline;
//                         the light model one Neural Engine copy alone
//     SGSingSeparator.m   the STFT around the model: two seconds in, their vocals out, on the faster copy in
//     SGSingEngine.m      Spotify's mixer pulled ahead of what plays, the vocals separated in the lead, mixed down
//                         and put where spatial voice holds them
//     Sing.x              the engine put between Spotify's mixer and its output (through Shared/Player/SpeedPitch.x's
//                         chain), Spotify's clock and seeks kept true to what plays, the heat, what Sing is doing,
//                         and the head's turn for spatial voice (Shared/HeadGestures' motion)
//     SingSettings.m      the Sing page, and Spatial voice's under it
//     SGSingCard.m        the Sing page's card: the song, Sing's state, the vocals and the rest traced live, the level
//     SGSpatialPreview.m  the Spatial voice page's preview: the voice in front of the listener on a field of dots,
//                         turned by the head the way the audio is
//
// The voice model is public and MIT licensed: Mel-Band RoFormer (Ju-Chiang Wang, Wei-Tsung Lu, Minz Won) with
// KimberleyJensen's vocal checkpoint, its spectral core exported for Core ML with two-second windows, from
// https://huggingface.co/My-Name-Is-Jeff/vitrine-sing's separator-ane.mlmodelc (App/About/Licenses.m carries its
// notice): Vitrine's export of that checkpoint for the Neural Engine (its layout (B, C, 1, S), 1x1 convolutions,
// attention per head, an RMSNorm that divides by the row's largest value first so half precision does not overflow),
// palettized to 6 bits. Every operation runs on the Neural Engine, and the CPU runs it too, more slowly. Its floor is
// iOS 18, the Core ML it was built with. No audio leaves the phone.
//
// The light model is Glassify's own and has no server: SGSingLight.m makes it on the iPhone from the full model, each
// weight's table of 64 values cut to 16 (4 bits) and the graph left as it is, 152 MB against 209 MB of weights, with
// slightly coarser vocals. It loads as one Neural Engine copy with no CPU copy beside it, so it takes about half the
// memory, and Voice model picks it (Auto, Full, Light). Either model can be kept without the other once the light one
// is made.
//
// Threading: main thread, but for what Sing.x's render side and the engine say.
#import <UIKit/UIKit.h>

@class SPTPlayerState;

// The mic: on and off at once, from the button or the Sing page; off until switched on.
#define SGKeySing @"spotifyglass.sing"
// Whether the redesign's lyrics show the mic in their corner; on until switched off (issue #12). Karaoke itself
// stays on its own switch, which this does not touch.
#define SGKeySingButton @"spotifyglass.sing.button"
extern NSNotificationName const SGSingButtonDidChangeNotification;
// The vocals' level, 0 (gone) through 1 (as the song has them) to 2 (the vocals alone) at the slider's top.
#define SGKeySingLevel @"spotifyglass.sing.level"
// Keeps the model running on a hot iPhone, which otherwise lets it go from the thermal state Serious up.
#define SGKeySingIgnoreHeat @"spotifyglass.sing.ignoreHeat"
// Keeps the model through iOS's memory warnings, which otherwise let it go and stop Karaoke until the next song.
// Off until switched on: with it on, iOS may close Spotify instead.
#define SGKeySingIgnoreMemory @"spotifyglass.sing.ignoreMemory"
// Where the model runs: an index into SGSingComputeUnitNames(), Automatic (0: a Neural Engine copy beside the CPU's,
// where the iPhone has a Neural Engine) unless CPU only (1) is chosen. The GPU, Neural Engine and GPU and Neural Engine
// stored before (2-4), and the earlier key's every value, are Automatic now, carried over at launch.
#define SGKeySingComputeUnits @"spotifyglass.sing.runsOn"
#define SGKeySingComputeUnitsBefore @"spotifyglass.sing.computeUnits"
// Compiles the Neural Engine copy in the background after an install or an iOS update, with the mic off; on unless
// switched off.
#define SGKeySingPrepareAhead @"spotifyglass.sing.prepareAhead"
// Which voice model Karaoke runs, an index into SGSingVoiceModelNames(): Auto (0, until another is chosen) runs the light
// model, when it is made, on an iPhone with less than 8 GB of memory, or when the process has little memory left or the
// iPhone is hot (thermal state Serious up) as Karaoke starts, and the full one otherwise; Full (1) and Light (2) run that
// one, and the other only while it is the one on the iPhone. Light chosen with the full model in makes the light one.
#define SGKeySingVoiceModel @"spotifyglass.sing.voiceModel"
// Spatial voice: through headphones that track the head, the vocals stay in front as it turns; off until
// switched on, and at once.
#define SGKeySingSpatial @"spotifyglass.sing.spatial"
// Spatial voice's sound: how far ahead the voice is (meters, 1.5 until set), how much of it is the room (percent, 25
// until set), how long a head that stays turned takes to bring it back in front (seconds, 5 until set), and how wide
// the instruments spread (percent, 110 until set).
#define SGKeySingSpatialDistance @"spotifyglass.sing.spatial.distance"
#define SGKeySingSpatialRoom @"spotifyglass.sing.spatial.room"
#define SGKeySingSpatialFront @"spotifyglass.sing.spatial.front"
#define SGKeySingSpatialWidth @"spotifyglass.sing.spatial.width"

// Posted on the main thread whenever what Sing is doing, or its model's download, changes.
extern NSString *const SGSingChangedNotification;

typedef NS_ENUM(NSInteger, SGSingState) {
    SGSingStateUnavailable,   // the OS or the iPhone cannot run it (SGSingMissing says which)
    SGSingStateNoModel,       // the model is not downloaded
    SGSingStateDownloading,
    SGSingStateOff,
    SGSingStatePreparing,     // the model loading (only while Spotify is active), which Core ML specializes the first time
    SGSingStateWaiting,       // on, the model ready, Spotify not playing through the chain yet; or resting at As sung
                              // (SGSingStatusText says which)
    SGSingStateBuffering,     // on, the lead filling: what plays is dry
    SGSingStateSinging,       // on, the vocals down
    SGSingStateBehind,        // on, the model slower than the song: what plays is dry until it catches up
    SGSingStateHot,           // on, held for the heat, the model let go
    SGSingStateFailed,        // the model or Spotify's output failed (SGSingStatusDetail says how)
};
SGSingState SGSingCurrentState(void);
// What Sing is doing, a few words for the button's label and the page, and what it means where there is
// more to say (what is missing, why it failed), nil otherwise.
NSString *SGSingStatusText(void);
NSString *SGSingStatusDetail(void);
// Which of the OS, the voice model or the iPhone Sing was built for is missing; nil when none is.
NSString *SGSingMissing(void);

BOOL SGSingOn(void);
void SGSetSingOn(BOOL on);
float SGSingLevel(void);
void SGSetSingLevel(float level);
// The loudness (RMS) of the vocals and of the rest of the song as heard, per tenth of a second, for the `count`
// tenths up to what plays now, oldest first; NO, and nothing written, unless Sing is turning the vocals down now.
// Reading them says a page shows them: with the vocals as sung and Spatial voice off, Sing separates only while
// they are read (at least once a second), and otherwise rests and plays the song as it is.
BOOL SGSingReadLevels(float *vocals, float *rest, int count);
// A level as the slider reads it out: Gone, a percentage, As sung, Backing and a percentage, Vocals only.
NSString *SGSingLevelText(double level);
void SGSetSingIgnoresHeat(BOOL ignores);
// Seconds of Spotify's sound Sing holds ahead of what plays now, as the render thread left it; 0 when none.
double SGSingHeldLead(void);
// The seconds to take off `state`'s position for what is heard: the lead held when the clock's line `state` is on
// began (its first state seen), less what Sing dropped since (SGSingEngineLeadAt). Every correction for the lead reads
// this; 0 while Sing never ran.
double SGSingLeadOf(SPTPlayerState *state);
// Whether this iPhone runs Sing and reads headphone motion, which spatial voice needs.
BOOL SGSingSpatialAvailable(void);
BOOL SGSingSpatial(void);
// Stored, the motion's permission asked for when it goes on, and applied at once.
void SGSetSingSpatial(BOOL on);
// Distance, Room, Back in front and Instruments width: read as stored, and stored and applied at once. Any thread for
// the getters.
double SGSingSpatialDistance(void);
double SGSingSpatialRoom(void);
double SGSingSpatialFront(void);
double SGSingSpatialWidth(void);
void SGSetSingSpatialSound(double meters, double roomPercent, double frontSeconds, double widthPercent);

// The top of the Spatial voice page: listener and voice on a field of dots seen from behind the head, which
// follows the head through HeadGestures' motion while it is on screen and the motion is allowed, and idles
// otherwise, a line under it saying which.
@interface SGSpatialPreview : UIView
// Reads the switch and the motion's permission again.
- (void)refresh;
@end
// Spatial voice's page, its preview and its switch: under Sing's page, and on Mod Settings' main page under Sing.
UIViewController *SGSpatialVoiceSettingsPage(void);
// Runs on changed: the Neural Engine copy loaded or dropped as it now says, the CPU's kept.
void SGSingComputeUnitsChanged(void);
// Voice model changed (stored by its row): the light model made if Light wants it, and the model in memory replaced
// when it is not one the choice runs.
void SGSingVoiceModelChanged(void);
// Which model runs and where, for the Karaoke page: "Light model on the Neural Engine", "Full model on the CPU", ...
NSString *SGSingModelInUseText(void);
// What the main page's Sing row reads out: On, Off, or how far the model has come.
NSString *SGSingSummary(void);
UIViewController *SGSingSettingsPage(void);

#pragma mark - the model (SGSingModel.m)

typedef NS_ENUM(NSInteger, SGSingModelState) {
    SGSingModelMissing,
    SGSingModelDownloading,   // with no model to run meanwhile (the old one runs on through its update's download, the
                              // light one through the full one's)
    SGSingModelReady,         // on the phone, every file checked: this model, the light one, or the old one until its
                              // update is in
};
SGSingModelState SGSingModelCurrentState(void);
// 0 to 1 while downloading.
double SGSingModelProgress(void);
// Whether the download is held until the iPhone is online again, or on Wi-Fi unless cellular is allowed.
BOOL SGSingModelWaitingForNetwork(void);
// The download over cellular and Low Data Mode networks too, which it otherwise waits out; for this launch.
void SGSingDownloadModelOverCellular(void);
BOOL SGSingModelOverCellular(void);
// The weights' checksum being read, the download's last step.
BOOL SGSingModelChecking(void);
// Bytes a stopped download kept for the next one to carry on from; 0 when there are none.
long long SGSingModelPausedBytes(void);
// The last download's failure, nil when there was none (too little free space among them: the download does not
// start then).
NSString *SGSingModelError(void);
// The download's size, for the row that offers it.
NSString *SGSingModelSizeText(void);
void SGSingDownloadModel(void);
void SGSingCancelModelDownload(void);
void SGSingDeleteModel(void);
// The compiled model's folder Karaoke would load now: the one Voice model picks (Auto deciding at this moment) of
// separator-ane.mlmodelc once it is downloaded and checked and separator-light.mlmodelc once it is made, else the old
// model (separator.mlmodelc) where it is still on the iPhone, else nil. On a FLEX build a copy put in Application
// Support/Vitrine/Sing/dev/ by hand comes first, unchecked.
NSURL *SGSingModelURL(void);
// The model is the old one: it runs on the CPU alone, and the download is its update.
BOOL SGSingModelUpdateAvailable(void);
// That update downloading (SGSingModelProgress and the rest say how far).
BOOL SGSingModelUpdateDownloading(void);
// The size of the model on the iPhone now, for the row that removes it.
NSString *SGSingModelInUseSizeText(void);
// Deletes what the old model's download left, and the old model (separator.mlmodelc) itself once separator-ane.mlmodelc
// is in, logging the space freed; from any thread, at launch and as the download ends.
void SGSingRemoveOldModel(void);
NSArray<NSString *> *SGSingComputeUnitNames(void);
// The full model alone, whatever the light one: Downloading while its download runs, Ready once it (or a FLEX build's
// dev copy) is on the iPhone, Missing with only the old model.
SGSingModelState SGSingFullModelState(void);
// Deletes the full model, the old one and what a download kept, the light model left; stops the light model being made.
void SGSingDeleteFullModel(void);

typedef NS_ENUM(NSInteger, SGSingVoiceModel) {
    SGSingVoiceModelAuto,
    SGSingVoiceModelFull,
    SGSingVoiceModelLight,
};
NSArray<NSString *> *SGSingVoiceModelNames(void);
SGSingVoiceModel SGSingVoiceModelChoice(void);
// Why Auto would run the light model now (the memory, what is left of it, the heat), nil when it would run the full one.
NSString *SGSingAutoLightReason(void);
// Whether `url` is the light model's folder.
BOOL SGSingModelIsLight(NSURL *url);
// "Light model", "Full model", "Old model" or "Dev model", for the page and the log.
NSString *SGSingModelName(NSURL *url);
// Whether `url` is a model on the iPhone that Voice model lets Karaoke run now: a model loaded under Auto stays while it is
// there, whichever Auto would pick next.
BOOL SGSingModelAllows(NSURL *url);

// The light model (SGSingLight.m), made on the iPhone from the full one.
typedef NS_ENUM(NSInteger, SGSingLightState) {
    SGSingLightNeedsFull,   // not made, and the full model it is made from is not on the iPhone
    SGSingLightMissing,     // not made, the full model in: it can be
    SGSingLightMaking,
    SGSingLightReady,
};
SGSingLightState SGSingLightCurrentState(void);
// 0 to 1 while it is made.
double SGSingLightProgress(void);
// Why the last one was not made, nil when it was or was stopped.
NSString *SGSingLightError(void);
// Its size on the iPhone, about 152 MB.
NSString *SGSingLightSizeText(void);
// Makes it on a utility queue from the full model, into a staging folder moved into place when it is whole; a stop or a
// closed app leaves nothing, and the next one starts from scratch.
void SGSingMakeLightModel(void);
// Makes it when Light is chosen and the full model is in: as Light is chosen, as the full model's download ends, and
// when Spotify comes to the front (a conversion cut off by a closed app).
void SGSingMakeLightModelIfChosen(void);
void SGSingCancelLightModel(void);
void SGSingDeleteLightModel(void);
// Whether this OS can load the model (iOS 18). Memory is checked as the model loads (SGSingLoader.m).
BOOL SGSingOSSupported(void);
