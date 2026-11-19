#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
[[ $# == 1 ]] || { echo "usage: $0 GENERATED_NATIVE_CPU_HDL" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
v="$1/Nds.WholeCore.DualSoc.dualFirmwareSocTopEntity/nds_dual_soc_firmware.v"
test -f "$v"
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-alignment.XXXXXX"); trap 'rm -rf "$out"' EXIT
arm-none-eabi-as -EL -o "$out/9.o" "$root/sim/tests/hs_native_alignment.S"
arm-none-eabi-ld -EL -Ttext=0xffff0000 -e start -o "$out/9.elf" "$out/9.o"
arm-none-eabi-objcopy -j .text -O binary "$out/9.elf" "$out/9.bin"
pass=$(arm-none-eabi-nm "$out/9.elf" | awk '$3=="passed"{print $1}')
verilator --cc --exe --build -j 1 -Wno-fatal -CFLAGS '-std=c++17 -O1' --top-module nds_dual_soc_firmware --Mdir "$out/obj" -I"$(dirname "$v")" "$v" "$root/sim/clash_native_alignment.cpp" >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
"$out/obj/Vnds_dual_soc_firmware" "$out/9.bin" "0x$pass"
