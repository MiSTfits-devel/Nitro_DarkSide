#!/bin/sh
# Focused atomic runtime BIOS-RAM load regression.
set -eu
cd "$(dirname "$0")/.."

WORK=sim/nvc_work_bios_hotload
mkdir -p "$WORK"

nvc --work="$WORK/altera_mf" -a --relaxed sim/altera_mf_stub.vhd
nvc -L "$WORK" --work="$WORK/mem" -a --relaxed rtl/SyncRamDualByteEnable.vhd

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/nds_bios7.vhd \
   rtl/nds_bios9.vhd \
   sim/tb_bios_hotload.vhd
nvc -L "$WORK" --work="$WORK/work" -e tb_bios_hotload
nvc -L "$WORK" --work="$WORK/work" -r tb_bios_hotload \
   --ieee-warnings=off --exit-severity=failure
