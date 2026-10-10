// The light voice model made from the full one (SGSingLight.h), as harness/sing/light/repalettize.py makes it.
//
// MIL's blob storage (weight.bin, version 2): a 64-byte header (uint32 count, uint32 version, zeros), then for each blob a
// 64-byte metadata (uint32 0xDEADBEEF, uint32 dtype, uint64 size in bytes, uint64 data offset, zeros) at the offset
// model.mil names, its data at the data offset, everything 64-byte aligned, the last blob's data ending the file with no
// padding. Sub-byte values are packed least significant bit first. The blobs are written again in the order of their
// offsets: one that is not a palettized weight's is copied as it is, a palettized weight's indices (uint6, dtype 13)
// become uint4 (dtype 11) with its new table (fp16, dtype 1) right after them, and every offset in model.mil is moved to
// where its blob now is.
//
// Each group's 64 values are cut to 16 by a weighted 1-D k-means, each value weighted by how many weights use it: the
// values sorted, centres started at weighted quantiles (np.interp of the cumulative weights), then up to 60 rounds of
// each value to its nearest centre (the first of two as near) and each centre to the weighted mean of its values, until
// no centre moves beyond np.allclose's tolerance. Every number is the one numpy gets: doubles, sums in numpy's pairwise
// order (eight running sums, then the rest one by one, after numpy's 0.0 start), np.interp's slope times the distance
// plus the start as one fused multiply-add, as the arm64 numpy the script ran on computes it, and nothing else fused
// (the pragma below). A group's values are all distinct in the pinned model, so the sort's order of equal values never
// matters.
//
// The source is mapped, not read: its pages are the file's, which iOS can drop and read again, so the 209 MB never count
// against Spotify's memory. weight.bin is written a megabyte at a time as it is made, and only one weight's indices are
// held at once (2.4 million at most, 1.2 MB packed).
#import <CommonCrypto/CommonDigest.h>
#import <fcntl.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>
#import "Core/SGLog.h"
#import "SGSingLight.h"

#pragma STDC FP_CONTRACT OFF

const long long kSGSingLightWeightBytes = 152276504, kSGSingLightMILBytes = 1346388;
const char *const kSGSingLightSHA256 = "d0d6e71d806084219fb5774fdd472b0a98d3b11d71a09c6cac05c82bcc1e0a05";

enum {
    kAlign = 64,
    kFrom = 64,                 // the full model's table: 6 bits
    kTo = 16,                   // the light one's: 4 bits
    kRounds = 60,
    kDtypeFP16 = 1, kDtypeUInt4 = 11, kDtypeUInt6 = 13,
};
static const uint32_t kSentinel = 0xDEADBEEF;
static const size_t kWriteChunk = 1 << 20;

static const char kBlobRef[] = "BLOBFILE(path = string(\"@model_path/weights/weight.bin\"), offset = uint64(";
static const char kOpHead[] = "constexpr_lut_to_dense(indices = tensor<uint6, [";
static const char kOpMiddle[] = "))), lut = tensor<fp16, [";

#pragma mark - numpy's arithmetic

// numpy's pairwise_sum for up to 128 values (a group has 64): eight running sums, combined in pairs, then the rest.
static double pairwiseSum(const double *a, int n) {
    if (n < 8) {
        double sum = -0.0;
        for (int i = 0; i < n; i++) sum += a[i];
        return sum;
    }
    double r[8];
    for (int j = 0; j < 8; j++) r[j] = a[j];
    int i = 8;
    for (; i < n - (n % 8); i += 8) {
        for (int j = 0; j < 8; j++) r[j] += a[i + j];
    }
    double sum = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]));
    for (; i < n; i++) sum += a[i];
    return sum;
}

// ndarray.sum(): the reduction starts at the identity, 0.0.
static double npSum(const double *a, int n) {
    return 0.0 + pairwiseSum(a, n);
}

// np.interp at one point of increasing `xp`: the last xp at or below x, its value where x is on it, else the slope times
// the distance from it plus its value, fused, as numpy's compiled loop is on arm64.
static double npInterp(double x, const double *xp, const double *fp, int n) {
    if (x < xp[0]) return fp[0];
    if (x > xp[n - 1]) return fp[n - 1];
    int j = 0;
    while (j + 1 < n && xp[j + 1] <= x) j++;
    if (j == n - 1 || xp[j] == x) return fp[j];
    double slope = (fp[j + 1] - fp[j]) / (xp[j + 1] - xp[j]);
    return fma(slope, x - xp[j], fp[j]);
}

