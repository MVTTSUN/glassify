// The Visualizer's spectrum (SGRSpectrum.h): a ring of the last kSize samples, analyzed every kHop. One FFT feeds
// both the hills' bands and the shaders' snapshot.
#import <Accelerate/Accelerate.h>
#import <math.h>
#import <stdatomic.h>
#import <string.h>
#import "SGRSpectrum.h"

enum { kLog2Size = 12, kSize = 1 << kLog2Size, kHalf = kSize / 2, kHop = 1024 };
// The bands' edges: a kick's fundamental at the bottom, the air of cymbals at the top.
static const double kLowest = 50, kHighest = 14000;
// The snapshot's bands, a little wider at both ends.
static const double kFineLowest = 30, kFineHighest = 16000;
// A beat: the power from kBeatLow to kBeatHigh Hz kBeatRise dB over its own average of the last kBeatMemory seconds
// (averaged as power, so a steady bass catches up within a second), louder than kBeatFloor dB and still rising by
// kBeatStep dB a hop, at most one in kBeatGap seconds.
static const double kBeatLow = 40, kBeatHigh = 150, kBeatMemory = 1.0, kBeatGap = 0.25;
static const float kBeatRise = 3, kBeatFloor = -60, kBeatStep = 0.25f;

// Main thread, once, before the render thread reads them.
static FFTSetup sg_setup;
static float sg_window[kSize];
static atomic_bool sg_prepared;

// The render thread's own.
static float sg_ring[kSize], sg_windowed[kSize], sg_real[kHalf], sg_imag[kHalf], sg_power[kHalf];
static uint32_t sg_at, sg_sinceLast, sg_filled;
static double sg_rate;
static uint32_t sg_from[SGRSpectrumBands], sg_to[SGRSpectrumBands];   // bins, the end not included
static uint32_t sg_fineFrom[SGRSpectrumFineBands], sg_fineTo[SGRSpectrumFineBands];
static uint32_t sg_bassFrom, sg_bassTo;
static float sg_bassMean, sg_bassBefore = SGRSpectrumFloor;   // the mean as power, the last as dB
static double sg_sinceBeat;   // seconds
static uint64_t sg_beatCount;

// Published.
static _Atomic(float) sg_levels[SGRSpectrumBands];
static _Atomic(uint64_t) sg_generation;
// The snapshot, written under sg_sequence: odd while the render thread writes it.
static _Atomic(uint32_t) sg_sequence;
static _Atomic(float) sg_fine[SGRSpectrumFineBands], sg_rms;
static _Atomic(uint64_t) sg_beats;

void SGRSpectrumPrepare(void) {
    if (atomic_load(&sg_prepared)) return;
    sg_setup = vDSP_create_fftsetup(kLog2Size, kFFTRadix2);
    vDSP_hann_window(sg_window, kSize, vDSP_HANN_DENORM);
    for (int band = 0; band < SGRSpectrumBands; band++) atomic_store(&sg_levels[band], SGRSpectrumFloor);
    for (int band = 0; band < SGRSpectrumFineBands; band++) atomic_store(&sg_fine[band], SGRSpectrumFloor);
    atomic_store(&sg_rms, SGRSpectrumFloor);
    atomic_store_explicit(&sg_prepared, true, memory_order_release);
}

// A band takes the bins whose middles are in it, and at least one, so the low bands, narrower than a bin, still
// read something; two of them can read the same bin.
static void bandEdges(double rate, double lowest, double highest, int count, uint32_t *froms, uint32_t *tos) {
    double binHz = rate / kSize, ratio = pow(highest / lowest, 1.0 / count);
    for (int band = 0; band < count; band++) {
        double low = lowest * pow(ratio, band), high = low * ratio;
        uint32_t from = (uint32_t)fmax(1, ceil(low / binHz)), to = (uint32_t)fmin(kHalf, ceil(high / binHz));
        if (from >= kHalf) from = kHalf - 1;
        froms[band] = from;
        tos[band] = to > from ? to : from + 1;
    }
}

static void setRate(double rate) {
    sg_rate = rate;
    sg_at = sg_sinceLast = sg_filled = 0;
    memset(sg_ring, 0, sizeof sg_ring);
    bandEdges(rate, kLowest, kHighest, SGRSpectrumBands, sg_from, sg_to);
    bandEdges(rate, kFineLowest, kFineHighest, SGRSpectrumFineBands, sg_fineFrom, sg_fineTo);
    double binHz = rate / kSize;
    sg_bassFrom = (uint32_t)fmax(1, ceil(kBeatLow / binHz));
    sg_bassTo = (uint32_t)fmax(sg_bassFrom + 1, ceil(kBeatHigh / binHz));
    sg_bassMean = 0;
    sg_bassBefore = SGRSpectrumFloor;
    sg_sinceBeat = kBeatGap;
}

static float bandLevel(uint32_t from, uint32_t to, float scale) {
    float sum = 0;
    vDSP_sve(sg_power + from, 1, &sum, to - from);
    return sum > 0 ? fmaxf(SGRSpectrumFloor, 10 * log10f(sum * scale)) : SGRSpectrumFloor;
}

