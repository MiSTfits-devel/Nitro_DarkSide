#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Exhaustive differential gate for pixel shading: the production
# SoftRenderer3D::RenderPixel against Nds.Gpu3D.Shade.shadePixel over every
# blend mode (modulate, decal, toon, highlight, shadow), texture on and off,
# every texel/vertex colour pair on one channel, every texture alpha against
# every polygon alpha, and every RGB555 texel through the direct VRAM path.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
out=${TMPDIR:-/tmp}/nds-gpu3d-shade-check

. "$here/tests/oracle_build.sh"
build_oracle nds_gx3d_unit_oracle
mkdir -p "$out"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/ShadeCheck.hs -o "$out/shade-check" >/dev/null

"$oracle_build/nds_gx3d_unit_oracle" shade > "$out/shade.bin"
"$out/shade-check" "$out/shade.bin"
