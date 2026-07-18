#!/bin/sh
# Assemble the ldm^-with-pc / bank-swap regression (M7 boot blocker #6:
# the swap block sat inside the execute_now branch and never ran in the
# DATARW_BLOCKSWITCH cycle, leaving IRQ-banked sp/lr live in system mode).
# Run: HEXFILE=sim/tests/ldm_bx_irq.hex MAXINSTR=20000 TIMEOUT_MS=2 sim/run_arm9_trace.sh
# Pass: loop PCs FFFF0080/84/88 retire in equal counts; 0xCAFEBABE lands
# at 0x02001004 after 50 timer IRQs.
set -eu
cd "$(dirname "$0")"
DKA=/opt/devkitpro/devkitARM/bin
$DKA/arm-none-eabi-as -mcpu=arm946e-s -o ldm_bx_irq.o ldm_bx_irq.s
$DKA/arm-none-eabi-ld -Ttext=0xFFFF0000 -o ldm_bx_irq.elf ldm_bx_irq.o
$DKA/arm-none-eabi-objcopy -O binary ldm_bx_irq.elf ldm_bx_irq.bin
python3 -c "
data=open('ldm_bx_irq.bin','rb').read(); data+=b'\0'*(-len(data)%4)
open('../ldm_bx_irq.hex','w').write('\n'.join('%08x'%int.from_bytes(data[i:i+4],'little') for i in range(0,len(data),4))+'\n')"
rm -f ldm_bx_irq.o ldm_bx_irq.elf ldm_bx_irq.bin
echo "wrote sim/tests/ldm_bx_irq.hex"
