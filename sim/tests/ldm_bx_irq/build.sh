#!/bin/sh
# Assemble the ldm^-with-pc exception-return regression (M7 boot blockers
# #6 and #7: the bank swap never ran in the DATARW_BLOCKSWITCH cycle, a
# return into thumb code fetched word-aligned because nextIsthumb took
# the loaded pc's bit 0 instead of SPSR.T, and the target fetch issued on
# the BLOCKSWITCH cycle with stale thumbmode, stepping +4 and skipping
# the halfword after any word-aligned return target).
# Run: HEXFILE=sim/tests/ldm_bx_irq.hex MAXINSTR=60000 TIMEOUT_MS=3 \
#      MARKBASE=$((0x02001000)) sim/run_arm9_trace.sh
# MARKBASE is what makes the testbench report a verdict instead of just writing
# arm9_trace.log; without it the run is silent and you are back to reading 30k
# lines by hand. It must point at this test's marker block, because a bare value
# snoop also catches any stmdb that spills a register holding 0xCAFEBABE.
# Pass: 0xCAFEBABE at 0x02001004 (50 IRQs, ARM loop), 0x02001008 (70,
# thumb counting-chain loop), 0x0200100C (90, same with MPU+icache);
# ends parked at hang (the run then times out - expected), and the testbench
# prints "tb_arm9_trace: PASS  3 pass marker(s), no fail marker".
# Fail: 0x0BAD0BAD at 0x02001010 (an IRQ exit skipped an instruction), or no
# marker at all - both exit non-zero. A livelock or wild jump shows up at the
# end of arm9_trace.log.
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
