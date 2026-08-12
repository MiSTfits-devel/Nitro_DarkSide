#!/bin/sh
# Contract test for the source-owned sigma-delta DAC. Measures DC transfer
# linearity, monotonicity and idle noise, and benchmarks the GPL module through
# the identical measurement. Not a bit-exact diff - see tb_sigma_delta.sv.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo"

iverilog -g2012 -s tb_sigma_delta -o /tmp/tb_sigma_delta.vvp \
  clash/rtl/nds_sigma_delta_dac.v \
  sys/sigma_delta_dac.v \
  clash/tests/tb_sigma_delta.sv
vvp /tmp/tb_sigma_delta.vvp
