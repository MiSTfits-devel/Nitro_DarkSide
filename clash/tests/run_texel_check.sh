#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Native differential gate for texture sampling: the production
# SoftRenderer3D::TextureLookup against the staged Nds.Gpu3D.Texture model,
# over a random VRAM image. Every 8x8 format x wrap/flip x colour-0 mode is
# swept exhaustively over texel positions -24..31 on both axes; CASES random
# lookups then cover every size, base, palette and coordinate.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
cases=${CASES:-200000}
out=${TMPDIR:-/tmp}/nds-gpu3d-texel-check

. "$here/tests/oracle_build.sh"
build_oracle nds_gx3d_unit_oracle
mkdir -p "$out"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/TexelCheck.hs -o "$out/texel-check" >/dev/null

"$oracle_build/nds_gx3d_unit_oracle" texel "$cases" "$out/vram.bin" > "$out/texel.bin"
"$out/texel-check" "$out/texel.bin" "$out/vram.bin"
