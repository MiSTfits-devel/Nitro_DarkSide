#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Gate for the geometry-engine model (Nds.Gpu3D.Geometry): directed streams
# covering every command and branch, then STREAMS seeded random streams of
# LENGTH inputs each (SEED selects them), all run through production melonDS
# GPU3D::ExecuteCommand by tools/gx3d_oracle/geometry_oracle.cpp and compared
# input by input (full state, result registers, emitted vertices and events).
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
seed=${SEED:-1}
streams=${STREAMS:-50}
length=${LENGTH:-4000}
out=${TMPDIR:-/tmp}/nds-gpu3d-geometry-check

. "$here/tests/oracle_build.sh"
build_oracle nds_gx3d_geometry_oracle
mkdir -p "$out"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/GeometryCheck.hs -o "$out/geometry-check" >/dev/null

failures=0

"$oracle_build/nds_gx3d_geometry_oracle" directed > "$out/directed.bin" 2>/dev/null
printf 'directed: '
"$out/geometry-check" "$out/directed.bin" || failures=$((failures + 1))

"$oracle_build/nds_gx3d_geometry_oracle" random "$seed" "$streams" "$length" \
    > "$out/random.bin"
printf 'random (seed %s, %s x %s): ' "$seed" "$streams" "$length"
"$out/geometry-check" "$out/random.bin" || failures=$((failures + 1))

echo "geometry: $failures failing runs"
[ "$failures" -eq 0 ]
