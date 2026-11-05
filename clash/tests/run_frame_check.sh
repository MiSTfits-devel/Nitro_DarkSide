#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Depth-test frame gate: production melonDS frames compared with the model at
# every pixel, on colour and on the final depth-buffer value. One directed frame
# (near/far order, equal-Z front- and back-facing, disjoint regions) and FRAMES
# seeded random frames of TRIS triangles each.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
melonds=${MELONDS_DIR:-$repo/../NDS4MiSTer/third_party/melonDS}
out=${TMPDIR:-/tmp}/nds-gpu3d-frame-check
frames=${FRAMES:-16}
tris=${TRIS:-48}

mkdir -p "$out"

cmake -S "$repo/tools/gx3d_oracle" -B "$out/build" \
    -DMELONDS_DIR="$melonds" >/dev/null
cmake --build "$out/build" --target nds_gx3d_frame_oracle >/dev/null

printf '%s\n' \
  'TRIZ 10 10 1048576 50 10 1048576 30 50 1048576 1 0 0 1' \
  'TRIZ 10 10 8388608 50 10 8388608 30 50 8388608 0 0 1 1' \
  'TRIZ 10 10 4194304 50 10 4194304 30 50 4194304 0 1 0 1' \
  'TRIZ 70 10 8388608 110 10 8388608 90 50 8388608 1 1 0 1' \
  'TRIZ 70 10 1048576 110 10 1048576 90 50 1048576 1 0 1 1' \
  'TRIZ 130 10 4194304 170 10 4194304 150 50 4194304 0 1 1 1' \
  'TRIZ 130 10 4194304 170 10 4194304 150 50 4194304 1 1 0 1' \
  'TRIZ 190 10 4194304 230 10 4194304 210 50 4194304 1 1 1 0' \
  'TRIZ 190 10 4194304 230 10 4194304 210 50 4194304 1 0 1 0' \
  'TRIZW 40 100 1048576 9 40 100 2097152 9 40 100 3145728 9 31 0 0 1' \
  'TRIZW 0 110 1048576 9 0 110 2097152 9 0 110 3145728 9 0 31 0 1' \
  'TRIZW 50 120 1048576 9 50 120 9437184 9 90 120 3145728 9 0 0 31 0' \
  'TRIZW 140 120 9437184 9 100 120 1048576 9 100 120 3145728 9 31 31 0 1' \
  'TRIZW 60 130 1048576 9 60 150 5242880 9 60 170 9437184 9 31 0 31 1' \
  'TRIZW 256 140 1048576 9 200 140 9437184 9 256 140 5242880 9 0 31 31 0' \
  'TRIZW 120 180 1048576 9 256 192 9437184 9 250 160 5242880 9 7 7 7 1' \
  'TRIZW 150 60 1048576 9 256 80 14680064 9 150 100 5242880 9 31 15 0 1' \
  'TRIZW 200 100 1048576 9 256 110 14680064 9 256 135 5242880 9 31 31 31 1' \
  'TRIZW 0 140 1048576 9 256 150 14680064 9 0 190 5242880 9 3 30 9 1' \
  > "$out/cases.txt"

cd "$here"
stack --resolver lts-22.43 ghc -- -O2 -isrc -itest -outputdir "$out/obj" \
    test/FrameCheck.hs -o "$out/frame-check" >/dev/null

run_frame() {
  ORACLE_DISPCNT=0x20 ORACLE_DEPTH_OUT="$out/$1.depth" \
      "$out/build/nds_gx3d_frame_oracle" < "$out/$1.txt" > "$out/$1.rgba"
  printf '%s: ' "$1"
  "$out/frame-check" "$out/$1.txt" "$out/$1.rgba" "$out/$1.depth"
}

cp "$out/cases.txt" "$out/directed.txt"
run_frame directed
# A triangle whose row 182 is a full-width span with raw interpolator interval
# [0, 257), the reciprocal table's last entry. It covers most of the screen, so
# it gets a frame of its own.
printf '%s\n' \
  'TRIZW 0 183 2097152 9 256 192 12582912 9 256 0 6291456 9 17 9 30 0' \
  > "$out/border.txt"
run_frame border
seed=1
while [ "$seed" -le "$frames" ]; do
  python3 "$here/tests/gen_frame_cases.py" "$seed" "$tris" > "$out/random$seed.txt"
  run_frame "random$seed"
  seed=$((seed + 1))
done
