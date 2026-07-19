#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo"

CYCLES=${CYCLES:-50000}
SEED=${SEED:-0x1badf00d}

iverilog -g2012 -s tb_video_mixer_diff -o /tmp/tb_video_mixer_diff.vvp \
  -Ptb_video_mixer_diff.CYCLES="$CYCLES" \
  -Ptb_video_mixer_diff.SEED="$SEED" \
  clash/rtl/nds_clash_video_mixer_core.sv \
  clash/tests/rtl/video_mixer_reference.sv \
  clash/tests/tb_video_mixer_diff.sv
vvp /tmp/tb_video_mixer_diff.vvp
