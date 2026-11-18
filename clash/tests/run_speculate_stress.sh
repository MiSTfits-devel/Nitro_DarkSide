#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Independent M5 cache-semantics stress. Public Speculate API only: bounded
# 192-entry LRU, exact-key reuse, stale-plan rejection, all memory/register/
# latch/engine/line identities, provider 3D-token invalidation, and output
# equality against the exact renderer. No shared module edits.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${TMPDIR:-/tmp}/nds-speculate-stress
mkdir -p "$out"
cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/SpeculateStress.hs -o "$out/speculate-stress"
"$out/speculate-stress"
