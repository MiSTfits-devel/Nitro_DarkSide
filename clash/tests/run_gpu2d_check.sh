#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Native gate for the Clash 2D engine.
#
# The pure 2D line model is checked against melonDS indirectly through the
# speculative engine: both the reference path and the one-pass path run the same
# line renderer, so the gate's job is the pixel equality of the two passes and
# the TARDIS/one-pass bookkeeping. The 2D model itself has a separate pixel
# gate against melonDS, added when the 2D oracle lands.
#
# Runs the monad laws, the speculative frame gate and the unified 2D/3D gate.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${TMPDIR:-/tmp}/nds-gpu2d-check

mkdir -p "$out"

cd "$here"
stack --resolver lts-22.43 ghc -- -fno-code -isrc src/Nds/Gpu2D/*.hs src/Nds/Gpu/Unified.hs

stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/LineCheck.hs src/Nds/Gpu2D/Types.hs src/Nds/Gpu2D/Line.hs \
    -o "$out/line-check" >/dev/null
"$out/line-check"

stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/TardisCheck.hs src/Nds/Gpu2D/Tardis.hs -o "$out/tardis-check" >/dev/null
"$out/tardis-check"

stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/SpeculateCheck.hs \
    src/Nds/Gpu2D/Types.hs src/Nds/Gpu2D/Line.hs \
    src/Nds/Gpu2D/Tardis.hs src/Nds/Gpu2D/Speculate.hs \
    -o "$out/speculate-check" >/dev/null
"$out/speculate-check"

stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/UnifiedCheck.hs \
    src/Nds/Gpu2D/Types.hs src/Nds/Gpu2D/Line.hs \
    -o "$out/unified-check" >/dev/null
"$out/unified-check"
