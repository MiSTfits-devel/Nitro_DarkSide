@ M4 dual-CPU boot test, ARM9 side. Linked at 0x02000000, loaded by
@ nds_loader from the .nds card image (see build_nds_dual.sh).
@
@ Replicates the NitroSDK startup shape (crt0 + PXI_InitFifo from the SDK
@ decomp sources): CP15/TCM/PU/cache setup, the IPCSYNC echo handshake
@ (ARM9 echoes the ARM7's 8..0 countdown, breaks on stable 0), IPC FIFO
@ init (CNT = 0xC408), then "main()": shared-WRAM handoff, EXMEMCNT, an
@ 8-word FIFO ping-pong with the ARM7, and the joint exit.
@
@ Mailbox (uncached main-RAM mirror, snooped by the testbench):
@   0x02FFFF00 ARM9 progress bitmask   0x02FFFF04 ARM9 magic
@   0x02FFFF10 ARM7 progress bitmask   0x02FFFF14 ARM7 done/fail word

   .arch armv5te
   .arm
   .global _start

_start:
@ ==== crt0-shaped CP15 setup ====
   mov  r0, #0x20
   mcr  p15, 0, r0, c9, c1, 1  @ ITCM: 32 MB virtual
   ldr  r0, =0x027E000A
   mcr  p15, 0, r0, c9, c1, 0  @ DTCM at 0x027E0000 (SDK spot), 16 KB
   ldr  r0, =0x0000003F        @ region 0: 4 GB, uncachable
   mcr  p15, 0, r0, c6, c0, 0
   ldr  r0, =0x0200002B        @ region 1: main RAM 4 MB, cachable
   mcr  p15, 0, r0, c6, c1, 0
   mov  r0, #0x02
   mcr  p15, 0, r0, c2, c0, 0
   mcr  p15, 0, r0, c2, c0, 1
   mcr  p15, 0, r0, c3, c0, 0
   ldr  r0, =0x33333333
   mcr  p15, 0, r0, c5, c0, 2
   mcr  p15, 0, r0, c5, c0, 3
   ldr  r0, =0x0005107D        @ PU + I/D caches + ITCM + DTCM
   mcr  p15, 0, r0, c1, c0, 0
   ldr  sp, =0x027E3F80        @ stack in DTCM, like the SDK

   ldr  r10, =0x02FFFF00       @ mailbox (mirror -> region 0 -> uncached)
   ldr  r11, =0x04000000
   ldr  r8,  =0x04000180       @ halfword base: SYNC +0, FIFOCNT +4 (ldrh/strh
   ldr  r7,  =0x04000204       @ only take 8-bit offsets); EXMEMCNT base
   mov  r9, #0
   orr  r9, r9, #1             @ bit 0: crt0 done
   str  r9, [r10]

@ ==== IPCSYNC echo handshake (PXI_InitFifo, ARM9 side) ====
   mov  r4, #0                 @ i
sync_loop:
   ldrh r0, [r8]
   and  r0, r0, #15            @ c = other side's value
   lsl  r1, r0, #8
   strh r1, [r8]      @ echo it
   cmp  r0, #0
   bne  1f
   cmp  r4, #4
   bgt  sync_done              @ c==0 && i>4
1: ldr  r2, =1000              @ wait for change, timeout resets i
2: ldrh r3, [r8]
   and  r3, r3, #15
   cmp  r3, r0
   bne  3f
   subs r2, r2, #1
   bne  2b
   mov  r4, #0                 @ timeout: i = 0 (SDK behavior)
   b    sync_loop
3: add  r4, r4, #1
   b    sync_loop
sync_done:
   orr  r9, r9, #2             @ bit 1: sync handshake done
   str  r9, [r10]

@ ==== FIFO init (CNT = SEND_CL | RECV_RI | ERR | E) ====
   ldr  r1, =0xC408
   strh r1, [r8, #4]

@ ==== shared WRAM: write pattern while we own it, hand to ARM7 ====
   ldr  r0, =0x03000000
   ldr  r1, =0x57A4C0DE
   str  r1, [r0]
   ldr  r2, =0x03007FFC
   ldr  r3, =0x57A4C0DF
   str  r3, [r2]
   mov  r1, #3
   strb r1, [r11, #0x247]      @ WRAMCNT = 3: both halves to ARM7
   orr  r9, r9, #4             @ bit 2: fifo init + wram handoff
   str  r9, [r10]

@ ==== EXMEMCNT: give everything to ARM7, check bit 13 reads set ====
   ldr  r1, =0x8880
   strh r1, [r7]
   ldrh r2, [r7]
   ldr  r3, =0xA880
   cmp  r2, r3
   bne  report_fail
   orr  r9, r9, #8             @ bit 3: exmem
   str  r9, [r10]

@ ==== FIFO ping-pong: send 8 tagged words, ARM7 replies +1 ====
   mov  r4, #0
pp_loop:
   ldr  r0, =0xCAFE0000
   orr  r0, r0, r4
   str  r0, [r11, #0x188]      @ IPCFIFOSEND
1: ldrh r1, [r8, #4]
   tst  r1, #0x100             @ recv empty?
   bne  1b
   ldr  r2, =0x04100000
   ldr  r1, [r2]               @ IPCFIFORECV
   add  r0, r0, #1
   cmp  r1, r0
   bne  report_fail
   add  r4, r4, #1
   cmp  r4, #8
   blt  pp_loop
   ldrh r1, [r8, #4]
   tst  r1, #0x4000            @ error flag must be clear
   bne  report_fail
   orr  r9, r9, #16            @ bit 4: ping-pong
   str  r9, [r10]

@ ==== shared SWP atomicity: collide with ARM7 on the SDK lock mirror ====
   ldr  r4, =0x02FFFFE8        @ same physical word as HW_CTRDG_LOCK_BUF
   mov  r0, #0
   str  r0, [r4]               @ lock word
   str  r0, [r4, #4]           @ ARM9 ready
   mvn  r0, #0
   str  r0, [r4, #12]          @ ARM9 old value (sentinel)
   str  r0, [r4, #16]          @ ARM7 old value (sentinel)
   mov  r0, #1
   str  r0, [r4, #4]
1: ldr  r0, [r4, #8]
   cmp  r0, #1
   bne  1b
   mov  r0, #0x40
   swp  r0, r0, [r4]
   str  r0, [r4, #12]
2: ldr  r1, [r4, #16]
   cmn  r1, #1                 @ wait while ARM7 result is 0xFFFFFFFF
   beq  2b
   cmp  r0, #0
   cmpeq r1, #0x40             @ ARM9 won, ARM7 observed ARM9's write
   beq  swp9_ok
   cmp  r1, #0
   cmpeq r0, #0x80             @ ARM7 won, ARM9 observed ARM7's write
   bne  report_fail
swp9_ok:
   orr  r9, r9, #64            @ bit 6: cross-CPU SWP was atomic
   str  r9, [r10]

@ ==== wait for the ARM7's done word ====
   ldr  r2, =0x02FFFF14
   ldr  r3, =0xBEEF7777
1: ldr  r1, [r2]
   cmp  r1, r3
   bne  1b
   orr  r9, r9, #32            @ bit 5: arm7 finished
   str  r9, [r10]

@ ==== all passed ====
   ldr  r1, =0xCAFEBABE
   str  r1, [r10, #4]
hang:
   b    hang

report_fail:
   ldr  r10, =0x02FFFF00
   ldr  r1, =0xBADBAD00
   str  r1, [r10, #4]
9: b    9b

   .ltorg
