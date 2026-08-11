#!/bin/sh
# Equivalence test: the pipelined affine and extended BG drawers vs the serial
# ones they replaced. Covers what gen_gpu2d_frame.py cannot - notably BG
# MOSAIC, which that model leaves off entirely, plus every screen size,
# wrapping both ways, all three extended variants and rotations steep enough
# to defeat word reuse. See the testbench header.
set -eu
cd "$(dirname "$0")/.."

VLAT="${VLAT:-5}"
WORK=sim/nvc_work_affext_eq
mkdir -p "$WORK"

nvc --work="$WORK/altera_mf" -a --relaxed sim/altera_mf_stub.vhd
nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/nds_drawer_affext.vhd \
   sim/nds_drawer_affine_ref.vhd \
   sim/nds_drawer_extended_ref.vhd \
   sim/tb_drawer_affext_equiv.vhd

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_drawer_affext_equiv -gVLAT="$VLAT"
nvc -H 1g -L "$WORK" --work="$WORK/work" -r tb_drawer_affext_equiv \
   --ieee-warnings=off --exit-severity=failure
