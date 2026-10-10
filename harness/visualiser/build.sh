#!/bin/sh
# Builds the Visualizer's checks for the Mac: SGRSpectrum.m as the tweak compiles it, under main.m, and the shaders'
# sources (SGRShaderSource.m) under shaders.m, which compiles and draws them through Metal.
set -e
cd "$(dirname "$0")"
mkdir -p build
xcrun clang -fobjc-arc -O2 -Wall -Werror -I ../../tweak/Sources -framework Foundation -framework Accelerate \
    main.m ../../tweak/Sources/Redesigned/Player/SGRSpectrum.m -o build/spectrum
echo "built build/spectrum"
xcrun clang -fobjc-arc -O2 -Wall -Werror -I ../../tweak/Sources -framework Foundation -framework Metal -framework CoreGraphics \
    -framework ImageIO -framework UniformTypeIdentifiers shaders.m ../../tweak/Sources/Redesigned/Player/SGRShaderSource.m -o build/shaders
echo "built build/shaders"
