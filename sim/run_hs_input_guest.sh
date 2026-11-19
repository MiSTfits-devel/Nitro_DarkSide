#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Input cone of a project produced by fpga/mister_hs_nds/stage.py. Works
# with stock or staged Clash FIO/UIO. No BIOS dump, controller or board.
set -euo pipefail
[[ $# == 1 ]] || { echo "usage: $0 STAGED_PROJECT" >&2;exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd);s=$(cd "$1" && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-guest-input.XXXXXX");trap 'rm -rf "$out"' EXIT
for cpu in 7 9; do
    target=arm7tdmi;len=16384;args=()
    if [[ $cpu == 9 ]]; then target=arm946e-s;len=4096;args=(--defsym ARM9=1);fi
    arm-none-eabi-as -EL -mcpu="$target" ${args[@]+"${args[@]}"} -o "$out/$cpu.o" "$root/sim/tests/hs_input_guest.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/$cpu.o" "$out/$cpu.bin"
    python3 - "$out/$cpu.bin" "$len" >"$out/$cpu.hex" <<'PY'
import struct,sys
from pathlib import Path
b=Path(sys.argv[1]).read_bytes();size=int(sys.argv[2]);assert len(b)<=size and len(b)%4==0
for (half,) in struct.iter_unpack('<H',b+struct.pack('<I',0xe7f000f0)*((size-len(b))//4)):print(f'{half:04x}')
PY
done
# Stock's constant-disabled PS2DIV serial branches assign implicit nets;
# retain the unmodified release file. Do not waive this for our own RTL.
printf '`verilator_config\nlint_off -rule PROCASSWIRE -file "%s"\n' "$s/sys/hps_io.sv" >"$out/release.vlt"
verilator --binary --timing -j 2 -Wno-fatal -Wno-PINMISSING --top-module tb_hs_input_guest --Mdir "$out/v" \
    "$out/release.vlt" -y "$s/hdl" -y "$s/rtl" -y "$s/sys" "$s/sys/hps_io.sv" "$root/sim/tb_hs_input_guest.sv" >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2;exit 1; }
"$out/v/Vtb_hs_input_guest" "+rom7=$out/7.hex" "+rom9=$out/9.hex"
