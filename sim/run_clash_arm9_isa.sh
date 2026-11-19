#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CPU-only ARM-state fixtures for the Clash ARM9 slice:
#   sim/tests/hs_arm9_isa.S  conditions, flags, data processing, branches;
#   sim/tests/hs_arm9_mem.S  addressing modes, LDM/STM, stack, loads to PC.
# Each must produce its hand-derived mailbox (sim/tests/*.expected) on
# (1) the product ARM9 RTL, (2) the pure Haskell sliceStep and (3) freshly
# generated Clash Verilog under Verilator. The product runs the
# PRODUCT_ORACLE ISA image (one skipped MOVS it mishandles removed) and the
# default memory image; (2) and (3) run those images, the full ISA image and
# every fault and link-offer variant. Variants do not run on the product:
# it implements LDRD/LDRT/SWP and its bus is not this link. Thumb, MUL and
# interworking loads to PC are covered by sim/run_clash_arm9_thumb.sh.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-clash-arm9-isa.XXXXXX")
trap 'rm -rf "$out"' EXIT
for tool in nvc arm-none-eabi-as arm-none-eabi-objcopy arm-none-eabi-nm stack verilator; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done
tests="$root/sim/tests"
mem_scratch=30   # hs_arm9_mem.S scratch starts at RAM word 0x30 (0x020000c0)

build_rom() {
    local name=$1 source=$2; shift 2
    arm-none-eabi-as -EL "$@" -o "$out/$name.o" "$tests/$source.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/$name.o" "$out/$name.bin"
    od -An -v -tx4 "$out/$name.bin" | awk '{for (i=1; i<=NF; i++) print $i}' >"$out/$name.hex"
}
# Absolute symbols are bus addresses; section symbols are ROM offsets.
fault_site() {
    arm-none-eabi-nm "$out/$1.o" | awk '$3 == "fault_site" {
        v = 0; s = tolower($1)
        for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
        if ($2 != "A" && $2 != "a") v += 4294901760
        printf "%08x\n", v }'
}

# One case per line: image name, fixture, then checker arguments.
: >"$out/cases"
add_case() { echo "$*" >>"$out/cases"; }
faults() {
    local source=$1 prefix=$2; shift 2
    local spec name site
    for spec in "$@"; do
        name=${spec%%:*}
        build_rom "$prefix$name" "$source" --defsym "$name=1"
        site=$(fault_site "$prefix$name")
        [[ -n $site ]] || { echo "no fault_site in $prefix$name" >&2; exit 1; }
        add_case "$prefix$name" "$source" ${extra[@]+"${extra[@]}"} --fault "${spec##*:}" "$site"
    done
}
offer() {
    local source=$1 name=$2; shift 2
    build_rom "$name" "$source" --defsym "$name=1"
    add_case "$name" "$source" ${extra[@]+"${extra[@]}"} --offer "$@"
}

build_rom isa hs_arm9_isa
build_rom isa-product hs_arm9_isa --defsym PRODUCT_ORACLE=1
add_case isa hs_arm9_isa
add_case isa-product hs_arm9_isa
extra=()
faults hs_arm9_isa isa- NEG_NV:1 NEG_MISALIGNED_PC:2 NEG_UNIMPLEMENTED:1 NEG_VCOUNT_WRITE:3
offer hs_arm9_isa OFFER_DISPCNT W 4 04000000 0000005a
offer hs_arm9_isa OFFER_VCOUNT R 2 04000006 00000000

build_rom mem hs_arm9_mem
add_case mem hs_arm9_mem --scratch "$mem_scratch"
extra=(--scratch "$mem_scratch")
faults hs_arm9_mem mem- NEG_WB_RD:1 NEG_WB_PC:1 NEG_RM_PC:1 NEG_WB_RM_RN:1 NEG_LDRT:1 \
    NEG_LDRD:1 NEG_HALF_SBZ:1 NEG_HALF_POST_WB:1 NEG_LDRB_PC:1 NEG_STR_PC:1 \
    NEG_LDM_WB_BASE:1 NEG_STM_WB_BASE:1 NEG_STM_PC:1 NEG_LDM_EMPTY:1 NEG_LDM_USER:1 \
    NEG_LDM_PC_BASE:1 NEG_BLOCK_MISALIGNED:2 \
    NEG_BLOCK_PAST_RAM:3 NEG_BLOCK_LINK_STORE:3 NEG_BLOCK_LINK_LOAD:3 NEG_BLOCK_ROM_STORE:3
