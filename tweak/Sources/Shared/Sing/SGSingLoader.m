#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <os/proc.h>
#endif
#import "Core/SGLog.h"
#import "SGSingLoader.h"
#import "SGSingSeparator.h"

// The CPU copy loaded in 0.9-5 s on an M4. The Neural Engine's first load compiles the model, which Core ML then
// keeps: 24-63 s on an M4 and 32-46 s on an iPhone 15 Pro, then 0.4-0.7 s; it has ten minutes.
double SGSingLoaderCPUDeadline = 120, SGSingLoaderNeuralDeadline = 600, SGSingLoaderKeepSeconds = 60;
// A CPU copy loads beside an abandoned load still out (or again after a memory warning) only with this much left: a
// second copy took 1.07-1.15 GB more of the process's footprint on an M4.
static const unsigned long long kCopyRoom = 1600ull * 1000 * 1000;
// The first CPU copy loads only with this much left, in place of a floor on the iPhone's memory. On an iPhone 15 Pro both
// copies warm added 0.1 GB of footprint (0.20 to 0.30 GB); the weights are mapped from disk and counted only as resident.
// 1 GB leaves the Neural Engine copy its 0.5 GB after the CPU's.
static const unsigned long long kFirstRoom = 1000ull * 1000 * 1000;
// The Neural Engine copy loads beside the CPU's only with this much left. On an iPhone 15 Pro it added 0.06-0.1 GB of
// footprint (resident 1.06 to 1.13 GB); 0.5 GB is that five times over, for its first compile, which was not measured
// apart, and for Spotify's own memory to grow without iOS closing it for a copy Sing can do without.
static const unsigned long long kNeuralRoom = 500ull * 1000 * 1000;
static const int kStillEvery = 30;

// One load of one copy.
@interface SGSingLoad : NSObject
@property (nonatomic) unsigned number;
@property (nonatomic, copy) NSString *name;   // the copy's, for the log
@property (nonatomic, copy) NSURL *url;
@property (nonatomic) CFAbsoluteTime began;
@property (nonatomic) BOOL finished, abandoned;
@end

@implementation SGSingLoad
@end

static void (^sg_changed)(void);
static SGSingLoaderState sg_state;
static NSString *sg_error;
static SGSingSeparator *sg_separator;
static SGSingLoad *sg_cpuLoad, *sg_fastLoad;   // the loads that count; abandoned ones are let go
static unsigned sg_outstanding;                 // loads not come back yet, abandoned ones with them
static unsigned sg_attempts;
static NSURL *sg_url;
static BOOL sg_neural;                          // a Neural Engine copy is asked for
static SGSingFastState sg_fastState;
static BOOL sg_foreground;
static NSUInteger sg_keepToken;                 // counts the mic's releases and wants, so a stale minute drops nothing
static BOOL sg_wanted;                          // the mic is on: the Neural Engine copy is worth loading
static BOOL sg_alone;                           // the model is wanted as one Neural Engine copy (the light model)
static BOOL sg_aloneFell;                       // that copy failed for this model: it is on the CPU alone
static BOOL sg_mainNeural;                      // the copy the separator is made with, loading or loaded, is the Neural Engine's

// Run after the caller returns, so a listener that wants or purges again does not run inside it.
static void changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sg_changed) sg_changed();
    });
}

// The memory the process has left before iOS closes it; 0 where the OS does not say (the Mac).
static unsigned long long memoryLeft(void) {
#if TARGET_OS_IPHONE
    return os_proc_available_memory();
#else
    return 0;
#endif
}

static NSString *memoryText(void) {
    unsigned long long left = memoryLeft();
    return left ? [NSString stringWithFormat:@"%.2f GB left to the process", left / 1e9] : @"memory left unknown";
}

// Whether `room` is left for a copy beside what is already in memory or still loading.
static BOOL roomFor(unsigned long long room) {
    unsigned long long left = memoryLeft();
    return !left || left >= room;
}

static void still(SGSingLoad *load, int seconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kStillEvery * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (load.finished || load.abandoned) return;
        SGLog(@"sing: still loading the %@ copy (load %u), %d s", load.name, load.number, seconds + kStillEvery);
        still(load, seconds + kStillEvery);
    });
}

