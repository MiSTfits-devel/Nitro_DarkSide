#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Native differential gate for vertex-colour, texture-coordinate and W
# interpolation: the production Interpolator<0> (span) and Interpolator<1>
# (edge) against Nds.Gpu3D.Depth.interpolate, at every X of each setup,
# consecutive and scattered. SETUPS sets the number of interpolators.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
setups=${SETUPS:-20000}
out=${TMPDIR:-/tmp}/nds-gpu3d-attr-check

. "$here/tests/oracle_build.sh"
build_oracle nds_gx3d_unit_oracle
mkdir -p "$out"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/AttrCheck.hs -o "$out/attr-check" >/dev/null

"$oracle_build/nds_gx3d_unit_oracle" attr "$setups" > "$out/attr.bin"
"$out/attr-check" "$out/attr.bin"
