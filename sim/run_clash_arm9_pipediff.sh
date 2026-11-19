#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Randomized differential test of the pipelined ARM9 slice against the frozen
# non-overlapped staged step (clash/test/Arm9SliceStaged.hs): seeded ARM/Thumb
# programs with random link stalls and IRQ times, including self-modifying
# local-RAM code, Thumb BL/BLX pairs with IRQs between the halves, wrong-path
# fetches off the end of the ROM and RAM, and real-path faults. Retire, store
# and link streams, IRQ boundaries and faults must be identical; every IRQ
# entry must be legal (line high, CPSR.I clear) and within the stated latency
# bound. See clash/test/Arm9PipeDiff.hs.
# Env: FIRST_SEED (default 1), SEEDS (default 1000).
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-clash-arm9-pipediff.XXXXXX")
trap 'rm -rf "$out"' EXIT
command -v stack >/dev/null || { echo "Required tool not found: stack" >&2; exit 2; }
# Every GHC process and the built checker are capped at a 3 GB heap.
(cd "$root/clash" && stack --resolver lts-22.43 ghc -- +RTS -M3g -RTS -rtsopts -with-rtsopts=-M3g \
    -O1 -isrc -itest -outputdir "$out/ghc" test/Arm9PipeDiff.hs -o "$out/pipe-diff") >"$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; exit 1; }
"$out/pipe-diff" "${FIRST_SEED:-1}" "${SEEDS:-1000}"
echo "PASS: pipelined ARM9 slice matches the staged oracle on ${SEEDS:-1000} random programs"
