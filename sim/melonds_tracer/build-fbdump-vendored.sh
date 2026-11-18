#!/bin/sh
# Build melonds_fbdump against this checkout's vendored NDS4MiSTer fork.
# Never mixes upstream headers: MELONDS_DIR defaults to third_party/melonDS and
# can only be overridden to another checkout that contains the NSD2 trace
# header. Output: sim/melonds_tracer/build-vendored/melonds_fbdump.
#
#   sim/melonds_tracer/build-fbdump-vendored.sh
#   MELONDS_DIR=/path/to/fork BUILD_DIR=/tmp/fbdump-build sim/.../build.sh
set -eu
cd "$(dirname "$0")"

repo=$(CDPATH= cd -- ../.. && pwd)
MELONDS_DIR="${MELONDS_DIR:-$repo/third_party/melonDS}"
BUILD_DIR="${BUILD_DIR:-$(pwd)/build-vendored}"

if [ ! -f "$MELONDS_DIR/src/NDS4MiSTer_2DTrace.h" ]; then
    echo "MELONDS_DIR=$MELONDS_DIR has no src/NDS4MiSTer_2DTrace.h;" >&2
    echo "this runner must use the vendored NDS4MiSTer fork" >&2
    exit 1
fi

cmake -S . -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DMELONDS_DIR="$MELONDS_DIR"
cmake --build "$BUILD_DIR" --target melonds_fbdump
echo "built: $BUILD_DIR/melonds_fbdump"
