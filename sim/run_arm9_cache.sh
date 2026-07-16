#!/bin/sh
# ARM9 cache test (roadmap M3): the island harness booting arm9_cache.hex -
# self-checking nds_cache9 exercise (write-back, clean/invalidate, I-cache
# staleness). TIMEOUT_MS env extends the watchdog.
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-10}"
WORK=sim/nvc_work
mkdir -p "$WORK"

nvc --work="$WORK/altera_mf" -a --relaxed sim/altera_mf_stub.vhd

nvc -L "$WORK" --work="$WORK/mem" -a --relaxed \
   rtl/SyncFifo.vhd \
   rtl/SyncFifoFallThrough.vhd \
   rtl/SyncRam.vhd \
   rtl/SyncRamDual.vhd \
   rtl/SyncRamDualByteEnable.vhd \
   rtl/SyncRamDualNotPow2.vhd

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/export.vhd \
   rtl/proc_bus_gba.vhd \
   rtl/reg_savestates.vhd \
   rtl/nds_cpu9.vhd \
   rtl/nds_cache9.vhd \
   rtl/reggba_timer.vhd \
   rtl/gba_timer_module.vhd \
   rtl/gba_timer.vhd \
   rtl/nds_wram.vhd \
   rtl/nds_irq.vhd \
   rtl/nds_mainram.vhd \
   rtl/nds_membus9.vhd \
   sim/tb_arm9_island.vhd

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_arm9_island -gTIMEOUT_MS="$TIMEOUT_MS" -gHEXFILE=sim/tests/arm9_cache.hex
nvc -H 1g -L "$WORK" --work="$WORK/work" -r tb_arm9_island --ieee-warnings=off --exit-severity=failure
