#!/usr/bin/env bash
# Smoke test: analyze every RTL file in the repo under nvc (three-library flow,
# same shape as GBA_MiSTfits). Catches breakage in vendored files and skeletons
# without needing a full testbench. CI-friendly.
set -eu
cd "$(dirname "$0")/.."

WORK=sim/nvc_work
mkdir -p "$WORK"

# 1) Altera megafunction stubs (sim only)
nvc --work="$WORK/altera_mf" -a --relaxed sim/altera_mf_stub.vhd

# 2) memory primitives -> logical library "mem"
nvc -L "$WORK" --work="$WORK/mem" -a --relaxed \
   rtl/SyncFifo.vhd \
   rtl/SyncFifoFallThrough.vhd \
   rtl/SyncRam.vhd \
   rtl/SyncRamDual.vhd \
   rtl/SyncRamDualByteEnable.vhd \
   rtl/SyncRamDualNotPow2.vhd

# 3) everything else -> work
nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/export.vhd \
   rtl/proc_bus_gba.vhd \
   rtl/reg_savestates.vhd \
   rtl/gba_cpu.vhd \
   rtl/dpram.vhd \
   rtl/DDR3Mux.vhd \
   rtl/reggba_timer.vhd \
   rtl/gba_timer_module.vhd \
   rtl/gba_timer.vhd \
   rtl/nds_vram_map.vhd \
   rtl/nds_vram.vhd \
   rtl/nds_wram.vhd \
   rtl/nds_mainram.vhd \
   rtl/nds_irq.vhd \
   rtl/nds_ipc.vhd \
   rtl/nds_membus7.vhd \
   rtl/nds_top.vhd \
   sim/tb_vram_map.vhd \
   sim/tb_vram_torture.vhd \
   sim/tb_mainram.vhd \
   sim/tb_arm7_island.vhd

# 4) elaborate the standalone entities as a sanity gate
nvc -L "$WORK" --work="$WORK/work" -e nds_top
nvc -L "$WORK" --work="$WORK/work" -e tb_vram_map
nvc -L "$WORK" --work="$WORK/work" -e tb_vram_torture
nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_mainram
nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_arm7_island

echo "analyze-all: OK"
