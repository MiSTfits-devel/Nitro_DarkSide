#!/bin/sh
# Build the sdk2d sample with the real devkitPro toolchain and pack it
# with ndstool - the first real-toolchain .nds through the M5 frame diff.
# Emits nds_sdk2d.nds (for melonds_fbdump) and ../nds_sdk2d.hex (for
# tb_top_frame). Custom crt0 (no calico kernel / DMA / BIOS - see
# arm9_crt0.s); libnds provides headers only.
set -eu
cd "$(dirname "$0")"

DKP=/opt/devkitpro
CC="$DKP/devkitARM/bin/arm-none-eabi-gcc"
AS="$DKP/devkitARM/bin/arm-none-eabi-as"
LD="$DKP/devkitARM/bin/arm-none-eabi-ld"
NDSTOOL="$DKP/tools/bin/ndstool"

# ARM9: crt0 + C main, linked at 0x02000000
"$CC" -mcpu=arm946e-s -marm -O2 -ffreestanding -Wall -Wextra \
   -I "$DKP/libnds/include" -I "$DKP/calico/include" -D__NDS__ -DARM9 \
   -c arm9_main.c -o arm9_main.o
"$AS" -mcpu=arm946e-s -o arm9_crt0.o arm9_crt0.s
"$LD" -T arm9.ld -o arm9.elf arm9_crt0.o arm9_main.o

# ARM7: idle stub at 0x037F8000
"$AS" -mcpu=arm7tdmi -o arm7_stub.o arm7_stub.s
"$LD" -Ttext=0x037F8000 -e _start -o arm7.elf arm7_stub.o

"$NDSTOOL" -c nds_sdk2d.nds -9 arm9.elf -7 arm7.elf \
   -g SDK2 01 "MISTFITS-M5" 1
"$NDSTOOL" -i nds_sdk2d.nds | head -20

python3 - <<'EOF'
img = open("nds_sdk2d.nds", "rb").read()
img += b"\0" * ((4 - len(img) % 4) % 4)
with open("../nds_sdk2d.hex", "w") as f:
    for i in range(0, len(img), 4):
        f.write(f"{int.from_bytes(img[i:i+4], 'little'):08x}\n")
print(f"nds_sdk2d.hex: {len(img)//4} words")
EOF

rm -f arm9_main.o arm9_crt0.o arm7_stub.o
