#!/bin/sh
# Self-checking bench for the DDR3 audio pipe (nds_audio_ddr3 + ddram.sv ch3).
# Run from the repo root. Passes iff "TB PASS".
set -eu

iverilog -g2012 -s tb_audio_ring -o /tmp/tb_audio_ring.vvp \
  rtl/ddram.sv rtl/nds_audio_ddr3.sv sim/tb_audio_ring.sv
vvp /tmp/tb_audio_ring.vvp | tee /tmp/tb_audio_ring.log
grep -q "TB PASS" /tmp/tb_audio_ring.log
