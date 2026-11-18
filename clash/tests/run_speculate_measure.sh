#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Real NTR v12 trace M5 measurement: provider-aware cache with actual Haskell
# Chip 3D line tokens vs the same exact renderer. Reports prefetch+demand
# renders, hits/misses/fixups/evictions, measured wall time, 3D Chip time, and
# exact output equality. Usage: run_speculate_measure.sh TRACE.nsd2 [maxFrames]
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
trace=${1:?usage: run_speculate_measure.sh TRACE.nsd2 [maxFrames]}
shift
out=${TMPDIR:-/tmp}/nds-speculate-measure
mkdir -p "$out"
cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/SpeculateMeasure.hs -o "$out/speculate-measure"
"$out/speculate-measure" "$trace" "$@"