// Loads and warms a copy on a queue of its own; `done` runs on the main thread unless the load was abandoned
// first, and `late` when its deadline passes before it comes back.
static SGSingLoad *startLoad(NSURL *url, BOOL neural, double deadline, void (^done)(MLModel *model, NSError *error), void (^late)(void)) {
    SGSingLoad *load = [SGSingLoad new];
    load.number = ++sg_attempts;
    load.name = neural ? @"Neural Engine" : @"CPU";
    load.url = url;
    load.began = CFAbsoluteTimeGetCurrent();
    sg_outstanding++;
    SGLog(@"sing: load %u, the %@ copy of %@, starts (Spotify %@, thermal state %s, %@, %@, %u loads out)", load.number, load.name,
          url.lastPathComponent, sg_foreground ? @"active" : @"not active", SGSingThermalName(), memoryText(), SGSingMemoryText(), sg_outstanding);
    NSString *name = [NSString stringWithFormat:@"spotifyglass.sing.load.%u", load.number];
    dispatch_queue_t queue = dispatch_queue_create(name.UTF8String, dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    dispatch_async(queue, ^{
        MLModelConfiguration *configuration = [MLModelConfiguration new];
        configuration.computeUnits = neural ? MLComputeUnitsCPUAndNeuralEngine : MLComputeUnitsCPUOnly;
        NSError *error;
        MLModel *model = [MLModel modelWithContentsOfURL:url configuration:configuration error:&error];
        double loaded = CFAbsoluteTimeGetCurrent() - load.began;
        NSString *loadedMemory = SGSingMemoryText();
        double warm = model ? [SGSingSeparator warmUp:model error:&error] : -1;
        NSString *warmMemory = SGSingMemoryText();
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_outstanding--;
            load.finished = YES;
            NSString *outcome = !model ? [NSString stringWithFormat:@"did not load after %.1f s: %@", loaded, error.localizedDescription]
                              : warm < 0 ? [NSString stringWithFormat:@"loaded in %.1f s, and its warm-up failed: %@", loaded, error.localizedDescription]
                                         : [NSString stringWithFormat:@"loaded in %.1f s, and its warm-up window of silence took %.1f s", loaded, warm];
            SGLog(@"sing: load %u, the %@ copy, %@ (memory loaded: %@; warm: %@)%@", load.number, load.name, outcome, loadedMemory, warmMemory,
                  load.abandoned ? @"; it was abandoned before, so it is let go" : @"");
            if (load.abandoned) return;
            done(warm >= 0 ? model : nil, error);
        });
    });
    still(load, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (load.finished || load.abandoned) return;
        load.abandoned = YES;
        SGLog(@"sing: load %u, the %@ copy, has not come back in %.0f s: abandoned", load.number, load.name, deadline);
        late();
    });
    return load;
}

static SGSingLoad *sg_prepareLoad;   // SGSingLoaderPrepareNeural's, until it comes back or is taken over
static void mainLoaded(MLModel *model, NSError *error);
static void mainLate(void);

static void fastLoaded(MLModel *model) {
    sg_fastLoad = nil;
    sg_fastState = model ? SGSingFastReady : SGSingFastFailed;
    if (model) [sg_separator setFastModel:model named:@"Neural Engine"];
    changed();
}

static void fastLate(void) {
    sg_fastLoad = nil;
    sg_fastState = SGSingFastTimedOut;
    changed();
}

static void startFast(void) {
    if (!sg_wanted || sg_state != SGSingLoaderReady || !sg_foreground || !sg_neural || sg_fastState != SGSingFastNone) return;
    // The compile running ahead of the mic is this copy's: a second load would compile it again beside it.
    if (sg_prepareLoad && [sg_prepareLoad.url isEqual:sg_url] && !sg_prepareLoad.finished && !sg_prepareLoad.abandoned) {
        sg_fastState = SGSingFastLoading;
        sg_fastLoad = sg_prepareLoad;
        SGLog(@"sing: the Neural Engine copy is the one already compiling (load %u)", sg_fastLoad.number);
        changed();
        return;
    }
    if (!roomFor(kNeuralRoom)) {
        sg_fastState = SGSingFastSkipped;
        SGLog(@"sing: no Neural Engine copy: %@, it wants %.1f GB, so Sing stays on the CPU", memoryText(), kNeuralRoom / 1e9);
        changed();
        return;
    }
    sg_fastState = SGSingFastLoading;
    sg_fastLoad = startLoad(sg_url, YES, SGSingLoaderNeuralDeadline, ^(MLModel *model, NSError *error) {
        fastLoaded(model);
    }, ^{
        fastLate();
    });
    changed();
}

