#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Gate for the both-screen tile SoC (Clash top nds_tile_soc,
# clash/src/Nds/WholeCore/TileSoc.hs): the Clash ARM9 slice runs
# sim/tests/hs_tile_arm9.S from its boot ROM, programs a text-BG + sprite
# scene on both 2D engines and animates it from its VBlank and VCount IRQs;
# the shared tile engine (Nds.Gpu2D.TileHw) draws both screens on DS line
# timing. All from fresh builds:
#
#  0. Assemble the program and its four fail-closed variants.
#  1. check: FRAMES frames (default 10) of the pure SoC step, in lockstep
#     with the authoritative Nds.Gpu.Live fed the same ordered GPU link
#     transactions at the same cycles. Every read value, every IF bit raised
#     (cycle and bits), and every pixel of both screens of every frame must
#     agree; once the scene shows, every frame must change.
#  2. Fail-closed variants: each must stop on its expected link error or
#     GPU fault (and match Live up to there).
#  3. Fresh Clash Verilog: Yosys lists the inferred memories and the
#     multipliers; Verilator replays the pure model's FRAMES-frame run cycle
#     by cycle (tests/tilesoc_cosim.cpp) and must match every output. A
#     corrupted stream must fail. (Clash's own Signal simulation of the SoC
#     is not run: it keeps the ARM9 SoC's unused output streams alive and
#     exhausts 3 GiB within a frame; see TileSocCheck.hs.)
#  4. Mutants of TileSoc.hs: each must fail the pure check (MUTANT_FRAMES
#     frames, default 4).
#
# MUTANTS="name ..." runs only those mutants (each name must exist).
#
# Memory: every checker run is capped at 3 GiB of heap (+RTS -M3g), every
# GHC and Clash compile too; the cosim reads the trace from a pipe and
# compares as it reads, so no trace is written to disk.
set -eu
set -o pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
frames=${FRAMES:-10}
mframes=${MUTANT_FRAMES:-4}
rts="+RTS -M3g -RTS"
out=${OUT:-${TMPDIR:-/tmp}/nds-tilesoc-check}
mkdir -p "$out"
failures=0
mutants_total=0
mutants_run=0

# 0. the program and its fail-closed variants
asm() {
  arm-none-eabi-as -EL $2 -o "$out/$1.o" "$repo/sim/tests/hs_tile_arm9.S"
  arm-none-eabi-objcopy -j .text -O binary "$out/$1.o" "$out/$1.bin"
  od -An -v -tx4 "$out/$1.bin" | awk '{ for (i = 1; i <= NF; i++) print $i }' > "$out/$1.hex"
}
asm guest ""
echo "program: hs_tile_arm9.S, $(wc -l < "$out/guest.hex" | tr -d ' ') words (sha256 $(shasum -a 256 "$out/guest.hex" | cut -d' ' -f1))"
for n in MASTER_BRIGHT PAL_BYTE VRAM_WINDOW BG_MODE; do asm "neg-$n" "--defsym NEG_$n=1"; done

# build SRC OUT: the checker with SRC ahead of src (a mutant's TileSoc.hs)
build() {
  (cd "$here" && STACK_YAML="$here/stack.yaml" stack --resolver lts-22.43 ghc -- +RTS -M3g -RTS -O1 -rtsopts \
      -i"$1" -isrc -itest -outputdir "$2/obj" test/TileSocCheck.hs -o "$2/tilesoc-check" >/dev/null)
}
build "$here/src" "$out"
chk=$out/tilesoc-check

# 1. the program against Live
"$chk" check "$out/guest.hex" "$frames" $rts | tee "$out/check.log" || failures=$((failures + 1))

# 2. fail-closed variants
neg() {
  printf 'negative %s: ' "$1"
  if "$chk" check "$out/neg-$1.hex" 2 --expect "$2" $rts > "$out/neg-$1.log"; then
    grep -E '^fault:' "$out/neg-$1.log"
  else
    echo "WRONG ($(grep -E '^(fault|tilesoc check):' "$out/neg-$1.log" | tr '\n' ' '))"; failures=$((failures + 1))
  fi
}
neg MASTER_BRIGHT cpu:400006c
neg PAL_BYTE cpu:5000000
neg VRAM_WINDOW cpu:6008000
neg BG_MODE gpu:1

# 3. fresh Verilog, memories, multipliers, cycle replay
rm -rf "$out/hdl"
(cd "$here" && stack exec clash -- +RTS -M3g -RTS --verilog -main-is tileSocTopEntity -isrc \
    -fclash-no-escaped-identifiers -outputdir "$out/clashobj" -fclash-hdldir "$out/hdl" \
    src/Nds/WholeCore/TileSoc.hs >/dev/null)
