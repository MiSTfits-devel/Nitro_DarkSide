#!/usr/bin/env bash
# Randomized torture test for nds_vram + nds_wram against a behavioral model.
# OPCOUNT=200000 SEED=7 ./sim/run_vram_torture_tb.sh  for longer runs (k8s host).
set -eu
cd "$(dirname "$0")/.."

OPCOUNT="${OPCOUNT:-20000}"
SEED="${SEED:-1}"
WORK=sim/nvc_work
mkdir -p "$WORK"

nvc --work="$WORK/altera_mf" -a --relaxed sim/altera_mf_stub.vhd

nvc -L "$WORK" --work="$WORK/mem" -a --relaxed \
   rtl/SyncRam.vhd \
   rtl/SyncRamDual.vhd \
   rtl/SyncRamDualByteEnable.vhd

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/nds_vram_map.vhd \
   rtl/nds_vram.vhd \
   rtl/nds_wram.vhd \
   sim/tb_vram_torture.vhd

nvc -L "$WORK" --work="$WORK/work" -e tb_vram_torture -gOPCOUNT="$OPCOUNT" -gSEED="$SEED"
nvc -L "$WORK" --work="$WORK/work" -r tb_vram_torture --ieee-warnings=off --exit-severity=failure
