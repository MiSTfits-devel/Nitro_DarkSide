#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Two real public guest BIOSes, native socket only. No firmware, cartridge or host MMIO.
set -euo pipefail
[[ $# == 1 ]] || { echo "usage: $0 GENERATED_NATIVE_CPU_HDL" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
file="$1/Nds.WholeCore.DualSoc.dualFirmwareSocTopEntity/nds_dual_soc_firmware.v"
test -f "$file"
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-postflag.XXXXXX"); trap 'rm -rf "$out"' EXIT
verilator --cc --exe --build -j 1 -Wno-fatal -CFLAGS -O1 --top-module nds_dual_soc_firmware --Mdir "$out/obj" -I"$(dirname "$file")" "$file" "$root/sim/clash_postflag.cpp" >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
for reject in 0 1 2 3; do
    pass=()
    for cpu in 9 7; do
        flags=(); base=0xffff0000
        if [[ $cpu == 7 ]]; then flags+=(--defsym ARM7=1); base=0; fi
        if [[ $reject != 0 ]]; then flags+=(--defsym REJECT="$reject"); fi
        arm-none-eabi-as -EL "${flags[@]}" -o "$out/$cpu.o" "$root/sim/tests/hs_postflag.S"
        arm-none-eabi-ld -EL -Ttext="$base" -e start -o "$out/$cpu.elf" "$out/$cpu.o"
        arm-none-eabi-objcopy -j .text -O binary "$out/$cpu.elf" "$out/$cpu.bin"
        pass+=("0x$(arm-none-eabi-nm "$out/$cpu.elf" | awk '$3=="passed"{print $1}')")
    done
    "$out/obj/Vnds_dual_soc_firmware" "$out/9.bin" "$out/7.bin" "${pass[@]}" "$reject"
done
