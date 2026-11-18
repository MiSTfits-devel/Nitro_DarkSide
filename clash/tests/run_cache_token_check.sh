#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# M5 token-key check on a trace whose phases carry sprites, windows, display
# state and 3D. Mutates each non-EngineState input independently (sprite
# buffer, WIN0/1 coords+mask, screens/swap/brightness/FIFO, capture flags,
# 3D line) and requires the token and LineKey to change; identical inputs must
# keep the key. Usage: run_cache_token_check.sh TRACE.nsd2
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
trace=${1:?usage: run_cache_token_check.sh TRACE.nsd2}
out=${TMPDIR:-/tmp}/nds-cache-token-check
mkdir -p "$out"
cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/CacheTokenCheck.hs -o "$out/cache-token-check"
"$out/cache-token-check" "$trace"
