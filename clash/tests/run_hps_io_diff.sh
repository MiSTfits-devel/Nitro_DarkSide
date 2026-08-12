#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo"

SEED=${SEED:-0x1badf00d}

iverilog -g2012 -s tb_hps_io_diff -o /tmp/tb_hps_io_diff.vvp \
  -Ptb_hps_io_diff.SEED="$SEED" \
  clash/tests/rtl/hps_io_oracle.sv \
  sys/math.sv \
  clash/rtl/nds_hps_io.sv \
  clash/tests/tb_hps_io_diff.sv
vvp /tmp/tb_hps_io_diff.vvp
