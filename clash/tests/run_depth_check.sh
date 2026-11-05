#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Native differential gate for the Clash depth interpolator.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
melonds=${MELONDS_DIR:-$repo/../NDS4MiSTer/third_party/melonDS}
cases=${CASES:-200000}
out=${TMPDIR:-/tmp}/nds-gpu3d-depth-check

mkdir -p "$out"

c++ -std=c++20 -O2 \
    -I"$melonds/src" \
    "$here/test/oracle/slope_oracle.cpp" \
    -o "$out/slope_oracle"

"$out/slope_oracle" "$cases" > "$out/depth.txt"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/DepthCheck.hs src/Nds/Gpu3D/Depth.hs -o "$out/depth-check" >/dev/null
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/NormCheck.hs src/Nds/Gpu3D/Depth.hs -o "$out/norm-check" >/dev/null

"$out/depth-check" "$out/depth.txt"
exec "$out/norm-check" "$out/depth.txt"