// Each sorted value to its nearest centre, the first of two as near (argmin).
static void nearest(const double *v, const double *centres, uint8_t *labels) {
    for (int i = 0; i < kFrom; i++) {
        double best = fabs(v[i] - centres[0]);
        int label = 0;
        for (int j = 1; j < kTo; j++) {
            double d = fabs(v[i] - centres[j]);
            if (d < best) {
                best = d;
                label = j;
            }
        }
        labels[i] = (uint8_t)label;
    }
}

// np.allclose(a, b): |a - b| <= atol + rtol * |b|, or equal.
static BOOL allClose(const double *a, const double *b) {
    for (int j = 0; j < kTo; j++) {
        double scaled = 1e-5 * fabs(b[j]);
        double tolerance = 1e-8 + scaled;
        if (!(fabs(a[j] - b[j]) <= tolerance) && a[j] != b[j]) return NO;
    }
    return YES;
}

// repalettize.py's kmeans_1d: the 64 values of a group and how many weights use each into 16 centres (`centres`) and
// each value's centre (`labels`, in the values' own order).
static void kmeans(const float *values, const uint32_t *counts, double *centres, uint8_t *labels) {
    int order[kFrom];
    for (int i = 0; i < kFrom; i++) {
        int j = i;
        while (j > 0 && values[i] < values[order[j - 1]]) {
            order[j] = order[j - 1];
            j--;
        }
        order[j] = i;
    }
    double v[kFrom], w[kFrom], cw[kFrom];
    for (int i = 0; i < kFrom; i++) {
        v[i] = values[order[i]];
        w[i] = (double)counts[order[i]] + 1e-9;
    }
    // Started at weighted quantiles, so busy regions of the palette keep their resolution.
    double total = npSum(w, kFrom);
    for (int i = 0; i < kFrom; i++) cw[i] = i ? cw[i - 1] + w[i] : w[0];
    for (int i = 0; i < kFrom; i++) cw[i] = cw[i] / total;
    for (int j = 0; j < kTo; j++) centres[j] = npInterp(((double)j + 0.5) / kTo, cw, v, kFrom);
    uint8_t sorted[kFrom];
    double weighted[kFrom], weights[kFrom], next[kTo];
    for (int round = 0; round < kRounds; round++) {
        nearest(v, centres, sorted);
        memcpy(next, centres, sizeof next);
        for (int j = 0; j < kTo; j++) {
            int n = 0;
            for (int i = 0; i < kFrom; i++) {
                if (sorted[i] != j) continue;
                weighted[n] = v[i] * w[i];
                weights[n] = w[i];
                n++;
            }
            if (n) next[j] = npSum(weighted, n) / npSum(weights, n);
        }
        if (allClose(next, centres)) break;
        memcpy(centres, next, sizeof next);
    }
    nearest(v, centres, sorted);
    for (int i = 0; i < kFrom; i++) labels[order[i]] = sorted[i];
}

#pragma mark - weight.bin

typedef struct {
    int fd;
    uint8_t *buffer;
    size_t used;
    uint64_t position;     // bytes written, the buffer's among them
    uint64_t pad;          // zeros owed before the next blob: the last blob ends the file without them
    CC_SHA256_CTX sha;
    int error;             // errno of a failed write
} Writer;

static void flushWriter(Writer *w) {
    size_t done = 0;
    while (!w->error && done < w->used) {
        ssize_t n = write(w->fd, w->buffer + done, w->used - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) w->error = n < 0 ? errno : EIO;
        else done += (size_t)n;
    }
    w->used = 0;
}

static void put(Writer *w, const void *bytes, size_t size) {
    CC_SHA256_Update(&w->sha, bytes, (CC_LONG)size);
    w->position += size;
    const uint8_t *p = bytes;
    while (size && !w->error) {
        size_t n = MIN(size, kWriteChunk - w->used);
        memcpy(w->buffer + w->used, p, n);
        w->used += n;
        p += n;
        size -= n;
        if (w->used == kWriteChunk) flushWriter(w);
    }
}

