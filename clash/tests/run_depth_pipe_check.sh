#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Streaming depth-engine gate: the flat rasteriser feeding Nds.Gpu3D.DepthPipe,
# run against a behavioural depth memory (variable read latency, output stalls,
# power-on garbage cleared by the engine itself) and compared with the frame
# model, which run_frame_check.sh compares with production melonDS.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${TMPDIR:-/tmp}/nds-gpu3d-depth-pipe-check
cases=${CASES:-400}

mkdir -p "$out"
cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/DepthPipeCheck.hs -o "$out/depth-pipe-check" >/dev/null

exec "$out/depth-pipe-check" "$cases"
