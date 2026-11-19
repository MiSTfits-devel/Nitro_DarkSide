#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# With no arguments, only a redistributable assembled fixture is used. For
# local verification pass --postfirmware-nds PATH or --postfirmware-hex PATH
# (a private Kirby image already prepared for post-firmware handoff). No ROM,
# BIOS, keys, opcodes, or traces are distributed. MELONDS_TRACE may name the
# patched melonds_fbdump executable with TRACE9/TRACE7 support.
set -euo pipefail
if [[ $# != 0 && ! ( $# == 2 && ( $1 == --postfirmware-hex || $1 == --postfirmware-nds ) ) ]]; then
    echo "usage: $0 [--postfirmware-{hex,nds} LOCAL_KIRBY]" >&2; exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd)
umask 077
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-direct.XXXXXX")
trap 'rm -rf "$out"' EXIT
tests=$root/sim/tests
# Independent of the software-program test below: these drive a delayed
# fill, invalidate and response on every relevant ordering edge.
(cd "$root/clash" && GHCRTS=-M512m stack ghc -- -O1 -isrc -outputdir "$out/line-obj" \
    -o "$out/line-check" test/FetchLineCheck.hs +RTS -M512m -RTS) >"$out/line.log" 2>&1 || { cat "$out/line.log" >&2; exit 1; }
"$out/line-check"
(cd "$root/clash" && GHCRTS=-M512m stack ghc -- -O1 -isrc -outputdir "$out/mpu-obj" \
    -o "$out/mpu-check" test/Arm9MpuCheck.hs +RTS -M512m -RTS) >"$out/mpu.log" 2>&1 || { cat "$out/mpu.log" >&2; exit 1; }
"$out/mpu-check"
assemble() {
    arm-none-eabi-as -EL -o "$out/tmp.o" "${@:3}" "$tests/$2.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/tmp.o" "$out/$1.bin"
}
assemble stock9 hs_dual_boot9; assemble stock7 hs_dual_boot7
for side in 9 7; do
    flag=(); if [[ $side == 7 ]]; then flag=(--defsym ARM7=1); fi
    assemble "entry$side" hs_direct_entry "${flag[@]}"
    assemble "guest$side" hs_direct_payload "${flag[@]}"
done
assemble swi-bad hs_direct_entry --defsym ARM7=1 --defsym BAD_SWI=1
unknown7=$(arm-none-eabi-nm "$out/tmp.o" | awk '$3=="unknown_swi7"{print $1}')
python3 -B - "$tests" "$out" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0,sys.argv[1]); from hs_dual_oracle import crc16, put32
out=Path(sys.argv[2]); rom=bytearray(0x10000)
for side,at,off,entry,addr in [(9,0x20,0x4000,0x02100800,0x02100000),(7,0x30,0x9000,0x02380000,0x02380000)]:
    data=(out/f'guest{side}.bin').read_bytes()
    rom[off:off+len(data)]=data
    for i,v in enumerate((off,entry,addr,len(data))): put32(rom,at+4*i,v)
rom[0x15e:0x160]=crc16(rom[:0x15e]).to_bytes(2,'little')
(out/'public.nds').write_bytes(rom)
rom[0x4000:0x4008]=bytes(8)
(out/'missing-marker.nds').write_bytes(rom)
PY
# DIRECT_HDL may name the exact generated tree from a previous build (e.g.
# the same one submitted to fit_fetch_line.sh). Default: freshly generate.
hdl=${DIRECT_HDL:-$out/hdl}
if [[ -z ${DIRECT_HDL:-} ]]; then
    (cd "$root/clash" && GHCRTS=-M3g stack exec clash -- +RTS -M3g -RTS --verilog -isrc \
        -fclash-no-escaped-identifiers -outputdir "$hdl" src/Nds/WholeCore/DualSoc.hs) >"$out/clash.log" 2>&1 || { cat "$out/clash.log" >&2; exit 1; }
