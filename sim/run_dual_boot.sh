#!/bin/sh
# M4 exit test: dual-CPU boot through the card-header HLE loader.
# nds_loader stages sim/tests/nds_dual.hex into main RAM, both CPUs run the
# SDK-shaped startup handshake (IPCSYNC + FIFO + WRAM/EXMEM handoff).
# TIMEOUT_MS env extends the watchdog.
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
   rtl/gba_cpu.vhd \
   rtl/nds_cpu9.vhd \
   rtl/nds_cache9.vhd \
   rtl/reggba_timer.vhd \
   rtl/gba_timer_module.vhd \
   rtl/gba_timer.vhd \
   rtl/nds_wram.vhd \
   rtl/nds_irq.vhd \
   rtl/nds_ipc.vhd \
   rtl/nds_syscnt.vhd \
   rtl/nds_loader.vhd \
   rtl/nds_mainram.vhd \
   rtl/nds_membus7.vhd \
   rtl/nds_membus9.vhd \
   sim/tb_dual_boot.vhd

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_dual_boot -gTIMEOUT_MS="$TIMEOUT_MS"
nvc -H 1g -L "$WORK" --work="$WORK/work" -r tb_dual_boot --ieee-warnings=off --exit-severity=failure
