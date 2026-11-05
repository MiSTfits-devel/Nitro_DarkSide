#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Native differential gate for the Clash flat-triangle rasteriser.
#
# The oracle is the production melonDS SoftRenderer3D, driven directly with
# synthetic polygons. The Haskell model is the same fill rule written for Clash.
# Nothing here needs Quartus, a board, or a ROM.
# DISPCNT selects the production DISP3DCNT; the flat top uses 0x20.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
melonds=${MELONDS_DIR:-$repo/../NDS4MiSTer/third_party/melonDS}
cases=${CASES:-5000}
dispcnt=${DISPCNT:-0}
out=${TMPDIR:-/tmp}/nds-gpu3d-raster-check

mkdir -p "$out"

cmake -S "$repo/tools/gx3d_oracle" -B "$out/build" \
    -DMELONDS_DIR="$melonds" >/dev/null
cmake --build "$out/build" --target nds_gx3d_oracle >/dev/null

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/RasterCheck.hs src/Nds/Gpu3D/Raster.hs \
    -o "$out/raster-check" >/dev/null
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/GenCases.hs -o "$out/gen-cases" >/dev/null
cd "$repo"

"$out/gen-cases" "$cases" "$out/cases.txt"
ORACLE_DISPCNT="$dispcnt" "$out/build/nds_gx3d_oracle" < "$out/cases.txt" > "$out/oracle.rgba"
"$out/raster-check" "$out/cases.txt" "$out/oracle.rgba" "$dispcnt"
