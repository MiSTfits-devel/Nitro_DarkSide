#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# M4 3D replay gate. Requires a v12 NSD2 trace captured with
#   melonds_fbdump --trace2d FILE --trace2d-raw3d ...
# Two independent checks run:
#  1. tools/gx3d_trace_oracle.cpp replays the ordered v12 raw inputs (type26
#     GX bus writes, type20-25 control/timing, type2 deltas) through melonDS's
#     own GPU3D/software renderer and requires every recorded type3 line to
#     match. This proves the trace inputs are complete for 3D.
#  2. clash/test/M4Check.hs replays the same inputs through Nds.Gpu3D.Chip and
#     compares its lines and the unified composition against recorded type3 /
#     type8 lines. Recorded pixels are expected-only.
#
# No shared build/config edits: the oracle object is compiled directly
# against the existing vendored core build. Usage: run_m4_check.sh TRACE.nsd2
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
trace=${1:?usage: run_m4_check.sh TRACE.nsd2}
out=${TMPDIR:-/tmp}/nds-m4-check
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
    -std=gnu++17 -arch "$arch" -fwrapv -c "$repo/tools/gx3d_trace_oracle.cpp" \
    -o "$out/gx3d_trace_oracle.o"
"$cxx" -O2 -DNDEBUG -arch "$arch" "$out/gx3d_trace_oracle.o" "$platform" \
    "$libcore" "$libteakra" -o "$out/gx3d-trace-oracle"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    -outputdir "$out/obj" test/M4Check.hs -o "$out/m4-check"

"$out/gx3d-trace-oracle" "$trace"
"$out/m4-check" "$trace"
