#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Gate for the compact geometry experiment (Clash top nds_gpu3d_geomtx,
# clash/src/Nds/Gpu3D/GeoMatrix.hs: the whole geometry engine on one row RAM
# and four multipliers; its divider in clash/src/Nds/Gpu3D/GeoDiv.hs), all
# from fresh builds:
#
#  1. melonDS's geometry oracle writes the directed streams and STREAMS
#     seeded random streams of LENGTH inputs (as run_geometry_check.sh).
#     geomatrix-check runs every stream whole, nothing dropped: the pure step
#     with a block-RAM model and the Clash circuit run through one
#     closed-loop driver (random entry gaps, event ready, polygon stall and
#     VBlank): every event in order against the model and its vertex against
#     melonDS, status after every input, the whole RAM and every register
#     against the model and melonDS's recorded state, all 33 result words
#     against both, the swap wait against its VBlank, and identical
#     pure/Clash outputs every cycle. A --mutate run interleaves multi-word
#     commands (model only).
#  2. TRACE=<v12 .nsd2> (default: the NTR v12 capture when present): the
#     cartridge's raw GX bus writes are replayed through Nds.Gpu3D.Chip's
#     front end and every geometry input it makes is checked the same way
#     (model only: there is no melonDS record of it).
#  3. The divider against Nds.Gpu3D.GeometryHw's (same definitions) and the
#     reference arithmetic on random and edge operands.
#  4. Fresh Clash Verilog: Yosys must infer exactly the two memories
#     (512 x 128 rows, 32 x 32 parameters) as $mem_v2, and the unoptimised
#     netlist must hold exactly four 32 x 32 product sites (Clash once copied
#     them into every sequencer branch: 16 sites, 49 DSP blocks in Quartus,
#     which Yosys's own merging hides). Verilator replays COSIM streams of the
#     Clash simulation cycle by cycle on that Verilog, 330-bit events included
#     (tests/geomtx_cosim.cpp, which says why not iverilog).
#  5. Seeded mutants (matrix, vertex, lighting, test and divider bugs) must
#     fail: the gate can see a wrong engine.
#
# TIMING=1 also prints cycles per command class for this engine and for
# Nds.Gpu3D.GeometryHw on the same streams, against melonDS's charge at
# one, two and three engine cycles per melonDS cycle, and requires both
# engines to transfer the same events and show the same GXSTAT bits.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
seed=${SEED:-1}
streams=${STREAMS:-50}
length=${LENGTH:-4000}
cosim=${COSIM:-4}
out=${OUT:-${TMPDIR:-/tmp}/nds-gpu3d-geomatrix-check}
trace=${TRACE:-/tmp/nds-v12c/ntr-v12.nsd2}

MELONDS_DIR=${MELONDS_DIR:-$repo/third_party/melonDS}
. "$here/tests/oracle_build.sh"
build_oracle nds_gx3d_geometry_oracle
mkdir -p "$out"

build() {
  (cd "$1" && STACK_YAML="$here/stack.yaml" stack --resolver lts-22.43 ghc -- -O1 -threaded -rtsopts -isrc -itest \
      -outputdir "$2/obj" test/GeoMatrixCheck.hs -o "$2/geomatrix-check" >/dev/null)
}
build "$here" "$out"
chk=$out/geomatrix-check
# Every checker run is capped: the whole process heap may not exceed 3 GB,
# so a retention bug fails the gate ("Heap exhausted") instead of taking the
# machine. The checker runs at most four streams at once.
rts="+RTS -N4 -M3g -RTS"

"$oracle_build/nds_gx3d_geometry_oracle" directed > "$out/directed.bin" 2>/dev/null
"$oracle_build/nds_gx3d_geometry_oracle" random "$seed" "$streams" "$length" > "$out/random.bin"

failures=0
"$chk" div "$here/src" $rts || failures=$((failures + 1))
printf 'directed: '
"$chk" check "$out/directed.bin" "$seed" $rts || failures=$((failures + 1))
printf 'random (seed %s, %s x %s): ' "$seed" "$streams" "$length"
"$chk" check "$out/random.bin" "$seed" $rts || failures=$((failures + 1))
printf 'random, interleaved gathering: '
"$chk" check "$out/random.bin" $((seed + 1)) --mutate $rts || failures=$((failures + 1))

if [ -f "$trace" ]; then
  "$chk" extract "$trace" "$out/trace.gxs" $rts || failures=$((failures + 1))
  printf 'cartridge GX stream: '
  "$chk" check "$out/trace.gxs" "$seed" $rts || failures=$((failures + 1))
else
  echo "cartridge GX stream: skipped (no $trace)"
fi

if [ "${TIMING:-0}" = 1 ]; then
  echo "cycles per command, directed + random streams back to back:"
  "$chk" time "$out/directed.bin" $rts || failures=$((failures + 1))
  "$chk" time "$out/random.bin" $rts || failures=$((failures + 1))
  [ -f "$out/trace.gxs" ] && { "$chk" time "$out/trace.gxs" $rts || failures=$((failures + 1)); }
fi

# Fresh Verilog, memory inference, cycle replay.
rm -rf "$out/hdl"
(cd "$here" && stack exec clash -- --verilog -isrc -fclash-no-escaped-identifiers \
    -outputdir "$out/hdl" src/Nds/Gpu3D/GeoMatrix.hs >/dev/null)
