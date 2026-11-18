#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Clash-simulation gate for the pipelined pixel back end (Clash top
# nds_gpu3d_shade): the real machine against a registered behavioural memory,
# free-running and with one stall cycle in four, compared pixel by pixel with
# pixelWithMemory, which the frame gates compare with melonDS. PIXELS per run.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pixels=${PIXELS:-50000}
out=${TMPDIR:-/tmp}/nds-gpu3d-shade-pipe-check

mkdir -p "$out"
cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/ShadePipeCheck.hs -o "$out/shade-pipe-check" >/dev/null

"$out/shade-pipe-check" "$pixels"
