#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Channel bench for rtl/sdram.sv - the only simulation coverage this file has.
#
#   sim/run_sdram_ch.sh                    # 3x, 100.542 MHz, tRCD 2 clocks
#   CLK_PS=7460 sim/run_sdram_ch.sh        # 4x, 134.056 MHz
#   CLK_PS=7460 TRCD_CK=3 sim/run_sdram_ch.sh   # 4x with the tRCD a faster clock needs
set -eu
cd "$(dirname "$0")/.."

CLK_PS="${CLK_PS:-9946}"
TRCD_CK="${TRCD_CK:-2}"
DQ_PIPE="${DQ_PIPE:-0}"
CAS_LAT="${CAS_LAT:-2}"
TRCD_WAIT="${TRCD_WAIT:-1}"
OUT="${OUT:-/tmp/tb_sdram_ch}"

iverilog -g2012 -s tb_sdram_ch -o "$OUT.vvp" \
  -I sim \
  -DCLK_PS="$CLK_PS" -DTRCD_CK="$TRCD_CK" -DDQ_PIPE="$DQ_PIPE" -DCAS_LAT="$CAS_LAT" -DTRCD_WAIT="$TRCD_WAIT" \
  rtl/sdram.sv sim/sdram_model.sv sim/altddio_out_stub.sv sim/tb_sdram_ch.sv

vvp "$OUT.vvp" | tee "$OUT.log"
grep -q "TB PASS" "$OUT.log"
