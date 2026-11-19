#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CPU-only fixtures for the ARM7 (ARMv4T) build of the Clash CPU slice
# (Nds.WholeCore.Arm7Slice: arm7Arch, boot ROM and vectors at 0), each with
# a hand-derived mailbox (sim/tests/*.expected):
#   sim/tests/hs_arm7_v4t.S    vectors at 0, SWI from ARM and Thumb, loads to
#                              PC that keep the state (LDR pc, LDM {pc},
#                              Thumb POP {pc}), BX, Thumb BL and MOV pc;
#   sim/tests/hs_arm9_mem.S    addressing modes, LDM/STM, stack, loads to PC
#                              (built with --defsym ROM=0);
#   sim/tests/hs_arm9_banks.S  both SPSRs and all three R13/R14 banks.
# Run on (1) the product ARM7 (gba_cpu + nds_membus7 in
# sim/tb_arm7_isa_oracle.vhd), (2) the pure Haskell core (Arm9IsaCheck
# --arm7) and (3) freshly generated nds_arm7_slice Verilog under Verilator;
# (2) and (3) also run five builds that must fault 1 at an ARMv5-only
# instruction (BLX register and immediate, CLZ, Thumb BLX register and the
# Thumb BLX suffix).
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-clash-arm7-isa.XXXXXX")
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
# The image is linked at 0: absolute and section symbols are both addresses.
fault_site() {
    arm-none-eabi-nm "$out/$1.o" | awk '$3 == "fault_site" { print $1 }'
}

: >"$out/cases"
build_rom v4t hs_arm7_v4t
echo "v4t hs_arm7_v4t --scratch 30" >>"$out/cases"
build_rom mem hs_arm9_mem --defsym ROM=0
echo "mem hs_arm9_mem --scratch 30" >>"$out/cases"
build_rom banks hs_arm9_banks
echo "banks hs_arm9_banks --scratch 30" >>"$out/cases"
for name in NEG_BLX_REG NEG_BLX_IMM NEG_CLZ NEG_THUMB_BLX_REG NEG_THUMB_BLX_SUFFIX; do
    build_rom "v4t-$name" hs_arm7_v4t --defsym "$name=1"
    site=$(fault_site "v4t-$name")
    [[ -n $site ]] || { echo "no fault_site in $name" >&2; exit 1; }
    echo "v4t-$name hs_arm7_v4t --scratch 30 --fault 1 $site" >>"$out/cases"
done
# Link offers: the ARM7 link carries the IPC spans (mem fixture variants).
for spec in OFFER_IPCSYNC:W:2:04000180:0000005a OFFER_IPCRECV:R:4:04100000:00000000 \
        OFFER_TIMER:W:2:04000102:0000005a OFFER_IE:R:4:04000210:00000000; do
    IFS=: read -r name kind width addr data <<<"$spec"
    build_rom "mem-$name" hs_arm9_mem --defsym ROM=0 --defsym "$name=1"
    echo "mem-$name hs_arm9_mem --scratch 30 --offer $kind $width $addr $data" >>"$out/cases"
done
# ARM9-only spans have no route on the ARM7: the same probes fault 3.
for spec in OFFER_DISPSTAT:04000004 OFFER_REG_WRITEBACK:06800010 OFFER_OAM:07000000; do
    name=${spec%%:*}
    build_rom "mem-$name" hs_arm9_mem --defsym ROM=0 --defsym "$name=1"
    echo "mem-$name hs_arm9_mem --scratch 30 --fault 3 ${spec#*:}" >>"$out/cases"
done
# Generated ARMv4T-specific programs: expectations from the generator's own
# model of the v4T rules (sim/tests/hs_arm7_v4t_gen.py). Each seed's first
# case separates ARMv4T from ARMv5, so the ARM9 build must fail every one.
seeds=${GEN_SEEDS:-40}
for seed in $(seq 1 "$seeds"); do
    python3 "$tests/hs_arm7_v4t_gen.py" "$seed" "$out/gen$seed.S" "$out/gen$seed.expected"
    arm-none-eabi-as -EL -o "$out/gen$seed.o" "$out/gen$seed.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/gen$seed.o" "$out/gen$seed.bin"
    od -An -v -tx4 "$out/gen$seed.bin" | awk '{for (i=1; i<=NF; i++) print $i}' >"$out/gen$seed.hex"
done

