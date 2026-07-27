@ bootreq ARM7: the ARM7 half of the cross-CPU subtests. No BIOS SWIs, no IRQs,
@ no DMA - this side must not be able to fail for a reason unrelated to what is
@ being measured.
@
@ Mailbox is the UNCACHED main-RAM mirror (0x02FFFF00). The ARM7 has no cache so
@ any view works for it, but it must be the SAME PHYSICAL WORD the ARM9 reads
@ through its uncached region 2, or the ARM9 serves its read from D-cache and the
@ handshake silently never completes.
@
@   +0x00  ARM7 -> ARM9 : 0x5EED000n, n = ARM9's IPCSYNC data-out nibble
@                         0x7140000n on timeout waiting for the ARM9
@   +0x04  ARM9 -> ARM7 : 0x600D0000 go flag
@   +0x08  ARM7 -> ARM9 : the word received over the IPC FIFO, echoed back

   .arch armv4t
   .arm
   .global _start
   .text

   .equ MBOX,        0x02FFFF00
   .equ IPCSYNC,     0x04000180
   .equ IPCFIFOCNT,  0x04000184
   .equ IPCFIFORECV, 0x04100000

_start:
   msr  cpsr_c, #0xDF          @ system mode, IRQs off
   ldr  sp, =0x0380FF00

   ldr  r0, =MBOX
   ldr  r1, =IPCSYNC

   @ post our own nibble 5 so the ARM9 could observe us too
   mov  r2, #0x0500
   strh r2, [r1]

   @ enable the FIFO on this side as well (bit 15), flush receive
   ldr  r8, =IPCFIFOCNT
   mov  r2, #0x8000
   orr  r2, r2, #0x0008
   strh r2, [r8]

   @ ---- wait (bounded) for the ARM9's go flag at +0x04 ----------------------
   ldr  r3, =0x600D0000
   mov  r4, #0
   ldr  r5, =50000
1: ldr  r6, [r0, #4]
   cmp  r6, r3
   beq  2f
   add  r4, r4, #1
   cmp  r4, r5
   blo  1b

   @ timed out: still report the nibble we can see, with a distinct tag
   ldrh r6, [r1]
   and  r6, r6, #0x0F
   ldr  r7, =0x71400000
   orr  r6, r7, r6
   str  r6, [r0]
   b    3f

2: @ ARM9 ready: report its data-out nibble from IPCSYNC bits[3:0]
   ldrh r6, [r1]
   and  r6, r6, #0x0F
   ldr  r7, =0x5EED0000
   orr  r6, r7, r6
   str  r6, [r0]

3: @ ---- IPC FIFO: wait (bounded) for a word and echo it to +0x08 -----------
   ldr  r9, =IPCFIFORECV
   mov  r4, #0
   ldr  r5, =50000
4: ldrh r6, [r8]               @ IPCFIFOCNT
   tst  r6, #0x0100            @ receive FIFO empty?
   beq  5f                     @ not empty -> read it
   add  r4, r4, #1
   cmp  r4, r5
   blo  4b
   b    9f                     @ never arrived: leave +0x08 as 0

5: ldr  r6, [r9]               @ pop the word
   str  r6, [r0, #8]

9: b    9b

   .ltorg
