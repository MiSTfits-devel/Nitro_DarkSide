#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ARM9 card-boot gate on Arm9Soc: the boot-ROM loader sim/tests/hs_arm9_boot.S
# copies the ARM9 binary of a synthetic DS image (hs_arm9_boot_oracle.py,
# binary = hs_arm9_boot_payload.S at ROM offset 0x8000) through the game-card
# registers into RAM and branches to it. The launcher handoff is the image's
# own 0x200-byte header placed in the boot ROM at 0xFFFF0E00 (see the loader
# header); nothing else of the image is preloaded.
#
# Pure Arm9Soc and fresh nds_arm9_soc Verilog, with image-store backpressure:
#   direct   card strap CARD_DIRECT_BOOT: CRC16 + fields of the handoff header,
#            B7 load, BX; mailbox, the image addresses fetched and the exact
#            RAM retirement trace come from the oracle; the whole binary must
#            be stored before the first RAM retirement and every RAM
#            instruction must be the word the guest stored there.
#   raw      raw power-up strap: the header read from the card with command
#            00, CRC16 and fields, compared word by word with the handoff;
#            nothing may run from RAM.
#   badcrc / badentry  the loader must reject the header and never run RAM.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-clash-arm9-boot.XXXXXX")
trap 'rm -rf "$out"' EXIT
for tool in arm-none-eabi-as arm-none-eabi-objcopy arm-none-eabi-nm stack verilator python3 cmp; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done
tests="$root/sim/tests"
oracle() { python3 "$tests/hs_arm9_boot_oracle.py" "$@"; }

assemble() {
    local name=$1 source=$2; shift 2
    arm-none-eabi-as -EL "$@" -o "$out/$name.o" "$tests/$source.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/$name.o" "$out/$name.bin"
}
assemble payload hs_arm9_boot_payload
entry=0x$(arm-none-eabi-nm "$out/payload.o" | awk '$3 == "entry" {print $1}')
size=$(printf '%x' $(( ($(wc -c <"$out/payload.bin") + 3) & ~3 )))
assemble loader-direct hs_arm9_boot
assemble loader-raw hs_arm9_boot --defsym RAW_HEADER=1

# Images, boot ROMs (loader + handoff header) and expectations per case.
: >"$out/cases"
for spec in direct:good raw:good direct:badcrc direct:badentry; do
    mode=${spec%%:*} variant=${spec##*:} name=$mode-$variant
    oracle image "$out/payload.bin" "$entry" "$variant" "$out/$name.card.hex"
    oracle bootrom "$out/loader-$mode.bin" "$out/payload.bin" "$entry" "$variant" "$out/$name.boot.hex"
    oracle expected "$mode" "$out/payload.bin" "$entry" "$variant" >"$out/$name.expected"
    case $name in
        direct-good)
            oracle trace "$out/payload.bin" "$entry" >"$out/trace"
            oracle romlog "$out/payload.bin" "$entry" good >"$out/direct.oracle.romlog"
            echo "$name $mode --trace $out/trace --load 02000400 $size --rom-log $out/direct.%s.romlog" >>"$out/cases" ;;
        *)  echo "$name $mode --no-ram-exec" >>"$out/cases" ;;
    esac
done
for mode in direct raw; do
    cmp "$out/$mode-good.expected" "$tests/hs_arm9_boot_$mode.expected" ||
        { echo "oracle no longer reproduces hs_arm9_boot_$mode.expected" >&2; exit 1; }
done

run_cases() {
    local runner=$1 tag=$2 name mode extra
    while read -r name mode extra; do
        # shellcheck disable=SC2086 # extra is a word list; %s names the model
        "$runner" "$out/$name.boot.hex" "$out/$name.expected" "$out/$name.card.hex" "$mode" \
            ${extra//%s/$tag} >"$out/$name.$tag.log" </dev/null ||
            { cat "$out/$name.$tag.log" >&2; echo "FAIL: $name ($tag)" >&2; exit 1; }
        echo "$name ($tag): $(tail -n 1 "$out/$name.$tag.log")"
    done <"$out/cases"
}

(cd "$root/clash" && stack --resolver lts-22.43 ghc -- -O1 -isrc -itest \
    -outputdir "$out/ghc" test/Arm9CardCheck.hs -o "$out/card-check")
run_cases "$out/card-check" pure

(cd "$root/clash" && stack exec clash -- --verilog -isrc \
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

cmp "$out/direct.oracle.romlog" "$out/direct.pure.romlog"
cmp "$out/direct.pure.romlog" "$out/direct.rtl.romlog"
echo "direct: $(wc -l <"$out/direct.pure.romlog" | tr -d ' ') image addresses and $(wc -l <"$out/trace" | tr -d ' ')-entry RAM trace equal in oracle, pure and RTL"
echo "PASS: ARM9 card boot gate on pure Arm9Soc and generated Verilog"
