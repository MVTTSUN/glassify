// Fonts to download for the whole app: a fixed catalog of Google Fonts families (SIL Open Font License), fetched from
// the google/fonts repository on GitHub (raw.githubusercontent.com/google/fonts/main/ofl/<directory>/<file>), each URL
// checked live when the catalog was written. Most are one variable file with a weight axis (Fonts.x sets the weight on
// it); the families published only as static files take their upright weights. The files land in
// SGFontFolder()/Downloaded/<directory>.incoming and move to SGFontFolder()/Downloaded/<directory> once every one has
// come and Core Text reads one family from them, so a failed download leaves nothing behind. Fonts.x registers the
// chosen family again at each launch, like an imported one.
//
// Threading: main thread throughout; the session calls its delegate on the main queue.
#import <CoreText/CoreText.h>
#import "Core/SGCore.h"
#import "Shared/Fonts/Fonts.h"

typedef struct {
    const char *name;
    const char *directory;   // under ofl/
    const char *files[7];    // upright faces only; NULL ends the list
    long long bytes;         // the files together when the catalog was checked, the progress's whole
} SGFontEntry;

static const SGFontEntry kCatalog[] = {
    {"Inter", "inter", {"Inter[opsz,wght].ttf"}, 876576},
    {"Manrope", "manrope", {"Manrope[wght].ttf"}, 164700},
    {"DM Sans", "dmsans", {"DMSans[opsz,wght].ttf"}, 240164},
    {"Outfit", "outfit", {"Outfit[wght].ttf"}, 110884},
    {"Plus Jakarta Sans", "plusjakartasans", {"PlusJakartaSans[wght].ttf"}, 176288},
    {"Sora", "sora", {"Sora[wght].ttf"}, 111400},
    {"Space Grotesk", "spacegrotesk", {"SpaceGrotesk[wght].ttf"}, 136676},
    {"Poppins", "poppins", {"Poppins-Light.ttf", "Poppins-Regular.ttf", "Poppins-Medium.ttf", "Poppins-SemiBold.ttf",
                            "Poppins-Bold.ttf", "Poppins-Black.ttf"}, 947576},
    {"Montserrat", "montserrat", {"Montserrat[wght].ttf"}, 744936},
    {"Nunito", "nunito", {"Nunito[wght].ttf"}, 276932},
    {"Rubik", "rubik", {"Rubik[wght].ttf"}, 359804},
    {"Work Sans", "worksans", {"WorkSans[wght].ttf"}, 361072},
    {"Figtree", "figtree", {"Figtree[wght].ttf"}, 62712},
    {"Lexend", "lexend", {"Lexend[wght].ttf"}, 175756},
    {"Urbanist", "urbanist", {"Urbanist[wght].ttf"}, 84840},
    {"Raleway", "raleway", {"Raleway[wght].ttf"}, 312352},
    {"Quicksand", "quicksand", {"Quicksand[wght].ttf"}, 124824},
    {"Josefin Sans", "josefinsans", {"JosefinSans[wght].ttf"}, 118588},
    {"Playfair Display", "playfairdisplay", {"PlayfairDisplay[wght].ttf"}, 300724},
    {"Lora", "lora", {"Lora[wght].ttf"}, 212196},
    {"Merriweather", "merriweather", {"Merriweather[opsz,wdth,wght].ttf"}, 4628080},
    {"Fraunces", "fraunces", {"Fraunces[SOFT,WONK,opsz,wght].ttf"}, 360440},
    {"DM Serif Display", "dmserifdisplay", {"DMSerifDisplay-Regular.ttf"}, 76580},
    {"Bricolage Grotesque", "bricolagegrotesque", {"BricolageGrotesque[opsz,wdth,wght].ttf"}, 408496},
    {"Onest", "onest", {"Onest[wght].ttf"}, 193056},
    {"Unbounded", "unbounded", {"Unbounded[wght].ttf"}, 778272},
    {"Comfortaa", "comfortaa", {"Comfortaa[wght].ttf"}, 201756},
    {"JetBrains Mono", "jetbrainsmono", {"JetBrainsMono[wght].ttf"}, 187208},
    {"IBM Plex Sans", "ibmplexsans", {"IBMPlexSans[wdth,wght].ttf"}, 537244},
    {"Source Serif 4", "sourceserif4", {"SourceSerif4[opsz,wght].ttf"}, 1209508},
    {"Noto Sans", "notosans", {"NotoSans[wdth,wght].ttf"}, 2049096},
};
static const NSUInteger kCatalogCount = sizeof(kCatalog) / sizeof(kCatalog[0]);
static NSString *const kRawBase = @"https://raw.githubusercontent.com/google/fonts/main/ofl/";

static const SGFontEntry *entryNamed(NSString *name) {
    for (NSUInteger i = 0; name && i < kCatalogCount; i++) {
        if ([name isEqualToString:@(kCatalog[i].name)]) return &kCatalog[i];
    }
    return NULL;
}

static NSArray<NSString *> *filesOf(const SGFontEntry *entry) {
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(entry->files) / sizeof(entry->files[0]) && entry->files[i]; i++) [files addObject:@(entry->files[i])];
    return files;
}

