#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Thumb, interworking, multiply, SWI and mode fixtures for the Clash ARM9
# slice, each with a hand-derived mailbox (sim/tests/*.expected):
#   sim/tests/hs_arm9_thumb.S      Thumb formats (CPU only);
#   sim/tests/hs_arm9_interwork.S  BX/BLX/loads to PC both ways, exception
#                                  return into Thumb, MUL/MLA/long multiplies,
#                                  CLZ, SWI from ARM and Thumb, System and
#                                  User modes (CPU only);
#   sim/tests/hs_arm9_thumb_irq.S  IRQ entry from Thumb, return to Thumb by
#                                  SUBS and LDM^, an IRQ between the halves
#                                  of a Thumb BL (Arm9Soc with timers);
#   sim/tests/hs_arm9_banks.S      SPSR_svc/SPSR_irq and the three R13/R14
#                                  banks live at once (CPU only).
# Run on (1) the product ARM9 RTL: the Thumb and bank images, the PRODUCT_ORACLE
# interwork image (SPSR_svc primed: the product loads CPSR flags/F from the
# old SPSR on exception entry) and the PRODUCT_ORACLE Thumb IRQ image (first
# 7 words: no harness IRQ source there); (2) the pure Haskell sliceStep /
# socStep and (3) freshly generated Clash Verilog under Verilator: every
# image in full plus the fault builds.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-clash-arm9-thumb.XXXXXX")
trap 'rm -rf "$out"' EXIT
for tool in nvc arm-none-eabi-as arm-none-eabi-objcopy arm-none-eabi-nm stack verilator; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done
tests="$root/sim/tests"

build_rom() {
    local name=$1 source=$2; shift 2
    arm-none-eabi-as -EL "$@" -o "$out/$name.o" "$tests/$source.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/$name.o" "$out/$name.bin"
    od -An -v -tx4 "$out/$name.bin" | awk '{for (i=1; i<=NF; i++) print $i}' >"$out/$name.hex"
}
# Bus address of a symbol: absolute symbols as they are, section symbols
# are ROM offsets.
symbol() {
    arm-none-eabi-nm "$out/$1.o" | awk -v want="$2" '$3 == want {
        v = 0; s = tolower($1)
        for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
        if ($2 != "A" && $2 != "a") v += 4294901760
        printf "%08x\n", v }'
}

# CPU-only cases: image, fixture, checker arguments.
: >"$out/cpu-cases"
faults() {
    local source=$1 prefix=$2 scratch=$3; shift 3
    local spec name site
    for spec in "$@"; do
        name=${spec%%:*}
        build_rom "$prefix$name" "$source" --defsym "$name=1"
        site=$(symbol "$prefix$name" fault_site)
        [[ -n $site ]] || { echo "no fault_site in $prefix$name" >&2; exit 1; }
        echo "$prefix$name $source --scratch $scratch --fault ${spec##*:} $site" >>"$out/cpu-cases"
    done
}
build_rom thumb hs_arm9_thumb
echo "thumb hs_arm9_thumb --scratch 30" >>"$out/cpu-cases"
faults hs_arm9_thumb thumb- 30 NEG_BKPT:1 NEG_UNDEF_COND:1 NEG_HI_LOW:1 NEG_BX_SBZ:1 \
    NEG_BLX_PC:1 NEG_BLX_ODD:1 NEG_LDMIA_EMPTY:1 NEG_STMIA_BASE:1 NEG_V6:1 NEG_POP_ARM_MISALIGNED:2
build_rom interwork hs_arm9_interwork
build_rom interwork-product hs_arm9_interwork --defsym PRODUCT_ORACLE=1
echo "interwork hs_arm9_interwork --scratch 38" >>"$out/cpu-cases"
echo "interwork-product hs_arm9_interwork --scratch 38" >>"$out/cpu-cases"
faults hs_arm9_interwork interwork- 38 NEG_MRS_SPSR_USER:1 NEG_MOVS_PC_USER:1 NEG_MUL_PC:1 \
    NEG_MUL_SBZ:1 NEG_UMULL_SAME:1 NEG_SMLAL_PC:1 NEG_CLZ_PC:1 NEG_LDM_USER_SVC:1
build_rom banks hs_arm9_banks
echo "banks hs_arm9_banks --scratch 30" >>"$out/cpu-cases"

