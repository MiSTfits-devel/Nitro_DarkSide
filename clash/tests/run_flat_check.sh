#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Simulation gate for the streaming flat-triangle Clash top.
#
# Runs the real 'flatRaster' mealy machine under Clash simulation, once with
# outReady tied high and once with a stalled ready pattern, and compares the
# expanded spans against 'rasterTri'. Nothing here needs Quartus or a board.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cases=${CASES:-5000}
out=${TMPDIR:-/tmp}/nds-gpu3d-flat-check

mkdir -p "$out"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/FlatCheck.hs src/Nds/Gpu3D/Flat.hs src/Nds/Gpu3D/Raster.hs \
    src/Nds/Gpu3D/Slope.hs -o "$out/flat-check" >/dev/null

exec "$out/flat-check" "$cases"
