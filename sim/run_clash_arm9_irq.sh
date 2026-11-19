#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ARM9 IRQ exception fixture (sim/tests/hs_arm9_irq.S) with hand-derived
# mailbox sim/tests/hs_arm9_irq.expected, on:
#  (1) the product ARM9 RTL with the product timers and IME/IE/IF on its I/O
#      bus (PRODUCT_ORACLE build, first 34 words: banking, masking, timer
#      IRQs, both return forms);
#  (2) the pure Arm9Soc socStep and (3) freshly generated nds_arm9_soc under
#      Verilator: all 48 words, including the exact entry point after an
#      MSR, CPSR.F on entry and IRQs raised while a link read or an STM is in
#      flight, plus fault builds for IRQ/PSR forms outside the subset.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-clash-arm9-irq.XXXXXX")
trap 'rm -rf "$out"' EXIT
for tool in nvc arm-none-eabi-as arm-none-eabi-objcopy arm-none-eabi-nm stack verilator; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done
source_file="$root/sim/tests/hs_arm9_irq.S"
expected="$root/sim/tests/hs_arm9_irq.expected"

build_rom() {
    local name=$1; shift
    arm-none-eabi-as -EL "$@" -o "$out/$name.o" "$source_file"
    arm-none-eabi-objcopy -j .text -O binary "$out/$name.o" "$out/$name.bin"
    od -An -v -tx4 "$out/$name.bin" | awk '{for (i=1; i<=NF; i++) print $i}' >"$out/$name.hex"
}
fault_site() {
    arm-none-eabi-nm "$out/$1.o" | awk '$3 == "fault_site" {
        v = 0; s = tolower($1)
        for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
        if ($2 != "A" && $2 != "a") v += 4294901760
        printf "%08x\n", v }'
}

build_rom irq
build_rom product --defsym PRODUCT_ORACLE=1
# External IF sources this fixture needs: the link read (bit 0) and the
# first STM beat at 0x020000e0 (bit 1).
sources="--link-read --store-irq 020000e0 2"
echo "irq $sources" >"$out/cases"
for name in NEG_SUBS_SYSTEM NEG_MRS_SPSR_SYSTEM NEG_MSR_FIQ NEG_MSR_THUMB NEG_MSR_Q \
        NEG_MSR_NO_FIELDS NEG_LDM_USER_IRQ NEG_STM_USER_IRQ NEG_SPSR_FIQ; do
    build_rom "$name" --defsym "$name=1"
    site=$(fault_site "$name")
    [[ -n $site ]] || { echo "no fault_site in $name" >&2; exit 1; }
    echo "$name $sources --fault 1 $site" >>"$out/cases"
done

run_cases() {
    local runner=$1 name extra
    while read -r name extra; do
        # shellcheck disable=SC2086 # extra is a word list
        "$runner" "$out/$name.hex" "$expected" $extra >"$out/$name.log" </dev/null ||
            { cat "$out/$name.log" >&2; echo "FAIL: $name" >&2; exit 1; }
        echo "$name: $(tail -n 1 "$out/$name.log")"
    done <"$out/cases"
}

# (1) Product ARM9 RTL with product timers and IRQ registers.
p="$root/third_party/Nitro_DarkSide/d2dabe/rtl"
(cd "$out" &&
 nvc --std=2008 --work=MEM -a "$root/rtl/tb_mem_sync_ram_dual_byte_enable.vhd" &&
 nvc --std=2008 -L . -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" \
     "$p/reggba_timer.vhd" "$p/gba_timer_module.vhd" "$p/gba_timer.vhd" "$p/nds_irq.vhd" \
     "$p/nds_card.vhd" "$p/nds_cpu9.vhd" "$p/nds_cache9.vhd" "$root/rtl/nds_nitro_membus9.vhd" \
     "$root/sim/tb_arm9_isa_oracle.vhd" &&
 nvc --std=2008 -L . --ieee-warnings=off -e -gROM_FILE="$out/product.hex" -gEXPECT_FILE="$expected" \
     -gSCRATCH=48 -gMAILBOX_WORDS=34 -gIRQ_IO=true \
     tb_arm9_isa_oracle -r --exit-severity=error tb_arm9_isa_oracle) >"$out/product.log" 2>&1 ||
    { cat "$out/product.log" >&2; exit 1; }
echo "product: $(grep -F 'PASS:' "$out/product.log" | sed 's/.*PASS:/PASS:/')"

# (2) Pure Arm9Soc.
# Every GHC/Clash process and every built checker is capped at a 3 GB heap.
(cd "$root/clash" && stack --resolver lts-22.43 ghc -- +RTS -M3g -RTS -rtsopts -with-rtsopts=-M3g \
    -O1 -isrc -itest -outputdir "$out/ghc" test/Arm9IrqCheck.hs -o "$out/irq-check")
run_cases "$out/irq-check"

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
    -I"$(dirname "$topfile")" --Mdir "$out/obj" "${sources[@]}" "$root/sim/clash_arm9_irq.cpp" \
    >"$out/verilator.log" 2>&1 || { cat "$out/verilator.log" >&2; exit 1; }
run_cases "$out/obj/Vnds_arm9_soc"
echo "PASS: ARM9 IRQ fixture on product RTL (34 words), pure Arm9Soc and generated Verilog (48 words)"
