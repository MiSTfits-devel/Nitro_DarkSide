#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Native differential gate for the Clash edge-walk model.
#
# The oracle is the production melonDS Slope class, compiled straight out of
# the vendored header. The Haskell model is the same equations written for
# Clash. Nothing here needs Quartus, a board, or a ROM.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
melonds=${MELONDS_DIR:-$repo/../NDS4MiSTer/third_party/melonDS}
cases=${CASES:-200000}
reports=${REPORTS:-20}
out=${TMPDIR:-/tmp}/nds-gpu3d-slope-check

mkdir -p "$out"

c++ -std=c++20 -O2 \
    -I"$melonds/src" \
    "$here/test/oracle/slope_oracle.cpp" \
    -o "$out/slope_oracle"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/SlopeCheck.hs -o "$out/slope-check" >/dev/null

"$out/slope_oracle" "$cases" | "$out/slope-check" "$reports"
