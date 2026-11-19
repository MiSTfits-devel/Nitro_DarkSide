#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Gate for the 2D tile engine (Clash top nds_gpu2d_tilehw,
# clash/src/Nds/Gpu2D/TileHw.hs: one mode-0 text BG, 4bpp/8bpp on the
# standard palette, and regular 1D-mapped sprites, over the backdrop), all
# from fresh builds. The reference for every pixel is the unchanged host
# model: Nds.Gpu2D.Line (bgLine, composeLine) and Nds.Gpu2D.Sprite
# (drawSprites), and renderReferenceLine wherever OBJ is off.
#
#  0. sim/tests/arm9_2dk.bin must be what sim/tests/arm9_2dk.s assembles to
#     (arm-none-eabi-as/ld/objcopy, as build_nds_2dk.sh), because the check
#     derives the scene by executing that binary.
#  1. fault: every unsupported register combination is refused at line start
#     and every unsupported sprite on the line during the OAM scan, with its
#     fault bit, before any pixel of the line; the engine halts; a response
#     with nothing outstanding faults; seven near-miss states that are
#     supported must render exactly (model and Clash circuit).
#  2. check: the arm9_2dk scene (engines A and B, all 192 lines each, its
#     registers, palettes, OAM and VRAM obtained by executing the binary),
#     the local gpu2d_kirby135 capture (192 lines) if present, and SCENES seeded
#     random scenes (16 directed BG scenes: both engines x both depths x four
#     screen sizes, scroll at the wrap points; 8 with overlapping sprite
#     chains at equal priority; the rest random) through the pure step and
#     the Clash circuit under one closed-loop driver with random request
#     stalls and random response latency. Every pixel (colour and layer)
#     against the reference, exactly the expected requests per line (two per
#     BG tile slot, one per sprite tile column), pure = Clash on every output
#     every cycle.
#  3. Fresh Clash Verilog: Yosys must infer exactly the eleven memories as
#     $mem_v2 (BG map 64x16, BG rows 64x64, palette 1024x16, OAM 3 x 256x16,
#     OBJ line buffer 256x16, column descriptors 64x24, OBJ rows 64x64, OBJ
#     extended palettes 2 x 4096x16) and find no multiplier. Verilator
#     replays the pure model's run of both check groups cycle by cycle
#     (tests/tilehw_cosim.cpp): every request space and address, every
#     pixel, ready and fault. A corrupted trace must fail.
#  4. Mutants: copies of TileHw.hs with one deliberate bug each must fail the
#     pure check or the fault check.
#
# TIMING=1 also prints cycles per line against memory latency.
#
# The gpu2d_kirby135 capture is a local, untracked input (gitignored; it
# comes from a commercial game and is never committed). It is used only when
# all seven sim/tests/gpu2d_kirby135_*.hex files are present in
# TILEHW_KIRBY_DIR (default sim/tests); otherwise the gate prints one
# "kirby135 capture not present, skipped" line, runs everything else and can
# pass. The final line says whether the capture ran. Point TILEHW_KIRBY_DIR
# at an empty directory to run without it.
#
# MUTANTS="name ..." runs only those mutants (each name must exist); the
# final line says how many of the mutants ran.
#
# Memory: every checker run is capped at 3 GiB of heap (+RTS -M3g); the
# checker runs scenes one at a time and judges each line as it completes,
# and the cosim streams the trace through a pipe into the Verilator
# harness, which compares as it reads, so no trace is written to disk.
set -eu
set -o pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
fixtures=$repo/sim/tests
seed=${SEED:-1}
scenes=${SCENES:-200}
cosim=${COSIM:-60}
mscenes=${MUTANT_SCENES:-60}
rts="+RTS -M3g -RTS"
out=${OUT:-${TMPDIR:-/tmp}/nds-gpu2d-tilehw-check}
mkdir -p "$out"

failures=0

# The optional local capture: present only if all seven files are.
kdir=${TILEHW_KIRBY_DIR:-$fixtures}
kfound=0
for part in bgvram pal bgep oam objvram objep frames; do
  if [ -f "$kdir/gpu2d_kirby135_$part.hex" ]; then kfound=$((kfound + 1)); fi
done
if [ "$kfound" = 7 ]; then
  kirby="ran (local capture in $kdir)"
  echo "kirby135 capture: present in $kdir, included"
else
  kirby="not present, skipped"
  echo "kirby135 capture not present ($kfound of 7 gpu2d_kirby135_*.hex in $kdir), skipped"
fi
export TILEHW_KIRBY_DIR="$kdir"
mutants_total=0
mutants_run=0

