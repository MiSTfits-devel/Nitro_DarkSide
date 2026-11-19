#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Nds.WholeCore.Ipc against the product IPC block (nds_ipc.vhd): seeded random
# register-operation sequences from both CPUs (sim/tests/hs_ipc_ops.py) run on
# the product under nvc (sim/tb_ipc_product.vhd) and on the Clash block
# (clash/test/IpcOpsCheck.hs); the per-operation logs (read data, ARM9 and
# ARM7 IRQ bits raised) must be identical. The generator steers clear of the
# four documented behaviours where the product differs from GBATEK, which the
# Clash block follows (see the generator's header).
# Env: SEEDS (default 40), OPS (operations per seed before filtering, 1500).
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-clash-ipc.XXXXXX")
trap 'rm -rf "$out"' EXIT
for tool in nvc python3 stack cmp; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done
p="$root/third_party/Nitro_DarkSide/d2dabe/rtl"
(cd "$out" && nvc --std=2008 -L . -a "$p/proc_bus_gba.vhd" "$p/nds_ipc.vhd" "$root/sim/tb_ipc_product.vhd") \
    >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
# Every GHC process and the built checker are capped at a 3 GB heap.
(cd "$root/clash" && stack --resolver lts-22.43 ghc -- +RTS -M3g -RTS -rtsopts -with-rtsopts=-M3g \
    -O1 -isrc -itest -outputdir "$out/ghc" test/IpcOpsCheck.hs -o "$out/ipc-ops") >>"$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; exit 1; }
seeds=${SEEDS:-40}
total=0
for seed in $(seq 1 "$seeds"); do
    python3 "$root/sim/tests/hs_ipc_ops.py" "$seed" "${OPS:-1500}" "$out/ops$seed.txt"
    (cd "$out" && nvc --std=2008 -L . --ieee-warnings=off -e -gOPS_FILE="$out/ops$seed.txt" \
        -gLOG_FILE="$out/product$seed.log" tb_ipc_product -r tb_ipc_product) >"$out/nvc$seed.log" 2>&1 ||
        { cat "$out/nvc$seed.log" >&2; exit 1; }
    "$out/ipc-ops" "$out/ops$seed.txt" >"$out/clash$seed.log"
    cmp "$out/product$seed.log" "$out/clash$seed.log" ||
        { diff "$out/product$seed.log" "$out/clash$seed.log" | head -n 20 >&2; echo "FAIL: seed $seed" >&2; exit 1; }
    total=$((total + $(wc -l <"$out/ops$seed.txt")))
done
irqs=$(cat "$out"/clash*.log | awk '$3 != "00000000" || $4 != "00000000"' | wc -l | tr -d ' ')
echo "PASS: Clash IPC equals the product nds_ipc on $seeds sequences, $total operations ($irqs raising IRQs)"
