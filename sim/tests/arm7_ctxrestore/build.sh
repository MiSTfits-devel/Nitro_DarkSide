#!/bin/sh
# Assemble the ARM7 context-restore regression (docs/TICKET-arm7-firmware-wedge.md).
# The generated arm7_ctxrestore.hex is checked in, so the sim host never needs
# the ARM toolchain.
#
# Run: HEXFILE=sim/tests/arm7_ctxrestore.hex TIMEOUT_MS=45 sim/run_arm7_island.sh
# Pass: "tb_arm7_island: PASS" with bitmask 00000003.
# Fail: bit 0 clear    -> `msr spsr` did not store what `mrs spsr` reads back.
#       "unhandled opcode 1C0E1C05 thumb=0" -> the exception return lost the
#       T bit, which is the firmware-boot fault at 1.588 s reproduced in ~1 s.
set -eu
cd "$(dirname "$0")"

AS=arm-none-eabi-as
LD=arm-none-eabi-ld
OC=arm-none-eabi-objcopy

$AS -march=armv4t -o arm7_ctxrestore.o arm7_ctxrestore.s
$LD -Ttext=0x0 -o arm7_ctxrestore.elf arm7_ctxrestore.o
$OC -O binary arm7_ctxrestore.elf arm7_ctxrestore.bin

python3 - <<'EOF'
data = open("arm7_ctxrestore.bin", "rb").read()
data += b"\0" * ((4 - len(data) % 4) % 4)
with open("../arm7_ctxrestore.hex", "w") as f:
    for i in range(0, len(data), 4):
        f.write("%08x\n" % int.from_bytes(data[i:i+4], "little"))
print("arm7_ctxrestore.hex: %d words" % (len(data) // 4))
EOF

rm -f arm7_ctxrestore.o arm7_ctxrestore.elf arm7_ctxrestore.bin
