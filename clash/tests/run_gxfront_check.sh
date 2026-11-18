#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Gates for the GX front end (ARM9 register block + command FIFO/PIPE):
#
# 1. model vs melonDS: Nds.Gpu3D.GxFront against the production GPU3D
#    register block and FIFO (tools/gx3d_oracle/gxfront_oracle.cpp), op by
#    op, on the directed cases and CASES seeded random cases of OPS op
#    proposals each (SEED);
# 2. hardware vs model: nds_gpu3d_gxfront (Nds.Gpu3D.GxFrontHw) in Clash
#    simulation against the model, cycle by cycle, on a directed script and
#    HW_RUNS random scripts of HW_ITEMS items, random ready on the command
#    stream and random gaps on the bus.
#
# MUTANTS=1 then applies every mutant below to a private copy of the
# sources, one at a time, rebuilds the gate it targets and requires that
# gate to fail. The checked-in sources are never touched. MUTANT_ONLY="3 7"
# runs only those mutants.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
seed=${SEED:-1}
cases=${CASES:-12}
ops=${OPS:-4000}
hw_runs=${HW_RUNS:-8}
hw_items=${HW_ITEMS:-12000}
out=${TMPDIR:-/tmp}/nds-gpu3d-gxfront-check

. "$here/tests/oracle_build.sh"
build_oracle nds_gx3d_gxfront_oracle
oracle="$oracle_build/nds_gx3d_gxfront_oracle"
mkdir -p "$out"

cd "$here"
# build SRC_DIR OBJ_DIR MAIN EXE
build() {
  stack --resolver lts-22.43 ghc -- -O2 -i"$1" -itest -outputdir "$2" "$3" -o "$4" >/dev/null
}

build src "$out/obj-model" test/GxFrontCheck.hs "$out/gxfront-check"
build src "$out/obj-hw" test/GxFrontHwCheck.hs "$out/gxfront-hw-check"

"$out/gxfront-check" "$oracle" "$seed" "$cases" "$ops"
"$out/gxfront-hw-check" "$seed" "$hw_runs" "$hw_items" | tail -n 1

[ "${MUTANTS:-0}" = 1 ] || exit 0

mut=$out/mutant
killed=0
survived=0
n=0
# mutant GATE FILE SEARCH REPLACE: SEARCH must occur exactly once in FILE.
mutant() {
  gate=$1 file=$2 search=$3 repl=$4
  n=$((n + 1))
  case " ${MUTANT_ONLY:-$n} " in *" $n "*) ;; *) return 0 ;; esac
  rm -rf "$mut/src"
  mkdir -p "$mut"
  cp -R src "$mut/src"
  S=$search R=$repl perl -0pi -e 'BEGIN { $c = 0 } $c += s/\Q$ENV{S}\E/$ENV{R}/g; END { exit($c == 1 ? 0 : 3) }' \
      "$mut/src/Nds/Gpu3D/$file" || { echo "mutant $n: pattern not unique in $file: $search"; exit 1; }
  if [ "$gate" = model ]; then
    build "$mut/src" "$mut/obj-model" test/GxFrontCheck.hs "$mut/gate"
    set -- "$mut/gate" "$oracle" "$seed" "$cases" "$ops"
  else
    build "$mut/src" "$mut/obj-hw" test/GxFrontHwCheck.hs "$mut/gate"
    set -- "$mut/gate" "$seed" "$hw_runs" "$hw_items"
  fi
  if "$@" >"$mut/log" 2>&1; then
    survived=$((survived + 1))
    echo "mutant $n ($gate): SURVIVED: $search -> $repl"
  else
    killed=$((killed + 1))
    echo "mutant $n ($gate): killed: $search -> $repl"
    echo "    $(grep -E 'failures$|mismatches$' "$mut/log" | tail -n 1)"
  fi
}

