#!/bin/sh
# AXI-3 handshake test for rtl/hps_lw_bridge.sv (the HPS lightweight-bridge slave).
#
# Uses ICARUS VERILOG, not nvc: the bridge is SystemVerilog and nvc is VHDL-only.
# It runs locally in under a second, so it needs no pod - and it is the only way
# to check the AXI handshake without spending a 20-minute Quartus build and a
# hardware session on it.
#
# sim/hps_lw_stub.sv stands in for the Quartus WYSIWYG
# cyclonev_hps_interface_hps2fpga_light_weight, with the port list and widths
# copied from Quartus's own libraries/megafunctions/xml_info entry. If that
# instantiation ever fails to fit or elaborate, check the stub against the XML
# again before touching the slave.
#
# Pass: "LW BRIDGE TB: PASS"
set -eu
cd "$(dirname "$0")/.."
command -v iverilog >/dev/null 2>&1 || { echo "iverilog not found"; exit 1; }
OUT=$(mktemp -d)
iverilog -g2012 -o "$OUT/tb.vvp" \
   sim/hps_lw_stub.sv rtl/hps_lw_bridge.sv sim/tb_hps_lw_bridge.sv
"$OUT/tb.vvp"
rm -rf "$OUT"
