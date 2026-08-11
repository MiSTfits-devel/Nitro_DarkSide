#!/bin/sh
# M5: timed engine-A full-frame tests — nds_gpu_timing paces nds_gpu2d +
# nds_vram at the real dot cadence (GPU fabric at CE_DIV x dot clock) and
# the frames must stay pixel-exact vs the gen_gpu2d_frame.py golden, with
# zero dropped lines. Vectors are generated, not checked in - run
# `python3 sim/tests/gen_gpu2d_frame.py` (from sim/tests/) first.
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-600}"
CE_DIV="${CE_DIV:-3}"
# A..D renderer feed: RSRV_ONE=1 models the hardware channel (one op in flight,
# ready low from acceptance to done); STALL_CYC>0 fails with a full dump if one
# line render stays busy that many cycles, which tells a wedge from slowness.
RSRV_LAT="${RSRV_LAT:-4}"
RSRV_ONE="${RSRV_ONE:-0}"
# RSRV_OUT/RSRV_GAP model the channel's DEPTH and THROUGHPUT rather than its
# latency - the pair that says what a clkMem overclock actually buys.
#   3x clkMem: RSRV_OUT=2 RSRV_GAP=3 RSRV_LAT=4
#   4x clkMem: RSRV_OUT=2 RSRV_GAP=2 RSRV_LAT=3
RSRV_OUT="${RSRV_OUT:-0}"
RSRV_GAP="${RSRV_GAP:-0}"
STALL_CYC="${STALL_CYC:-0}"
WORK="${WORK:-sim/nvc_work}"
mkdir -p "$WORK"

[ -f sim/tests/gpu2d_vectors.hex ] || { echo "vectors missing: python3 sim/tests/gen_gpu2d_frame.py"; exit 1; }

nvc --work="$WORK/altera_mf" -a --relaxed sim/altera_mf_stub.vhd
nvc -L "$WORK" --work="$WORK/mem" -a --relaxed rtl/SyncRamDualByteEnable.vhd
nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/reg_nds_display.vhd \
   rtl/nds_vram_map.vhd \
   rtl/nds_vram.vhd \
   rtl/nds_gpu_timing.vhd \
   rtl/nds_drawer_text.vhd \
   rtl/nds_drawer_affext.vhd \
   rtl/nds_drawer_obj.vhd \
   rtl/nds_drawer_merge.vhd \
   rtl/nds_gpu2d.vhd \
   sim/tb_gpu2d_timed.vhd

nvc -H 2g -L "$WORK" --work="$WORK/work" -e tb_gpu2d_timed -gTIMEOUT_MS="$TIMEOUT_MS" -gCE_DIV="$CE_DIV" \
   -gRSRV_LAT="$RSRV_LAT" -gRSRV_ONE="$RSRV_ONE" -gRSRV_OUT="$RSRV_OUT" \
   -gRSRV_GAP="$RSRV_GAP" -gSTALL_CYC="$STALL_CYC"
nvc -H 2g -L "$WORK" --work="$WORK/work" -r tb_gpu2d_timed --ieee-warnings=off --exit-severity=failure
