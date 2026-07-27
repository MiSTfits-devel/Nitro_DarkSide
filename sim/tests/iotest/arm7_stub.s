@ iotest ARM7: report what the ARM7 side sees of the ARM9's IPCSYNC nibble.
@
@ Deliberately uses no BIOS SWIs, no IRQs and no DMA - this ROM exists to test
@ the ARM9's IO path, so it must not be able to fail for an unrelated reason.
@ Waits (bounded) for the ARM9's ready flag, reads IPCSYNC, and posts
@ 0x5EED000n where n is the nibble it saw in bits[3:0] (the ARM9's data-out).
@
@ A timeout posts 0x7140000n instead, so "the ARM7 never got there" and "the
@ ARM7 saw the wrong nibble" are different values rather than both being silence.

   .arch armv4t
   .arm
   .global _start
   .text

_start:
   msr  cpsr_c, #0xDF          @ system mode, IRQs off
   ldr  sp, =0x0380FF00

   ldr  r0, =0x02300000        @ shared block (main RAM)
   ldr  r1, =0x04000180        @ IPCSYNC

   @ post our own nibble 5 so the ARM9 could see us too if it looks
   mov  r2, #0x0500
   strh r2, [r1]

   @ bounded wait for ARM9_READY == 0x600D0000 at +0x04
   ldr  r3, =0x600D0000
   mov  r4, #0
   ldr  r5, =100000
1: ldr  r6, [r0, #4]
   cmp  r6, r3
   beq  2f
   add  r4, r4, #1
   cmp  r4, r5
   blo  1b

   @ timed out waiting for the ARM9: still report the nibble we can see
   ldrh r6, [r1]
   and  r6, r6, #0x0F
   ldr  r7, =0x71400000
   orr  r6, r7, r6
   str  r6, [r0]
   b    9f

2: @ ARM9 is ready - read its data-out nibble from IPCSYNC bits[3:0]
   ldrh r6, [r1]
   and  r6, r6, #0x0F
   ldr  r7, =0x5EED0000
   orr  r6, r7, r6
   str  r6, [r0]

9: b    9b

   .ltorg
