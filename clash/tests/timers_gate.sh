#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Gate for Nds.WholeCore.Timers (standalone; not integrated). Stages:
#   1. TimersCheck: directed literals + seeded random against TimersOracle
#   2. fresh Clash Verilog of nds_ds_timers replayed on the oracle's vectors
#   3. shipping rtl/gba_timer.vhd under nvc, compared by TimersCheck --vhdl
#   4. mutants of the DUT must each fail stage 1 (MUTANTS=0 skips)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(cd "$here/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-timers-gate.XXXXXX")
trap 'rm -rf "$out"' EXIT
for tool in stack iverilog vvp nvc; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done
cd "$here"
ghc() { stack --resolver lts-22.43 ghc -- -O1 -Wall -Werror "$@"; }

echo "== TimersCheck"
ghc -isrc -itest -outputdir "$out/ghc" test/TimersCheck.hs -o "$out/timers-check" >/dev/null
"$out/timers-check" --vectors "$out/vectors.txt"

echo "== generated HDL"
stack --resolver lts-22.43 exec clash -- --verilog -isrc -fclash-no-escaped-identifiers \
    -outputdir "$out/clash" -fclash-hdldir "$out/hdl" src/Nds/WholeCore/Timers.hs >/dev/null
iverilog -g2012 -s tb_ds_timers -o "$out/tb.vvp" tests/tb_ds_timers.v \
    "$out/hdl/Nds.WholeCore.Timers.dsTimersTopEntity/nds_ds_timers.v"
vvp -n "$out/tb.vvp" +vectors="$out/vectors.txt" | tee "$out/tb.log"
grep -q '^PASS tb_ds_timers' "$out/tb.log"

echo "== shipping VHDL witness"
mkdir -p "$out/nvc"
(cd "$out/nvc" && nvc --std=2008 -a "$root/rtl/proc_bus_gba.vhd" "$root/rtl/reg_savestates.vhd" \
    "$root/rtl/reggba_timer.vhd" "$root/rtl/gba_timer_module.vhd" "$root/rtl/gba_timer.vhd" \
    "$here/tests/tb_gba_timer_witness.vhd" -e tb_gba_timer_witness -r >"$out/vhdl.log" 2>"$out/vhdl.err") \
    || { cat "$out/vhdl.err" >&2; exit 1; }
"$out/timers-check" --vhdl "$out/vhdl.log"

[ "${MUTANTS:-1}" = 0 ] && { echo "PASS timers gate (mutants skipped)"; exit 0; }
echo "== mutants"
mutants=(
    'IRQ enable sampled before the write|(control t) 6) ticked ovf|(control t) 6) ts ovf'
    'fraction kept on cascade overflow|frac = if cascade then 0 else|frac = if False then 0 else'
    'fraction dropped on prescaled overflow|else truncateB total .&. 0x3ff|else 0'
    'timer 0 cascades|cascade = n /= 0 && testBit ctl 2|cascade = testBit ctl 2'
    'CNT read mask 0xff|.&. 0xc7|.&. 0xff'
    'start loads the old reload|unpack (reload'"'"' ++# 0)|unpack (reload t ++# 0)'
    'start 1->1 reloads|not (testBit (control t) 7) && testBit control'"'"' 7|testBit control'"'"' 7'
    'F/64 steps 32|1 -> 16|1 -> 32'
    'stopped timer passes carry|not (testBit ctl 7) = (False,|not (testBit ctl 7) = (carry,'
    'tick before write|zip indicesI written|zip indicesI ts'
)
src=$(<src/Nds/WholeCore/Timers.hs)
for m in "${mutants[@]}"; do
    IFS='|' read -r name from to <<<"$m"
    dir="$out/mut/$(printf '%s' "$name" | tr -c 'a-z0-9' '_')"
    mkdir -p "$dir/Nds/WholeCore"
    mutated=${src/"$from"/"$to"}
    [ "$mutated" != "$src" ] || { echo "mutant '$name': pattern not found" >&2; exit 1; }
    printf '%s\n' "$mutated" >"$dir/Nds/WholeCore/Timers.hs"
    # GHC takes the first -i match, so the mutant shadows src/.
    stack --resolver lts-22.43 ghc -- -O1 -i"$dir" -isrc -itest -outputdir "$dir/ghc" \
        test/TimersCheck.hs -o "$dir/check" >"$dir/build.log" 2>&1 \
        || { cat "$dir/build.log" >&2; echo "mutant '$name' does not build" >&2; exit 1; }
    if "$dir/check" >"$dir/run.log" 2>&1; then
        echo "mutant survived: $name" >&2; exit 1
    fi
    echo "killed: $name ($(grep -c '^FAIL' "$dir/run.log") failing checks)"
done
echo "PASS timers gate"
