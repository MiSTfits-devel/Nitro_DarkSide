#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Full renderer gate: Nds.Gpu3D.Render against the production
# SoftRenderer3D::RenderFrame (direct TextureLookup path) on whole frames.
# Every directed case of gen_render_cases.py (one per feature: n-gon walk,
# anti-aliasing, edge marking, fog, rear-plane image, lower layer, shadows,
# shading, textures, W-buffer, RenderXPos, state carried between frames)
# and FRAMES seeded random frames of POLYS polygons are rendered by
# render_oracle and by the model; RenderCheck compares all 192 GetLine lines
# and every pixel of both colour/depth/attribute layers of every frame.
#
# Environment: FRAMES (default 64), POLYS (default 72), SEED0 (first random
# seed, default 1), KINDS (directed kinds, default all), STOP_ON_FAIL=1 to
# stop at the first failing case (mutation runs).
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
frames=${FRAMES:-64}
polys=${POLYS:-72}
seed0=${SEED0:-1}
kinds=${KINDS:-"ngon aa edge fog clear lower shadow shade texture wbuffer xpos carry"}
out=${TMPDIR:-/tmp}/nds-gpu3d-render-check

. "$here/tests/oracle_build.sh"
build_oracle nds_gx3d_render_oracle
mkdir -p "$out/obj"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/RenderCheck.hs -o "$out/render-check" >/dev/null

failures=0
cases=0
run_case() {
  name=$1
  python3 "$here/tests/gen_render_cases.py" "$2" "$3" "$polys" "$out/$name.txt" "$out/$name.vram"
  ORACLE_VRAM="$out/$name.vram" "$oracle_build/nds_gx3d_render_oracle" \
      < "$out/$name.txt" > "$out/$name.out"
  printf '%s: ' "$name"
  cases=$((cases + 1))
  if ! "$out/render-check" "$out/$name.txt" "$out/$name.vram" "$out/$name.out"; then
    failures=$((failures + 1))
    if [ "${STOP_ON_FAIL:-0}" = 1 ]; then
      echo "render-frames: stopped at the first failure ($cases cases run)"
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

echo "render-frames: $cases cases ($(echo $kinds | wc -w | tr -d ' ') directed, $frames random of $polys polygons), $failures failures"
[ "$failures" -eq 0 ]
