#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo"

CYCLES=${CYCLES:-2500000}
SEED=${SEED:-0x1badf00d}

iverilog -g2012 -s tb_video_freak_diff -o /tmp/tb_video_freak_diff.vvp \
  -Ptb_video_freak_diff.CYCLES="$CYCLES" \
  -Ptb_video_freak_diff.SEED="$SEED" \
  clash/rtl/nds_video_freak.sv \
  clash/tests/rtl/video_freak_port_oracle.sv \
  clash/tests/tb_video_freak_diff.sv
vvp /tmp/tb_video_freak_diff.vvp
