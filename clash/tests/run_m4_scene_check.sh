#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# M4 directed/seeded synthetic full-frame gate.
#
# tools/gx3d_scene_oracle.cpp generates real GX geometry plus 2D background/
# sprite/window/blend state, drives production GPU3D and SoftRenderer2D, and
# streams a v12 NSD2 trace. Recorded type3 3D lines and type8 screen lines are
# expected-only. Two independent checks then run on that trace:
#  1. tools/gx3d_trace_oracle.cpp replays the raw inputs through production
#     GPU3D and must reproduce every recorded type3 line.
#  2. clash/test/M4Check.hs replays the raw inputs through Nds.Gpu3D.Chip and
#     the Haskell unified composition and must reproduce type3 and type8.
#
# No shared build/config edits. Usage: run_m4_scene_check.sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
out=${TMPDIR:-/tmp}/nds-m4-scene-check
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

build_oracle() {
    name=$1
    "$cxx" -I "$melonds/src" -I "$build/melonds-core/src" -O2 -DNDEBUG \
        -std=gnu++17 -arch "$arch" -fwrapv -c "$repo/tools/$name.cpp" -o "$out/$name.o"
    "$cxx" -O2 -DNDEBUG -arch "$arch" "$out/$name.o" "$platform" \
        "$libcore" "$libteakra" -o "$out/$name"
}
build_oracle gx3d_scene_oracle
build_oracle gx3d_trace_oracle

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    -outputdir "$out/obj" test/M4Check.hs -o "$out/m4-check"

trace=$out/scene.nsd2
"$out/gx3d_scene_oracle" "$trace"
"$out/gx3d_trace_oracle" "$trace"
"$out/m4-check" "$trace"