run_cases() {
    local runner=$1 name source extra expect seed
    while read -r name source extra; do
        # shellcheck disable=SC2086 # extra is a word list
        "$runner" "$out/$name.hex" "$tests/$source.expected" "${@:2}" $extra >"$out/$name.log" </dev/null ||
            { cat "$out/$name.log" >&2; echo "FAIL: $name" >&2; exit 1; }
        echo "$name: $(tail -n 1 "$out/$name.log")"
    done <"$out/cases"
    for seed in $(seq 1 "$seeds"); do
        expect="$out/gen$seed.expected"
        "$runner" "$out/gen$seed.hex" "$expect" "${@:2}" --scratch 30 >"$out/gen$seed.log" </dev/null ||
            { cat "$out/gen$seed.log" >&2; echo "FAIL: generated seed $seed" >&2; exit 1; }
    done
    echo "generated: $seeds ARMv4T programs pass"
}

# (1) Product ARM7 RTL oracle.
p="$root/third_party/Nitro_DarkSide/d2dabe/rtl"
(cd "$out" &&
 nvc --std=2008 -L . -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" \
     "$p/reggba_timer.vhd" "$p/gba_timer_module.vhd" "$p/gba_timer.vhd" "$p/nds_irq.vhd" \
     "$p/gba_cpu.vhd" "$p/nds_membus7.vhd" "$root/sim/tb_arm7_isa_oracle.vhd") >"$out/product-build.log" 2>&1 ||
    { cat "$out/product-build.log" >&2; exit 1; }
product() {
    local name=$1 expect=$2
    (cd "$out" && nvc --std=2008 -L . --ieee-warnings=off -e -gROM_FILE="$out/$name.hex" \
        -gEXPECT_FILE="$expect" -gSCRATCH=48 \
        tb_arm7_isa_oracle -r --exit-severity=error tb_arm7_isa_oracle) >"$out/product-$name.log" 2>&1 ||
        { cat "$out/product-$name.log" >&2; echo "FAIL: product $name" >&2; exit 1; }
}
for name in v4t:hs_arm7_v4t mem:hs_arm9_mem banks:hs_arm9_banks; do
    product "${name%%:*}" "$tests/${name#*:}.expected"
    echo "product ${name%%:*}: $(grep -F 'PASS:' "$out/product-${name%%:*}.log" | sed 's/.*PASS:/PASS:/')"
done
for seed in $(seq 1 "$seeds"); do product "gen$seed" "$out/gen$seed.expected"; done
echo "product generated: $seeds ARMv4T programs pass"

# (2) Pure Haskell core, ARM7 build; the ARM9 (ARMv5) build must fail every
# generated program.
# Every GHC/Clash process and every built checker is capped at a 3 GB heap.
(cd "$root/clash" && stack --resolver lts-22.43 ghc -- +RTS -M3g -RTS -rtsopts -with-rtsopts=-M3g \
    -O1 -isrc -itest -outputdir "$out/ghc" test/Arm9IsaCheck.hs -o "$out/isa-check")
run_arm7() { "$out/isa-check" "$1" "$2" --arm7 "${@:3}"; }
run_cases run_arm7
for seed in $(seq 1 "$seeds"); do
    if "$out/isa-check" "$out/gen$seed.hex" "$out/gen$seed.expected" --scratch 30 >/dev/null 2>&1; then
        echo "FAIL: generated seed $seed passes on the ARMv5 build: it does not separate v4T from v5" >&2; exit 1
    fi
done
echo "generated: the ARMv5 build fails all $seeds"

# (3) Fresh Clash Verilog of nds_arm7_slice, never a checked-in netlist.
(cd "$root/clash" && GHCRTS=-M3g stack exec clash -- +RTS -M3g -RTS --verilog -isrc \
    -fclash-no-escaped-identifiers -outputdir "$out/hdl" src/Nds/WholeCore/Arm7Slice.hs)
topfile=$(find "$out/hdl" -name 'nds_arm7_slice.v' -print)
[[ -n $topfile && $(printf '%s\n' "$topfile" | wc -l | tr -d ' ') = 1 ]] || {
    echo "Expected one generated nds_arm7_slice.v, found: $topfile" >&2; exit 1;
}
verilator --cc --exe --build -Wno-fatal --top-module nds_arm7_slice -CFLAGS -DARM7_SLICE \
    -I"$(dirname "$topfile")" --Mdir "$out/obj" "$topfile" "$root/sim/clash_arm9_isa.cpp" >"$out/verilator.log" 2>&1 ||
    { cat "$out/verilator.log" >&2; exit 1; }
run_cases "$out/obj/Vnds_arm7_slice"
echo "PASS: ARM7 (ARMv4T) fixtures on product gba_cpu, the pure ARM7 core and generated Verilog"
