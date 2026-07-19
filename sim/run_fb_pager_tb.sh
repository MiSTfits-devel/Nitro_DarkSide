#!/bin/sh
# Self-checking bench for the DDR3 framebuffer path (nds_fb_ddr3 + the
# ddram.sv burst channels). Run from the repo root. Passes iff "TB PASS".
set -eu

iverilog -g2012 -s tb_fb_pager -o /tmp/tb_fb_pager.vvp \
  rtl/ddram.sv rtl/nds_fb_ddr3.sv sim/tb_fb_pager.sv
vvp /tmp/tb_fb_pager.vvp | tee /tmp/tb_fb_pager.log
grep -q "TB PASS" /tmp/tb_fb_pager.log
