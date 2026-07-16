#!/bin/sh
# Assemble the ARM9 cache test (boot ROM at 0xFFFF0000, island harness).
set -eu
cd "$(dirname "$0")"

arm-none-eabi-as -march=armv5te -o arm9_cache.o arm9_cache.s
arm-none-eabi-ld -Ttext=0xFFFF0000 -o arm9_cache.elf arm9_cache.o
arm-none-eabi-objcopy -O binary arm9_cache.elf arm9_cache.bin

python3 - <<'EOF'
data = open("arm9_cache.bin", "rb").read()
data += b"\0" * ((4 - len(data) % 4) % 4)
with open("arm9_cache.hex", "w") as f:
    for i in range(0, len(data), 4):
        w = int.from_bytes(data[i:i+4], "little")
        f.write(f"{w:08x}\n")
print(f"arm9_cache.hex: {len(data)//4} words")
EOF

rm -f arm9_cache.o arm9_cache.elf arm9_cache.bin
