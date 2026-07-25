#!/bin/sh
# nds_gpu2d frame tests: engine A end-to-end (registers + drawers + merge +
# channel arbitration + ext-pal shadow) against the gen_gpu2d.py golden
# compositor. Vectors are generated, not checked in - run
# `python3 sim/tests/gen_gpu2d.py` (from sim/tests/) before a DIRTY stream.
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-200}"
BGVRAMFILE="${BGVRAMFILE:-sim/tests/gpu2d_bgvram.hex}"
OBJVRAMFILE="${OBJVRAMFILE:-sim/tests/gpu2d_objvram.hex}"
BGEPFILE="${BGEPFILE:-sim/tests/gpu2d_bgep.hex}"
OBJEPFILE="${OBJEPFILE:-sim/tests/gpu2d_objep.hex}"
PALFILE="${PALFILE:-sim/tests/gpu2d_pal.hex}"
OAMFILE="${OAMFILE:-sim/tests/gpu2d_oam.hex}"
FRAMEFILE="${FRAMEFILE:-sim/tests/gpu2d_frames.hex}"
WORK=sim/nvc_work
mkdir -p "$WORK"

[ -f "$FRAMEFILE" ] || { echo "vectors missing: $FRAMEFILE"; exit 1; }

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/export.vhd \
   rtl/proc_bus_gba.vhd \
   rtl/reg_nds_display.vhd \
   rtl/nds_drawer_text.vhd \
   rtl/nds_drawer_affine.vhd \
   rtl/nds_drawer_extended.vhd \
   rtl/nds_drawer_obj.vhd \
   rtl/nds_drawer_merge.vhd \
   rtl/nds_gpu2d.vhd \
   sim/tb_gpu2d.vhd

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_gpu2d -gTIMEOUT_MS="$TIMEOUT_MS" \
   -gBGVRAMFILE="$BGVRAMFILE" -gOBJVRAMFILE="$OBJVRAMFILE" \
   -gBGEPFILE="$BGEPFILE" -gOBJEPFILE="$OBJEPFILE" \
   -gPALFILE="$PALFILE" -gOAMFILE="$OAMFILE" -gFRAMEFILE="$FRAMEFILE"
nvc -H 2g -L "$WORK" --work="$WORK/work" -r tb_gpu2d --ieee-warnings=off --exit-severity=failure