# Arm9Soc case: the harness raises IF bit 1 when the BL prefix retires.
build_rom thumb-irq hs_arm9_thumb_irq
build_rom thumb-irq-product hs_arm9_thumb_irq --defsym PRODUCT_ORACLE=1
bl_prefix=$(symbol thumb-irq bl_prefix)
irq_args="--retire-irq $bl_prefix 2"

run_cpu() {
    local runner=$1 name source extra
    while read -r name source extra; do
        # shellcheck disable=SC2086 # extra is a word list
        "$runner" "$out/$name.hex" "$tests/$source.expected" $extra >"$out/$name.log" </dev/null ||
            { cat "$out/$name.log" >&2; echo "FAIL: $name" >&2; exit 1; }
        echo "$name: $(tail -n 1 "$out/$name.log")"
    done <"$out/cpu-cases"
}
run_irq() {
    # shellcheck disable=SC2086 # irq_args is a word list
    "$1" "$out/thumb-irq.hex" "$tests/hs_arm9_thumb_irq.expected" $irq_args >"$out/thumb-irq.log" </dev/null ||
        { cat "$out/thumb-irq.log" >&2; echo "FAIL: thumb-irq" >&2; exit 1; }
    echo "thumb-irq: $(tail -n 1 "$out/thumb-irq.log")"
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
    local name=$1 source=$2; shift 2
    (cd "$out" && nvc --std=2008 -L . --ieee-warnings=off -e -gROM_FILE="$out/$name.hex" \
        -gEXPECT_FILE="$tests/$source.expected" "$@" \
        tb_arm9_isa_oracle -r --exit-severity=error tb_arm9_isa_oracle) >"$out/product-$name.log" 2>&1 ||
        { cat "$out/product-$name.log" >&2; exit 1; }
    echo "product $name: $(grep -F 'PASS:' "$out/product-$name.log" | sed 's/.*PASS:/PASS:/')"
}
product thumb hs_arm9_thumb -gSCRATCH=48
product interwork-product hs_arm9_interwork -gSCRATCH=56
product banks hs_arm9_banks -gSCRATCH=48
product thumb-irq-product hs_arm9_thumb_irq -gSCRATCH=48 -gMAILBOX_WORDS=7 -gIRQ_IO=true

# (2) Pure Haskell slice and SoC.
# Every GHC/Clash process and every built checker is capped at a 3 GB heap.
(cd "$root/clash" && stack --resolver lts-22.43 ghc -- +RTS -M3g -RTS -rtsopts -with-rtsopts=-M3g \
    -O1 -isrc -itest -outputdir "$out/ghc-isa" test/Arm9IsaCheck.hs -o "$out/isa-check" &&
 stack --resolver lts-22.43 ghc -- +RTS -M3g -RTS -rtsopts -with-rtsopts=-M3g \
    -O1 -isrc -itest -outputdir "$out/ghc-irq" test/Arm9IrqCheck.hs -o "$out/irq-check")
run_cpu "$out/isa-check"
run_irq "$out/irq-check"

# (3) Fresh Clash Verilog, never a checked-in or stale netlist.
verilate() {
    local module=$1 source=$2 host=$3 dir=$4
    (cd "$root/clash" && stack exec clash -- +RTS -M3g -RTS --verilog -isrc \
        -fclash-no-escaped-identifiers -outputdir "$out/$dir-hdl" "src/Nds/WholeCore/$source.hs")
    local topfile
    topfile=$(find "$out/$dir-hdl" -name "$module.v" -print)
    [[ -n $topfile && $(printf '%s\n' "$topfile" | wc -l | tr -d ' ') = 1 ]] || {
        echo "Expected one generated $module.v, found: $topfile" >&2; exit 1;
    }
    local sources=()
    while IFS= read -r f; do sources+=("$f"); done < <(find "$out/$dir-hdl" -name '*.v' -print)
    verilator --cc --exe --build -Wno-fatal --top-module "$module" -I"$(dirname "$topfile")" \
        --Mdir "$out/$dir-obj" "${sources[@]}" "$root/sim/$host" >"$out/$dir-verilator.log" 2>&1 ||
        { cat "$out/$dir-verilator.log" >&2; exit 1; }
}
verilate nds_arm9_slice Arm9Slice clash_arm9_isa.cpp slice
run_cpu "$out/slice-obj/Vnds_arm9_slice"
verilate nds_arm9_soc Arm9Soc clash_arm9_irq.cpp soc
run_irq "$out/soc-obj/Vnds_arm9_soc"
echo "PASS: ARM9 Thumb, interworking, multiply, SWI/mode, register-bank and Thumb IRQ fixtures on product RTL, Haskell and generated Verilog"
