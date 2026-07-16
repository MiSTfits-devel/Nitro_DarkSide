#!/bin/sh
# NDS merge-stage line tests (windows/priority/blending incl. bitmap-OBJ
# alpha) against the gen_gpu_merge.py golden model. Vectors are generated,
# not checked in - run `python3 sim/tests/gen_gpu_merge.py` (from sim/tests/)
# before streaming a DIRTY tree.
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-10}"
WORK=sim/nvc_work
mkdir -p "$WORK"

[ -f sim/tests/gpu_merge_vectors.hex ] || { echo "vectors missing: python3 sim/tests/gen_gpu_merge.py"; exit 1; }

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/nds_drawer_merge.vhd \
   sim/tb_gpu_merge.vhd

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_gpu_merge -gTIMEOUT_MS="$TIMEOUT_MS"
nvc -H 1g -L "$WORK" --work="$WORK/work" -r tb_gpu_merge --ieee-warnings=off --exit-severity=failure
