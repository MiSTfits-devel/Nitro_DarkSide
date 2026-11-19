#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run the native CPU socket, NOT a direct handoff or completed firmware boot.
# The optional BIOS pair stays outside the repository and simulator build.
set -euo pipefail
if [[ $# != 1 && ! ( $# == 4 && $2 == --bios-bin ) ]]; then
    echo 'usage: run_clash_native_reset.sh GENERATED_HDL [--bios-bin BIOS9 BIOS7]' >&2; exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd)
umask 077
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-native-reset.XXXXXX")
trap 'rm -rf "$out"' EXIT
file=$(find "$1" -name nds_dual_soc_firmware.v)
test -f "$file" || { echo 'expected one generated native CPU top' >&2; exit 1; }
for cpu in 9 7; do
    flag=(); base=0xffff0000
    if [[ $cpu == 7 ]]; then flag=(--defsym ARM7=1); base=0; fi
    arm-none-eabi-as -EL ${flag[@]+"${flag[@]}"} -o "$out/$cpu.o" "$root/sim/tests/hs_native_reset.S"
    arm-none-eabi-ld -EL -Ttext="$base" -e start -o "$out/$cpu.elf" "$out/$cpu.o"
    arm-none-eabi-objcopy -j .text -O binary "$out/$cpu.elf" "$out/$cpu.bin"
    pass+=("0x$(arm-none-eabi-nm "$out/$cpu.elf" | awk '$3=="passed"{print $1}')")
done
if ! verilator --cc --exe --build -j 1 -Wno-fatal -CFLAGS -O1 --top-module nds_dual_soc_firmware \
    --Mdir "$out/build" -I"$(dirname "$file")" "$file" "$root/sim/clash_native_reset.cpp" >"$out/build.log" 2>&1; then
    cat "$out/build.log" >&2; exit 1
fi
runner=$out/build/Vnds_dual_soc_firmware
"$runner" "$out/9.bin" "$out/7.bin" "${pass[@]}"
if [[ $# == 4 ]]; then
    if [[ -n ${NATIVE_REF_BUILD:-} ]]; then
        b=$NATIVE_REF_BUILD
        src=$(awk -F= '/^MELONDS_DIR:PATH=/{print $2}' "$b/CMakeCache.txt")
        "${CXX:-c++}" -std=c++17 -O1 -I"$src/src" -I"$b/melonds-core/src" \
            "$root/sim/melonds_tracer/main_native_reset_pcs.cpp" \
            "$b/CMakeFiles/melonds_fbdump.dir/Platform.cpp.o" "$b/melonds-core/src/libcore.a" \
            "$b/melonds-core/src/teakra/src/libteakra.a" -o "$out/reference"
        export NATIVE_PC9=$out/pc9 NATIVE_PC7=$out/pc7
        # Some instrumented builds log profile identifiers and MMIO on stderr.
        # Keep both streams private; the child exit status remains mandatory.
        "$out/reference" "$3" "$4" "${NATIVE_FIRMWARE:?private native firmware path required}" "$NATIVE_PC9" "$NATIVE_PC7" >/dev/null 2>&1
    fi
    "$runner" "$3" "$4"
fi