# Model mutants, each against the melonDS gate.
mutant model GxFront.hs 'pipeDepth = 4' 'pipeDepth = 3'
mutant model GxFront.hs 'Seq.length rest <= 2' 'Seq.length rest <= 1'
mutant model GxFront.hs 'x :< xs | fifoLevel s < fifoDepth' 'x :< xs | fifoLevel s < fifoDepth - 1'
mutant model GxFront.hs 'Seq.length fifo >= fifoDepth' 'Seq.length fifo > fifoDepth'
mutant model GxFront.hs '(nc == 4 && cur == 0)' '(cur == 0)'
mutant model GxFront.hs '1 -> level < 128' '1 -> level <= 128'
mutant model GxFront.hs '2 -> level == 0' '2 -> level <= 1'
mutant model GxFront.hs 'flag (level == 0) 26' 'flag (level <= 1) 26'
# (v .&. 0x7FFF) here would be equivalent: a written bit 12/13 is cleared next.
mutant model GxFront.hs 'd0 = (v .&. 0x4FFF)' 'd0 = (v .&. 0x0FFF)'
mutant model GxFront.hs 'be (d .&. 0x7F7F7F7F)' 'be (d .&. 0xFFFFFFFF)'
mutant model GxFront.hs 'head fd : fd' '0 : fd'
mutant model GxFront.hs 'if c == 0x71 then 2' 'if c == 0x71 then 1'
mutant model GxFront.hs '(xpos .&. mask .&. 0x01FF)' '(xpos .&. mask .&. 0x03FF)'
mutant model GxFront.hs '`shiftL` 9) .|. 0x1FF' '`shiftL` 8) .|. 0x1FF'
mutant model GxFront.hs 'o < 0x5CC' 'o < 0x5D0'
mutant model GxFront.hs '0x606 -> nv' '0x606 -> np'
mutant model GxFront.hs 'gfTestBit st && gfNumTest st /= 0' 'gfTestBit st'
mutant model GxFront.hs 'gfGeomEn st && gfRendEn st = st' 'gfRendEn st = st'
mutant model GxFront.hs 'WaGxStat (testBit v 7)' 'WaGxStat (testBit v 6)'
mutant model GxFront.hs 'resetRenderRegs (rrXPos (gfRender st))' 'resetRenderRegs 0'
mutant model GxFront.hs 'o >= 0x400 && o < 0x700 && not geomEn' 'o >= 0x440 && o < 0x700 && not geomEn'
# Hardware mutants, each against the hardware-vs-model gate.
mutant hw GxFrontHw.hs "if pipeN' > 2 then PIdle" "if pipeN' > 1 then PIdle"
mutant hw GxFrontHw.hs 'if sCount s /= 1 then PFillB' 'if sCount s /= 0 then PFillB'
mutant hw GxFrontHw.hs 'sCount s < 128)' 'sCount s <= 128)'
mutant hw GxFrontHw.hs 'sPend s == PendNone && not tableBusy &&' 'sPend s == PendNone &&'
mutant hw GxFrontHw.hs '| i >= 33 = 31' '| i >= 34 = 31'
mutant hw GxFrontHw.hs '(8 * fromIntegral (acAddr a .&. 3))' '(8 * fromIntegral (acAddr a .&. 2))'
mutant hw GxFrontHw.hs '| testBit be 1 -> 1' '| testBit be 1 -> 2'
mutant hw GxFrontHw.hs 'abortCopy copy1, True)' 'abortCopy copy1, zero1)'
mutant hw GxFrontHw.hs '(n32 (m `shiftR` 30), fifoIrqCond m' '(n32 (m `shiftR` 30), fifoIrqCond (irqModeW s)'
mutant hw GxFrontHw.hs 'toPipe = sCount s == 0 && sPipeN s < 4' 'toPipe = sCount s == 0'

echo "gxfront-mutants: $n mutants, $killed killed, $survived survived"
[ "$survived" -eq 0 ]
