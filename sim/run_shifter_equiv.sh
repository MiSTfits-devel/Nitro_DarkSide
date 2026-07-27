#!/bin/sh
# Exhaustive equivalence check for the nds_cpu9 barrel-shifter rewrite.
# Self-contained (no RTL dependencies) and runs in seconds.
set -eu
cd "$(dirname "$0")/.."

WORK="${WORK:-sim/nvc_work}"
mkdir -p "$WORK"

nvc -L "$WORK" --work="$WORK/work" -a --relaxed sim/tb_shifter_equiv.vhd
nvc -L "$WORK" --work="$WORK/work" -e tb_shifter_equiv
nvc -L "$WORK" --work="$WORK/work" -r tb_shifter_equiv --exit-severity=failure