fi
run() { "$runner" "$1" "$2" "$out/stock9.bin" "$out/stock7.bin" "$out/entry9.bin" "$out/entry7.bin" "${@:3}"; }
for variant in wide buffered; do
    top=nds_dual_soc_$variant
    v=$(find "$hdl" -name "$top.v"); test -f "$v"
    cflags=-O1
    [[ $variant != buffered ]] || cflags+=" -DFETCH_BUFFER"
    verilator --cc --exe --build -j 1 -Wno-fatal -CFLAGS "$cflags" --top-module "$top" \
        --Mdir "$out/$variant" -I"$(dirname "$v")" "$v" "$root/sim/clash_direct_handoff.cpp" >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    runner=$out/$variant/V$top
    echo "== $variant =="
    PUBLIC_RETIRE_PREFIX="$out/ret-$variant" run public "$out/public.nds"
    "$root/sim/run_shared_wram_guest.sh" "$runner" "$out/stock9.bin" "$out/stock7.bin" "$out/entry9.bin" "$out/entry7.bin"
    "$runner" fault7 "$out/swi-bad.bin" 1 "$((16#$unknown7))"
    for probe in USERMODE USERINV USERMPU BADMPU BADREG BADINV BADDRN ENDIAN DCENABLE LOWVEC ARM7 GPUEDGE; do
        assemble control hs_cp15_control --defsym "$probe=1"
        case $probe in
            ARM7) "$runner" fault7 "$out/control.bin" 1 0 ;;
            LOWVEC) "$runner" fault9 "$out/control.bin" 3 8 ;;
            GPUEDGE) "$runner" fault9 "$out/control.bin" 3 0x04000248 ;;
            *) offset=$(arm-none-eabi-nm "$out/tmp.o" | awk '$3=="fault_at"{print $1}')
               "$runner" fault9 "$out/control.bin" 1 "$((0xffff0000+16#$offset))" ;;
        esac
    done
    for kind in SKIPINV INV DONLY; do
        args=(--defsym INVPROBE=1)
        invalidate=0
        if [[ $kind == INV ]]; then invalidate=1; else args+=(--defsym "$kind=1"); fi
        assemble control hs_cp15_control "${args[@]}"
        offset=$(arm-none-eabi-nm "$out/tmp.o" | awk '$3=="finished"{print $1}')
        "$runner" inv9 "$out/control.bin" "$((0xffff0000+16#$offset))" "$invalidate"
    done
    assemble control hs_cp15_control --defsym DRAIN=1
    offset=$(arm-none-eabi-nm "$out/tmp.o" | awk '$3=="finished"{print $1}')
    "$runner" drain9 "$out/control.bin" "$((0xffff0000+16#$offset))"
    assemble control hs_arm9_mpu
    offset=$(arm-none-eabi-nm "$out/tmp.o" | awk '$3=="finished"{print $1}')
    "$runner" mpu9 "$out/control.bin" "$((0xffff0000+16#$offset))"
    echo 'Control register, privilege, invalidate-all (resident line vs failed condition), low SWI vector, graphics lane bound and ARM7 negatives passed.'
done
for cpu in 9 7; do cmp "$out/ret-wide.$cpu" "$out/ret-buffered.$cpu"; done
echo 'Identical per-CPU PC/opcode sequences through both public mailboxes (timer IF/vector/ack verified).'
if run public "$out/missing-marker.nds" >"$out/negative" 2>&1 || ! grep -q 'encrypted input not supported' "$out/negative"; then
    echo 'missing post-firmware markers did not produce the required rejection' >&2; exit 1
fi
if [[ $# == 2 ]]; then
    image=$2
    if [[ $1 == --postfirmware-hex ]]; then
        image=$out/local.nds
        # Stream product card words into an ephemeral little-endian image.
        python3 - "$2" "$image" <<'PY'
import struct,sys
with open(sys.argv[1], 'rb') as src, open(sys.argv[2], 'wb') as dst:
    for line in src: dst.write(struct.pack('<I', int(line,16)))
PY
    fi
    trace=()
    if [[ -n ${MELONDS_TRACE:-} ]]; then
        TRACE9="$out/trace9" TRACE9MAX=64 TRACE7="$out/trace9.7" TRACE7MAX=231400 \
            "$MELONDS_TRACE" --direct "$image" /dev/null 16 >"$out/ref.log" 2>&1
        # Both header entries start in ARM state (+8); the C++ comparator
        # tracks later Thumb/ARM transitions using the previous post-CPSR.
        python3 - "$image" "$out/trace9" "$out/trace9.7" <<'PY'
from struct import unpack_from
import sys
with open(sys.argv[1],'rb') as f: h=f.read(512)
for side,off,path in [(9,0x24,sys.argv[2]),(7,0x34,sys.argv[3])]:
    with open(path) as f: pc=int(f.readline().split()[0],16)-8
    if pc!=unpack_from('<I',h,off)[0]: sys.exit('reference entry does not match cartridge header')
    print(f'melonDS first retired ARM{side} PC: {pc:08x}')
PY
        trace=("$out/trace9")
    fi
    assemble entry7-trap hs_direct_entry --defsym ARM7=1 --defsym TRAP_ALL_SWI=1
    for variant in wide buffered; do
        runner=$out/$variant/Vnds_dual_soc_$variant
        "$runner" kirby-vector "$image" "$out/stock9.bin" "$out/stock7.bin" "$out/entry9.bin" "$out/entry7-trap.bin" "${trace[@]}"
        run kirby "$image" "${trace[@]}"
    done
fi