offer hs_arm9_mem OFFER_POST_INDEX R 2 04000000 00000000
offer hs_arm9_mem OFFER_REG_WRITEBACK W 4 06800010 0000005a
offer hs_arm9_mem OFFER_TIMER W 2 04000102 0000005a
offer hs_arm9_mem OFFER_IE R 4 04000210 00000000
offer hs_arm9_mem OFFER_DISPSTAT W 2 04000004 0000005a

run_cases() {
    local runner=$1 name source extra
    while read -r name source extra; do
        # shellcheck disable=SC2086 # extra is a word list
        "$runner" "$out/$name.hex" "$tests/$source.expected" $extra >"$out/$name.log" </dev/null ||
            { cat "$out/$name.log" >&2; echo "FAIL: $name" >&2; exit 1; }
        echo "$name: $(tail -n 1 "$out/$name.log")"
    done <"$out/cases"
}

# (1) Product ARM9 RTL oracle.
p="$root/third_party/Nitro_DarkSide/d2dabe/rtl"
(cd "$out" &&
 nvc --std=2008 --work=MEM -a "$root/rtl/tb_mem_sync_ram_dual_byte_enable.vhd" &&
 nvc --std=2008 -L . -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" \
     "$p/reggba_timer.vhd" "$p/gba_timer_module.vhd" "$p/gba_timer.vhd" "$p/nds_irq.vhd" \
     "$p/nds_card.vhd" "$p/nds_cpu9.vhd" "$p/nds_cache9.vhd" "$root/rtl/nds_nitro_membus9.vhd" \
     "$root/sim/tb_arm9_isa_oracle.vhd") >"$out/product-build.log" 2>&1 ||
    { cat "$out/product-build.log" >&2; exit 1; }
product() {
    local name=$1 source=$2 scratch=$3
    (cd "$out" && nvc --std=2008 -L . --ieee-warnings=off -e -gROM_FILE="$out/$name.hex" \
        -gEXPECT_FILE="$tests/$source.expected" -gSCRATCH="$scratch" \
        tb_arm9_isa_oracle -r --exit-severity=error tb_arm9_isa_oracle) >"$out/product-$name.log" 2>&1 ||
        { cat "$out/product-$name.log" >&2; exit 1; }
    echo "product $name: $(grep -F 'PASS:' "$out/product-$name.log" | sed 's/.*PASS:/PASS:/')"
}
product isa-product hs_arm9_isa 64
product mem hs_arm9_mem $((16#$mem_scratch))

# (2) Pure Haskell transition function.
# Every GHC/Clash process and every built checker is capped at a 3 GB heap.
(cd "$root/clash" && stack --resolver lts-22.43 ghc -- +RTS -M3g -RTS -rtsopts -with-rtsopts=-M3g \
    -O1 -isrc -itest -outputdir "$out/ghc" test/Arm9IsaCheck.hs -o "$out/isa-check")
run_cases "$out/isa-check"

# (3) Fresh Clash Verilog, never a checked-in or stale netlist.
(cd "$root/clash" && stack exec clash -- +RTS -M3g -RTS --verilog -isrc \
    -fclash-no-escaped-identifiers -outputdir "$out/hdl" src/Nds/WholeCore/Arm9Slice.hs)
topfile=$(find "$out/hdl" -name 'nds_arm9_slice.v' -print)
[[ -n $topfile && $(printf '%s\n' "$topfile" | wc -l | tr -d ' ') = 1 ]] || {
    echo "Expected one generated nds_arm9_slice.v, found: $topfile" >&2; exit 1;
}
sources=()
while IFS= read -r f; do sources+=("$f"); done < <(find "$out/hdl" -name '*.v' -print)
verilator --cc --exe --build -Wno-fatal --top-module nds_arm9_slice \
    -I"$(dirname "$topfile")" --Mdir "$out/obj" "${sources[@]}" "$root/sim/clash_arm9_isa.cpp" >"$out/verilator.log" 2>&1 ||
    { cat "$out/verilator.log" >&2; exit 1; }
run_cases "$out/obj/Vnds_arm9_slice"
echo "PASS: ARM9 ISA and memory fixtures on product RTL, Haskell and generated Verilog"
