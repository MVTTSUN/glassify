// The light model made on the Mac by SGSingLight.m, as the iPhone makes it, against repalettize.py's: a conversion
// stopped a third of the way in reports it, then one from scratch is compared file by file, byte for byte.
#import <Foundation/Foundation.h>
#import "Shared/Sing/SGSingLight.h"
#import "Shared/Sing/SGSingLoader.h"
#import "Shared/Sing/SGSingSeparator.h"

static int failures;

#define CHECK(condition, ...) do { \
    BOOL ok_ = (condition); \
    if (!ok_) failures++; \
    printf("%s  %s\n", ok_ ? "ok  " : "FAIL", [NSString stringWithFormat:__VA_ARGS__].UTF8String); \
} while (0)

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: light <separator-ane.mlmodelc> <out.mlmodelc> <reference separator-light.mlmodelc>\n");
            return 2;
        }
        NSURL *full = [NSURL fileURLWithPath:@(argv[1])], *out = [NSURL fileURLWithPath:@(argv[2])], *reference = [NSURL fileURLWithPath:@(argv[3])];
        NSFileManager *files = NSFileManager.defaultManager;
        [files removeItemAtURL:out error:nil];

        __block double last = 0;
        NSString *stopped = SGSingLightConvert(full, out, ^BOOL(double done) {
            last = done;
            return done < 1.0 / 3;
        }, nil);
        CHECK([stopped isEqualToString:@"Stopped"], @"a conversion stopped at %.0f%% says so (%@)", last * 100, stopped);
        [files removeItemAtURL:out error:nil];

        __block int calls = 0;
        __block double previous = 0;
        __block BOOL rising = YES;
        NSString *sha;
        CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
        NSString *error = SGSingLightConvert(full, out, ^BOOL(double done) {
            calls++;
            rising &= done >= previous;
            previous = done;
            return YES;
        }, &sha);
        double took = CFAbsoluteTimeGetCurrent() - began;
        CHECK(!error, @"the conversion from scratch finishes in %.1f s (%@)", took, error ?: @"no error");
        CHECK(rising && calls > 50 && previous == 1, @"its progress rises to 1 over %d reports", calls);
        CHECK([sha isEqualToString:@(kSGSingLightSHA256)], @"weight.bin's SHA-256 is the one pinned (%@)", sha);
        for (NSString *name in @[@"weights/weight.bin", @"model.mil", @"coremldata.bin", @"metadata.json", @"analytics/coremldata.bin"]) {
            NSData *mine = [NSData dataWithContentsOfURL:[out URLByAppendingPathComponent:name] options:NSDataReadingMappedIfSafe error:nil];
            NSData *theirs = [NSData dataWithContentsOfURL:[reference URLByAppendingPathComponent:name] options:NSDataReadingMappedIfSafe error:nil];
            NSUInteger differ = NSNotFound;
            for (NSUInteger i = 0; mine && theirs && i < MIN(mine.length, theirs.length) && differ == NSNotFound; i++) {
                if (((const uint8_t *)mine.bytes)[i] != ((const uint8_t *)theirs.bytes)[i]) differ = i;
            }
            CHECK(mine && theirs && [mine isEqualToData:theirs], @"%@: %lu bytes, the same as repalettize.py's byte for byte%@", name, (unsigned long)mine.length,
                  differ != NSNotFound ? [NSString stringWithFormat:@" (first difference at %lu)", (unsigned long)differ] : @"");
        }
        long long weightBytes = [[files attributesOfItemAtPath:[out URLByAppendingPathComponent:@"weights/weight.bin"].path error:nil] fileSize];
        long long milBytes = [[files attributesOfItemAtPath:[out URLByAppendingPathComponent:@"model.mil"].path error:nil] fileSize];
        CHECK(weightBytes == kSGSingLightWeightBytes && milBytes == kSGSingLightMILBytes, @"the sizes are the ones pinned (%lld, %lld)", weightBytes, milBytes);
        if (argc > 4 && !strcmp(argv[4], "load")) {
            // The light model as Karaoke loads it: one Neural Engine copy, no CPU copy.
            BOOL (^waitReady)(double) = ^BOOL(double seconds) {
                CFAbsoluteTime until = CFAbsoluteTimeGetCurrent() + seconds;
                while (CFAbsoluteTimeGetCurrent() < until && SGSingLoaderCurrentState() == SGSingLoaderLoading) {
                    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                }
                return SGSingLoaderCurrentState() == SGSingLoaderReady;
            };
            SGSingLoaderSetForeground(YES);
            CFAbsoluteTime loadBegan = CFAbsoluteTimeGetCurrent();
            SGSingLoaderWantAlone(out);
            CHECK(SGSingLoaderMainNeural() && SGSingLoaderFastState() == SGSingFastLoading, @"wanted alone, the copy loading is the Neural Engine's");
            BOOL ready = waitReady(600);
            CHECK(ready && SGSingLoaderMainNeural() && SGSingLoaderFastState() == SGSingFastReady && SGSingLoaderAttempts() == 1,
                  @"it loads and warms in %.1f s, the one load of the run (%u), with no CPU copy", CFAbsoluteTimeGetCurrent() - loadBegan, SGSingLoaderAttempts());
            float *left = calloc(kSGSingWindowFrames, sizeof(float)), *right = calloc(kSGSingWindowFrames, sizeof(float));
            float *vocalsLeft = calloc(kSGSingWindowFrames, sizeof(float)), *vocalsRight = calloc(kSGSingWindowFrames, sizeof(float));
            for (int i = 0; i < kSGSingWindowFrames; i++) {
                left[i] = 0.3f * sinf(2 * (float)M_PI * 220 * i / kSGSingRate) + 0.05f * ((float)arc4random_uniform(1000) / 1000 - 0.5f);
                right[i] = left[i];
            }
            NSError *windowError;
            SGSingSeparator *separator = SGSingLoaderSeparator();
            BOOL separated = [separator separateLeft:left right:right vocalsLeft:vocalsLeft vocalsRight:vocalsRight error:&windowError];
            BOOL finite = YES;
            for (int i = 0; i < kSGSingWindowFrames; i++) finite &= isfinite(vocalsLeft[i]) && isfinite(vocalsRight[i]);
            SGSingSeparatorStats stats = separator ? [separator stats] : (SGSingSeparatorStats){0};
            CHECK(separated && finite && stats.windows[0] == 1 && !stats.fast, @"a window separates on it, as the separator's own copy (%.0f ms%@)", stats.averageMS[0],
                  windowError ? [@", " stringByAppendingString:windowError.localizedDescription] : @"");
            // A Neural Engine copy past its deadline: the light model on the CPU alone in its place.
            SGSingLoaderPurge(@"the harness checks the fallback");
            double deadline = SGSingLoaderNeuralDeadline;
            SGSingLoaderNeuralDeadline = 0.001;
            SGSingLoaderWantAlone(out);
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            ready = waitReady(300);
            SGSingLoaderNeuralDeadline = deadline;
            CHECK(ready && !SGSingLoaderMainNeural() && SGSingLoaderFastState() == SGSingFastTimedOut, @"one past its deadline leaves the light model Ready on the CPU alone");
            SGSingLoaderWantAlone(out);
            CHECK(SGSingLoaderCurrentState() == SGSingLoaderReady && !SGSingLoaderMainNeural(), @"wanted alone again, the CPU copy it fell back to is kept");
            SGSingLoaderPurge(@"the harness is done");
            free(left);
            free(right);
            free(vocalsLeft);
            free(vocalsRight);
        }
        printf("%s\n", failures ? "FAILED" : "all passed");
    }
    return failures ? 1 : 0;
}
