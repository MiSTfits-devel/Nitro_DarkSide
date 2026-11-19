#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Read-only NTR game-card gate for Arm9Soc. sim/tests/hs_arm9_card.S, in a
# raw power-up build and a DIRECT_BOOT build, must store the mailbox that
# sim/tests/hs_arm9_card_oracle.py derives from melonDS's protocol for its
# synthetic image (checked in as hs_arm9_card_{raw,direct}.expected; this
# script fails if the oracle no longer reproduces them), on:
#  (1) the product ARM9 RTL with the product nds_card, timers and nds_irq on
#      its I/O bus (PRODUCT_ORACLE builds: the words before the first
#      slice-only check);
#  (2) the pure Arm9Soc socStep and (3) fresh nds_arm9_soc Verilog under
#      Verilator: every word, the fetched image-address stream (equal to the
#      oracle's, and between (2) and (3)), under image-store backpressure,
#      plus builds that must fault exactly.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-clash-arm9-card.XXXXXX")
trap 'rm -rf "$out"' EXIT
for tool in nvc arm-none-eabi-as arm-none-eabi-objcopy stack verilator python3 cmp; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done
tests="$root/sim/tests"
oracle="$tests/hs_arm9_card_oracle.py"
chip=1fc2

python3 "$oracle" image "$out/card.hex"
for mode in raw direct; do
    python3 "$oracle" expected "$mode" >"$out/$mode.expected"
    cmp "$out/$mode.expected" "$tests/hs_arm9_card_$mode.expected" ||
        { echo "oracle no longer reproduces hs_arm9_card_$mode.expected" >&2; exit 1; }
    python3 "$oracle" romlog "$mode" >"$out/$mode.oracle.romlog"
done

build_rom() {
    local name=$1; shift
    arm-none-eabi-as -EL "$@" -o "$out/$name.o" "$tests/hs_arm9_card.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/$name.o" "$out/$name.bin"
    od -An -v -tx4 "$out/$name.bin" | awk '{for (i=1; i<=NF; i++) print $i}' >"$out/$name.hex"
}
build_rom raw
build_rom direct --defsym DIRECT_BOOT=1
build_rom product-raw --defsym PRODUCT_ORACLE=1
build_rom product-direct --defsym PRODUCT_ORACLE=1 --defsym DIRECT_BOOT=1

# Cases: image, mode, checker arguments. Register faults are link reply
# errors (4) at the register; slice routing faults are 3.
{
    echo "raw raw --rom-log $out/raw.%s.romlog"
    echo "direct direct --rom-log $out/direct.%s.romlog"
    echo "raw raw --no-cart --fault 4 040001a4 --after 2"
} >"$out/cases"
neg() {
    local name=$1 mode=$2; shift 2
    if [[ $mode == direct ]]; then build_rom "$name" --defsym DIRECT_BOOT=1 --defsym "$name=1"
    else build_rom "$name" --defsym "$name=1"; fi
    echo "$name $mode $*" >>"$out/cases"
}
neg NEG_RESET raw --fault 4 040001a4 --after 1
neg NEG_KEY1 raw --fault 4 040001a4
neg NEG_RAW_B7 raw --fault 4 040001a4
neg NEG_UNALIGNED raw --fault 4 040001a4
neg NEG_SPI_MODE raw --fault 4 040001a4
neg NEG_WRITE_DIR raw --fault 4 040001a4
neg NEG_BUSY_WRITE raw --fault 4 040001a4
neg NEG_NOT_READY raw --fault 4 04100010
neg NEG_HALF_DATA raw --fault 4 04100010
neg NEG_CMD_READ raw --fault 4 040001a8
neg NEG_AUXSPIDATA raw --fault 3 040001a2
neg NEG_LDM_DATA raw --fault 3 04100010
neg NEG_DIRECT_9F direct --fault 4 040001a4
neg NEG_DIRECT_UNALIGNED direct --fault 4 040001a4

