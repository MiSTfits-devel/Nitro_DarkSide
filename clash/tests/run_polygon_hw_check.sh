#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Clash-simulation gate for the polygon pipeline hardware (Clash top
# nds_gpu3d_polygon, Nds.Gpu3D.PolygonHw) against the pure model
# (Nds.Gpu3D.Polygon), on the polygon oracle's streams: the directed stream,
# then SEEDS seeded random streams of FRAMES frames (seeds SEED ..
# SEED+SEEDS-1). Behavioural memory with random ready and 1..8-cycle read
# latency, random event gaps of up to GAP cycles, VBlank and acknowledge
# pulses that land while the block is busy. Every event's RAM_COUNT /
# overflow / timing and every swap's render list (decoded from memory
# through Nds.Gpu3D.PolyRam) are compared; counts and cycle figures last.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
seed=${SEED:-1}
seeds=${SEEDS:-4}
frames=${FRAMES:-128}
gap=${GAP:-16}
out=${TMPDIR:-/tmp}/nds-gpu3d-polygon-hw-check

. "$here/tests/oracle_build.sh"
build_oracle nds_gx3d_polygon_oracle
mkdir -p "$out"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/PolygonHwCheck.hs -o "$out/polygon-hw-check" >/dev/null

oracle=$oracle_build/nds_gx3d_polygon_oracle
run_oracle() {
  name=$1
  shift
  if ! "$oracle" "$@" > "$out/$name.txt" 2> "$out/$name.log"; then
    cat "$out/$name.log" >&2
    exit 1
  fi
}
run_oracle directed directed
streams=$out/directed.txt
i=0
while [ "$i" -lt "$seeds" ]; do
  s=$((seed + i))
  run_oracle "random$s" random "$s" "$frames"
  streams="$streams $out/random$s.txt"
  i=$((i + 1))
done

# shellcheck disable=SC2086
"$out/polygon-hw-check" --gap "$gap" $streams
