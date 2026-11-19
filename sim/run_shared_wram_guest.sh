#!/usr/bin/env bash
# Run the same redistributable two-CPU binary on stock melonDS (no args)
# or on an already built wide/buffered Verilator direct-handoff runner.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tests=$root/sim/tests
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-shared-wram.XXXXXX")
trap 'rm -rf "$out"' EXIT
for side in 7 9; do
    flag=(); if [[ $side == 7 ]]; then flag=(--defsym ARM7=1); fi
    arm-none-eabi-as -EL ${flag[@]+"${flag[@]}"} -o "$out/$side.o" "$tests/hs_shared_wram.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/$side.o" "$out/$side.bin"
done
python3 -B - "$out" <<'PY'
import pathlib, struct, sys
out=pathlib.Path(sys.argv[1]); image=bytearray(0x10000)
for side,offset,addr,entry,at in [(9,0x4000,0x02100000,0x02100800,0x20),(7,0x9000,0x02380000,0x02380000,0x30)]:
    code=(out/f'{side}.bin').read_bytes()
    struct.pack_into('<4I',image,at,offset,entry,addr,len(code))
    image[offset:offset+len(code)]=code
(out/'shared.nds').write_bytes(image)
PY
if [[ $# == 5 ]]; then
    "$1" shared "$out/shared.nds" "${@:2}"
elif [[ $# == 0 ]]; then
    ref=${MELONDS_FBDUMP:-$root/sim/melonds_tracer/build/melonds_fbdump}
    "$ref" --direct --no-text-dump --ram-dump 0x02000fe8:2 "$out/shared.nds" /dev/null 1 >"$out/oracle.log"
    grep -Fx 'ram[02000FE8]=9999CAFE' "$out/oracle.log"
    grep -Fx 'ram[02000FEC]=7777BEEF' "$out/oracle.log"
    echo 'PASS: stock melonDS shared WRAM modes, mixed registers, private fallback and executable bank transfers'
else
    echo "usage: $0 [runner stock9.bin stock7.bin entry9.bin entry7.bin]" >&2; exit 2
fi
