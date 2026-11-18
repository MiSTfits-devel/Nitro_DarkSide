#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Independent composed-scanline differential. tools/gx2d_compose_oracle.cpp
# drives production melonDS sprite+scanline scanout with full phase inputs and
# streams a real NSD2 v10 trace; clash/test/ComposeCheck.hs replays that trace
# through the current Haskell trace/line path and compares its top/bottom
# lines with the production framebuffer records. Deliberately not part of
# run_pixel_gate.sh and no shared build-file edits: the oracle object is
# compiled directly against the existing vendored core build.
#
# Usage: run_compose_check.sh [trace-out]
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
out=${TMPDIR:-/tmp}/nds-gpu2d-compose-check
melonds=${MELONDS_DIR:-$repo/third_party/melonDS}
build=${BUILD_DIR:-$repo/sim/melonds_tracer/build-vendored}
cxx=${CXX:-/usr/bin/c++}
arch=${ARCH:-$(uname -m)}

mkdir -p "$out"
if [ ! -f "$build/melonds-core/src/libcore.a" ]; then
    cmake -S "$repo/sim/melonds_tracer" -B "$build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DMELONDS_DIR="$melonds"
    cmake --build "$build" --target nds_gx2d_bg_oracle
fi
libcore=$build/melonds-core/src/libcore.a
libteakra=$build/melonds-core/src/teakra/src/libteakra.a
platform=$build/CMakeFiles/nds_gx2d_bg_oracle.dir/Platform.cpp.o
if [ ! -f "$platform" ]; then
    "$cxx" -I "$melonds/src" -I "$build/melonds-core/src" -O2 -DNDEBUG \
        -std=gnu++17 -arch "$arch" -fwrapv -c "$repo/sim/melonds_tracer/Platform.cpp" \
        -o "$out/Platform.o"
    platform=$out/Platform.o
fi

"$cxx" -I "$melonds/src" -I "$build/melonds-core/src" -O2 -DNDEBUG \
    -std=gnu++17 -arch "$arch" -fwrapv -c "$repo/tools/gx2d_compose_oracle.cpp" \
    -o "$out/compose_oracle.o"
"$cxx" -O2 -DNDEBUG -arch "$arch" "$out/compose_oracle.o" "$platform" \
    "$libcore" "$libteakra" -o "$out/compose-oracle"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    -outputdir "$out/obj" test/ComposeCheck.hs -o "$out/compose-check"

trace=${1:-$out/trace.nsd2}
"$out/compose-oracle" "$trace"
if ! "$out/compose-check" "$trace" "$trace.cases"; then
    echo "compose-check: failing trace kept at $trace" >&2
    exit 1
fi
