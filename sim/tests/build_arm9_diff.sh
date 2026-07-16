#!/bin/sh
# Assemble the ARM9 differential-trace workload, linked at 0x02000000 (main
# RAM). Produces arm9_diff.bin (melonds_tracer input) and arm9_diff.hex
# (tb_arm9_trace LOADADDR=0x02000000 input); both are checked in.
set -eu
cd "$(dirname "$0")"

arm-none-eabi-as -march=armv5te -o arm9_diff.o arm9_diff.s
arm-none-eabi-ld -Ttext=0x02000000 -o arm9_diff.elf arm9_diff.o
arm-none-eabi-objcopy -O binary arm9_diff.elf arm9_diff.bin

python3 - <<'EOF'
data = open("arm9_diff.bin", "rb").read()
data += b"\0" * ((4 - len(data) % 4) % 4)
with open("arm9_diff.hex", "w") as f:
    for i in range(0, len(data), 4):
        w = int.from_bytes(data[i:i+4], "little")
        f.write(f"{w:08x}\n")
print(f"arm9_diff.hex: {len(data)//4} words")
EOF

rm -f arm9_diff.o arm9_diff.elf
