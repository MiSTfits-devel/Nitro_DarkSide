#!/bin/sh
# Torture test for nds_mainram (dual guest channels + arbiter) against a
# behavioral SDRAM controller model.
# OPCOUNT=100000 SEED=3 sim/run_mainram_tb.sh for soaks.
set -eu
cd "$(dirname "$0")/.."

OPCOUNT="${OPCOUNT:-10000}"
SEED="${SEED:-1}"
WORK=sim/nvc_work
mkdir -p "$WORK"

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/nds_mainram.vhd \
   sim/tb_mainram.vhd

# -H: the 4 MB reference arrays are ~32 MB each as sim objects
nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_mainram -gOPCOUNT="$OPCOUNT" -gSEED="$SEED"
nvc -H 1g -L "$WORK" --work="$WORK/work" -r tb_mainram --ieee-warnings=off --exit-severity=failure
