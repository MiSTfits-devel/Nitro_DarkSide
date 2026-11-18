#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Pixel-perfect gate for the 3D path: the flat slice, then Gouraud, textured
# and translucent triangles, then every hardware block. Cheap checks run first
# so a broken equation fails in seconds instead of spending a Quartus-shaped
# amount of time.
#
# Restartable: every stage writes its output under $TMPDIR. With GATE_RESUME=1
# a stage that already passed on this exact tree (HEAD, diff and untracked
# files) is not rerun; its recorded output is printed again, marked as such.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../.." && pwd)
property_cases=${PROPERTY_CASES:-200000}
stream_cases=${STREAM_CASES:-5000}
raster_cases=${RASTER_CASES:-2000}
slope_cases=${SLOPE_CASES:-200000}
scene_frames=${SCENE_FRAMES:-64}

tree=$(cd "$repo" && { git rev-parse HEAD; git diff HEAD;
          git ls-files --others --exclude-standard -z | xargs -0 cat 2>/dev/null; } \
        | cksum | cut -d' ' -f1)
state=${TMPDIR:-/tmp}/nds-gpu3d-gate-state/$tree
mkdir -p "$state"

# stage SLUG TITLE COMMAND...: run one stage, record its output and status.
stage() {
  slug=$1
  title=$2
  shift 2
  echo "== $title =="
  if [ "${GATE_RESUME:-0}" = 1 ] && [ -f "$state/$slug.ok" ]; then
    cat "$state/$slug.log"
    echo "(resumed: recorded output of an earlier passing run on this tree)"
    return 0
  fi
  rm -f "$state/$slug.ok"
  { rc=0; "$@" 2>&1 || rc=$?; echo "$rc" > "$state/$slug.rc"; } | tee "$state/$slug.log"
  rc=$(cat "$state/$slug.rc")
  [ "$rc" -eq 0 ] || exit "$rc"
  touch "$state/$slug.ok"
}

# Type-check every module, including the tops no other gate loads. Catches
# duplicate instances and signature drift in seconds.
stage compile "module compile" \
  sh -c 'cd "$1/.." && stack --resolver lts-22.43 ghc -- -fno-code -isrc src/Nds/Gpu3D/*.hs src/Nds/Gpu3D/*/*.hs' \
  sh "$here"

stage twod "2D engine (TARDIS, one-pass frame, unified 3D/2D)" \
  "$here/run_gpu2d_check.sh"
stage recip "reciprocal table" "$here/run_recip_check.sh"
stage depth "depth interpolation" "$here/run_depth_check.sh"
stage frame "depth-tested frame (production melonDS, every pixel)" \
  "$here/run_frame_check.sh"
stage depthpipe "streaming depth engine" "$here/run_depth_pipe_check.sh"
stage property "exhaustive row union" \
  env CASES="$property_cases" "$here/run_flat_property.sh"
stage stream "streaming top" env CASES="$stream_cases" "$here/run_flat_check.sh"
stage raster "melonDS raster oracle" \
  env DISPCNT=0x20 CASES="$raster_cases" "$here/run_raster_check.sh"
stage slope "melonDS slope oracle" env CASES="$slope_cases" "$here/run_slope_check.sh"

stage attr "attribute interpolation (production Interpolator)" "$here/run_attr_check.sh"
stage gouraud "Gouraud frames (production melonDS, every pixel, 3 layers)" \
  env FRAMES="$scene_frames" "$here/run_scene_check.sh" gouraud
stage texel "texture sampling (production TextureLookup)" "$here/run_texel_check.sh"
stage shade "pixel shading (production RenderPixel, exhaustive)" "$here/run_shade_check.sh"
stage textured "textured frames (production melonDS, every pixel, 3 layers)" \
  env FRAMES="$scene_frames" "$here/run_scene_check.sh" textured
stage translucent "translucent frames (production melonDS, every pixel, 3 layers)" \
  env FRAMES="$scene_frames" "$here/run_scene_check.sh" translucent
stage shadepipe "pipelined pixel back end (Clash simulation, nds_gpu3d_shade)" \
  "$here/run_shade_pipe_check.sh"
stage polygon "polygon pipeline (production SubmitPolygon / VBlank sort, every field)" \
  "$here/run_polygon_check.sh"
stage geometry "geometry engine (production ExecuteCommand, full state per command)" \
  "$here/run_geometry_check.sh"
stage render "full renderer (production RenderFrame, both layers and every GetLine line)" \
  env FRAMES="$scene_frames" "$here/run_render_check.sh"
stage gxfront "GX front end (production GPU3D MMIO/FIFO; nds_gpu3d_gxfront in Clash simulation)" \
  "$here/run_gxfront_check.sh"
stage chip "whole chip (melonDS NDS via ARM9 I/O: every read, status and GetLine line)" \
  "$here/run_chip_check.sh"
stage polygonhw "polygon pipeline hardware (nds_gpu3d_polygon in Clash simulation vs the model)" \
  "$here/run_polygon_hw_check.sh"
stage geometryhw "geometry engine hardware (nds_gpu3d_geometry in Clash simulation vs the model)" \
  "$here/run_geometry_hw_check.sh"
stage rasterhw "rasteriser hardware (nds_gpu3d_raster in Clash simulation vs the model, random memory)" \
  "$here/run_raster_hw_check.sh"
stage chiphw "chip hardware (nds_gpu3d in Clash simulation vs the model, random memory)" \
  "$here/run_chip_hw_check.sh"
