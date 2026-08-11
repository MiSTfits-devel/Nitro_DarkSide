#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Equivalence gate for the mosaic-Y counter rewrite in nds_gpu2d.vhd: the
# 4-bit counter against the `linecounter mod (size + 1)` divider it replaced,
# over every line of a frame x every one of the 16 mosaic sizes, on both the BG
# and the OBJ path.
#
# Self-contained (no RTL dependencies) and runs in seconds. See the testbench
# header for what it does and does not prove - notably, the mid-frame MOSAIC
# write behaviour is DELIBERATELY different and is not checked here.
set -eu
cd "$(dirname "$0")/.."

WORK="${WORK:-sim/nvc_work_mosaic_eq}"
mkdir -p "$WORK"

nvc -L "$WORK" --work="$WORK/work" -a --relaxed sim/tb_mosaic_equiv.vhd
nvc -L "$WORK" --work="$WORK/work" -e tb_mosaic_equiv
nvc -L "$WORK" --work="$WORK/work" -r tb_mosaic_equiv --exit-severity=failure
