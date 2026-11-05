#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Exhaustive-plus-random row gate for the flat rasteriser. This is the fast
# pixel-perfect check: it compares the fast row union against the exact
# melonDS three-segment fill on every ordered vertex triple in a small grid,
# then on random large-coordinate triangles.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cases=${CASES:-200000}
out=${TMPDIR:-/tmp}/nds-gpu3d-flat-property

mkdir -p "$out"
cd "$here"

stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/FlatProperty.hs src/Nds/Gpu3D/Flat.hs src/Nds/Gpu3D/Raster.hs \
    src/Nds/Gpu3D/Slope.hs -o "$out/flat-property" >/dev/null

exec "$out/flat-property" "$cases"
