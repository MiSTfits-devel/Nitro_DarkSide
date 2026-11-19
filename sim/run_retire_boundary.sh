#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Use one supplied, already-generated HDL snapshot. Never synthesizes Clash.
set -euo pipefail
[[ $# == 1 && -d $1 ]] || { echo "usage: $0 GENERATED_HDL_DIRECTORY" >&2; exit 2; }
hdl=$(cd "$1" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
# GHC/Clash are not invoked. Darwin does not support RLIMIT_AS for native
# children; on systems that do, cap the compiler and checker at 3 GiB.
if [[ $(uname -s) != Darwin ]]; then
    ulimit -v $((3 * 1024 * 1024))
fi
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-retire-boundary.XXXXXX")
trap 'rm -rf "$out"' EXIT
for tool in arm-none-eabi-as arm-none-eabi-objcopy arm-none-eabi-nm verilator; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done
for mode in BOOT9 BOOT7 ARM9 ARM7; do
    arm-none-eabi-as -EL --defsym "$mode=1" -o "$out/$mode.o" "$root/sim/tests/hs_retire_boundary.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/$mode.o" "$out/$mode.bin"
done
pcs=()
for symbol in preirq pred_read branch wrong_read recv1 recv2 recv3 done; do
    value=$(arm-none-eabi-nm "$out/ARM9.o" | awk -v s="$symbol" '$3==s {print $1}')
    [[ -n $value ]] || { echo "Missing symbol $symbol" >&2; exit 1; }
    pcs+=("$((0x02001000 + 16#$value))")
done
for variant in wide buffered; do
    top=nds_dual_soc_$variant
    file=$(find "$hdl" -name "$top.v" -print)
    [[ -n $file && $(printf '%s\n' "$file" | wc -l | tr -d ' ') == 1 ]] || { echo "Expected exactly one $top.v in snapshot" >&2; exit 1; }
    echo "== $variant: $(shasum -a 256 "$file") =="
    flags=-O1
    [[ $variant != buffered ]] || flags+=' -DFETCH_BUFFER'
    if ! verilator --cc --exe --build -j 1 -Wno-fatal -CFLAGS "$flags" --top-module "$top" \
        -I"$(dirname "$file")" --Mdir "$out/$variant" "$file" "$root/sim/clash_retire_boundary.cpp" >"$out/build.log" 2>&1; then
        cat "$out/build.log" >&2; exit 1
    fi
    for slow in 0 1; do
        echo "-- slow=$slow --"
        "$out/$variant/V$top" "$out/BOOT9.bin" "$out/BOOT7.bin" "$out/ARM9.bin" "$out/ARM7.bin" "${pcs[@]}" "$slow"
    done
done
