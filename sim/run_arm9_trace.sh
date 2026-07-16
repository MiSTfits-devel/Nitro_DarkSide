#!/bin/sh
# ARM9 instruction-trace run (roadmap M3 exit-test harness). Produces
# arm9_trace.log in the repo root; compare against a melonDS trace with
# sim/tests/compare_trace.py (see docs/TRACE_DIFF.md).
#   MAXINSTR=10000000 HEXFILE=sim/tests/armwrestler.hex sim/run_arm9_trace.sh
set -eu
cd "$(dirname "$0")/.."

MAXINSTR="${MAXINSTR:-1000000}"
HEXFILE="${HEXFILE:-sim/tests/arm9_island.hex}"
TIMEOUT_MS="${TIMEOUT_MS:-100}"
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
   rtl/reggba_timer.vhd \
   rtl/gba_timer_module.vhd \
   rtl/gba_timer.vhd \
   rtl/nds_wram.vhd \
   rtl/nds_irq.vhd \
   rtl/nds_mainram.vhd \
   rtl/nds_membus9.vhd \
   sim/tb_arm9_trace.vhd

nvc -H 2g -L "$WORK" --work="$WORK/work" -e tb_arm9_trace \
   -gMAXINSTR="$MAXINSTR" -gHEXFILE="$HEXFILE" -gTIMEOUT_MS="$TIMEOUT_MS"
nvc -H 2g -L "$WORK" --work="$WORK/work" -r tb_arm9_trace --ieee-warnings=off --exit-severity=failure
