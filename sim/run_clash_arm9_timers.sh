#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Assembled ARM program against both the pure composition and fresh Clash RTL.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-arm9-timers.XXXXXX")
trap 'rm -rf "$out"' EXIT
for tool in arm-none-eabi-as arm-none-eabi-objcopy stack verilator; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done
arm-none-eabi-as -EL -o "$out/rom.o" "$root/sim/tests/hs_arm9_timers.S"
arm-none-eabi-objcopy -j .text -O binary "$out/rom.o" "$out/rom.bin"
od -An -v -tx4 "$out/rom.bin" | awk '{for (i=1; i<=NF; i++) print $i}' >"$out/rom.hex"
# Every GHC/Clash process and every built checker is capped at a 3 GB heap.
(cd "$root/clash" && stack --resolver lts-22.43 ghc -- +RTS -M3g -RTS -rtsopts -with-rtsopts=-M3g \
    -O1 -isrc -itest -outputdir "$out/ghc" test/Arm9TimerIntegrationCheck.hs -o "$out/check")
"$out/check" "$out/rom.hex" "$root/sim/tests/hs_arm9_timers.expected"
(cd "$root/clash" && stack exec clash -- +RTS -M3g -RTS --verilog -isrc \
    -fclash-no-escaped-identifiers -outputdir "$out/hdl" src/Nds/WholeCore/Arm9Soc.hs)
topfile=$(find "$out/hdl" -name nds_arm9_soc.v -print)
[[ -n $topfile && $(printf '%s\n' "$topfile" | wc -l | tr -d ' ') = 1 ]] || {
    echo "Expected one freshly generated nds_arm9_soc.v" >&2; exit 1;
}
sources=()
while IFS= read -r f; do sources+=("$f"); done < <(find "$out/hdl" -name '*.v' -print)
if ! verilator --cc --exe --build -Wno-fatal --top-module nds_arm9_soc \
    -I"$(dirname "$topfile")" --Mdir "$out/obj" "${sources[@]}" \
    "$root/sim/clash_arm9_timers.cpp" >"$out/verilator.log" 2>&1; then
    cat "$out/verilator.log" >&2; exit 1
fi
"$out/obj/Vnds_arm9_soc" "$out/rom.hex" "$root/sim/tests/hs_arm9_timers.expected"
