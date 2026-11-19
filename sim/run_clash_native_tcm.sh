#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
[[ $# == 1 ]] || { echo "usage: $0 GENERATED_NATIVE_CPU_HDL" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd); v="$1/Nds.WholeCore.DualSoc.dualFirmwareSocTopEntity/nds_dual_soc_firmware.v"; test -f "$v"
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-tcm.XXXXXX"); trap 'rm -rf "$out"' EXIT
pass=(); for cpu in 9 7; do
    base=0xffff0000; if [[ $cpu == 7 ]]; then base=0; arm-none-eabi-as -EL --defsym ARM7=1 -o "$out/$cpu.o" "$root/sim/tests/hs_native_tcm.S"; else arm-none-eabi-as -EL -o "$out/$cpu.o" "$root/sim/tests/hs_native_tcm.S"; fi
    arm-none-eabi-ld -EL -Ttext="$base" -e start -o "$out/$cpu.elf" "$out/$cpu.o"
    arm-none-eabi-objcopy -j .text -O binary "$out/$cpu.elf" "$out/$cpu.bin"
    pass+=("0x$(arm-none-eabi-nm "$out/$cpu.elf" | awk '$3=="passed"{print $1}')")
done
verilator --cc --exe --build -j 1 -Wno-fatal -CFLAGS '-std=c++17 -O1' --top-module nds_dual_soc_firmware --Mdir "$out/obj" -I"$(dirname "$v")" "$v" "$root/sim/clash_native_tcm.cpp" >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
"$out/obj/Vnds_dual_soc_firmware" "$out/9.bin" "$out/7.bin" "${pass[@]}"