# 0. fixture binary against its source
mkdir -p "$out/asm"
arm-none-eabi-as -march=armv5te -o "$out/asm/arm9_2dk.o" "$fixtures/arm9_2dk.s"
arm-none-eabi-ld -Ttext=0x02000000 -o "$out/asm/arm9_2dk.elf" "$out/asm/arm9_2dk.o"
arm-none-eabi-objcopy -O binary "$out/asm/arm9_2dk.elf" "$out/asm/arm9_2dk.bin"
if cmp -s "$out/asm/arm9_2dk.bin" "$fixtures/arm9_2dk.bin"; then
  echo "arm9_2dk.bin: identical to a fresh assembly of arm9_2dk.s"
else
  echo "arm9_2dk.bin: DIFFERS from a fresh assembly of arm9_2dk.s"; failures=$((failures + 1))
fi

build() {
  (cd "$1" && STACK_YAML="$here/stack.yaml" stack --resolver lts-22.43 ghc -- -O1 -rtsopts -isrc -itest \
      -outputdir "$2/obj" test/TileHwCheck.hs -o "$2/tilehw-check" >/dev/null)
}
build "$here" "$out"
chk=$out/tilehw-check

"$chk" fault "$fixtures" $rts || failures=$((failures + 1))
"$chk" check "$fixtures" "$seed" "$scenes" $rts || failures=$((failures + 1))

if [ "${TIMING:-0}" = 1 ]; then
  "$chk" time "$fixtures" $rts || failures=$((failures + 1))
fi

# 3. fresh Verilog, memory inference, multipliers, cycle replay
rm -rf "$out/hdl"
(cd "$here" && stack exec clash -- --verilog -isrc -fclash-no-escaped-identifiers \
    -outputdir "$out/hdl" src/Nds/Gpu2D/TileHw.hs >/dev/null)
v=$(find "$out/hdl" -name nds_gpu2d_tilehw.v)
[ -n "$v" ] || { echo "no generated nds_gpu2d_tilehw.v" >&2; exit 1; }
echo "verilog: $v (sha256 $(shasum -a 256 "$v" | cut -d' ' -f1))"
yosys -p "read_verilog -sv $v; hierarchy -top nds_gpu2d_tilehw; proc; opt -fast; memory -nomap; opt -fast; dump t:\$mem_v2" \
  > "$out/yosys-mem.log" 2>&1
