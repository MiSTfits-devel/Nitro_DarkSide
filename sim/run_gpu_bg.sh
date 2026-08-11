#!/bin/sh
# M5 part 1: NDS BG drawer line tests (text + affine + ext palettes) against
# the gen_gpu_bg.py golden model. The vector/VRAM hex files are generated,
# not checked in - run `python3 sim/tests/gen_gpu_bg.py` (from sim/tests/)
# before streaming a DIRTY tree to the pod.
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-10}"
WORK=sim/nvc_work
mkdir -p "$WORK"

[ -f sim/tests/gpu_bg_vectors.hex ] || { echo "vectors missing: python3 sim/tests/gen_gpu_bg.py"; exit 1; }

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/nds_drawer_text.vhd \
   rtl/nds_drawer_affext.vhd \
   sim/tb_gpu_bg.vhd

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_gpu_bg -gTIMEOUT_MS="$TIMEOUT_MS"
nvc -H 1g -L "$WORK" --work="$WORK/work" -r tb_gpu_bg --ieee-warnings=off --exit-severity=failure
