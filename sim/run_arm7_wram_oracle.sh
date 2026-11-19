#!/usr/bin/env bash
# Stock melonDS reference only. The generated Clash guest gate runs the same
# WRAM operations in sim/run_clash_direct_handoff.sh; this needs no HDL,
# private cartridge, firmware or save.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
ref=${MELONDS_FBDUMP:-$root/sim/melonds_tracer/build-vendored/melonds_fbdump}
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-arm7-wram-oracle.XXXXXX")
trap 'rm -rf "$out"' EXIT
arm-none-eabi-as -EL --defsym ARM7=1 --defsym WRAM_ONLY=1 -o "$out/probe.o" "$root/sim/tests/hs_direct_payload.S"
arm-none-eabi-objcopy -j .text -O binary "$out/probe.o" "$out/probe.bin"
# The stock HLE section loader needs only the two section descriptors. ARM9
# loops in main RAM and never touches the mailbox; ARM7 publishes the word
# returned by the code that it stored and executed through two WRAM aliases.
python3 - "$out" <<'PY'
import pathlib, struct, sys
out=pathlib.Path(sys.argv[1]); arm7=(out/'probe.bin').read_bytes()
image=bytearray(0x9000 + len(arm7))
for offset, code, addr, at in [(0x8000, bytes.fromhex('feffffea'), 0x02004000, 0x20),
                               (0x9000, arm7, 0x02380000, 0x30)]:
    struct.pack_into('<4I', image, at, offset, addr, addr, len(code))
    image[offset:offset+len(code)] = code
(out/'public.nds').write_bytes(image)
PY
"$ref" --no-text-dump --ram-dump 0x02000ffc:1 "$out/public.nds" /dev/null 1 >"$out/oracle.log"
grep -Fx 'ram[02000FFC]=0000002B' "$out/oracle.log"
echo 'PASS: independent ARM7 private-WRAM mirrors, byte lanes, stores and ARM/Thumb execution'