v=$(ls "$out"/hdl/*/nds_tile_soc.v)
vdir=$(dirname "$v")
echo "verilog: $vdir ($(ls "$vdir"/*.v | wc -l | tr -d ' ') files; nds_tile_soc.v sha256 $(shasum -a 256 "$v" | cut -d' ' -f1))"
yosys -p "read_verilog -sv $vdir/*.v; hierarchy -top nds_tile_soc; proc; opt -fast; memory -nomap; opt -fast; dump t:\$mem_v2" \
  > "$out/yosys-mem.log" 2>&1
shapes=$(awk '/cell \$mem_v2/ { inmem = 1; w = ""; s = "" }
              inmem && /parameter .WIDTH / { w = $3 }
              inmem && /parameter .SIZE / { s = $3 }
              inmem && w != "" && s != "" { print s "x" w; inmem = 0 }' "$out/yosys-mem.log" | sort | uniq -c \
         | awk '{ printf "%s%dx %s", sep, $1, $2; sep = ", " }')
yosys -p "read_verilog -sv $vdir/*.v; hierarchy -top nds_tile_soc; proc; flatten; stat -width" > "$out/yosys-raw.log" 2>&1
muls=$(awk '$2 ~ /^\$mul/ { n += $1 } END { print n + 0 }' "$out/yosys-raw.log")
echo "yosys: memories $shapes; $muls multipliers"

rm -rf "$out/vobj"
verilator --cc --exe --build -O2 -Wno-fatal --top-module nds_tile_soc --Mdir "$out/vobj" \
    "$vdir"/*.v "$here/tests/tilesoc_cosim.cpp" > "$out/verilator.log" 2>&1 \
  || { cat "$out/verilator.log" >&2; exit 1; }
sim=$out/vobj/Vnds_tile_soc
printf 'verilog (%s frames): ' "$frames"
if "$chk" dump "$out/guest.hex" "$frames" $rts | "$sim" "$out/guest.hex" - > "$out/cosim.log"; then :; else
  failures=$((failures + 1))
fi
tail -n 1 "$out/cosim.log"
# negative control: one picture pixel's colour changed in the expected stream
if "$chk" dump "$out/guest.hex" 2 $rts \
   | awk 'BEGIN { done = 0 } !done && NR > 600000 && $2 ~ /^0c/ && $2 != "0c000000" { $2 = "0c000001"; done = 1 } { print }' \
   | "$sim" "$out/guest.hex" - > "$out/cosim-corrupt.log"; then
  echo "verilog corrupted stream: NOT detected"; failures=$((failures + 1))
else
  echo "verilog corrupted stream: detected ($(tail -n 1 "$out/cosim-corrupt.log" | sed 's/.*, \([0-9]* mismatches\)/\1/'))"
fi

# 4. mutants: a copy of the source with one deliberate bug each
mutant() {
  mutants_total=$((mutants_total + 1))
  if [ -n "${MUTANTS:-}" ]; then
    case " $MUTANTS " in *" $1 "*) ;; *) return ;; esac
  fi
  mutants_run=$((mutants_run + 1))
  m=$out/mutant-$1
  rm -rf "$m"
  mkdir -p "$m/obj" "$m/src/Nds/WholeCore"
  sed -e "$2" "$here/src/Nds/WholeCore/TileSoc.hs" > "$m/src/Nds/WholeCore/TileSoc.hs"
  if cmp -s "$here/src/Nds/WholeCore/TileSoc.hs" "$m/src/Nds/WholeCore/TileSoc.hs"; then
    echo "mutant $1: the substitution did not apply"; failures=$((failures + 1)); return
  fi
  if ! build "$m/src" "$m" > "$m/build.log" 2>&1; then
    echo "mutant $1: did not build (see $m/build.log)"; failures=$((failures + 1)); return
  fi
  if "$m/tilesoc-check" check "$out/guest.hex" "$mframes" $rts > "$m/check.log" 2>&1; then
    echo "mutant $1: NOT detected"; failures=$((failures + 1))
  else
    echo "mutant $1: detected ($(grep -E '^tilesoc check:' "$m/check.log" | sed 's/tilesoc check: //' || echo failed); pixel mismatches $(sed -n 's/.*pixel mismatches \([0-9]*\)$/\1/p' "$m/check.log" | head -n 1); $(grep -E 'reads/IRQ mismatches: [0-9]+$' "$m/check.log" | sed 's/.*; //' | head -n 1))"
  fi
}
mutant vblank-irq-line 's/vblankIrq = lineStart \&\& cVc c == 192/vblankIrq = lineStart \&\& cVc c == 193/'
mutant vcount-match-line 's/vcountIrq = lineStart \&\& cVc c == matchOf st/vcountIrq = lineStart \&\& cVc c == matchOf st + 1/'
mutant hblank-flag-late 's/hblankFlag = h >= fromIntegral hblankCycle/hblankFlag = h >= fromIntegral hblankCycle + 8/'
mutant sprites-not-line-ahead 's/then Just (resize vc + 1) else if vc == 262/then Just (resize vc) else if vc == 262/'
mutant swap-bit-inverted 's/(codeOf 0 :> codeOf 1 :> Nil) (testBit (cPower c) 15)/(codeOf 0 :> codeOf 1 :> Nil) (not (testBit (cPower c) 15))/'
mutant scanout-line-offset 's/py = resize (vc - fromIntegral pictureLine0) :: Unsigned 8/py = resize (vc - fromIntegral pictureLine0 + 1) :: Unsigned 8/'
mutant bank-f-dropped 's/(TVram, VExt ix) | memWrite -> Just/(TVram, VExt ix) | False -> Just/'
mutant engine-b-palette-half 's/TPal | memWrite -> Just (unpack (slice d10 d1 subAddr), halfData)/TPal | memWrite -> Just (unpack ((0 :: BitVector 1) ++# slice d9 d1 subAddr), halfData)/'
mutant hold-removed 's/holding = holdKind \&\& not (lSub link)/holding = False \&\& holdKind \&\& not (lSub link)/'
mutant screens-not-frame-latched 's/cScreens = if frameStart then testBit (cPower c) 0/cScreens = if lineStart then testBit (cPower c) 0/'

if [ -n "${MUTANTS:-}" ]; then
  set -- $MUTANTS
  if [ "$mutants_run" != "$#" ]; then
    echo "MUTANTS names $# mutants but $mutants_run matched: \"$MUTANTS\""; failures=$((failures + 1))
  fi
fi

echo "tilesoc: $failures failing runs; mutants: $mutants_run of $mutants_total run"
[ "$failures" -eq 0 ]
