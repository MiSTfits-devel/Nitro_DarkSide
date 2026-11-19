#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# No board, firmware dump, BIOS or stock-ROM files required.
set -euo pipefail
[[ $# -le 1 ]] || { echo "usage: $0 [GENERATED_NATIVE_CPU_HDL]" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-systemspi.XXXXXX")
trap 'rm -rf "$out"' EXIT
hdl=${SPI_HDL:-$out/hdl}
if [[ -z ${SPI_HDL:-} ]]; then
    (cd "$root/clash" && GHCRTS='-M850m -N1' stack exec clash -- +RTS -M850m -N1 -RTS --verilog -isrc -fclash-no-escaped-identifiers -outputdir "$hdl" test/SystemSpiTop.hs)
fi
v="$hdl/SystemSpiTop.topEntity/nds_system_spi.v"
verilator -Wno-fatal --cc --exe --build -j 1 -CFLAGS -std=c++17 --top-module nds_system_spi --Mdir "$out/obj" -I"$(dirname "$v")" "$v" "$root/sim/clash_system_spi.cpp" >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
"$out/obj/Vnds_system_spi"
if [[ $# == 1 ]]; then
    cpu="$1/Nds.WholeCore.DualSoc.dualFirmwareSocTopEntity/nds_dual_soc_firmware.v"
    test -f "$cpu"
    arm-none-eabi-as -EL -mcpu=arm7tdmi -o "$out/7.o" "$root/sim/tests/hs_system_spi_guest.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/7.o" "$out/7.bin"
    python3 - "$out/7.bin" "$out/7.hex" <<'PY'
import struct, sys
from pathlib import Path
code = Path(sys.argv[1]).read_bytes()
assert len(code) <= 16384 and len(code) % 4 == 0
code += struct.pack('<I', 0xe7f000f0) * ((16384-len(code))//4)
Path(sys.argv[2]).write_text(''.join(f'{w:08x}\n' for w, in struct.iter_unpack('<I',code)))
PY
    verilator --binary --timing -j 1 -Wno-fatal -Wno-PINMISSING -CFLAGS -O1 --top-module tb_clash_system_spi_guest \
      --Mdir "$out/guest" -I"$(dirname "$cpu")" -I"$(dirname "$v")" "$cpu" "$v" "$root/rtl/nds_firmware_cache.sv" "$root/sim/tb_clash_system_spi_guest.sv" \
      >"$out/guest.log" 2>&1 || { cat "$out/guest.log" >&2; exit 1; }
    "$out/guest/Vtb_clash_system_spi_guest" "+ROM=$out/7.hex"
fi
