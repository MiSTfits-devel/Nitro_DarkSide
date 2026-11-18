#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Gate for the polygon pipeline model (Nds.Gpu3D.Polygon): polygon assembly,
# culling, clipping, the viewport transform, polygon/vertex RAM and the
# SWAP_BUFFERS / VBlank sort, against the production melonDS GPU3D driven
# through its own command path (tools/gx3d_oracle/polygon_oracle.cpp).
#
# One directed stream, then SEEDS seeded random streams of FRAMES frames
# each (seeds SEED .. SEED+SEEDS-1). Every vertex, dump and VBlank of every
# stream is compared; the counts and the failure total are printed last.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
seed=${SEED:-1}
seeds=${SEEDS:-16}
frames=${FRAMES:-128}
out=${TMPDIR:-/tmp}/nds-gpu3d-polygon-check

. "$here/tests/oracle_build.sh"
build_oracle nds_gx3d_polygon_oracle
mkdir -p "$out"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/PolygonCheck.hs -o "$out/polygon-check" >/dev/null

oracle=$oracle_build/nds_gx3d_polygon_oracle
# run_oracle NAME ARGS...: write one stream; the oracle's own consistency
# check (its ClipVertex replica against TempVertexBuffer) aborts the gate.
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
"$out/polygon-check" $streams