static NSURL *downloadsFolder(void) {
    return [SGFontFolder() URLByAppendingPathComponent:@"Downloaded" isDirectory:YES];
}

static NSURL *familyFolder(const SGFontEntry *entry, BOOL incoming) {
    NSString *directory = @(entry->directory);
    if (incoming) directory = [directory stringByAppendingString:@".incoming"];
    return [downloadsFolder() URLByAppendingPathComponent:directory isDirectory:YES];
}

// The file's raw URL. The brackets of a variable font's name ("Inter[opsz,wght].ttf") are escaped; its commas may stay.
static NSURL *remoteURL(const SGFontEntry *entry, NSString *file) {
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLPathAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"[]/"];
    NSString *escaped = [file stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@%s/%@", kRawBase, entry->directory, escaped]];
}

NSArray<NSString *> *SGDownloadableFonts(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:kCatalogCount];
    for (NSUInteger i = 0; i < kCatalogCount; i++) [names addObject:@(kCatalog[i].name)];
    return names;
}

BOOL SGFontDownloaded(NSString *name) {
    const SGFontEntry *entry = entryNamed(name);
    if (!entry) return NO;
    NSURL *folder = familyFolder(entry, NO);
    for (NSString *file in filesOf(entry)) {
        if (![NSFileManager.defaultManager fileExistsAtPath:[folder URLByAppendingPathComponent:file].path]) return NO;
    }
    return YES;
}

BOOL SGAnyFontDownloaded(void) {
    for (NSUInteger i = 0; i < kCatalogCount; i++) {
        if (SGFontDownloaded(@(kCatalog[i].name))) return YES;
    }
    return NO;
}

NSString *SGFontDownloadSize(NSString *name) {
    const SGFontEntry *entry = entryNamed(name);
    return entry ? [NSByteCountFormatter stringFromByteCount:entry->bytes countStyle:NSByteCountFormatterCountStyleFile] : nil;
}

#pragma mark - registering

// The families registered in this process, by catalog name, so the Font page drawing each row in its own font does not
// register a file twice.
static NSMutableDictionary<NSString *, NSString *> *registered(void) {
    static NSMutableDictionary<NSString *, NSString *> *names;
    if (!names) names = [NSMutableDictionary dictionary];
    return names;
}

// The one family name every face of the files shares, or nil.
static NSString *familyOfFiles(NSArray<NSURL *> *urls) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSArray<NSString *> *faces = SGFontFamiliesIn(url);
        if (!faces.count) return nil;
        [names addObjectsFromArray:faces];
    }
    return SGFontSingleFamily(names);
}

NSString *SGRegisterDownloadedFont(NSString *name) {
    NSString *known = registered()[name ?: @""];
    if (known) return known;
    const SGFontEntry *entry = entryNamed(name);
    if (!entry || !SGFontDownloaded(name)) return nil;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *file in filesOf(entry)) [urls addObject:[familyFolder(entry, NO) URLByAppendingPathComponent:file]];
    NSString *family = familyOfFiles(urls);
    if (!family) return nil;
    for (NSURL *url in urls) {
        CFErrorRef error = NULL;
        if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error)) {
            NSError *failure = CFBridgingRelease(error);
            SGLog(@"fonts: %@ not registered: %@", url.lastPathComponent, failure.localizedDescription);
        }
    }
    if (![UIFont fontNamesForFamilyName:family].count) return nil;
    registered()[name] = family;
    return family;
}

void SGDeleteDownloadedFont(NSString *name) {
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSUInteger i = 0; i < kCatalogCount; i++) {
        const SGFontEntry *entry = &kCatalog[i];
        NSString *entryName = @(entry->name);
        if (name && ![name isEqualToString:entryName]) continue;
        if (registered()[entryName]) {
            for (NSString *file in filesOf(entry)) {
                NSURL *url = [familyFolder(entry, NO) URLByAppendingPathComponent:file];
                CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, NULL);
            }
            [registered() removeObjectForKey:entryName];
        }
        [files removeItemAtURL:familyFolder(entry, NO) error:nil];
    }
    NSString *chosen = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyAppFontDownload];
    if (!name || [name isEqualToString:chosen]) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyAppFontDownload];
        if (SGAppFontChosen() == SGAppFontDownloaded) SGSetInt(SGKeyAppFont, SGAppFontSpotify);
    }
}

#pragma mark - downloading

@interface SGFontJob : NSObject
@property (nonatomic) const SGFontEntry *entry;
@property (nonatomic) NSUInteger index;          // the file being fetched
@property (nonatomic) long long fetched;         // the bytes of the files before it
@property (nonatomic) double fraction;
@property (nonatomic) BOOL failed;
@property (nonatomic, strong) NSMutableArray<void (^)(double)> *progress;
@property (nonatomic, strong) NSMutableArray<void (^)(NSString *)> *done;
@end

@implementation SGFontJob
@end

