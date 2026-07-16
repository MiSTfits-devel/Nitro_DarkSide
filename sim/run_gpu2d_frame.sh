#!/bin/sh
# M5: engine-A full-frame tests — nds_gpu2d + nds_vram + line server against
# the gen_gpu2d_frame.py golden (256x192 pixel-exact frames). Vectors are
# generated, not checked in - run `python3 sim/tests/gen_gpu2d_frame.py`
# (from sim/tests/) first.
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-400}"
WORK=sim/nvc_work
mkdir -p "$WORK"

[ -f sim/tests/gpu2d_vectors.hex ] || { echo "vectors missing: python3 sim/tests/gen_gpu2d_frame.py"; exit 1; }

nvc --work="$WORK/altera_mf" -a --relaxed sim/altera_mf_stub.vhd
nvc -L "$WORK" --work="$WORK/mem" -a --relaxed rtl/SyncRamDualByteEnable.vhd
nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/reg_nds_display.vhd \
   rtl/nds_vram_map.vhd \
   rtl/nds_vram.vhd \
   rtl/nds_drawer_text.vhd \
   rtl/nds_drawer_affine.vhd \
   rtl/nds_drawer_extended.vhd \
   rtl/nds_drawer_obj.vhd \
   rtl/nds_drawer_merge.vhd \
   rtl/nds_gpu2d.vhd \
   sim/tb_gpu2d_frame.vhd

nvc -H 2g -L "$WORK" --work="$WORK/work" -e tb_gpu2d_frame -gTIMEOUT_MS="$TIMEOUT_MS"
nvc -H 2g -L "$WORK" --work="$WORK/work" -r tb_gpu2d_frame --ieee-warnings=off --exit-severity=failure