// A beat is the low end jumping over its own recent average while still on the way up.
static void listenForBeat(float scale) {
    float bass = bandLevel(sg_bassFrom, sg_bassTo, scale), power = powf(10, bass / 10);
    float mean = sg_bassMean > 0 ? 10 * log10f(sg_bassMean) : SGRSpectrumFloor;
    double hop = kHop / sg_rate;
    sg_sinceBeat += hop;
    if (bass > kBeatFloor && bass - mean > kBeatRise && bass > sg_bassBefore + kBeatStep && sg_sinceBeat >= kBeatGap) {
        sg_beatCount++;
        sg_sinceBeat = 0;
    }
    sg_bassMean += (power - sg_bassMean) * (float)fmin(1, hop / kBeatMemory);
    sg_bassBefore = bass;
}

// The snapshot, under the sequence count: odd while it is written, so a reader that saw it change reads again.
static void publishSnapshot(float scale) {
    float rms = 0;
    vDSP_rmsqv(sg_ring + ((sg_at - kHop) & (kSize - 1)), 1, &rms, kHop);
    uint32_t sequence = atomic_load_explicit(&sg_sequence, memory_order_relaxed);
    atomic_store_explicit(&sg_sequence, sequence + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    for (int band = 0; band < SGRSpectrumFineBands; band++) {
        atomic_store_explicit(&sg_fine[band], bandLevel(sg_fineFrom[band], sg_fineTo[band], scale), memory_order_relaxed);
    }
    atomic_store_explicit(&sg_rms, rms > 0 ? fmaxf(SGRSpectrumFloor, 20 * log10f(rms)) : SGRSpectrumFloor, memory_order_relaxed);
    atomic_store_explicit(&sg_beats, sg_beatCount, memory_order_relaxed);
    atomic_store_explicit(&sg_sequence, sequence + 2, memory_order_release);
}

// The power over a band, summed, as a full scale sine's: a Hann window keeps 3/8 of a sine's power over its
// bins, and vDSP's real FFT gives twice the DFT, so a sine of amplitude A sums to 3/8 * kSize^2 * A^2 here.
static void analyse(void) {
    // The ring from its oldest sample, windowed.
    uint32_t tail = kSize - sg_at;
    vDSP_vmul(sg_ring + sg_at, 1, sg_window, 1, sg_windowed, 1, tail);
    vDSP_vmul(sg_ring, 1, sg_window + tail, 1, sg_windowed + tail, 1, sg_at);
    DSPSplitComplex split = {sg_real, sg_imag};
    vDSP_ctoz((const DSPComplex *)sg_windowed, 2, &split, 1, kHalf);
    vDSP_fft_zrip(sg_setup, &split, 1, kLog2Size, kFFTDirection_Forward);
    // The first bin's imaginary part is the Nyquist bin's real one, which no band reaches.
    sg_imag[0] = 0;
    vDSP_zvmags(&split, 1, sg_power, 1, kHalf);
    const float scale = 1.0f / (0.375f * (float)kSize * (float)kSize);
    for (int band = 0; band < SGRSpectrumBands; band++) {
        atomic_store_explicit(&sg_levels[band], bandLevel(sg_from[band], sg_to[band], scale), memory_order_relaxed);
    }
    listenForBeat(scale);
    publishSnapshot(scale);
    atomic_fetch_add_explicit(&sg_generation, 1, memory_order_release);
}

void SGRSpectrumFeed(const float *samples, uint32_t count, double sampleRate) {
    if (!samples || sampleRate <= 0 || !atomic_load_explicit(&sg_prepared, memory_order_acquire)) return;
    if (sampleRate != sg_rate) setRate(sampleRate);
    while (count) {
        uint32_t run = count;
        if (run > kSize - sg_at) run = kSize - sg_at;
        if (run > kHop - sg_sinceLast) run = kHop - sg_sinceLast;
        memcpy(sg_ring + sg_at, samples, run * sizeof(float));
        samples += run;
        count -= run;
        sg_at = (sg_at + run) & (kSize - 1);
        sg_sinceLast += run;
        if (sg_filled < kSize) sg_filled += run;
        if (sg_sinceLast == kHop) {
            sg_sinceLast = 0;
            // Not before the ring is full once: a window half of zeros would read a step in the sound.
            if (sg_filled >= kSize) analyse();
        }
    }
}

uint64_t SGRSpectrumRead(float levels[SGRSpectrumBands]) {
    uint64_t generation = atomic_load_explicit(&sg_generation, memory_order_acquire);
    for (int band = 0; band < SGRSpectrumBands; band++) {
        levels[band] = atomic_load_explicit(&sg_levels[band], memory_order_relaxed);
    }
    return generation;
}

uint64_t SGRSpectrumReadSnapshot(SGRSpectrumSnapshot *snapshot) {
    uint64_t generation = atomic_load_explicit(&sg_generation, memory_order_acquire);
    // A few tries; the render thread writes for microseconds every 20 ms, so a second one all but always lands.
    for (int attempt = 0; attempt < 4; attempt++) {
        uint32_t before = atomic_load_explicit(&sg_sequence, memory_order_acquire);
        for (int band = 0; band < SGRSpectrumFineBands; band++) {
            snapshot->levels[band] = atomic_load_explicit(&sg_fine[band], memory_order_relaxed);
        }
        snapshot->rms = atomic_load_explicit(&sg_rms, memory_order_relaxed);
        snapshot->beats = atomic_load_explicit(&sg_beats, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (!(before & 1) && atomic_load_explicit(&sg_sequence, memory_order_relaxed) == before) break;
    }
    return generation;
}
