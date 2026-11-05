#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Pixel-perfect gate for the flat 3D path. Cheap checks run first so a broken
# equation fails in seconds instead of spending a Quartus-shaped amount of time.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
property_cases=${PROPERTY_CASES:-200000}
stream_cases=${STREAM_CASES:-5000}
raster_cases=${RASTER_CASES:-2000}
slope_cases=${SLOPE_CASES:-200000}

echo "== module compile =="
# Type-check every module, including the tops no other gate loads. Catches
# duplicate instances and signature drift in seconds.
(cd "$here/.." && stack --resolver lts-22.43 ghc -- -fno-code -isrc src/Nds/Gpu3D/*.hs)

echo "== reciprocal table =="
"$here/run_recip_check.sh"

echo "== depth interpolation =="
"$here/run_depth_check.sh"

echo "== depth-tested frame (production melonDS, every pixel) =="
"$here/run_frame_check.sh"

echo "== streaming depth engine =="
"$here/run_depth_pipe_check.sh"

echo "== exhaustive row union =="
CASES="$property_cases" "$here/run_flat_property.sh"

echo "== streaming top =="
CASES="$stream_cases" "$here/run_flat_check.sh"

echo "== melonDS raster oracle =="
DISPCNT=0x20 CASES="$raster_cases" "$here/run_raster_check.sh"

echo "== melonDS slope oracle =="
CASES="$slope_cases" "$here/run_slope_check.sh"
