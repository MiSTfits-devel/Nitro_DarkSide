#!/bin/sh
# ARM7 island exit test (roadmap M2): vendored gba_cpu + nds_membus7 + memory
# fabric + timers/IRQ/IPC running sim/tests/arm7_island.hex as BIOS.
# TIMEOUT_MS=20 sim/run_arm7_island.sh to extend the watchdog.
set -eu
cd "$(dirname "$0")/.."

# 45 ms, not 10: nds_vram's reset clear pass zeroes all 656 KB of banks before
# the CPU is released (mirroring nds_top's clr_busy gate), and this TB's
# behavioral A..D server answers with 1..8 cycles of random latency, so the
# clear alone costs ~26 ms of simulated time (measured: 131072 word writes at
# ~200 ns each).
TIMEOUT_MS="${TIMEOUT_MS:-45}"
WORK="${WORK:-sim/nvc_work}"
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
   rtl/reggba_timer.vhd \
   rtl/gba_timer_module.vhd \
   rtl/gba_timer.vhd \
   rtl/nds_vram_map.vhd \
   rtl/nds_vram.vhd \
   rtl/nds_wram.vhd \
   rtl/nds_irq.vhd \
   rtl/nds_ipc.vhd \
   rtl/nds_mainram.vhd \
   rtl/nds_membus7.vhd \
   sim/tb_arm7_island.vhd

# HEXFILE selects which ARM7 image runs as the "BIOS": the island smoke test
# by default, or e.g. sim/tests/arm7_ctxrestore.hex for the exception-return
# regression. Without this the tb silently ran arm7_island whatever was asked
# for, which makes a new test look like it passed (or failed) on its own.
HEXFILE="${HEXFILE:-sim/tests/arm7_island.hex}"

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_arm7_island -gTIMEOUT_MS="$TIMEOUT_MS" -gHEXFILE="$HEXFILE"
nvc -H 1g -L "$WORK" --work="$WORK/work" -r tb_arm7_island --ieee-warnings=off --exit-severity=failure
