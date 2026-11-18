#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Whole-chip gate: Nds.Gpu3D.Chip (GX front end + geometry engine + polygon
# pipeline + renderer, composed) against a melonDS NDS driven only through
# ARM9 I/O, GPU3D::Run, VBlank, RenderFrame, GetLine and FinishFrame
# (tools/gx3d_oracle/chip_oracle.cpp). Every directed sequence of
# gen_chip_cases.py, SEQS seeded multi-frame scene sequences and FUZZ seeded
# command-fuzz sequences; ChipCheck compares the status word after every op
# (bus stall, GXFIFO IRQ, GX entries executed), every ARM9 read and every
# GetLine line.
#
# Environment: SEQS (random sequences, default 32), FUZZ (default 8), SEED0
# (first seed, default 1), KINDS (directed kinds, default all),
# STOP_ON_FAIL=1 to stop at the first failing case (mutation runs), REUSE=1
# to reuse the scripts and oracle outputs of an earlier run in the same
# TMPDIR, CHIP_SRC to build the checker from another source tree (mutants).
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
nseqs=${SEQS:-32}
nfuzz=${FUZZ:-8}
seed0=${SEED0:-1}
kinds=${KINDS:-"basic strips translucent effects clear stall power overflow abort stack noswap regs carry dot burst"}
out=${TMPDIR:-/tmp}/nds-gpu3d-chip-check
src=${CHIP_SRC:-$here/src}

mkdir -p "$out/obj"
if [ "${REUSE:-0}" != 1 ]; then
  . "$here/tests/oracle_build.sh"
  build_oracle nds_gx3d_chip_oracle
fi

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -i"$src" -itest -outputdir "$out/obj" \
    test/ChipCheck.hs -o "$out/chip-check" >/dev/null

failures=0
cases=0
names=
run_case() {
  name=$1
  if [ "${REUSE:-0}" != 1 ]; then
    python3 "$here/tests/gen_chip_cases.py" "$2" "$3" "$out/$name.txt" "$out/$name.vram"
    if ! ORACLE_VRAM="$out/$name.vram" "$oracle_build/nds_gx3d_chip_oracle" \
        < "$out/$name.txt" > "$out/$name.out" 2> "$out/$name.log"; then
      cat "$out/$name.log" >&2
      exit 1
    fi
  fi
  cases=$((cases + 1))
  names="$names $name"
  if ! "$out/chip-check" "$out/$name.txt" "$out/$name.vram" "$out/$name.out" > "$out/$name.chk"; then
    failures=$((failures + 1))
    sed -n '1,14p' "$out/$name.chk"
    if [ "${STOP_ON_FAIL:-0}" = 1 ]; then
      echo "chip-check: stopped at the first failure ($cases cases run)"
      exit 1
    fi
  else
    sed -n '1p' "$out/$name.chk"
  fi
}

for kind in $kinds; do
  run_case "$kind" "$kind" 0
done
i=0
while [ "$i" -lt "$nseqs" ]; do
  run_case "random$((seed0 + i))" random "$((seed0 + i))"
  i=$((i + 1))
done
i=0
while [ "$i" -lt "$nfuzz" ]; do
  run_case "fuzz$((seed0 + i))" fuzz "$((seed0 + i))"
  i=$((i + 1))
done

# Totals: the "stats:" line of every checker report (ops writes reads
# entries swaps frames polygons lines aborted stalled irq dma burst maxfifo
# failures).
for n in $names; do grep '^stats:' "$out/$n.chk"; done | awk '
  { for (i = 2; i <= 14; i++) t[i] += $i; if ($15 > m) m = $15 }
  END { printf "chip-check totals: %d ops (%d writes, %d reads compared, %d burst ops), %d GX entries executed (%d DMA triggers), %d swaps, %d frames rendered (%d polygons), %d GetLine lines compared (%d aborted), %d ops ending with the ARM9 stalled, %d with the GXFIFO IRQ raised, max FIFO level %d\n", t[2], t[3], t[4], t[14], t[5], t[13], t[6], t[7], t[8], t[9], t[10], t[11], t[12], m }'
echo "chip-check: $cases cases ($(echo $kinds | wc -w | tr -d ' ') directed, $nseqs random, $nfuzz fuzz), $failures failures"
[ "$failures" -eq 0 ]