BOOL SGSingLoaderPrepareNeural(NSURL *url, void (^done)(BOOL loaded)) {
    if (!url || sg_outstanding || sg_state != SGSingLoaderIdle || !sg_foreground || !roomFor(kNeuralRoom)) return NO;
    __block SGSingLoad *load = startLoad(url, YES, SGSingLoaderNeuralDeadline, ^(MLModel *model, NSError *error) {
        BOOL taken = sg_fastLoad == load, main = sg_cpuLoad == load;
        sg_prepareLoad = nil;
        if (main) mainLoaded(model, error);
        else if (taken) fastLoaded(model);
        else if (done) done(model != nil);
    }, ^{
        BOOL taken = sg_fastLoad == load, main = sg_cpuLoad == load;
        sg_prepareLoad = nil;
        if (main) mainLate();
        else if (taken) fastLate();
        else if (done) done(NO);
    });
    sg_prepareLoad = load;
    return YES;
}

// The copy the separator is made with: the CPU's, or a model wanted alone's Neural Engine copy (which takes over the compile
// running ahead of the mic, as startFast does) until it has failed.
static void startCPU(void) {
    BOOL neural = sg_alone && !sg_aloneFell;
    unsigned long long room = sg_outstanding ? kCopyRoom : neural ? kNeuralRoom : kFirstRoom;
    if (!roomFor(room)) {
        sg_state = SGSingLoaderFailed;
        sg_error = sg_outstanding
            ? [NSString stringWithFormat:@"A load abandoned earlier still holds memory, and %@. Close Spotify and open it again to load the voice model.", memoryText()]
            : [NSString stringWithFormat:@"iOS leaves Spotify too little memory for the voice model: %@, and it needs %.1f GB. Closing Spotify and opening it again can free some.", memoryText(), room / 1e9];
        SGLog(@"sing: no new load: %@", sg_error);
        changed();
        return;
    }
    sg_state = SGSingLoaderLoading;
    sg_error = nil;
    sg_mainNeural = neural;
    if (neural) sg_fastState = SGSingFastLoading;
    if (neural && sg_prepareLoad && [sg_prepareLoad.url isEqual:sg_url] && !sg_prepareLoad.finished && !sg_prepareLoad.abandoned) {
        sg_cpuLoad = sg_prepareLoad;
        SGLog(@"sing: the Neural Engine copy is the one already compiling (load %u), and no CPU copy loads beside it", sg_cpuLoad.number);
    } else {
        sg_cpuLoad = startLoad(sg_url, neural, neural ? SGSingLoaderNeuralDeadline : SGSingLoaderCPUDeadline, ^(MLModel *model, NSError *error) {
            mainLoaded(model, error);
        }, ^{
            mainLate();
        });
    }
    changed();
}

// A model wanted alone whose Neural Engine copy failed: on the CPU alone from here, for this model.
static void aloneFell(SGSingFastState state, NSString *why) {
    sg_aloneFell = YES;
    sg_fastState = state;
    SGLog(@"sing: the Neural Engine copy of %@ %@, so it loads on the CPU alone", sg_url.lastPathComponent, why);
    changed();
    startCPU();
}

static void mainLoaded(MLModel *model, NSError *error) {
    sg_cpuLoad = nil;
    if (!model && sg_mainNeural) {
        aloneFell(SGSingFastFailed, [NSString stringWithFormat:@"did not load (%@)", error.localizedDescription ?: @"Core ML gave no reason"]);
        return;
    }
    sg_separator = model ? [[SGSingSeparator alloc] initWithModel:model named:sg_mainNeural ? @"Neural Engine" : @"CPU"] : nil;
    if (sg_separator) {
        sg_state = SGSingLoaderReady;
        if (sg_mainNeural) sg_fastState = SGSingFastReady;
    } else {
        sg_state = SGSingLoaderFailed;
        sg_error = model ? @"Karaoke could not set aside memory for the voice model."
                         : [NSString stringWithFormat:@"The voice model did not load: %@", error.localizedDescription ?: @"Core ML gave no reason."];
    }
    changed();
    startFast();
}

static void mainLate(void) {
    sg_cpuLoad = nil;
    if (sg_mainNeural) {
        aloneFell(SGSingFastTimedOut, [NSString stringWithFormat:@"did not load in %.0f s", SGSingLoaderNeuralDeadline]);
        return;
    }
    sg_state = SGSingLoaderFailed;
    sg_error = [NSString stringWithFormat:@"The voice model did not load in %.0f s, so that load was given up.", SGSingLoaderCPUDeadline];
    changed();
}

static void abandon(SGSingLoad *load) {
    if (load && !load.finished) load.abandoned = YES;
}

void SGSingLoaderSetChanged(void (^block)(void)) {
    sg_changed = block;
}

