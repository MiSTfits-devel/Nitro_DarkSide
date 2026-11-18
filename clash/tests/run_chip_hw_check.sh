#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Whole-chip hardware gate: Nds.Gpu3D.ChipHw (the Clash top nds_gpu3d) against
# the independent transaction-scheduled Chip/geometry/polygon models in Clash
# simulation. Scripts come from tests/gen_chip_cases.py. '+' skips the
# post-access drain; it does not freeze the free-running geometry clock.
# Expected payload/event order, FIFO/IRQ/DMA timing, consumer reads and final
# pixels are checked; RAM_COUNT overlaps use monotonic event-prefix
# linearizability, not guessed geometry microcycle latency.
#
# Environment: SEQS (random sequences, default 16), FUZZ (default 8), SEED0
# (first seed, default 1), KINDS (directed kinds, default all), READY (memory
# ready probability over 1024, default 768), LATMAX (memory latency, default 12).
# IF_EVERY_CYCLE=1 is a focused real-input IF/refill priority stress stimulus.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
nseqs=${SEQS:-16}
nfuzz=${FUZZ:-8}
seed0=${SEED0:-1}
kinds=${KINDS:-"tiny basic strips translucent effects clear stall power overflow abort stack noswap regs carry dot burst"}
out=${TMPDIR:-/tmp}/nds-gpu3d-chip-hw-check
src=${CSRC:-$here/src}

mkdir -p "$out/cases" "$out/obj"
if [ "${REUSE:-0}" != 1 ]; then
  for kind in $kinds; do
    python3 "$here/tests/gen_chip_cases.py" "$kind" 0 "$out/cases/$kind.txt" "$out/cases/$kind.vram"
  done
  i=0
  while [ "$i" -lt "$nseqs" ]; do
    python3 "$here/tests/gen_chip_cases.py" random "$((seed0 + i))" \
      "$out/cases/random$((seed0 + i)).txt" "$out/cases/random$((seed0 + i)).vram"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$nfuzz" ]; do
    python3 "$here/tests/gen_chip_cases.py" fuzz "$((seed0 + i))" \
      "$out/cases/fuzz$((seed0 + i)).txt" "$out/cases/fuzz$((seed0 + i)).vram"
    i=$((i + 1))
  done
fi

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -i"$src" -itest -outputdir "$out/obj" \
    test/ChipHwCheck.hs -o "$out/chip-hw-check" >/dev/null

failures=0
cases=0
names=
run_case() {
  name=$1
  cases=$((cases + 1))
  names="$names $name"
  if ! "$out/chip-hw-check" "$out/cases/$name.txt" "$out/cases/$name.vram" \
      > "$out/cases/$name.chk"; then
    failures=$((failures + 1))
    sed -n '1,20p' "$out/cases/$name.chk"
    if [ "${STOP_ON_FAIL:-0}" = 1 ]; then
      echo "chip-hw-check: stopped at the first failure ($cases cases run)"
      exit 1
    fi
  else
    sed -n '1p' "$out/cases/$name.chk"
  fi
}

for kind in $kinds; do
  run_case "$kind"
done
i=0
while [ "$i" -lt "$nseqs" ]; do
  run_case "random$((seed0 + i))"
  i=$((i + 1))
done
i=0
while [ "$i" -lt "$nfuzz" ]; do
  run_case "fuzz$((seed0 + i))"
  i=$((i + 1))
done

# suM the per-case "stats:" lines (statList order: ops writes reads entries
# dma bursts frames lines swaps aborted held irq bus-wait fails cycles render)
for n in $names; do grep '^stats: ' "$out/cases/$n.chk"; done | awk '
  { for (i = 2; i <= 17; i++) t[i] += $i }
  END { printf "chip-hw-check totals: %d ops (%d writes, %d reads), %d GX entries, %d DMA triggers, %d bursts, %d swaps, %d frames, %d lines compared, %d aborted, %d stalled, %d IRQ, %d bus-wait cycles, %d cycles (%d render cycles), %d mismatches\n", t[2], t[3], t[4], t[5], t[6], t[7], t[10], t[8], t[9], t[11], t[12], t[13], t[14], t[16], t[17], t[15] }'
echo "chip-hw-check: $cases cases, $failures failures"
[ "$failures" -eq 0 ]
