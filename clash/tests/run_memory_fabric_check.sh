#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# No BIOS, ROM, state captures, board access, or existing HDL required.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-fabric.XXXXXX")
trap 'rm -rf "$out"' EXIT
# Match the existing native melonDS gate. Outside an existing build tree,
# compile the pinned library and the ordinary headless Platform callbacks.
ref=${BUILD_DIR:-$root/sim/melonds_tracer/build-vendored}
if [[ ! -f "$ref/build.ninja" ]]; then ref=$out/reference; fi
cmake -S "$root/sim/melonds_tracer" -B "$ref" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DMELONDS_DIR="$root/third_party/melonDS" >/dev/null
cmake --build "$ref" --target nds_gx2d_bg_oracle -j2 >/dev/null
cd "$root/clash"
GHCRTS=-M3g stack exec clash -- +RTS -M6g -RTS --verilog -isrc -fclash-no-escaped-identifiers \
    -outputdir "$out/obj" -fclash-hdldir "$out/hdl" test/MemoryFabricTop.hs
cd "$root"
iverilog -g2012 -s sdram_session_reset -I sim -o "$out/session_reset" \
    rtl/nds_clash_sdram.sv rtl/sdram.sv sim/sdram_model.sv sim/altddio_out_stub.sv \
    clash/tests/sdram_session_reset.sv
vvp "$out/session_reset"
verilator --cc --exe --build -j 2 -Wno-fatal --top-module memory_fabric_gate -I"$root/sim" --Mdir "$out/vobj" \
    -CFLAGS "-std=c++17 -fwrapv -I$root/third_party/melonDS/src -I$ref/melonds-core/src" \
    -LDFLAGS "$ref/CMakeFiles/nds_gx2d_bg_oracle.dir/Platform.cpp.o $ref/melonds-core/src/libcore.a $ref/melonds-core/src/teakra/src/libteakra.a" \
    "$out"/hdl/*/*.v rtl/nds_clash_sdram.sv rtl/sdram.sv sim/sdram_model.sv sim/altddio_out_stub.sv \
    clash/tests/memory_fabric_gate.sv "$root/clash/tests/memory_fabric_cosim.cpp" >"$out/build.log" 2>&1 || { tail -80 "$out/build.log"; exit 1; }
verilator --cc --exe --build -j 2 -Wno-fatal --top-module memory_channel_gate -I"$root/sim" --Mdir "$out/channel" \
    rtl/sdram.sv sim/sdram_model.sv sim/altddio_out_stub.sv clash/tests/memory_channel_gate.sv \
    "$root/clash/tests/memory_channel_cosim.cpp" >"$out/channel.log" 2>&1 || { tail -80 "$out/channel.log"; exit 1; }
run_checker(){ (if [[ $(uname -s) == Linux ]]; then ulimit -v 3145728; fi; exec "$1"); }
run_checker "$out/vobj/Vmemory_fabric_gate" | tee "$out/fabric.results"
run_checker "$out/channel/Vmemory_channel_gate" | tee "$out/channel.results"
diff <(grep '^paired-hash ' "$out/fabric.results" | sort) <(grep '^paired-hash ' "$out/channel.results" | sort -u)
