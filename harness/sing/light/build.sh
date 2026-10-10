#!/bin/sh
# Builds the light model's check for the Mac: tweak/Sources/Shared/Sing/SGSingLight.m as the tweak compiles it, with
# ../shim/Core/SGLog.h printing its log line, and main.m.
#   ./build.sh && ../build/light <separator-ane.mlmodelc> <out.mlmodelc> <repalettize.py's separator-light.mlmodelc> [load]
# makes the light model from the full one as the iPhone does, stops one conversion a third of the way in, and checks
# every file of the one it finishes byte for byte against the script's (python3 -I repalettize.py <full> <light>).
# With `load`, SGSingLoader.m then loads the light model alone on the Neural Engine and separates a window on it, and
# falls back to the CPU alone when that copy is past its deadline.
set -e
cd "$(dirname "$0")"
SRC=../../../tweak/Sources
mkdir -p ../build
xcrun clang -fobjc-arc -O2 -g -Wall -Werror -target arm64-apple-macos15.0 \
    -I ../shim -I "$SRC" main.m "$SRC/Shared/Sing/SGSingLight.m" "$SRC/Shared/Sing/SGSingLoader.m" "$SRC/Shared/Sing/SGSingSeparator.m" \
    -framework Foundation -framework CoreML -framework Accelerate -o ../build/light
echo "built ../build/light"
