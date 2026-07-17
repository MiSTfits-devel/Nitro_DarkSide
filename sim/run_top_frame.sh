#!/bin/sh
# M5 exit test: boot a .nds image through nds_top and dump engine-A frames.
#   sim/run_top_frame.sh [image.hex]     (default sim/tests/nds_dual.hex)
# Env: FRAMES (default 3), TIMEOUT_MS (default 100), DUMPFILE.
# Heavy (full dual-CPU system + render path) - run on the sim pod, not the laptop.
set -eu
cd "$(dirname "$0")/.."

HEXFILE="${1:-${HEXFILE:-sim/tests/nds_dual.hex}}"
FRAMES="${FRAMES:-3}"
TIMEOUT_MS="${TIMEOUT_MS:-400}"
DUMPFILE="${DUMPFILE:-top_frame_fb.txt}"
DUMPFILE_B="${DUMPFILE_B:-top_frame_fb_b.txt}"
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
   rtl/nds_top.vhd \
   sim/tb_top_frame.vhd

nvc -H 2g -L "$WORK" --work="$WORK/work" -e tb_top_frame \
   -gHEXFILE="$HEXFILE" -gFRAMES="$FRAMES" -gTIMEOUT_MS="$TIMEOUT_MS" \
   -gDUMPFILE="$DUMPFILE" -gDUMPFILE_B="$DUMPFILE_B"
nvc -H 2g -L "$WORK" --work="$WORK/work" -r tb_top_frame --ieee-warnings=off --exit-severity=failure
