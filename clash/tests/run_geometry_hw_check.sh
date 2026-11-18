#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Clash-simulation gate for the geometry-engine hardware (Clash top
# nds_gpu3d_geometry) against the geometry model, on the geometry gate's own
# input streams: the directed streams, then STREAMS seeded random streams of
# LENGTH inputs (SEED selects them), produced by
# tools/gx3d_oracle/geometry_oracle.cpp exactly as run_geometry_check.sh
# produces them. Random entry gaps, event ready, polygon stall and VBlank;
# every event, the status and every result word after every input are
# compared. TIMING=1 also runs the streams back to back and prints the cycles
# per command class against melonDS's accounting.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
seed=${SEED:-1}
streams=${STREAMS:-50}
length=${LENGTH:-4000}
out=${TMPDIR:-/tmp}/nds-gpu3d-geometry-hw-check

. "$here/tests/oracle_build.sh"
build_oracle nds_gx3d_geometry_oracle
mkdir -p "$out"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -threaded -rtsopts -isrc -itest -outputdir "$out/obj" \
    test/GeometryHwCheck.hs -o "$out/geometry-hw-check" >/dev/null

failures=0

"$oracle_build/nds_gx3d_geometry_oracle" directed > "$out/directed.bin" 2>/dev/null
"$oracle_build/nds_gx3d_geometry_oracle" random "$seed" "$streams" "$length" \
    > "$out/random.bin"

printf 'directed: '
"$out/geometry-hw-check" check "$out/directed.bin" "$seed" +RTS -N || failures=$((failures + 1))
printf 'random (seed %s, %s x %s): ' "$seed" "$streams" "$length"
"$out/geometry-hw-check" check "$out/random.bin" "$seed" +RTS -N || failures=$((failures + 1))

if [ "${TIMING:-0}" = 1 ]; then
  echo "cycles per command, directed + random streams back to back:"
  "$out/geometry-hw-check" time "$out/directed.bin" "$seed" +RTS -N || failures=$((failures + 1))
  "$out/geometry-hw-check" time "$out/random.bin" "$seed" +RTS -N || failures=$((failures + 1))
fi

# The checked-in Verilog against the Clash simulation: every directed stream
# and COSIM_RANDOM random streams replayed cycle by cycle under iverilog.  The
# replay is informational (see the doc); the Clash-simulation comparison above
# is the gate.
"$out/geometry-hw-check" dump "$out/directed.bin" "$seed" "$out/cosim-directed.txt"
"$out/geometry-hw-check" dump "$out/random.bin" "$seed" "$out/cosim-random.txt" \
    $(seq 0 $((${COSIM_RANDOM:-2} - 1)))
iverilog -g2012 -o "$out/cosim.vvp" "$here/tests/tb_geometry_cosim.sv" "$here/rtl/nds_gpu3d_geometry.v"
for t in directed random; do
  printf 'verilog %s: ' "$t"
  vvp -n "$out/cosim.vvp" +trace="$out/cosim-$t.txt" > "$out/cosim-$t.log"
  grep 'geometry cosim:' "$out/cosim-$t.log" | tail -n 1
  # The replay must compare every cycle of the stream.  Its mismatches are
  # reported, not asserted: the generated Verilog has x bits where the Clash
  # simulation is defined (Clash's packed reset padding reaches STATUS bit 27 and
  # the result port), which the model gate cannot see.  See doc-geometry-hw.md.
  grep -Eq 'geometry cosim: [1-9][0-9]* cycles compared' "$out/cosim-$t.log" \
    || failures=$((failures + 1))
done

echo "geometry hardware: $failures failing runs"
[ "$failures" -eq 0 ]
