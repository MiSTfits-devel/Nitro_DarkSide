#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Compare the same assembled program and ABI2 device against product RTL.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-clash-arm9.XXXXXX")
trap 'rm -rf "$out"' EXIT
for tool in nvc arm-none-eabi-as arm-none-eabi-objcopy stack python3 verilator "${CC:-cc}"; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done
build_rom() {
    local name=$1; shift
    arm-none-eabi-as -EL "$@" -o "$out/$name.o" "$root/sim/tests/hs_gpu_arm9.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/$name.o" "$out/$name.bin"
    od -An -v -tx4 "$out/$name.bin" | awk '{for (i=1; i<=NF; i++) print $i}' >"$out/$name.hex"
}
build_rom witness
build_rom unsupported --defsym UNSUPPORTED_IO=1
# Build one service library for both the product and generated RTL processes.
export HS_GPU_LIBRARY="$out/gpu.so"
(cd "$root/clash" && stack --resolver lts-22.43 ghc -- -O2 -dynamic -shared -fPIC \
    -flink-rts -threaded -no-hs-main -isrc -itest -outputdir "$out/gpu-ghc" \
    test/GpuService.hs -o "$HS_GPU_LIBRARY")
# The product runner independently assembles the same source, and checks the
# unsupported I/O negative case as well as its six fixed mailbox expectations.
"$root/sim/run_hs_gpu_arm9.sh" >"$out/product.log" 2>&1 || { cat "$out/product.log" >&2; exit 1; }
(cd "$root/clash" && stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    -outputdir "$out/ghc" test/Arm9SliceWitness.hs -o "$out/clash-witness")
"$out/clash-witness" "$out/witness.hex" >"$out/clash.log" || { cat "$out/clash.log" >&2; exit 1; }
python3 "$root/sim/compare_hs_arm9_witness.py" "$out/product.log" "$out/clash.log"
"$out/clash-witness" "$out/unsupported.hex" --unsupported

# Compile from fresh Clash output, never a checked-in or stale netlist.
(cd "$root/clash" && stack exec clash -- --verilog -isrc \
    -fclash-no-escaped-identifiers -outputdir "$out/hdl" src/Nds/WholeCore/Arm9Slice.hs)
topfile=$(find "$out/hdl" -name 'nds_arm9_slice.v' -print)
[[ -n $topfile && $(printf '%s\n' "$topfile" | wc -l | tr -d ' ') = 1 ]] || {
    echo "Expected one generated nds_arm9_slice.v, found: $topfile" >&2; exit 1;
}
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -c "$root/sim/hs_gpu_arm9_bridge.c" -o "$out/bridge.o"
sources=()
while IFS= read -r f; do sources+=("$f"); done < <(find "$out/hdl" -name '*.v' -print)
case $(uname -s) in Darwin) dl= ;; *) dl=" -ldl" ;; esac
verilator --cc --exe --build -Wno-fatal --top-module nds_arm9_slice \
    -I"$(dirname "$topfile")" --Mdir "$out/obj" \
    -LDFLAGS "$out/bridge.o$dl" "${sources[@]}" "$root/sim/clash_arm9_witness.cpp"
"$out/obj/Vnds_arm9_slice" "$out/witness.hex" >"$out/rtl.log" || { cat "$out/rtl.log" >&2; exit 1; }
python3 "$root/sim/compare_hs_arm9_witness.py" "$out/product.log" "$out/rtl.log"
"$out/obj/Vnds_arm9_slice" "$out/unsupported.hex" --unsupported
for scenario in offer write read; do
    "$out/obj/Vnds_arm9_slice" "$out/witness.hex" "--reset-$scenario" >"$out/reset-$scenario.log" || {
        cat "$out/reset-$scenario.log" >&2; exit 1;
    }
    # Only the fresh, coordinated-reset epoch is comparable to the product.
    awk '/^ARM9 RESET COMPLETE$/ { found++; next } found { print } END { if (found != 1) exit 1 }' \
        "$out/reset-$scenario.log" >"$out/reset-$scenario-post.log"
    python3 "$root/sim/compare_hs_arm9_witness.py" "$out/product.log" "$out/reset-$scenario-post.log"
    echo "PASS: generated RTL reset during $scenario"
done
