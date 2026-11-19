#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CPU + VRAM display prototype gate. One assembled ARM program runs on:
#  1. the pure ARM9 slice + pure VramDisplay model, and the pure slice + the
#     authoritative ABI2 GPU service (GfxSliceCheck): equal ordered GPU
#     transactions/replies/stores, and the service's rendered top LCD equals
#     the model's colour on every pixel;
#  2. freshly generated Clash Verilog of the whole SoC under Verilator: the
#     same event log, and the captured VGA frame (2x2 per LCD pixel) equals
#     the service's frame.
# Negative programs must stop with the same GPU reply fault in both.
# Optional: EVIDENCE_DIR=<dir> keeps logs/frames; a single argument stages a
# new MiSTer Quartus project from the exact tested netlist and ROM image.
set -euo pipefail
if [[ $# -gt 1 ]]; then
    echo "usage: $0 [new Quartus project directory]" >&2
    exit 2
fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-gfx-soc.XXXXXX")
trap 'rm -rf "$out"' EXIT
for tool in arm-none-eabi-as arm-none-eabi-objcopy stack verilator cmp; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done

build_rom() {
    local name=$1 source=$2; shift 2
    arm-none-eabi-as -EL "$@" -o "$out/$name.o" "$source"
    arm-none-eabi-objcopy -j .text -O binary "$out/$name.o" "$out/$name.bin"
    od -An -v -tx4 "$out/$name.bin" | awk '{for (i=1; i<=NF; i++) print $i}' >"$out/$name.hex"
}
gfx=$root/sim/tests/hs_gfx_arm9.S
build_rom gfx "$gfx"
build_rom witness "$root/sim/tests/hs_gpu_arm9.S"
build_rom bad-mode "$gfx" --defsym UNSUPPORTED_MODE=1
build_rom bad-bank "$gfx" --defsym UNSUPPORTED_BANK=1
build_rom bad-status "$gfx" --defsym UNSUPPORTED_STATUS=1
# name:expected CPU fault code:fault address (all GPU reply errors)
negatives=(bad-mode:4:04000000 bad-bank:4:04000242 bad-status:4:04000006)

# Every GHC/Clash process and every built checker is capped at a 3 GB heap.
(cd "$root/clash" && stack --resolver lts-22.43 ghc -- +RTS -M3g -RTS -rtsopts -with-rtsopts=-M3g \
    -O2 -isrc -itest -outputdir "$out/ghc" test/GfxSliceCheck.hs -o "$out/gfx-slice-check")
for name in gfx witness; do
    mkdir "$out/$name"
    "$out/gfx-slice-check" "$out/$name.hex" "$out/$name"
done
for spec in "${negatives[@]}"; do
    IFS=: read -r name code addr <<<"$spec"
    mkdir "$out/$name"
    "$out/gfx-slice-check" "$out/$name.hex" "$out/$name" --expect-fault "$code" "$addr"
done

# Compile from fresh Clash output, never a checked-in or stale netlist.
# VramDisplay's lanes $readmemb "nds_vram_zero.bin" (all-zero power-up
# contents, see vramZeroFile); Clash reads it from its working directory and
# copies it beside the netlist, which is where the RTL host and stage use it.
awk 'BEGIN { for (i = 0; i < 32768; i++) print "0000000000000000" }' >"$out/nds_vram_zero.bin"
(cd "$out" && STACK_YAML="$root/clash/stack.yaml" stack exec clash -- +RTS -M3g -RTS --verilog \
    -i"$root/clash/src" -fclash-no-escaped-identifiers -outputdir "$out/hdl" \
    "$root/clash/src/Nds/WholeCore/GfxSoc.hs")
hdl="$out/hdl/Nds.WholeCore.GfxSoc.gfxSocTopEntity"
netlist="$hdl/nds_gfx_soc.v"
[[ -s $netlist ]] || { echo "Expected generated $netlist" >&2; exit 1; }
cmp "$out/nds_vram_zero.bin" "$hdl/nds_vram_zero.bin"
[[ $(grep -c 'readmemb("nds_vram_zero.bin"' "$netlist") == 4 ]] || {
    echo "Expected four VRAM lanes initialised from nds_vram_zero.bin" >&2; exit 1;
}
if ! verilator --cc --exe --build -CFLAGS -O2 -Wno-fatal --top-module nds_gfx_soc \
    --Mdir "$out/obj" "$netlist" "$root/sim/clash_gfx_soc.cpp" >"$out/verilator.log" 2>&1; then
    cat "$out/verilator.log" >&2
    exit 1
fi
rtl() { (cd "$hdl" && "$out/obj/Vnds_gfx_soc" "$@"); }
for name in gfx witness; do
    rtl "$out/$name.hex" "$out/$name"
    cmp "$out/$name/model.log" "$out/$name/rtl.log"
    cmp "$out/$name/frame.hex" "$out/$name/rtl-frame.hex"
    echo "PASS: generated RTL ($name): $(grep -c '^[RW]' "$out/$name/rtl.log") GPU transactions and 49152 LCD pixels equal the service"
done
for spec in "${negatives[@]}"; do
    IFS=: read -r name _ _ <<<"$spec"
    rtl "$out/$name.hex" "$out/$name" --expect-fault
    cmp "$out/$name/model.log" "$out/$name/rtl.log"
    echo "PASS: generated RTL ($name): $(tail -n 1 "$out/$name/rtl.log")"
done
# The power-up contents really come from the file: with a 0x5555 pattern the
# witness's read of a never-written VRAM halfword must change accordingly.
mkdir -p "$out/pattern/witness"
awk 'BEGIN { for (i = 0; i < 32768; i++) print "0101010101010101" }' >"$out/pattern/nds_vram_zero.bin"
(cd "$out/pattern" && "$out/obj/Vnds_gfx_soc" "$out/witness.hex" "$out/pattern/witness") >/dev/null
grep -qx 'R4 06000000 a5265555' "$out/pattern/witness/rtl.log" || {
    echo "FAIL: VRAM power-up contents do not come from nds_vram_zero.bin" >&2; exit 1;
}
echo "PASS: generated RTL loads VRAM power-up contents from nds_vram_zero.bin"

if [[ -n ${EVIDENCE_DIR:-} ]]; then
    mkdir -p "$EVIDENCE_DIR"
    cp "$out/gfx.hex" "$EVIDENCE_DIR/hs_gfx_arm9.hex"
    for name in gfx witness "${negatives[@]%%:*}"; do
        mkdir -p "$EVIDENCE_DIR/$name"
        cp "$out/$name"/* "$EVIDENCE_DIR/$name/"
    done
    rm -rf "$EVIDENCE_DIR/hdl"
    cp -R "$hdl" "$EVIDENCE_DIR/hdl"
    if command -v sips >/dev/null; then
        sips -s format png "$EVIDENCE_DIR/gfx/frame.ppm" --out "$EVIDENCE_DIR/gfx/frame.png" >/dev/null
        sips -s format png "$EVIDENCE_DIR/gfx/vga.ppm" --out "$EVIDENCE_DIR/gfx/vga.png" >/dev/null
    fi
    echo "Evidence kept in $EVIDENCE_DIR"
fi
if [[ $# == 1 ]]; then
    bash "$root/fpga/mister_hs_gfx_slice/stage.sh" "$netlist" "$out/gfx.hex" "$1"
fi
