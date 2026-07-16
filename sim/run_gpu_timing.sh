#!/bin/sh
# M5: nds_gpu_timing checks — cycle-exact cadence/flag/IRQ model asserts
# every DUT output every edge over 4+ frames, both CPU register buses.
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-200}"
WORK=sim/nvc_work
mkdir -p "$WORK"

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/reg_nds_display.vhd \
   rtl/nds_gpu_timing.vhd \
   sim/tb_gpu_timing.vhd

nvc -L "$WORK" --work="$WORK/work" -e tb_gpu_timing -gTIMEOUT_MS="$TIMEOUT_MS"
nvc -L "$WORK" --work="$WORK/work" -r tb_gpu_timing --ieee-warnings=off --exit-severity=failure
