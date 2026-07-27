#!/bin/sh
# Build the iotest ROM: a purpose-built dual-CPU .nds that answers "does an ARM9
# IO access work" from the inside, where the expected value is known exactly.
# Same custom-crt0 pattern as sdk2d (no calico kernel, no BIOS SWIs, no DMA).
#
# Emits nds_iotest.nds (for melonds_fbdump, as an oracle) and ../nds_iotest.hex
# (for tb_top_frame). Boots in microseconds - the whole point is that iterating
# on it costs seconds instead of the ~75 ms of simulated time Kirby needs to
# reach its first IO access.
set -eu
cd "$(dirname "$0")"

DKP=/opt/devkitpro
CC="$DKP/devkitARM/bin/arm-none-eabi-gcc"
AS="$DKP/devkitARM/bin/arm-none-eabi-as"
LD="$DKP/devkitARM/bin/arm-none-eabi-ld"
NDSTOOL="$DKP/tools/bin/ndstool"

"$CC" -mcpu=arm946e-s -marm -O2 -ffreestanding -Wall -Wextra \
   -I "$DKP/libnds/include" -I "$DKP/calico/include" -D__NDS__ -DARM9 \
   -c arm9_main.c -o arm9_main.o
"$AS" -mcpu=arm946e-s -o arm9_crt0.o arm9_crt0.s
"$LD" -T arm9.ld -o arm9.elf arm9_crt0.o arm9_main.o

"$AS" -mcpu=arm7tdmi -o arm7_stub.o arm7_stub.s
"$LD" -Ttext=0x037F8000 -e _start -o arm7.elf arm7_stub.o

"$NDSTOOL" -c nds_iotest.nds -9 arm9.elf -7 arm7.elf \
   -g IOTS 01 "MISTFITS-IO" 1
"$NDSTOOL" -i nds_iotest.nds | head -12

python3 - <<'EOF'
img = open("nds_iotest.nds", "rb").read()
img += b"\0" * ((4 - len(img) % 4) % 4)
with open("../nds_iotest.hex", "w") as f:
    for i in range(0, len(img), 4):
        f.write(f"{int.from_bytes(img[i:i+4], 'little'):08x}\n")
print(f"nds_iotest.hex: {len(img)//4} words")
EOF

rm -f arm9_main.o arm9_crt0.o arm7_stub.o