void SGSingLoaderDropFast(NSString *why) {
    BOOL had = sg_fastState == SGSingFastLoading || sg_fastState == SGSingFastReady;
    abandon(sg_fastLoad);
    sg_fastLoad = nil;
    [sg_separator setFastModel:nil named:nil];
    sg_fastState = SGSingFastNone;
    if (!had) return;
    if (why) SGLog(@"sing: the Neural Engine copy is dropped: %@", why);
    changed();
}

static void want(NSURL *url, BOOL neural, BOOL alone) {
    // Another model (its update in, or the light one for the full): the copies of the one before go, a failure with
    // them, and this one loads. So do they for the same model wanted as the other kind of copy, unless a model wanted
    // alone already fell back to the CPU copy now wanted.
    BOOL another = sg_url && url && ![url isEqual:sg_url];
    BOOL otherCopy = !another && sg_state != SGSingLoaderIdle && sg_state != SGSingLoaderFailed && sg_mainNeural != (alone && !sg_aloneFell);
    if (another || otherCopy) {
        SGSingLoaderPurge(another ? [NSString stringWithFormat:@"the model is now %@", url.lastPathComponent]
                                  : alone ? @"it now loads on the Neural Engine alone" : @"it now loads on the CPU first");
        sg_state = SGSingLoaderIdle;
        sg_error = nil;
    }
    sg_keepToken++;
    sg_wanted = YES;
    sg_url = url;
    sg_alone = alone;
    sg_neural = neural && !alone;
    if (!neural && !alone) SGSingLoaderDropFast(@"Karaoke runs on the CPU alone now");
    if (sg_state == SGSingLoaderIdle) startCPU();
    else startFast();
}

void SGSingLoaderWant(NSURL *url, BOOL neural) {
    want(url, neural, NO);
}

void SGSingLoaderWantAlone(NSURL *url) {
    want(url, NO, YES);
}

BOOL SGSingLoaderMainNeural(void) {
    return sg_state != SGSingLoaderIdle && sg_state != SGSingLoaderFailed && sg_mainNeural;
}

void SGSingLoaderPurge(NSString *why) {
    sg_keepToken++;
    sg_wanted = NO;
    BOOL had = sg_separator || sg_cpuLoad || sg_fastLoad;
    abandon(sg_cpuLoad);
    sg_cpuLoad = nil;
    SGSingLoaderDropFast(nil);
    sg_separator = nil;
    sg_mainNeural = NO;
    sg_aloneFell = NO;
    if (!had) return;
    sg_state = SGSingLoaderIdle;
    SGLog(@"sing: the voice model is dropped: %@", why);
    changed();
}

void SGSingLoaderRelease(void) {
    NSUInteger token = ++sg_keepToken;
    sg_wanted = NO;
    if (sg_state == SGSingLoaderFailed) {
        sg_state = SGSingLoaderIdle;
        sg_error = nil;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SGSingLoaderKeepSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token == sg_keepToken) SGSingLoaderPurge([NSString stringWithFormat:@"the mic has been off for %.0f s", SGSingLoaderKeepSeconds]);
    });
}

void SGSingLoaderSetForeground(BOOL foreground) {
    sg_foreground = foreground;
    if (foreground) startFast();
}

BOOL SGSingLoaderHasRoom(void) {
    return roomFor(kCopyRoom);
}

NSURL *SGSingLoaderURL(void) {
    return sg_url;
}

SGSingLoaderState SGSingLoaderCurrentState(void) {
    return sg_state;
}

SGSingSeparator *SGSingLoaderSeparator(void) {
    return sg_state == SGSingLoaderReady ? sg_separator : nil;
}

NSString *SGSingLoaderError(void) {
    return sg_state == SGSingLoaderFailed ? sg_error : nil;
}

NSTimeInterval SGSingLoaderSeconds(void) {
    return sg_cpuLoad ? CFAbsoluteTimeGetCurrent() - sg_cpuLoad.began : 0;
}

SGSingFastState SGSingLoaderFastState(void) {
    return sg_fastState;
}

NSTimeInterval SGSingLoaderFastSeconds(void) {
    SGSingLoad *load = sg_fastLoad ?: sg_mainNeural ? sg_cpuLoad : nil;
    return load ? CFAbsoluteTimeGetCurrent() - load.began : 0;
}

unsigned SGSingLoaderAttempts(void) {
    return sg_attempts;
}

unsigned SGSingLoaderOutstanding(void) {
    return sg_outstanding;
}

NSTimeInterval SGSingLoaderPreparingSeconds(void) {
    SGSingLoad *load = sg_prepareLoad;
    if (!load || load.finished || load.abandoned || sg_fastLoad == load) return -1;
    return CFAbsoluteTimeGetCurrent() - load.began;
}
