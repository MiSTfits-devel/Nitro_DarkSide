#!/bin/sh
# Focused synchronous-tag lookup/maintenance overlap regression.
set -eu
cd "$(dirname "$0")/.."

WORK=sim/nvc_work_cache9_lookup
mkdir -p "$WORK"

nvc --work="$WORK/altera_mf" -a --relaxed sim/altera_mf_stub.vhd
nvc -L "$WORK" --work="$WORK/mem" -a --relaxed rtl/SyncRamDualByteEnable.vhd
nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/nds_cache9.vhd \
   sim/tb_cache9_lookup.vhd
nvc -H 256m -L "$WORK" --work="$WORK/work" -e tb_cache9_lookup
nvc -H 256m -L "$WORK" --work="$WORK/work" -r tb_cache9_lookup \
   --ieee-warnings=off --exit-severity=failure
