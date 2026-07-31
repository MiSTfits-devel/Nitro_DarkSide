#!/bin/sh
# Equivalence test: pipelined text drawer vs the serial one it replaced.
# Covers what gen_gpu2d_frame.py cannot - notably BG MOSAIC, which that model
# leaves off entirely. See the testbench header.
set -eu
cd "$(dirname "$0")/.."

VLAT="${VLAT:-5}"
WORK=sim/nvc_work_eq
mkdir -p "$WORK"

nvc --work="$WORK/altera_mf" -a --relaxed sim/altera_mf_stub.vhd
nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/nds_drawer_text.vhd \
   sim/nds_drawer_text_ref.vhd \
   sim/tb_drawer_text_equiv.vhd

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_drawer_text_equiv -gVLAT="$VLAT"
nvc -H 1g -L "$WORK" --work="$WORK/work" -r tb_drawer_text_equiv \
   --ieee-warnings=off --exit-severity=failure