static void putZeros(Writer *w, size_t size) {
    static const uint8_t zeros[kAlign];
    while (size) {
        size_t n = MIN(size, sizeof zeros);
        put(w, zeros, n);
        size -= n;
    }
}

// One blob, its metadata then its data, after the padding the one before owes; the offset of its metadata.
static uint64_t putBlob(Writer *w, uint32_t dtype, const void *data, uint64_t size) {
    putZeros(w, (size_t)w->pad);
    uint64_t meta = w->position, start = meta + kAlign;
    uint8_t header[kAlign] = {0};
    memcpy(header, &kSentinel, 4);
    memcpy(header + 4, &dtype, 4);
    memcpy(header + 8, &size, 8);
    memcpy(header + 16, &start, 8);
    put(w, header, sizeof header);
    // A large blob copied from the mapped source goes in pieces, so the hash and the buffer see a megabyte at a time.
    const uint8_t *p = data;
    for (uint64_t left = size; left;) {
        size_t n = (size_t)MIN(left, (uint64_t)kWriteChunk);
        put(w, p, n);
        p += n;
        left -= n;
    }
    w->pad = (kAlign - w->position % kAlign) % kAlign;
    return meta;
}

#pragma mark - model.mil

typedef struct {
    NSRange range;          // the whole operation in model.mil
    NSRange indexShape;     // its indices' shape, kept as written
    uint64_t indices, lut;  // the blobs' offsets
    int lutShape[8];
    int lutRank;
} Op;

// The digits at `*at` as a number, `*at` moved past them; NO where there are none.
static BOOL readNumber(const char *text, size_t length, size_t *at, uint64_t *number) {
    size_t i = *at;
    uint64_t value = 0;
    while (i < length && text[i] >= '0' && text[i] <= '9') value = value * 10 + (uint64_t)(text[i++] - '0');
    if (i == *at) return NO;
    *number = value;
    *at = i;
    return YES;
}

static BOOL readLiteral(const char *text, size_t length, size_t *at, const char *literal) {
    size_t n = strlen(literal);
    if (*at + n > length || memcmp(text + *at, literal, n)) return NO;
    *at += n;
    return YES;
}

// A shape, `[0-9, ]+` up to its "]".
static BOOL readShape(const char *text, size_t length, size_t *at, NSRange *range) {
    size_t i = *at;
    while (i < length && ((text[i] >= '0' && text[i] <= '9') || text[i] == ',' || text[i] == ' ')) i++;
    if (i == *at) return NO;
    *range = NSMakeRange(*at, i - *at);
    *at = i;
    return YES;
}

// repalettize.py's OP pattern at `start`.
static BOOL readOp(const char *text, size_t length, size_t start, Op *op) {
    size_t at = start;
    NSRange lutShape;
    if (!readLiteral(text, length, &at, kOpHead) || !readShape(text, length, &at, &op->indexShape)
        || !readLiteral(text, length, &at, "]>(") || !readLiteral(text, length, &at, kBlobRef) || !readNumber(text, length, &at, &op->indices)
        || !readLiteral(text, length, &at, kOpMiddle) || !readShape(text, length, &at, &lutShape)
        || !readLiteral(text, length, &at, "]>(") || !readLiteral(text, length, &at, kBlobRef) || !readNumber(text, length, &at, &op->lut)
        || !readLiteral(text, length, &at, "))))")) return NO;
    op->range = NSMakeRange(start, at - start);
    op->lutRank = 0;
    size_t i = lutShape.location, end = NSMaxRange(lutShape);
    while (i < end) {
        while (i < end && text[i] == ' ') i++;
        uint64_t dimension;
        if (!readNumber(text, end, &i, &dimension) || op->lutRank == 8 || dimension > INT32_MAX) return NO;
        op->lutShape[op->lutRank++] = (int)dimension;
        while (i < end && text[i] == ' ') i++;
        if (i < end && text[i++] != ',') return NO;
    }
    return op->lutRank >= 2;
}