run_cases() {
    local runner=$1 tag=$2 name mode extra
    while read -r name mode extra; do
        # shellcheck disable=SC2086 # extra is a word list; %s names the model
        "$runner" "$out/$name.hex" "$tests/hs_arm9_card_$mode.expected" "$out/card.hex" "$mode" \
            ${extra//%s/$tag} >"$out/$name.$tag.log" </dev/null ||
            { cat "$out/$name.$tag.log" >&2; echo "FAIL: $name ($tag)" >&2; exit 1; }
        echo "$name${extra:+ [${extra//%s/$tag}]}: $(tail -n 1 "$out/$name.$tag.log")" | sed "s#$out/##g"
    done <"$out/cases"
}

# (1) Product ARM9 RTL with the product game-card slot.
p="$root/third_party/Nitro_DarkSide/d2dabe/rtl"
(cd "$out" &&
 nvc --std=2008 --work=MEM -a "$root/rtl/tb_mem_sync_ram_dual_byte_enable.vhd" &&
 nvc --std=2008 -L . -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" \
     "$p/reggba_timer.vhd" "$p/gba_timer_module.vhd" "$p/gba_timer.vhd" "$p/nds_irq.vhd" \
     "$p/nds_card.vhd" "$p/nds_cpu9.vhd" "$p/nds_cache9.vhd" "$root/rtl/nds_nitro_membus9.vhd" \
     "$root/sim/tb_arm9_isa_oracle.vhd") >"$out/product-build.log" 2>&1 ||
    { cat "$out/product-build.log" >&2; exit 1; }
for b in raw:1 direct:0; do
    mode=${b%%:*}
    words=$(python3 "$oracle" product-words "$mode")
    (cd "$out" && nvc --std=2008 -L . --ieee-warnings=off -e -gROM_FILE="$out/product-$mode.hex" \
        -gEXPECT_FILE="$tests/hs_arm9_card_$mode.expected" -gSCRATCH=48 -gMAILBOX_WORDS="$words" \
        -gIRQ_IO=true -gIO_FULL_RATE=true -gCARD_IO=true -gCARD_FILE="$out/card.hex" \
        -gCARD_FW_BOOT="'${b##*:}'" -gCARD_CHIPID=$((16#$chip)) -gCARD_MASK=$((16#FFFF)) \
        tb_arm9_isa_oracle -r --exit-severity=error tb_arm9_isa_oracle) >"$out/product-$mode.log" 2>&1 ||
        { cat "$out/product-$mode.log" >&2; exit 1; }
    echo "product $mode: $(grep -F 'PASS:' "$out/product-$mode.log" | sed 's/.*PASS:/PASS:/')"
done

# (2) Pure Arm9Soc.
# Every GHC/Clash process and every built checker is capped at a 3 GB heap.
(cd "$root/clash" && stack --resolver lts-22.43 ghc -- +RTS -M3g -RTS -rtsopts -with-rtsopts=-M3g \
    -O1 -isrc -itest -outputdir "$out/ghc" test/Arm9CardCheck.hs -o "$out/card-check")
run_cases "$out/card-check" pure

# (3) Fresh Clash Verilog of nds_arm9_soc.
(cd "$root/clash" && stack exec clash -- +RTS -M3g -RTS --verilog -isrc \
    -fclash-no-escaped-identifiers -outputdir "$out/hdl" src/Nds/WholeCore/Arm9Soc.hs)
topfile=$(find "$out/hdl" -name nds_arm9_soc.v -print)
[[ -n $topfile && $(printf '%s\n' "$topfile" | wc -l | tr -d ' ') = 1 ]] || {
    echo "Expected one freshly generated nds_arm9_soc.v, found: $topfile" >&2; exit 1;
}
sources=()
while IFS= read -r f; do sources+=("$f"); done < <(find "$out/hdl" -name '*.v' -print)
verilator --cc --exe --build -Wno-fatal --top-module nds_arm9_soc \
    -I"$(dirname "$topfile")" --Mdir "$out/obj" "${sources[@]}" "$root/sim/clash_arm9_card.cpp" \
    >"$out/verilator.log" 2>&1 || { cat "$out/verilator.log" >&2; exit 1; }
run_cases "$out/obj/Vnds_arm9_soc" rtl

for mode in raw direct; do
    cmp "$out/$mode.oracle.romlog" "$out/$mode.pure.romlog"
    cmp "$out/$mode.pure.romlog" "$out/$mode.rtl.romlog"
    echo "$mode: $(wc -l <"$out/$mode.pure.romlog" | tr -d ' ') image addresses equal in oracle, pure and RTL"
done
echo "PASS: game-card fixture on product RTL, pure Arm9Soc and generated Verilog"
