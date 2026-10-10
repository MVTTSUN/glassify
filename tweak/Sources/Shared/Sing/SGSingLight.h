// The light voice model (Sing.h), made on the iPhone from the full one: separator-ane.mlmodelc's 309 palettized weights
// (constexpr_lut_to_dense: uint6 indices into a fp16 table of 64 values per group of output channels) cut to 16 values
// and uint4 indices, the graph, its shapes and coremldata.bin, metadata.json and analytics/coremldata.bin as they are.
// weight.bin goes from 209.1 to 152.3 MB; Core ML loads it as it does the full model, and its vocals are a little
// coarser (2.67 dB against 3.03 dB on harness/sing's synthetic mix, 8.4 dB agreement between the two).
//
// It is harness/sing/light/repalettize.py in C, byte for byte: harness/sing/light/build.sh builds this file for the Mac
// and checks its weight.bin and model.mil against the script's. Its k-means is numpy's arithmetic, in double precision
// and in numpy's order (pairwise sums, np.interp's fused multiply-add), so the file comes out the same on every iPhone
// and on the Mac (kSGSingLightSHA256).
//
// Threading: any thread but the main one; one conversion at a time per output folder.
#import <Foundation/Foundation.h>

// The light model's weight.bin and model.mil, as the conversion of the pinned full model makes them.
extern const long long kSGSingLightWeightBytes, kSGSingLightMILBytes;
extern const char *const kSGSingLightSHA256;   // weight.bin's

// Writes the light model of the compiled model in `full` into `out`, a folder it creates (it must not exist yet).
// `progress` is called now and then with how far it has come, 0 to 1, and stops the conversion when it returns NO.
// Nil when it is done, else why it is not (stopped among them; `out` is then left half written for the caller to
// remove). `sha256` is weight.bin's, in hex, when it is done.
NSString *SGSingLightConvert(NSURL *full, NSURL *out, BOOL (^progress)(double done), NSString **sha256);