static int sortOffsets(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

#pragma mark - the conversion

typedef struct {
    const uint8_t *data;
    uint64_t size;
} Source;

// The blob whose metadata is at `offset`: its dtype, data and size; NO where there is none.
static BOOL readBlob(Source source, uint64_t offset, uint32_t *dtype, const uint8_t **data, uint64_t *size) {
    if (offset > source.size || source.size - offset < 24) return NO;
    uint32_t sentinel;
    uint64_t start;
    memcpy(&sentinel, source.data + offset, 4);
    memcpy(dtype, source.data + offset + 4, 4);
    memcpy(size, source.data + offset + 8, 8);
    memcpy(&start, source.data + offset + 16, 8);
    if (sentinel != kSentinel || start > source.size || source.size - start < *size) return NO;
    *data = source.data + start;
    return YES;
}

// Index `i` of LSB-first uint6.
static inline uint8_t index6(const uint8_t *packed, uint64_t size, uint64_t i) {
    uint64_t bit = i * 6, byte = bit >> 3;
    unsigned shift = (unsigned)(bit & 7);
    unsigned word = packed[byte];
    if (shift > 2 && byte + 1 < size) word |= (unsigned)packed[byte + 1] << 8;
    return (uint8_t)((word >> shift) & 63);
}


// The position of `value` in the sorted `offsets`, or -1.
static long find(const uint64_t *offsets, size_t count, uint64_t value) {
    size_t low = 0, high = count;
    while (low < high) {
        size_t mid = low + (high - low) / 2;
        if (offsets[mid] < value) low = mid + 1;
        else high = mid;
    }
    return low < count && offsets[low] == value ? (long)low : -1;
}

// The number of indices a shape as model.mil writes it holds.
static uint64_t elements(const char *text, NSRange shape) {
    uint64_t count = 1;
    size_t i = shape.location, end = NSMaxRange(shape);
    while (i < end) {
        while (i < end && (text[i] == ' ' || text[i] == ',')) i++;
        uint64_t dimension;
        if (i < end && readNumber(text, end, &i, &dimension)) count *= dimension;
    }
    return count;
}

// One palettized weight's `n` indices cut to uint4 into `packed` ((n + 1) / 2 bytes) and its table of 64 values a group
// to 16 into `table`, the weights' squared error and size added to `errorNum` and `errorDen` for the log. The groups
// are the table's first axis, and each group's indices follow the last one's.
static NSString *cutWeight(const Op *op, uint64_t n, const uint8_t *indices, uint64_t indicesSize, const uint8_t *lut,
                           uint64_t lutSize, uint8_t *packed, uint16_t *table, double *errorNum, double *errorDen) {
    uint64_t groups = (uint64_t)op->lutShape[0], entries = 1;
    for (int i = 0; i < op->lutRank; i++) entries *= (uint64_t)op->lutShape[i];
    if (!groups || entries != groups * kFrom || op->lutShape[op->lutRank - 2] != kFrom || op->lutShape[op->lutRank - 1] != 1) {
        return [NSString stringWithFormat:@"the table at %llu is not %d values a group", op->lut, kFrom];
    }
    if (n % groups || indicesSize < (n * 6 + 7) / 8 || lutSize != entries * 2) {
        return [NSString stringWithFormat:@"the weight at %llu is not the size its shapes say", op->indices];
    }
    uint64_t per = n / groups;
    memset(packed, 0, (size_t)((n + 1) / 2));
    for (uint64_t g = 0; g < groups; g++) {
        uint32_t counts[kFrom] = {0};
        for (uint64_t i = g * per; i < (g + 1) * per; i++) counts[index6(indices, indicesSize, i)]++;
        float values[kFrom];
        for (int k = 0; k < kFrom; k++) {
            _Float16 half;
            memcpy(&half, lut + (g * kFrom + (uint64_t)k) * 2, 2);
            values[k] = (float)half;
        }
        double centres[kTo];
        uint8_t labels[kFrom];
        kmeans(values, counts, centres, labels);
        _Float16 cut[kTo];
        for (int j = 0; j < kTo; j++) {
            cut[j] = (_Float16)centres[j];
            memcpy(table + g * kTo + (uint64_t)j, &cut[j], 2);
        }
        for (uint64_t i = g * per; i < (g + 1) * per; i++) packed[i >> 1] |= (uint8_t)(labels[index6(indices, indicesSize, i)] << ((i & 1) * 4));
        for (int k = 0; k < kFrom; k++) {
            double before = values[k], after = (double)cut[labels[k]];
            *errorNum += counts[k] * (before - after) * (before - after);
            *errorDen += counts[k] * before * before;
        }
    }
    return nil;
}

// model.mil with every blob's offset moved, the palettized weights' as uint4 with tables of 16.
static NSString *rewriteMIL(const char *mil, size_t length, const Op *ops, size_t opCount, const uint64_t *offsets,
                            const uint64_t *moved, size_t blobCount, NSMutableData *into) {
    size_t refLength = strlen(kBlobRef);
    __block NSString *error;
    uint64_t (^movedOf)(uint64_t) = ^uint64_t(uint64_t offset) {
        long at = find(offsets, blobCount, offset);
        if (at < 0) error = [NSString stringWithFormat:@"model.mil names a blob at %llu that is not in weight.bin", offset];
        return at < 0 ? 0 : moved[at];
    };
    void (^append)(NSString *) = ^(NSString *text) {
        [into appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    };
    // The text between two operations, each blob reference in it moved.
    void (^copyMoving)(size_t, size_t) = ^(size_t from, size_t to) {
        size_t at = from;
        while (at < to) {
            const char *found = to - at >= refLength ? memmem(mil + at, to - at, kBlobRef, refLength) : NULL;
            size_t i = found ? (size_t)(found - mil) + refLength : to;
            uint64_t offset;
            if (!found) {
                [into appendBytes:mil + at length:to - at];
                break;
            }
            if (readNumber(mil, to, &i, &offset) && readLiteral(mil, to, &i, "))")) {
                [into appendBytes:mil + at length:(size_t)(found - mil) - at];
                append([NSString stringWithFormat:@"%s%llu))", kBlobRef, movedOf(offset)]);
                at = i;
            } else {
                [into appendBytes:mil + at length:(size_t)(found - mil) + 1 - at];
                at = (size_t)(found - mil) + 1;
            }
        }
    };
    size_t at = 0;
    for (size_t k = 0; k < opCount; k++) {
        const Op *op = &ops[k];
        copyMoving(at, op->range.location);
        NSMutableArray<NSString *> *shape = [NSMutableArray array];
        for (int i = 0; i < op->lutRank; i++) [shape addObject:@(i == op->lutRank - 2 ? kTo : op->lutShape[i]).stringValue];
        NSString *indexShape = [[NSString alloc] initWithBytes:mil + op->indexShape.location length:op->indexShape.length encoding:NSUTF8StringEncoding];
        append([NSString stringWithFormat:@"constexpr_lut_to_dense(indices = tensor<uint4, [%@]>(%s%llu))), lut = tensor<fp16, [%@]>(%s%llu))))",
                indexShape, kBlobRef, movedOf(op->indices), [shape componentsJoinedByString:@", "], kBlobRef, movedOf(op->lut)]);
        at = NSMaxRange(op->range);
    }
    copyMoving(at, length);
    return error;
}

NSString *SGSingLightConvert(NSURL *full, NSURL *out, BOOL (^progress)(double done), NSString **sha256) {
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    NSFileManager *files = NSFileManager.defaultManager;
    NSData *milData = [NSData dataWithContentsOfURL:[full URLByAppendingPathComponent:@"model.mil"] options:0 error:nil];
    if (!milData) return @"The full model's model.mil could not be read";
    const char *mil = milData.bytes;
    size_t milLength = milData.length;

    // Every blob model.mil names, and the palettized weights among them, in the order they are written.
    NSMutableData *offsetData = [NSMutableData data], *opData = [NSMutableData data];
    size_t refLength = strlen(kBlobRef), headLength = strlen(kOpHead);
    for (size_t at = 0; at + refLength <= milLength;) {
        const char *found = memmem(mil + at, milLength - at, kBlobRef, refLength);
        if (!found) break;
        size_t i = (size_t)(found - mil) + refLength;
        uint64_t offset;
        if (readNumber(mil, milLength, &i, &offset) && readLiteral(mil, milLength, &i, "))")) [offsetData appendBytes:&offset length:sizeof offset];
        at = (size_t)(found - mil) + 1;
    }
    for (size_t at = 0; at + headLength <= milLength;) {
        const char *found = memmem(mil + at, milLength - at, kOpHead, headLength);
        if (!found) break;
        Op op;
        if (readOp(mil, milLength, (size_t)(found - mil), &op)) {
            [opData appendBytes:&op length:sizeof op];
            at = NSMaxRange(op.range);
        } else {
            at = (size_t)(found - mil) + 1;
        }
    }
    uint64_t *offsets = offsetData.mutableBytes;
    size_t refs = offsetData.length / sizeof(uint64_t), blobCount = 0;
    qsort(offsets, refs, sizeof(uint64_t), sortOffsets);
    for (size_t i = 0; i < refs; i++) {
        if (!blobCount || offsets[blobCount - 1] != offsets[i]) offsets[blobCount++] = offsets[i];
    }
    const Op *ops = opData.bytes;
    size_t opCount = opData.length / sizeof(Op);
    if (!opCount) return @"The full model has no palettized weights to cut";
    // Each blob's operation, if it is a palettized weight's indices, and whether it is one's table.
    NSMutableData *roleData = [NSMutableData dataWithLength:blobCount * sizeof(long)];
    long *opOf = roleData.mutableBytes;
    NSMutableData *tableData = [NSMutableData dataWithLength:blobCount];
    uint8_t *isTable = tableData.mutableBytes;
    for (size_t i = 0; i < blobCount; i++) opOf[i] = -1;
    for (size_t k = 0; k < opCount; k++) {
        long indices = find(offsets, blobCount, ops[k].indices), lut = find(offsets, blobCount, ops[k].lut);
        if (indices < 0 || lut < 0 || opOf[indices] >= 0 || isTable[lut]) return @"The full model's palettized weights are not laid out as expected";
        opOf[indices] = (long)k;
        isTable[lut] = 1;
    }

    NSURL *weights = [full URLByAppendingPathComponent:@"weights/weight.bin"];
    int source = open(weights.path.fileSystemRepresentation, O_RDONLY);
    if (source < 0) return [NSString stringWithFormat:@"The full model's weights could not be opened (%s)", strerror(errno)];
    struct stat status;
    void *mapped = fstat(source, &status) == 0 && status.st_size > kAlign ? mmap(NULL, (size_t)status.st_size, PROT_READ, MAP_PRIVATE, source, 0) : MAP_FAILED;
    close(source);
    if (mapped == MAP_FAILED) return @"The full model's weights could not be mapped";
    Source from = {mapped, (uint64_t)status.st_size};
    madvise(mapped, (size_t)from.size, MADV_SEQUENTIAL);
    uint32_t count, version;
    memcpy(&count, from.data, 4);
    memcpy(&version, from.data + 4, 4);
    NSString *error = version != 2 ? [NSString stringWithFormat:@"The full model's weights are version %u, not 2", version]
                    : count != blobCount ? [NSString stringWithFormat:@"weight.bin holds %u blobs and model.mil names %zu", count, blobCount] : nil;

    // The folder, written from scratch.
    NSURL *outWeights = [out URLByAppendingPathComponent:@"weights/weight.bin"];
    NSError *fileError;
    if (!error && [files fileExistsAtPath:out.path]) error = @"The light model's folder is in the way";
    if (!error && (![files createDirectoryAtURL:outWeights.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&fileError]
                   || ![files createDirectoryAtURL:[out URLByAppendingPathComponent:@"analytics"] withIntermediateDirectories:YES attributes:nil error:&fileError])) {
        error = [NSString stringWithFormat:@"The light model's folder could not be made (%@)", fileError.localizedDescription];
    }
    Writer w = {.fd = -1};
    if (!error) {
        w.fd = open(outWeights.path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (w.fd < 0) error = [NSString stringWithFormat:@"The light model's weights could not be written (%s)", strerror(errno)];
    }
    NSMutableData *bufferData = [NSMutableData dataWithLength:kWriteChunk];
    w.buffer = bufferData.mutableBytes;
    CC_SHA256_Init(&w.sha);
    uint8_t header[kAlign] = {0};
    memcpy(header, &count, 4);
    memcpy(header + 4, &version, 4);
    if (!error) put(&w, header, sizeof header);

    // The blobs in the order of their offsets, each palettized weight's table right after its indices.
    NSMutableData *movedData = [NSMutableData dataWithLength:blobCount * sizeof(uint64_t)];
    uint64_t *moved = movedData.mutableBytes;
    NSMutableData *packedData = [NSMutableData data], *lutOut = [NSMutableData data];
    double errorNum = 0, errorDen = 0, reported = 0;
    uint64_t done = 0;
    for (size_t b = 0; b < blobCount && !error; b++) {
        if (isTable[b]) continue;   // written with its indices
        uint32_t dtype;
        const uint8_t *data;
        uint64_t size;
        if (!readBlob(from, offsets[b], &dtype, &data, &size)) {
            error = [NSString stringWithFormat:@"weight.bin has no blob at %llu", offsets[b]];
            break;
        }
        done += size;
        if (opOf[b] < 0) {
            moved[b] = putBlob(&w, dtype, data, size);
        } else {
            const Op *op = &ops[opOf[b]];
            uint32_t lutType;
            const uint8_t *lut;
            uint64_t lutSize, n = elements(mil, op->indexShape);
            if (dtype != kDtypeUInt6 || !readBlob(from, op->lut, &lutType, &lut, &lutSize)) {
                error = [NSString stringWithFormat:@"the weight at %llu is not uint6 indices with a table", offsets[b]];
                break;
            }
            done += lutSize;
            packedData.length = (NSUInteger)((n + 1) / 2);
            lutOut.length = (NSUInteger)op->lutShape[0] * kTo * 2;
            error = cutWeight(op, n, data, size, lut, lutSize, packedData.mutableBytes, lutOut.mutableBytes, &errorNum, &errorDen);
            if (error) break;
            moved[b] = putBlob(&w, kDtypeUInt4, packedData.bytes, packedData.length);
            moved[find(offsets, blobCount, op->lut)] = putBlob(&w, kDtypeFP16, lutOut.bytes, lutOut.length);
        }
        if (w.error) error = [NSString stringWithFormat:@"The light model's weights could not be written (%s)", strerror(w.error)];
        double fraction = (double)done / (double)from.size;
        if (!error && progress && fraction - reported >= 0.005) {
            reported = fraction;
            if (!progress(fraction)) error = @"Stopped";
        }
    }
    munmap(mapped, (size_t)from.size);
    // The blobs' data is most of the file but not all of it (the metadata), so the end is said outright.
    if (!error && progress) progress(1);
    // The last blob ends the file: the padding it would owe the next one is never written.
    if (w.fd >= 0) {
        if (!error) flushWriter(&w);
        if (!error && w.error) error = [NSString stringWithFormat:@"The light model's weights could not be written (%s)", strerror(w.error)];
        if (!error && fsync(w.fd) != 0) error = [NSString stringWithFormat:@"The light model's weights could not be written (%s)", strerror(errno)];
        close(w.fd);
    }
    if (error) return error;

    NSMutableData *newMIL = [NSMutableData dataWithCapacity:milLength];
    error = rewriteMIL(mil, milLength, ops, opCount, offsets, moved, blobCount, newMIL);
    if (error) return error;
    if (![newMIL writeToURL:[out URLByAppendingPathComponent:@"model.mil"] options:NSDataWritingAtomic error:&fileError]) {
        return [NSString stringWithFormat:@"The light model's model.mil could not be written (%@)", fileError.localizedDescription];
    }
    for (NSString *name in @[@"coremldata.bin", @"metadata.json", @"analytics/coremldata.bin"]) {
        if (![files copyItemAtURL:[full URLByAppendingPathComponent:name] toURL:[out URLByAppendingPathComponent:name] error:&fileError]) {
            return [NSString stringWithFormat:@"The full model's %@ could not be copied (%@)", name, fileError.localizedDescription];
        }
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &w.sha);
    NSMutableString *hex = [NSMutableString stringWithCapacity:2 * CC_SHA256_DIGEST_LENGTH];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    if (sha256) *sha256 = hex;
    SGLog(@"sing: the light model is made: %zu weights cut to 4 bits, weight.bin %.1f -> %.1f MB, relative weight error %.4f, in %.1f s",
          opCount, from.size / 1e6, w.position / 1e6, sqrt(errorNum / MAX(errorDen, 1e-30)), CFAbsoluteTimeGetCurrent() - began);
    return nil;
}
