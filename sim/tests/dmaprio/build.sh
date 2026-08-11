#!/bin/sh
# Build the dmaprio ROM: a standalone repro of the NITRO Tester's [04-02] DMA
# PRIORITY test, which is where the cart halts (progress 011/058).
#
# Emits nds_dmaprio.nds (for melonds_fbdump, as an oracle) and ../nds_dmaprio.hex
# (for tb_top_frame). Reaching the transfers costs microseconds instead of the
# ~4 hours the cart itself needs, so the DMA cadence can be iterated on.
#
#   sim/tests/dmaprio/build.sh
#   DUMP_STATE=1 PRELOAD=1 DIRECT=1 FRAMES=2 \
#      sim/run_top_frame.sh sim/tests/nds_dmaprio.hex
#   sim/tests/dmaprio/check.py            # decodes rtl_state_banks.hex
set -eu
cd "$(dirname "$0")"

DKP=/opt/devkitpro
AS="$DKP/devkitARM/bin/arm-none-eabi-as"
LD="$DKP/devkitARM/bin/arm-none-eabi-ld"
NDSTOOL="$DKP/tools/bin/ndstool"

"$AS" -mcpu=arm946e-s -o arm9.o arm9.s
"$LD" -T arm9.ld -o arm9.elf arm9.o

"$AS" -mcpu=arm7tdmi -o arm7_stub.o arm7_stub.s
"$LD" -Ttext=0x037F8000 -e _start -o arm7.elf arm7_stub.o

"$NDSTOOL" -c nds_dmaprio.nds -9 arm9.elf -7 arm7.elf \
   -g DMAP 01 "MISTFITS-DMA" 1
"$NDSTOOL" -i nds_dmaprio.nds | head -12

python3 - <<'EOF'
img = open("nds_dmaprio.nds", "rb").read()
img += b"\0" * ((4 - len(img) % 4) % 4)
with open("../nds_dmaprio.hex", "w") as f:
    for i in range(0, len(img), 4):
        f.write(f"{int.from_bytes(img[i:i+4], 'little'):08x}\n")
print(f"nds_dmaprio.hex: {len(img)//4} words")
EOF

rm -f arm9.o arm7_stub.o
