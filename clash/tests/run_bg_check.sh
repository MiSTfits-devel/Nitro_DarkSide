#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Standalone BG differential: production SoftRenderer2D BG line vs
# Nds.Gpu2D.Line.renderReferenceLine. Builds its own oracle and checker; it is
# deliberately not part of run_pixel_gate.sh. Directed cases then seeded random
# cases; the directed count clamps to the directed table. Usage:
# run_bg_check.sh [directed] [random]
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
directed=${1:-64}
random=${2:-120}
out=${TMPDIR:-/tmp}/nds-gpu2d-bg-check
melonds=${MELONDS_DIR:-$repo/third_party/melonDS}
build=${BUILD_DIR:-$repo/sim/melonds_tracer/build-vendored}

mkdir -p "$out"
if [ ! -f "$build/build.ninja" ]; then
    cmake -S "$repo/sim/melonds_tracer" -B "$build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DMELONDS_DIR="$melonds"
fi
cmake --build "$build" --target nds_gx2d_bg_oracle

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/BgCheck.hs src/Nds/Gpu2D/Line.hs src/Nds/Gpu2D/Types.hs \
    -o "$out/bg-check"

"$build/nds_gx2d_bg_oracle" "$directed" "$random" > "$out/oracle.bin"
if ! "$out/bg-check" "$out/oracle.bin"; then
    echo "bg-check: failing oracle kept at $out/oracle.bin" >&2
    exit 1
fi
