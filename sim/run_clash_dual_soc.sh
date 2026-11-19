#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Two-CPU gate for Nds.WholeCore.DualSoc: ARM9 (ARMv5, 67.03 MHz clock) and
# ARM7 (ARMv4T, ce7 every other cycle) with shared main RAM behind a
# request/response port, each CPU's own IE/IF/IME and timers, IPC, and the
# game card on the ARM9 side.
#
# A synthetic DS image (sim/tests/hs_dual_oracle.py) carries the ARM9 binary
# hs_dual_arm9.S and the ARM7 binary hs_dual_arm7.S. The ARM9 boot ROM
# hs_dual_boot9.S checks the header (handed over at 0xFFFF0E00), copies both
# binaries through the card into main RAM, hands the ARM7 its entry and starts
# it over IPCSYNC (hs_dual_boot7.S at 0); both guests then handshake over
# IPCSYNC, exchange data both ways through the FIFOs under IRQ, hit FIFO full,
# empty and error conditions, and pass buffers through shared RAM. Expected
# mailboxes come from the oracle's own IPC model.
#
# Run on the pure dualStep and on freshly generated nds_dual_soc Verilog under
# Verilator, each with four memory settings (latency 1, and random stalls with
# latency up to 4, 12 and 30 cycles) and random card-image delays; both
# checkers assert the memory protocol and the arbiter's bounded wait. With
# MELONDS_DUAL=<path to melonds_dual> the same binaries also run under melonDS
# (sim/melonds_tracer/main_dual.cpp) and its mailboxes must equal the oracle's.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-clash-dual.XXXXXX")
trap 'rm -rf "$out"' EXIT
for tool in arm-none-eabi-as arm-none-eabi-objcopy arm-none-eabi-nm stack verilator python3; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done
tests="$root/sim/tests"
oracle() { python3 "$tests/hs_dual_oracle.py" "$@"; }
for f in hs_dual_boot9 hs_dual_boot7 hs_dual_arm9 hs_dual_arm7; do
    arm-none-eabi-as -EL -o "$out/$f.o" "$tests/$f.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/$f.o" "$out/$f.bin"
done
entry() { printf '0x%s' "$(arm-none-eabi-nm "$out/$1.o" | awk '$3 == "entry" {print $1}')"; }
e9=$(entry hs_dual_arm9) e7=$(entry hs_dual_arm7)
bins=("$out/hs_dual_arm9.bin" "$e9" "$out/hs_dual_arm7.bin" "$e7")
oracle image "${bins[@]}" "$out/card.hex"
oracle boot9 "$out/hs_dual_boot9.bin" "${bins[@]}" "$out/boot9.hex"
oracle boot7 "$out/hs_dual_boot7.bin" "$out/boot7.hex"
oracle expected 9 "${bins[@]}" >"$out/expect9"
oracle expected 7 "${bins[@]}" >"$out/expect7"
settings=("--latency 1 1" "--latency 1 4 --stall 30 --card-stall 20 --seed 11"
          "--latency 2 12 --stall 50 --card-stall 40 --seed 12" "--latency 8 30 --stall 60 --card-stall 50 --seed 13")

run_all() {
    local runner=$1 tag=$2 k=0 s
    for s in "${settings[@]}"; do
        # shellcheck disable=SC2086 # s is a word list
        "$runner" "$out/boot9.hex" "$out/boot7.hex" "$out/card.hex" "$out/expect9" "$out/expect7" $s \
            >"$out/$tag$k.log" 2>&1 || { tail -n 20 "$out/$tag$k.log" >&2; echo "FAIL: $tag ($s)" >&2; exit 1; }
        echo "$tag $s: $(tail -n 1 "$out/$tag$k.log")"
        k=$((k + 1))
    done
}

# (1) Pure dualStep. Every GHC/Clash process and every checker: 3 GB heap.
(cd "$root/clash" && stack --resolver lts-22.43 ghc -- +RTS -M3g -RTS -rtsopts -with-rtsopts=-M3g \
    -O1 -isrc -itest -outputdir "$out/ghc" test/DualSocCheck.hs -o "$out/dual-check") >"$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; exit 1; }
run_all "$out/dual-check" pure

# (2) Fresh Clash Verilog of nds_dual_soc.
(cd "$root/clash" && GHCRTS=-M3g stack exec clash -- +RTS -M3g -RTS --verilog -isrc \
    -fclash-no-escaped-identifiers -outputdir "$out/hdl" src/Nds/WholeCore/DualSoc.hs) >"$out/clash.log" 2>&1 ||
    { cat "$out/clash.log" >&2; exit 1; }
topfile=$(find "$out/hdl" -name nds_dual_soc.v -print)
[[ -n $topfile && $(printf '%s\n' "$topfile" | wc -l | tr -d ' ') = 1 ]] || {
    echo "Expected one freshly generated nds_dual_soc.v, found: $topfile" >&2; exit 1;
}
verilator --cc --exe --build -Wno-fatal -CFLAGS -O1 --top-module nds_dual_soc \
    -I"$(dirname "$topfile")" --Mdir "$out/obj" "$topfile" "$root/sim/clash_dual_soc.cpp" \
    >"$out/verilator.log" 2>&1 || { cat "$out/verilator.log" >&2; exit 1; }
run_all "$out/obj/Vnds_dual_soc" rtl

# (3) Optional second oracle: the same binaries under melonDS.
if [[ -n ${MELONDS_DUAL:-} ]]; then
    "$MELONDS_DUAL" "$out/hs_dual_boot9.bin" "$out/hs_dual_boot7.bin" \
        "$out/hs_dual_arm9.bin" "$e9" "$out/hs_dual_arm7.bin" "$e7" 600 >"$out/melonds.log"
    python3 - "$out/melonds.log" "$out/expect9" "$out/expect7" <<'EOF'
import sys
got = {}
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) == 3 and p[0] in ("9", "7"):
        got[(p[0], int(p[1]))] = int(p[2], 16)
exp = {c: [int(l.split()[0], 16) for l in open(f) if l.strip()] for c, f in (("9", sys.argv[2]), ("7", sys.argv[3]))}
# The loader's slots 0-5 do not exist under melonDS (no card copy there).
bad = [(c, k) for c, e in exp.items() for k, v in enumerate(e) if not (c == "9" and k < 6) and got.get((c, k)) != v]
if bad:
    sys.exit("melonDS differs from the oracle at %s" % bad)
print("melonDS: ARM9 slots 6..%d and ARM7 slots 0..%d equal the oracle" % (len(exp["9"]) - 1, len(exp["7"]) - 1))
EOF
fi
echo "PASS: two-CPU DualSoc fixture on pure dualStep and generated Verilog"
