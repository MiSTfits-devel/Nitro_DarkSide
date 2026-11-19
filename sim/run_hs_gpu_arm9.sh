#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-hs-arm9.XXXXXX")
trap 'rm -rf "$out"' EXIT

for tool in nvc arm-none-eabi-as arm-none-eabi-objcopy "${CC:-cc}"; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done

if [[ -n ${HS_GPU_LIBRARY:-} ]]; then
    # Resolve relative to the caller before entering the simulation directory.
    HS_GPU_LIBRARY=$(cd "$(dirname "$HS_GPU_LIBRARY")" && pwd)/$(basename "$HS_GPU_LIBRARY")
else
    HS_GPU_LIBRARY="$out/gpu.so"
    (cd "$root/clash" && stack --resolver lts-22.43 ghc -- -O2 -dynamic -shared -fPIC \
        -flink-rts -threaded -no-hs-main -isrc -itest -outputdir "$out/ghc" \
        test/GpuService.hs -o "$HS_GPU_LIBRARY")
fi
export HS_GPU_LIBRARY

build_rom() {
    local name=$1; shift
    arm-none-eabi-as -EL "$@" -o "$out/$name.o" "$root/sim/tests/hs_gpu_arm9.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/$name.o" "$out/$name.bin"
    # The GPU ABI requires a little-endian host. Read words, not byte columns.
    od -An -v -tx4 "$out/$name.bin" | awk '{for (i=1; i<=NF; i++) print $i}' >"$out/$name.hex"
}
build_rom witness
build_rom unsupported --defsym UNSUPPORTED_IO=1

case $(uname -s) in
    Darwin) dl=() ;;
    *) dl=(-ldl) ;;
esac
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -shared -fPIC \
    "$root/sim/hs_gpu_arm9_bridge.c" -o "$out/bridge.so" ${dl[@]+"${dl[@]}"}

# Use the exact CPU, cache and product-local membus sources from the MiSTer QIP.
# The portable MEM entity is the existing host shim for the cache's dormant
# hardware-only RAM branch; the cache uses its own is_simu model here.
cd "$out"
p="$root/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 --work=MEM -a "$root/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
nvc --std=2008 -L . -a \
    "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" \
    "$p/nds_cpu9.vhd" "$p/nds_cache9.vhd" "$root/rtl/nds_nitro_membus9.vhd" \
    "$root/sim/tb_hs_gpu_arm9.vhd"
run_rom() {
    nvc --std=2008 -L . --load="$out/bridge.so" --ieee-warnings=off \
        -e -gROM_FILE="$out/$1.hex" tb_hs_gpu_arm9 \
        -r --exit-severity=error tb_hs_gpu_arm9
}
run_rom witness
if run_rom unsupported >"$out/unsupported.log" 2>&1; then
    cat "$out/unsupported.log" >&2
    echo "Unsupported ARM9 bus access did not stop the bridge" >&2
    exit 1
fi
if ! grep -F 'ARM9 Haskell bridge: unsupported ARM9 I/O 04000247/1' "$out/unsupported.log"; then
    cat "$out/unsupported.log" >&2
    exit 1
fi
echo 'PASS: real ARM9 WRAMCNT load fails closed'
