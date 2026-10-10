# Visualizer harness

The player's Visualizer background reads Spotify's sound through `Redesigned/Player/SGRSpectrum.m`. `main.m`
runs it on the Mac as the tweak compiles it, fed in IO buffers of 1024 the way `PlayerVisualiser.m` is fed by
`AudioEffects.x`'s reader:

    ./build.sh && build/spectrum

It checks that nothing is analyzed before the tables are made, that a full scale 1 kHz sine reads 0 dB in its band
(and a tenth of it -20 dB) with every band more than one away at least 30 dB under, that 56 Hz and 10 kHz land in
the lowest band and the last but one at 48 and 44.1 kHz, that silence reads the floor, that white noise rises
about 3 dB an octave over the bands, and that it analyzes about 47 times a second at 48 kHz; then the shaders'
snapshot: 1 kHz in its band of 32 with the loudness at -3 dB, eight kicks read as about eight beats and steady bass
as none. The log ends with `spectrum checks: n of 14 right -- PASS` or `FAIL`.

The view itself is laid out in the player harness (`harness/player`, scenario `visualiser`).

`build/shaders` checks the shaders (`Redesigned/Player/SGRShaderSource.m`) through the Mac's Metal runtime compiler,
the way the player compiles them with `newLibraryWithSource:`: every built-in body and the custom template compile,
each draws one frame of a made-up loud passage on a beat into `build/<name>.png` with nothing brighter than the
ceiling (0.14 relative luminance) over the field, and a broken body's error is told at the body's own line. The log
ends with `shader checks: n of 9 right -- PASS` or `FAIL`. (`xcrun metal` needs the Metal Toolchain component; the
runtime compiler does not.)
