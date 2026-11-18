#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Clash-simulation gate for the rasteriser hardware (Clash top
# nds_gpu3d_raster) against the renderer model Nds.Gpu3D.Render, which
# run_render_check.sh gates against melonDS. Every frame of the directed
# cases of gen_render_cases.py and FRAMES seeded random frames of POLYS
# polygons is encoded with Nds.Gpu3D.PolyRam into a behavioural memory and
# rendered back to back on one simulated rasteriser with random ready
# (READY/1024, default 768) and in-order latency 1..LATMAX (default 12) on
# every port (MEM=ideal: ready always, latency 1). raster-hw-check compares
# all output lines, the lower layer left in memory and the stencil/flag
# snapshot with renderFrameFrom, and reports cycles per frame. Before that,
# --jobs compares the front end and setup engine (every span value at every
# position) with the model's span setup.
#
# Environment: FRAMES (default 16), POLYS (default 72), SEED0 (default 1),
# KINDS (directed kinds), STOP_ON_FAIL=1, READY, LATMAX, MEM.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
frames=${FRAMES:-16}
polys=${POLYS:-72}
seed0=${SEED0:-1}
kinds=${KINDS:-"ngon aa edge fog clear lower shadow shade texture wbuffer xpos carry"}
out=${TMPDIR:-/tmp}/nds-gpu3d-raster-hw-check

mkdir -p "$out/obj"
cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/RasterHwCheck.hs -o "$out/raster-hw-check" >/dev/null

failures=0
cases=0
run_case() {
  name=$1
  python3 "$here/tests/gen_render_cases.py" "$2" "$3" "$polys" "$out/$name.txt" "$out/$name.vram"
  cases=$((cases + 1))
  printf '%s: ' "$name"
  if ! "$out/raster-hw-check" --jobs "$out/$name.txt" || \
     ! { printf '%s: ' "$name"; "$out/raster-hw-check" "$out/$name.txt" "$out/$name.vram"; }; then
    failures=$((failures + 1))
    if [ "${STOP_ON_FAIL:-0}" = 1 ]; then
      echo "raster-hw-frames: stopped at the first failure ($cases cases run)"
      exit 1
    fi
  fi
}

for kind in $kinds; do
  run_case "$kind" "$kind" 0
done
seed=$seed0
while [ "$seed" -lt $((seed0 + frames)) ]; do
  run_case "random$seed" random "$seed"
  seed=$((seed + 1))
done

echo "raster-hw-frames: $cases cases ($(echo $kinds | wc -w | tr -d ' ') directed, $frames random of $polys polygons), $failures failures"
[ "$failures" -eq 0 ]