v=$(find "$out/hdl" -name nds_gpu3d_geomtx.v)
[ -n "$v" ] || { echo "no generated nds_gpu3d_geomtx.v" >&2; exit 1; }
yosys -p "read_verilog -sv $v; hierarchy -top nds_gpu3d_geomtx; proc; opt -fast; memory -nomap; opt -fast; dump t:\$mem_v2" \
  > "$out/yosys-mem.log" 2>&1
mems=$(grep -c 'cell \$mem_v2' "$out/yosys-mem.log" || true)
rows=$(grep -A12 'cell \$mem_v2' "$out/yosys-mem.log" | grep -c 'parameter \\SIZE 512' || true)
prms=$(grep -A12 'cell \$mem_v2' "$out/yosys-mem.log" | grep -c 'parameter \\SIZE 32' || true)
yosys -p "read_verilog -sv $v; hierarchy -top nds_gpu3d_geomtx; proc; stat -width" > "$out/yosys-raw.log" 2>&1
muls=$(awk '$2 == "$mul_64" { print $1 }' "$out/yosys-raw.log")
wide=$(awk '$2 ~ /^\$mul_(4[0-9]|[5-9][0-9]|1[0-9][0-9])$/ && $2 != "$mul_64" { n += $1 } END { print n + 0 }' "$out/yosys-raw.log")
echo "yosys: $mems inferred memories ($rows of 512 rows, $prms of 32 words); ${muls:-0} 32 x 32 product sites, $wide other wide multipliers"
[ "$mems" = 2 ] && [ "$rows" = 1 ] && [ "$prms" = 1 ] && [ "${muls:-0}" = 4 ] && [ "$wide" = 0 ] \
  || failures=$((failures + 1))

rm -rf "$out/vobj"
verilator --cc --exe --build -O2 -Wno-fatal --top-module nds_gpu3d_geomtx --Mdir "$out/vobj" \
    "$v" "$here/tests/geomtx_cosim.cpp" > "$out/verilator.log" 2>&1 \
  || { cat "$out/verilator.log" >&2; exit 1; }
# The cycle trace is piped straight into the bench (no trace file); the bench
# prints at most ten mismatches and a summary, and fails a trace without its
# end trailer, so a dump that died cannot pass.
for t in directed random; do
  printf 'verilog %s: ' "$t"
  "$chk" dump "$out/$t.bin" "$seed" - "$cosim" $rts | "$out/vobj/Vnds_gpu3d_geomtx" - > "$out/cosim-$t.log" \
    || failures=$((failures + 1))
  grep 'geomtx cosim:' "$out/cosim-$t.log" | tail -n 1
done

# Mutants: a copy of the source tree with one deliberate bug each in FILE
# (under src/); the random check, or the given check, must fail.
mutant() {
  name=$1 file=$2 expr=$3
  shift 3
  m=$out/mutant-$name
  rm -rf "$m"
  mkdir -p "$m/obj"
  cp -R "$here/src" "$here/test" "$m/"
  sed -e "$expr" "$here/src/$file" > "$m/src/$file"
  if cmp -s "$here/src/$file" "$m/src/$file"; then
    echo "mutant $name: the substitution did not apply"; failures=$((failures + 1)); return
  fi
  if ! build "$m" "$m" > "$m/build.log" 2>&1; then
    echo "mutant $name: did not build (see $m/build.log)"; failures=$((failures + 1)); return
  fi
  [ "$#" -gt 0 ] || set -- check "$out/random.bin" "$seed"
  # detected means the checker finished and counted mismatches; a crash or
  # an exhausted heap is a gate failure, not a detection
  if "$m/geomatrix-check" "$@" $rts > "$m/check.log" 2>&1; then
    echo "mutant $name: NOT detected"; failures=$((failures + 1))
  elif n=$(grep -E -o '[;,] [1-9][0-9]* (mismatches|wrong)$' "$m/check.log" | tail -n 1) && [ -n "$n" ]; then
    echo "mutant $name: detected (${n#[;,] })"
  else
    echo "mutant $name: the check failed without a mismatch count (see $m/check.log)"; failures=$((failures + 1))
  fi
  # keep the logs, drop the source copy, objects and binary (about 100 MB)
  rm -rf "$m/obj" "$m/src" "$m/test" "$m/geomatrix-check"
  return 0
}
gm=Nds/Gpu3D/GeoMatrix.hs
mutant stack-bound "$gm" 's/gErr g || sp'"'"' > 30/gErr g || sp'"'"' > 31/'
mutant mult43-column "$gm" 's/ShMul43 -> if r == 3 then (0, 3) else (0, 2)/ShMul43 -> if r == 3 then (0, 2) else (0, 2)/'
mutant vtxdiff-sign "$gm" 's/resize (unpack f :: Signed 10)/unpack (zeroExtend f)/'
mutant tex3-window "$gm" 's/slice d39 d24 (pack x)/slice d38 d23 (pack x)/'
mutant specular-window "$gm" 's/truncateB (x `shiftR` 8) - 512/truncateB (x `shiftR` 9) - 512/'
mutant diffuse-unlit "$gm" 's/difOf x = if lit then lowU x else 0/difOf x = lowU x/'
mutant box-far-plane "$gm" 's/bxComp b == 2 \&\& not far then/bxComp b == 2 \&\& far then/'
mutant vectest-bit12 "$gm" 's/if testBit w 12 then/if testBit w 11 then/'
mutant wide-denominator Nds/Gpu3D/GeoDiv.hs 's/divDone (truncateB (prod `shiftR` 32))/divDone (truncateB (prod `shiftR` 31))/' \
  div "$out/mutant-wide-denominator/src"

echo "geomatrix: $failures failing runs"
[ "$failures" -eq 0 ]
