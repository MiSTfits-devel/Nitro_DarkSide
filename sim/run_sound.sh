#!/bin/sh
# nds_sound regression: the gate for the fptr/frem BRAM conversion (M9
# ALM endgame, see COORDINATION.md). Not a golden-vector check - there's
# no independent oracle here, so this only proves the tb harness is
# alive (PASS/FAIL on two sanity checks). The real gate is external: run
# this once against nds_sound.vhd before the conversion and once after,
# then diff the two runs' "SAMPLE" report lines - they must match
# exactly. TIMEOUT_MS env extends the watchdog.
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-50}"
WORK=sim/nvc_work
mkdir -p "$WORK"

nvc --work="$WORK/altera_mf" -a --relaxed sim/altera_mf_stub.vhd

nvc -L "$WORK" --work="$WORK/mem" -a --relaxed \
   rtl/SyncRamDualByteEnable.vhd

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/nds_sound.vhd \
   sim/tb_sound.vhd

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_sound -gTIMEOUT_MS="$TIMEOUT_MS"
nvc -H 1g -L "$WORK" --work="$WORK/work" -r tb_sound --ieee-warnings=off --exit-severity=failure
