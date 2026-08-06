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
# FWBOOT=1: real firmware boot - no staging, no env block, BIOSes run from their
# reset vectors. Needs FWFILE to be a genuine firmware image (firmware_retail.hex
# is the real DS non-Lite dump, verified 100% word-identical to a retail dump).
FWBOOT="${FWBOOT:-0}"
HEARTBEAT_MS="${HEARTBEAT_MS:-0}"
VRAMOPS="${VRAMOPS:-0}"
GPUFAST="${GPUFAST:-0}"
# 0 = compile nds_sound out, matching nds_port_wrap's SOUND_ENABLE=0 build switch
SOUND="${SOUND:-1}"
# A..D renderer read model: LAT cycles, ONE=1 models hardware (one op in flight)
VRSRV_LAT="${VRSRV_LAT:-4}"
VRSRV_ONE="${VRSRV_ONE:-0}"
VRSRV_OUT="${VRSRV_OUT:-0}"
VRSRV_GAP="${VRSRV_GAP:-0}"
ISLAND="${ISLAND:-1}"      # 0 = tie clk2x to clk1x, no ARM9 island (see tb generic)
# clk2x half period in ps: 7500 = 66.67 MHz (the current 2:1). Raise to model
# giving the ARM9 island its own slower PLL output instead of sharing the video
# clock - e.g. 8750 = 57.1 MHz, which is where clk2x timing would close.
ISLAND_HALF_PS="${ISLAND_HALF_PS:-7500}"
DUMPFILE="${DUMPFILE:-top_frame_fb.txt}"
DUMPFILE_B="${DUMPFILE_B:-top_frame_fb_b.txt}"
DUMP_START_FRAME="${DUMP_START_FRAME:-0}"
TRACEFILE="${TRACEFILE:-}"
TRACEFILE7="${TRACEFILE7:-}"
TRACE_START_FRAME="${TRACE_START_FRAME:-0}"
TRACE7_START_FRAME="${TRACE7_START_FRAME:-0}"
# ARM7 trace window in us. TRACE7_T1>0 replaces the frame gate above, which is
# useless for firmware boot: the dump-frame counter does not advance until the
# display runs (POWCNT1 at 1.49 s), long after the interesting code.
TRACE7_T0="${TRACE7_T0:-0}"
TRACE7_T1="${TRACE7_T1:-0}"
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
# >0: cumulative ARM9 memory-path cycle histogram every N clk1x cycles
CYCLE_HIST="${CYCLE_HIST:-0}"
# 1: stage the ARM9/ARM7 main-RAM sections straight into the SDRAM model instead
# of simulating nds_loader's word-by-word copy. Identical end state; removes
# ~70 ms of simulated time (443k word copies for Kirby) from every boot.
PRELOAD="${PRELOAD:-0}"
# >0: fail with a full renderer-chain dump if one engine-A line render stays busy
# that many clk1x cycles (wedge vs over-budget). GPUFAST=0 only - see the generic.
STALL_CYC="${STALL_CYC:-0}"
# ARM7 firmware-boot instruments: IRQ source census + ARM7 WRAM write watch on
# ARM7WATCH (default the faulting word of the first ticket). Trace-free.
ARM7DBG="${ARM7DBG:-0}"
# Give this in HEX and let the shell convert. Writing the decimal out by hand put
# the watch on 0x0380108C for one run - a hand-converted address is a silent way
# to watch the wrong memory for four hours.
ARM7WATCH="${ARM7WATCH:-0x0380E28C}"
# 1: stop the run at the instant the ARM7 PC first retires at >=0x04000000,
# printing the last 96 retires. The 1.588 s decode fault is ~100 ms and over a
# million instructions downstream of the actual departure, so this is the only
# probe that points at the cause rather than the crash site.
ARM7RUNAWAY="${ARM7RUNAWAY:-0}"
NVCHEAP="${NVCHEAP:-2g}"
NVCOPT="${NVCOPT:--O2}"
GPUCEDIV="${GPUCEDIV:-3}"
# overridable so a second run can analyse into its own library instead of
# rewriting the one a long run in another shell is still executing from
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
   rtl/nds_gpu2d_fast.vhd \
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
   -gCARD_WORDS="$CARDWORDS" -gCARD_LAT="$CARD_LAT" -gFW_LAT="$FW_LAT" -gMEM_LAT="$MEM_LAT" -gCYCLE_HIST="$CYCLE_HIST" -gPRELOAD="$PRELOAD" -gSTALL_CYC="$STALL_CYC" -gARM7DBG="$ARM7DBG" -gARM7WATCH="$((ARM7WATCH))" -gARM7RUNAWAY="$ARM7RUNAWAY" \
   -gGPUCEDIV="$GPUCEDIV" -gHEXFILE="$HEXFILE" -gFWFILE="$FWFILE" -gFRAMES="$FRAMES" -gTIMEOUT_MS="$TIMEOUT_MS" \
   -gDUMPFILE="$DUMPFILE" -gDUMPFILE_B="$DUMPFILE_B" -gDUMP_START_FRAME="$DUMP_START_FRAME" -gDIRECT="$DIRECT" -gFWBOOT="$FWBOOT" -gHEARTBEAT_MS="$HEARTBEAT_MS" -gVRAMOPS="$VRAMOPS" -gGPUFAST="$GPUFAST" -gSOUND="$SOUND" -gVRSRV_LAT="$VRSRV_LAT" -gVRSRV_ONE="$VRSRV_ONE" -gVRSRV_OUT="$VRSRV_OUT" -gVRSRV_GAP="$VRSRV_GAP" -gISLAND="$ISLAND" -gISLAND_HALF_PS="$ISLAND_HALF_PS" \
   -gMAXINSTR="$MAXINSTR" -gTRACE_START_FRAME="$TRACE_START_FRAME" -gTRACE7_START_FRAME="$TRACE7_START_FRAME" -gDUMP_STATE="$DUMP_STATE" \
   -gTRACE7_T0="$TRACE7_T0" -gTRACE7_T1="$TRACE7_T1" \
   -gDBG_T0="$DBG_T0" -gDBG_T1="$DBG_T1" -gDBG_TRIGPC="$DBG_TRIGPC" $TRACEGEN
nvc -H "$NVCHEAP" -L "$WORK" --work="$WORK/work" -r tb_top_frame --ieee-warnings=off --exit-severity=failure
