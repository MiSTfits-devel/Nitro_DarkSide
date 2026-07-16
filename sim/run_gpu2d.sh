#!/bin/sh
# nds_gpu2d frame tests: engine A end-to-end (registers + drawers + merge +
# channel arbitration + ext-pal shadow) against the gen_gpu2d.py golden
# compositor. Vectors are generated, not checked in - run
# `python3 sim/tests/gen_gpu2d.py` (from sim/tests/) before a DIRTY stream.
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-200}"
WORK=sim/nvc_work
mkdir -p "$WORK"

[ -f sim/tests/gpu2d_frames.hex ] || { echo "vectors missing: python3 sim/tests/gen_gpu2d.py"; exit 1; }

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/export.vhd \
   rtl/proc_bus_gba.vhd \
   rtl/reg_nds_display.vhd \
   rtl/nds_drawer_text.vhd \
   rtl/nds_drawer_affine.vhd \
   rtl/nds_drawer_extended.vhd \
   rtl/nds_drawer_obj.vhd \
   rtl/nds_drawer_merge.vhd \
   rtl/nds_gpu2d.vhd \
   sim/tb_gpu2d.vhd

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_gpu2d -gTIMEOUT_MS="$TIMEOUT_MS"
nvc -H 2g -L "$WORK" --work="$WORK/work" -r tb_gpu2d --ieee-warnings=off --exit-severity=failure
