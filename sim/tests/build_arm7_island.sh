#!/bin/sh
# Assemble the ARM7 island test into a word-hex init file for the testbench
# "BIOS" BRAM. The generated arm7_island.hex is checked in, so the sim host
# never needs the ARM toolchain.
set -eu
cd "$(dirname "$0")"

arm-none-eabi-as -march=armv4t -o arm7_island.o arm7_island.s
arm-none-eabi-ld -Ttext=0x0 -o arm7_island.elf arm7_island.o
arm-none-eabi-objcopy -O binary arm7_island.elf arm7_island.bin

python3 - <<'EOF'
data = open("arm7_island.bin", "rb").read()
data += b"\0" * ((4 - len(data) % 4) % 4)
with open("arm7_island.hex", "w") as f:
    for i in range(0, len(data), 4):
        w = int.from_bytes(data[i:i+4], "little")
        f.write(f"{w:08x}\n")
print(f"arm7_island.hex: {len(data)//4} words")
EOF

rm -f arm7_island.o arm7_island.elf
