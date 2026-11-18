#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Frame gate for the textured/translucent rasteriser. KIND is gouraud,
# textured or translucent (see gen_scene_cases.py). One directed frame (seed 0)
# and FRAMES seeded random frames of TRIS triangles are rendered through the
# production SoftRenderer3D::RenderFrame and through Nds.Gpu3D.Scene, and every
# pixel is compared on the top colour, depth and attribute layers.
#
# The reference is melonDS's direct TextureLookup path, which is upstream
# melonDS's only software path. The NDS4MiSTer fork also has a decoded
# texture cache (its default); for textured kinds that path is rendered too
# and its disagreement with the model is counted, not gated (two known fork
# divergences, documented in docs/GPU3D_CLASH.md).
set -eu

kind=${1:?usage: run_scene_check.sh gouraud|textured|translucent}
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
frames=${FRAMES:-32}
tris=${TRIS:-48}
out=${TMPDIR:-/tmp}/nds-gpu3d-scene-check/$kind

. "$here/tests/oracle_build.sh"
build_oracle nds_gx3d_scene_oracle
mkdir -p "$out"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/../obj" \
    test/SceneCheck.hs -o "$out/../scene-check" >/dev/null

render() {
  ORACLE_VRAM="$out/$1.vram" ORACLE_TEXCACHE="$2" \
  ORACLE_DEPTH_OUT="$out/$1.$2.depth" ORACLE_ATTR_OUT="$out/$1.$2.attr" \
      "$oracle_build/nds_gx3d_scene_oracle" < "$out/$1.txt" > "$out/$1.$2.rgba"
}

failures=0
cache_frames=0
cache_layers=0
seed=0
while [ "$seed" -le "$frames" ]; do
  name=$kind$seed
  python3 "$here/tests/gen_scene_cases.py" "$kind" "$seed" "$tris" \
      "$out/$name.txt" "$out/$name.vram"
  render "$name" 0
  printf '%s: ' "$name"
  "$out/../scene-check" "$out/$name.txt" "$out/$name.vram" \
      "$out/$name.0.rgba" "$out/$name.0.depth" "$out/$name.0.attr" \
      || failures=$((failures + 1))
  if [ "$kind" != gouraud ]; then
    render "$name" 1
    n=$("$out/../scene-check" --count "$out/$name.txt" "$out/$name.vram" \
          "$out/$name.1.rgba" "$out/$name.1.depth" "$out/$name.1.attr" \
        | sed -n 's/^texcache-path: \([0-9]*\) .*/\1/p')
    if [ "$n" != 0 ]; then
      cache_frames=$((cache_frames + 1))
      cache_layers=$((cache_layers + n))
    fi
  fi
  seed=$((seed + 1))
done

echo "$kind-frames: $((frames + 1)) frames of $tris triangles, $failures failures"
if [ "$kind" != gouraud ]; then
  echo "$kind-texcache (fork cache path, informational): $cache_frames of $((frames + 1)) frames differ, $cache_layers pixel layers"
fi
[ "$failures" -eq 0 ]