@interface SGFontFetcher : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SGFontJob *> *jobs;   // by catalog name
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, SGFontJob *> *tasks;  // by task identifier
+ (instancetype)shared;
- (void)fetchNext:(SGFontJob *)job;
- (void)finish:(SGFontJob *)job family:(NSString *)family;
@end

@implementation SGFontFetcher

+ (instancetype)shared {
    static SGFontFetcher *fetcher;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fetcher = [SGFontFetcher new];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
        configuration.timeoutIntervalForRequest = 30;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        fetcher.session = [NSURLSession sessionWithConfiguration:configuration delegate:fetcher delegateQueue:NSOperationQueue.mainQueue];
        fetcher.jobs = [NSMutableDictionary dictionary];
        fetcher.tasks = [NSMutableDictionary dictionary];
    });
    return fetcher;
}

- (void)fetchNext:(SGFontJob *)job {
    NSString *file = filesOf(job.entry)[job.index];
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:remoteURL(job.entry, file)];
    self.tasks[@(task.taskIdentifier)] = job;
    [task resume];
}

- (void)finish:(SGFontJob *)job family:(NSString *)family {
    NSString *name = @(job.entry->name);
    [self.jobs removeObjectForKey:name];
    SGLog(@"fonts: download of %@ %@", name, family ? [NSString stringWithFormat:@"done, family %@", family] : @"failed");
    for (void (^done)(NSString *) in job.done) done(family);
}

// Every file has come: they move into the family's folder once Core Text reads one family from them.
- (void)install:(SGFontJob *)job {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *incoming = familyFolder(job.entry, YES), *folder = familyFolder(job.entry, NO);
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *file in filesOf(job.entry)) [urls addObject:[incoming URLByAppendingPathComponent:file]];
    NSString *family = familyOfFiles(urls);
    if (family) {
        [files removeItemAtURL:folder error:nil];
        if (![files moveItemAtURL:incoming toURL:folder error:nil]) family = nil;
    }
    [files removeItemAtURL:incoming error:nil];
    [self finish:job family:family ? SGRegisterDownloadedFont(@(job.entry->name)) : nil];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)written
        totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected {
    SGFontJob *job = self.tasks[@(task.taskIdentifier)];
    if (!job) return;
    long long whole = MAX(job.entry->bytes, job.fetched + total);
    job.fraction = whole > 0 ? (double)(job.fetched + total) / whole : 0;
    for (void (^progress)(double) in job.progress) progress(job.fraction);
}

// The temporary file is gone once this returns, so it is moved aside here.
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    SGFontJob *job = self.tasks[@(task.taskIdentifier)];
    if (!job) return;
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
    if (![response isKindOfClass:NSHTTPURLResponse.class] || response.statusCode != 200) {
        job.failed = YES;
        return;
    }
    NSURL *target = [familyFolder(job.entry, YES) URLByAppendingPathComponent:filesOf(job.entry)[job.index]];
    [NSFileManager.defaultManager removeItemAtURL:target error:nil];
    if (![NSFileManager.defaultManager moveItemAtURL:location toURL:target error:nil]) job.failed = YES;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    SGFontJob *job = self.tasks[@(task.taskIdentifier)];
    [self.tasks removeObjectForKey:@(task.taskIdentifier)];
    if (!job) return;
    if (error || job.failed) {
        SGLog(@"fonts: %@ not downloaded: %@", filesOf(job.entry)[job.index], error.localizedDescription ?: @"not a 200");
        [NSFileManager.defaultManager removeItemAtURL:familyFolder(job.entry, YES) error:nil];
        [self finish:job family:nil];
        return;
    }
    job.fetched += task.countOfBytesReceived;
    job.index++;
    if (job.index < filesOf(job.entry).count) [self fetchNext:job];
    else [self install:job];
}

@end

void SGDownloadFont(NSString *name, void (^progress)(double fraction), void (^done)(NSString *family)) {
    const SGFontEntry *entry = entryNamed(name);
    if (!entry) {
        if (done) done(nil);
        return;
    }
    SGFontFetcher *fetcher = SGFontFetcher.shared;
    SGFontJob *job = fetcher.jobs[name];
    BOOL running = job != nil;
    if (!job) {
        job = [SGFontJob new];
        job.entry = entry;
        job.progress = [NSMutableArray array];
        job.done = [NSMutableArray array];
        fetcher.jobs[name] = job;
    }
    if (progress) [job.progress addObject:progress];
    if (done) [job.done addObject:done];
    if (running) return;
    NSURL *incoming = familyFolder(entry, YES);
    [NSFileManager.defaultManager removeItemAtURL:incoming error:nil];
    if (![NSFileManager.defaultManager createDirectoryAtURL:incoming withIntermediateDirectories:YES attributes:nil error:nil]) {
        [fetcher finish:job family:nil];
        return;
    }
    SGLog(@"fonts: downloading %@ (%lu file%@)", name, (unsigned long)filesOf(entry).count, filesOf(entry).count == 1 ? @"" : @"s");
    [fetcher fetchNext:job];
}

double SGFontDownloadProgress(NSString *name) {
    SGFontJob *job = name ? SGFontFetcher.shared.jobs[name] : nil;
    return job ? job.fraction : -1;
}
