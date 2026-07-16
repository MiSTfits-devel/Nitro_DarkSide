#!/bin/sh
# Build the headless melonDS tracer (docs/TRACE_DIFF.md).
#   MELONDS_DIR=~/sources/melonDS sim/melonds_tracer/build.sh
# Clones melonDS 0.9.5 into MELONDS_DIR if absent, applies tracer.patch
# (idempotent), builds into sim/melonds_tracer/build/melonds_tracer.
set -eu
cd "$(dirname "$0")"

MELONDS_DIR="${MELONDS_DIR:-$HOME/sources/melonDS}"
MELONDS_TAG=0.9.5

if [ ! -d "$MELONDS_DIR" ]; then
   git clone --branch "$MELONDS_TAG" --depth 1 \
      https://github.com/melonDS-emu/melonDS.git "$MELONDS_DIR"
fi

if git -C "$MELONDS_DIR" apply --check "$(pwd)/tracer.patch" 2>/dev/null; then
   git -C "$MELONDS_DIR" apply "$(pwd)/tracer.patch"
   echo "applied tracer.patch"
elif git -C "$MELONDS_DIR" apply --check --reverse "$(pwd)/tracer.patch" 2>/dev/null; then
   echo "tracer.patch already applied"
else
   echo "tracer.patch does not apply cleanly to $MELONDS_DIR (expected tag $MELONDS_TAG)" >&2
   exit 1
fi

cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DMELONDS_DIR="$MELONDS_DIR"
cmake --build build --target melonds_tracer
echo "built: $(pwd)/build/melonds_tracer"
