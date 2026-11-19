#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Generate and exercise the same Clash Verilog used for the MiSTer build.
set -euo pipefail
if [[ $# -gt 1 ]]; then
    echo "usage: $0 [new Quartus project directory]" >&2
    exit 2
fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/hs-pong.XXXXXX")
trap 'rm -rf "$out"' EXIT
(cd "$root/clash" && stack exec clash -- --verilog -isrc \
    -fclash-no-escaped-identifiers -outputdir "$out/hdl" src/Mister/Pong.hs)
netlist="$out/hdl/Mister.Pong.topEntity/hs_pong.v"
if ! verilator --cc --exe --build -CFLAGS -O3 -Wno-fatal --top-module hs_pong \
    --Mdir "$out/obj" "$netlist" "$root/sim/clash_pong.cpp" >"$out/verilator.log" 2>&1; then
    cat "$out/verilator.log" >&2
    exit 1
fi
"$out/obj/Vhs_pong"
# Optional output is a freshly generated, allowlisted Quartus project directory.
if [[ $# == 1 ]]; then
    bash "$root/fpga/mister_hs_pong/stage.sh" "$netlist" "$1"
fi
