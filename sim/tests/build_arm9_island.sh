#!/bin/sh
# Assemble the ARM9 island test (v5TE) into a word-hex init file for the
# testbench boot ROM at 0xFFFF0000. The generated arm9_island.hex is checked
# in, so the sim host never needs the ARM toolchain.
set -eu
cd "$(dirname "$0")"

arm-none-eabi-as -march=armv5te -o arm9_island.o arm9_island.s
arm-none-eabi-ld -Ttext=0xFFFF0000 -o arm9_island.elf arm9_island.o
arm-none-eabi-objcopy -O binary arm9_island.elf arm9_island.bin

python3 - <<'EOF'
data = open("arm9_island.bin", "rb").read()
data += b"\0" * ((4 - len(data) % 4) % 4)
with open("arm9_island.hex", "w") as f:
    for i in range(0, len(data), 4):
        w = int.from_bytes(data[i:i+4], "little")
        f.write(f"{w:08x}\n")
print(f"arm9_island.hex: {len(data)//4} words")
EOF

rm -f arm9_island.o arm9_island.elf
