#!/bin/sh
# M5 exit test: boot a .nds image through nds_top and dump engine-A frames.
#   sim/run_top_frame.sh [image.hex]     (default sim/tests/nds_dual.hex)
# Env: FRAMES (default 3), TIMEOUT_MS (default 100), DUMPFILE.
# Heavy (full dual-CPU system + render path) - run on the sim pod, not the laptop.
set -eu
cd "$(dirname "$0")/.."

HEXFILE="${1:-${HEXFILE:-sim/tests/nds_dual.hex}}"
FWFILE="${FWFILE:-sim/tests/nds_firmware.hex}"
FRAMES="${FRAMES:-3}"
TIMEOUT_MS="${TIMEOUT_MS:-400}"
DIRECT="${DIRECT:-0}"
DUMPFILE="${DUMPFILE:-top_frame_fb.txt}"
DUMPFILE_B="${DUMPFILE_B:-top_frame_fb_b.txt}"
DUMP_START_FRAME="${DUMP_START_FRAME:-0}"
TRACEFILE="${TRACEFILE:-}"
TRACEFILE7="${TRACEFILE7:-}"
TRACE_START_FRAME="${TRACE_START_FRAME:-0}"
TRACE7_START_FRAME="${TRACE7_START_FRAME:-0}"
DUMP_STATE="${DUMP_STATE:-0}"
MAXINSTR="${MAXINSTR:-20000000}"
DBG_T0="${DBG_T0:-0}"
DBG_T1="${DBG_T1:-0}"
DBG_TRIGPC="${DBG_TRIGPC:-0}"
CARDWORDS="${CARDWORDS:-1048576}"
# Card/firmware read latency injection (0 = donor one-cycle models). On hardware
# both go through DDR3 (card = ddram ch2, firmware = ch1) at tens of cycles.
CARD_LAT="${CARD_LAT:-0}"
FW_LAT="${FW_LAT:-0}"
# Main-RAM latency injection (0 = fixed 6-read/3-write clkMem behavioral model).
# Real ddram ch2 is longer and variable; arbiter races in nds_mainram/nds_cache9
# need that variability to be reachable at all.
MEM_LAT="${MEM_LAT:-0}"
NVCHEAP="${NVCHEAP:-2g}"
NVCOPT="${NVCOPT:--O2}"
GPUCEDIV="${GPUCEDIV:-3}"
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
   rtl/nds_spi.vhd \
   rtl/nds_syscnt.vhd \
   rtl/nds_loader.vhd \
   rtl/nds_debug.vhd \
   rtl/nds_card.vhd \
   rtl/nds_rtc.vhd \
   rtl/nds_sound.vhd \
   rtl/nds_mainram.vhd \
   rtl/nds_membus7.vhd \
   rtl/nds_membus9.vhd \
   rtl/nds_vram_map.vhd \
   rtl/nds_vram.vhd \
   rtl/reg_nds_display.vhd \
   rtl/nds_drawer_text.vhd \
   rtl/nds_drawer_affine.vhd \
   rtl/nds_drawer_extended.vhd \
   rtl/nds_drawer_obj.vhd \
   rtl/nds_drawer_merge.vhd \
   rtl/nds_gpu2d.vhd \
   rtl/nds_gpu_timing.vhd \
   rtl/nds_dma9.vhd \
   rtl/nds_dma7.vhd \
   rtl/nds_bios7.vhd \
   rtl/nds_bios9.vhd \
   rtl/nds_top.vhd \
   sim/tb_top_frame.vhd

# nvc rejects -gNAME= with an empty value: only pass the trace generics when set
TRACEGEN=""
[ -n "$TRACEFILE" ]  && TRACEGEN="$TRACEGEN -gTRACEFILE=$TRACEFILE"
[ -n "$TRACEFILE7" ] && TRACEGEN="$TRACEGEN -gTRACEFILE7=$TRACEFILE7"

nvc -H "$NVCHEAP" -L "$WORK" --work="$WORK/work" -e "$NVCOPT" tb_top_frame \
   -gCARD_WORDS="$CARDWORDS" -gCARD_LAT="$CARD_LAT" -gFW_LAT="$FW_LAT" -gMEM_LAT="$MEM_LAT" \
   -gGPUCEDIV="$GPUCEDIV" -gHEXFILE="$HEXFILE" -gFWFILE="$FWFILE" -gFRAMES="$FRAMES" -gTIMEOUT_MS="$TIMEOUT_MS" \
   -gDUMPFILE="$DUMPFILE" -gDUMPFILE_B="$DUMPFILE_B" -gDUMP_START_FRAME="$DUMP_START_FRAME" -gDIRECT="$DIRECT" \
   -gMAXINSTR="$MAXINSTR" -gTRACE_START_FRAME="$TRACE_START_FRAME" -gTRACE7_START_FRAME="$TRACE7_START_FRAME" -gDUMP_STATE="$DUMP_STATE" \
   -gDBG_T0="$DBG_T0" -gDBG_T1="$DBG_T1" -gDBG_TRIGPC="$DBG_TRIGPC" $TRACEGEN
nvc -H "$NVCHEAP" -L "$WORK" --work="$WORK/work" -r tb_top_frame --ieee-warnings=off --exit-severity=failure
