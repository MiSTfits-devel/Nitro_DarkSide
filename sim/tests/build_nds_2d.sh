#!/bin/sh
# Assemble the M5 2D frame-dump pair (arm9_2d.s scene at 0x02000000,
# arm7_2d.s idle stub at 0x02380000) and pack them into a minimal .nds
# card image (same layout as build_nds_dual.sh). Emits both the hex for
# nds_loader/tb_top_frame and the raw .nds for melonDS. The generated
# nds_2d.hex is checked in, so the sim host never needs the ARM toolchain.
set -eu
cd "$(dirname "$0")"

arm-none-eabi-as -march=armv5te -o arm9_2d.o arm9_2d.s
arm-none-eabi-ld -Ttext=0x02000000 -o arm9_2d.elf arm9_2d.o
arm-none-eabi-objcopy -O binary arm9_2d.elf arm9_2d.bin

arm-none-eabi-as -march=armv4t -o arm7_2d.o arm7_2d.s
arm-none-eabi-ld -Ttext=0x02380000 -o arm7_2d.elf arm7_2d.o
arm-none-eabi-objcopy -O binary arm7_2d.elf arm7_2d.bin

python3 - <<'EOF'
import struct

def align4(b):
    return b + b"\0" * ((4 - len(b) % 4) % 4)

arm9 = align4(open("arm9_2d.bin", "rb").read())
arm7 = align4(open("arm7_2d.bin", "rb").read())

ARM9_OFF, ARM9_ENTRY, ARM9_LOAD = 0x200, 0x02000000, 0x02000000
ARM7_OFF = ARM9_OFF + len(arm9)
ARM7_ENTRY = ARM7_LOAD = 0x02380000

hdr = bytearray(0x200)
hdr[0x00:0x0C] = b"M5 2D SCENE\0"
hdr[0x20:0x40] = struct.pack("<8I", ARM9_OFF, ARM9_ENTRY, ARM9_LOAD, len(arm9),
                                    ARM7_OFF, ARM7_ENTRY, ARM7_LOAD, len(arm7))
img = bytes(hdr) + arm9 + arm7

with open("nds_2d.nds", "wb") as f:
    f.write(img)
with open("nds_2d.hex", "w") as f:
    for i in range(0, len(img), 4):
        f.write(f"{int.from_bytes(img[i:i+4], 'little'):08x}\n")
print(f"nds_2d: {len(img)} bytes (arm9 {len(arm9)}B @0x{ARM9_OFF:X}, arm7 {len(arm7)}B @0x{ARM7_OFF:X})")
EOF

rm -f arm9_2d.o arm9_2d.elf arm7_2d.o arm7_2d.elf
