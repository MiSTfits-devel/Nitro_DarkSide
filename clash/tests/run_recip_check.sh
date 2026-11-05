#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Checks the flat reciprocal table against the exact divider, including the
# tall-edge fallback outside the 257-entry table.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${TMPDIR:-/tmp}/nds-gpu3d-recip-check

mkdir -p "$out"
cd "$here"

stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    test/RecipCheck.hs src/Nds/Gpu3D/Slope.hs -o "$out/recip-check" >/dev/null

exec "$out/recip-check"
