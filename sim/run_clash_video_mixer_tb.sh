#!/bin/sh
set -eu

iverilog -g2012 -s tb_clash_video_mixer -o /tmp/tb_clash_video_mixer.vvp \
  clash/rtl/nds_clash_video_mixer_core.sv sim/tb_clash_video_mixer.sv
vvp /tmp/tb_clash_video_mixer.vvp
