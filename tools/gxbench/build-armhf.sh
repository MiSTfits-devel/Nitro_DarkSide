#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Cross-build melonds_gxbench for the DE10-Nano's Cortex-A9 (armhf, static).
#
#   tools/gxbench/build-armhf.sh
#   -> tools/gxbench/build-armhf/melonds_gxbench
#
# Same shape as Nitro_DarkSide's sim/melonds_tracer/build-armhf.sh: a Debian
# container matching the host arch runs crossbuild-essential-armhf, so nothing is
# emulated on Apple Silicon. PROF=1 adds debug symbols and frame pointers without
# changing the optimization level, which is what the gdb sampling profile needs.
set -eu
cd "$(dirname "$0")"

REPO_ROOT=$(cd ../.. && pwd)
MELONDS_DIR="${MELONDS_DIR:-$REPO_ROOT/third_party/melonDS}"
IMAGE="nds-armhf-xc:bookworm"
BUILD_DIR="build-armhf"
FLAGS="-O2"

if [ "${PROF:-0}" = "1" ]; then
   BUILD_DIR="build-armhf-prof"
   FLAGS="-O2 -g -fno-omit-frame-pointer"
fi

[ -d "$MELONDS_DIR" ] || { echo "no melonDS tree at $MELONDS_DIR" >&2; exit 1; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
   echo "== building toolchain image $IMAGE (first run only)"
   docker build -t "$IMAGE" - <<'EOF'
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
        crossbuild-essential-armhf cmake ninja-build make \
    && rm -rf /var/lib/apt/lists/*
EOF
fi

echo "== cross-compiling melonds_gxbench for armhf ($BUILD_DIR, flags: $FLAGS)"
docker run --rm \
   -v "$(pwd):/bench" \
   -v "$MELONDS_DIR:/melonds:ro" \
   -w /bench \
   "$IMAGE" sh -c "
      set -e
      cmake -S /bench -B /bench/$BUILD_DIR -G Ninja \
         -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_TOOLCHAIN_FILE=/bench/armhf-toolchain.cmake \
         -DMELONDS_DIR=/melonds \
         -DCMAKE_C_FLAGS_RELEASE='$FLAGS' \
         -DCMAKE_CXX_FLAGS_RELEASE='$FLAGS'
      cmake --build /bench/$BUILD_DIR --target melonds_gxbench
   "

BIN="$(pwd)/$BUILD_DIR/melonds_gxbench"
echo "== built: $BIN"
file "$BIN" 2>/dev/null || true
