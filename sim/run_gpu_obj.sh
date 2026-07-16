#!/bin/sh
# M5 part 2: NDS OBJ drawer line tests (tile/bitmap/affine sprites, ext
# palettes, priority merge) against the gen_gpu_obj.py golden model. The
# vector/VRAM hex files are generated, not checked in - run
# `python3 sim/tests/gen_gpu_obj.py` (from sim/tests/) before streaming a
# DIRTY tree to the pod.
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-10}"
WORK=sim/nvc_work
mkdir -p "$WORK"

[ -f sim/tests/gpu_obj_vectors.hex ] || { echo "vectors missing: python3 sim/tests/gen_gpu_obj.py"; exit 1; }

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/nds_drawer_obj.vhd \
   sim/tb_gpu_obj.vhd

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_gpu_obj -gTIMEOUT_MS="$TIMEOUT_MS"
nvc -H 1g -L "$WORK" --work="$WORK/work" -r tb_gpu_obj --ieee-warnings=off --exit-severity=failure