mems=$(grep -c 'cell \$mem_v2' "$out/yosys-mem.log" || true)
shapes=$(awk '/cell \$mem_v2/ { inmem = 1; w = ""; s = "" }
              inmem && /parameter .WIDTH / { w = $3 }
              inmem && /parameter .SIZE / { s = $3 }
              inmem && w != "" && s != "" { print s "x" w; inmem = 0 }' "$out/yosys-mem.log" | sort | tr '\n' ' ')
yosys -p "read_verilog -sv $v; hierarchy -top nds_gpu2d_tilehw; proc; stat -width" > "$out/yosys-raw.log" 2>&1
muls=$(awk '$2 ~ /^\$mul/ { n += $1 } END { print n + 0 }' "$out/yosys-raw.log")
echo "yosys: $mems inferred memories (${shapes% }); $muls multipliers"
[ "$mems" = 11 ] && [ "$shapes" = "1024x16 256x16 256x16 256x16 256x16 4096x16 4096x16 64x16 64x24 64x64 64x64 " ] \
  && [ "$muls" = 0 ] || failures=$((failures + 1))

rm -rf "$out/vobj"
verilator --cc --exe --build -O2 -Wno-fatal --top-module nds_gpu2d_tilehw --Mdir "$out/vobj" \
    "$v" "$here/tests/tilehw_cosim.cpp" > "$out/verilator.log" 2>&1 \
  || { cat "$out/verilator.log" >&2; exit 1; }
sim=$out/vobj/Vnds_gpu2d_tilehw
for t in fixtures random; do
  printf 'verilog %s: ' "$t"
  if "$chk" dump "$fixtures" "$seed" "$cosim" "$t" $rts 2> "$out/dump-$t.log" | "$sim" - > "$out/cosim-$t.log"; then :; else
    failures=$((failures + 1))
  fi
  tail -n 1 "$out/cosim-$t.log"
  sed 's/^/  /' "$out/dump-$t.log"
done
# negative control: one pixel colour changed in the expected stream
if "$chk" dump "$fixtures" "$seed" "$cosim" fixtures $rts 2>/dev/null \
   | awk 'BEGIN { done = 0 } !done && $15 ~ /^[4-7c-f]$/ && NR > 5000 { $18 = ($18 == "0000") ? "0001" : "0000"; done = 1 } { print }' \
   | "$sim" - > "$out/cosim-corrupt.log"; then
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
  mkdir -p "$m/obj" "$m/test"
  cp -R "$here/src" "$m/"
  cp "$here/test/TileHwCheck.hs" "$m/test/"
  sed -e "$2" "$here/src/Nds/Gpu2D/TileHw.hs" > "$m/src/Nds/Gpu2D/TileHw.hs"
  if cmp -s "$here/src/Nds/Gpu2D/TileHw.hs" "$m/src/Nds/Gpu2D/TileHw.hs"; then
    echo "mutant $1: the substitution did not apply"; failures=$((failures + 1)); return
  fi
  if ! build "$m" "$m" > "$m/build.log" 2>&1; then
    echo "mutant $1: did not build (see $m/build.log)"; failures=$((failures + 1)); return
  fi
  c=0; f=0
  "$m/tilehw-check" check "$fixtures" "$seed" "$mscenes" --pure $rts > "$m/check.log" 2>&1 || c=1
  "$m/tilehw-check" fault "$fixtures" $rts > "$m/fault.log" 2>&1 || f=1
  if [ "$c" = 0 ] && [ "$f" = 0 ]; then
    echo "mutant $1: NOT detected"; failures=$((failures + 1))
  else
    echo "mutant $1: detected (check: $(grep -E '^tilehw check:' "$m/check.log" | sed 's/tilehw check: //' || echo failed); fault: $(grep -E '^tilehw fault:' "$m/fault.log" | sed 's/tilehw fault: //' || echo failed))"
  fi
}
# background
mutant hflip 's/xx = if testBit e 10 then 7 - tx else tx/xx = if testBit e 11 then 7 - tx else tx/'
mutant vflip 's/rowOf c e = if testBit e 11 then 7 - cFineY c else cFineY c/rowOf c e = cFineY c/'
mutant hscroll-wrap 's/resize (xt .&. 0xF8)/resize (xt .\&. 0x1F8)/'
mutant vscroll-wrap 's/(if wide then resize (yoff .&. 0x100) `shiftL` 3 else 0)/0/'
mutant char-base 's/cTiles = dispChar + charBase/cTiles = dispChar/'
mutant dispcnt-screen-base 's/mapBase = dispScreen + screenBase/mapBase = screenBase/'
mutant transparency-4bpp 's/opaque4 = nib \/= 0/opaque4 = b4 \/= 0/'
mutant backdrop-palette-entry 's/(if bgOpaque then bgIdx else 0)/bgIdx/'
mutant engine-b-vram-wrap 's/a .&. 0x1FFFF/a/'
mutant map-entry-hazard "s/cRcv c > loaded' - n1/cRcv c >= loaded' - n1/"
mutant mode-not-refused 's/flag 0 (slice d2 d0 d \/= 0)/flag 0 False/'
# sprites
mutant obj-hflip 's/lx = if dsFlip ds then 7 - cur else cur/lx = cur/'
mutant obj-vflip 's/ypos1 = if flipY then height - 1 - yl else yl/ypos1 = yl/'
mutant obj-tile-boundary 's/(resize tile `shiftL` fromEnum (cBound c))/(resize tile `shiftL` 0)/'
mutant obj-8bpp-row-stride 's/`shiftL` (if is256 then 1 else 0)/`shiftL` 0/'
mutant obj-left-clip 's/xoff = if xpos >= 0 then 0 else negate xpos/xoff = 0 :: Signed 10/'
mutant obj-y-wrap 's/ypos = resize (cY c - unpack (slice d7 d0 a0)) :: Unsigned 9/ypos = resize (cY c) - resize (unpack (slice d7 d0 a0) :: Unsigned 8) :: Unsigned 9/'
mutant obj-bg-priority-tie 's/entryPrio lb <= cBgPrio c/entryPrio lb < cBgPrio c/'
mutant obj-oam-order 's/entryPrio e < entryPrio old/entryPrio e <= entryPrio old/'
mutant obj-ext-palette-number 's/(if ext then dsPal ds else 0) ++# c8/(0 :: BitVector 4) ++# c8/'
mutant obj-ext-enable 's/spExt = is256 \&\& cExtOn c/spExt = is256/'
mutant obj-rmw-forwarding 's/Just (lx, le) | lx == x -> le/Just (lx, le) | False \&\& lx == x -> le/'
mutant obj-semitrans-not-refused 's/mode == 1 \&\& cBld2 c = FaultSpr/mode == 1 \&\& False = FaultSpr/'

if [ -n "${MUTANTS:-}" ]; then
  set -- $MUTANTS
  if [ "$mutants_run" != "$#" ]; then
    echo "MUTANTS names $# mutants but $mutants_run matched: \"$MUTANTS\""; failures=$((failures + 1))
  fi
fi

echo "tilehw: $failures failing runs; kirby135 capture: $kirby; mutants: $mutants_run of $mutants_total run"
[ "$failures" -eq 0 ]
