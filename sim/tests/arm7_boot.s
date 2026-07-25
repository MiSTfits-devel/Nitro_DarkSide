@ M4 dual-CPU boot test, ARM7 side. Linked at 0x02380000 (main RAM), loaded
@ by nds_loader. Replicates the SDK PXI_InitFifo ARM7 half: IPCSYNC 8..0
@ countdown (restart on echo mismatch), FIFO init, then "main()": wait for
@ the shared-WRAM handoff, EXMEMSTAT checks, FIFO reply loop, done word.
@ Progress bitmask at 0x02FFFF10, done/fail word at 0x02FFFF14.

   .arch armv4t
   .arm
   .global _start

_start:
   ldr  sp, =0x0380FF00        @ stack in ARM7-private WRAM
   ldr  r11, =0x04000000
   ldr  r8,  =0x04000180       @ halfword base: SYNC +0, FIFOCNT +4 (ldrh/strh
   ldr  r7,  =0x04000204       @ only take 8-bit offsets); EXMEMSTAT base
   ldr  r10, =0x02FFFF10
   mov  r9, #0
   orr  r9, r9, #1             @ bit 0: booted
   str  r9, [r10]

@ ==== IPCSYNC countdown (PXI_InitFifo, ARM7 side) ====
   mov  r4, #8
s_loop:
   lsl  r0, r4, #8
   strh r0, [r8]      @ our value out
   ldr  r1, =200               @ OS_SpinWait
1: subs r1, r1, #1
   bne  1b
   ldrh r1, [r8]
   and  r1, r1, #15            @ ARM9's echo
   cmp  r1, r4
   bne  s_restart
   subs r4, r4, #1
   bge  s_loop
   b    s_done
s_restart:
   mov  r4, #8
   b    s_loop
s_done:
   orr  r9, r9, #2             @ bit 1: sync done
   str  r9, [r10]

@ ==== FIFO init ====
   ldr  r1, =0xC408
   strh r1, [r8, #4]

@ ==== wait for shared-WRAM handoff, verify the ARM9's pattern ====
1: ldrb r0, [r11, #0x241]      @ WRAMSTAT
   cmp  r0, #3
   bne  1b
   ldr  r0, =0x03000000
   ldr  r1, [r0]
   ldr  r2, =0x57A4C0DE
   cmp  r1, r2
   bne  report_fail
   ldr  r3, =0x03007FFC
   ldr  r1, [r3]
   ldr  r2, =0x57A4C0DF
   cmp  r1, r2
   bne  report_fail
   orr  r9, r9, #4             @ bit 2: wram
   str  r9, [r10]

@ ==== EXMEMSTAT: wait for ARM9's grants, then our own timing bits ====
1: ldrh r0, [r7]
   ldr  r1, =0xA880
   and  r2, r0, r1
   cmp  r2, r1
   bne  1b
   mov  r0, #0x5A
   strh r0, [r7]
   ldrh r0, [r7]
   and  r1, r0, #0x7F
   cmp  r1, #0x5A
   bne  report_fail
   orr  r9, r9, #8             @ bit 3: exmem
   str  r9, [r10]

@ ==== FIFO reply loop: 8 words, each answered +1 ====
   mov  r4, #0
pp_loop:
1: ldrh r0, [r8, #4]
   tst  r0, #0x100             @ recv empty?
   bne  1b
   ldr  r2, =0x04100000
   ldr  r0, [r2]
   add  r0, r0, #1
   str  r0, [r11, #0x188]
   add  r4, r4, #1
   cmp  r4, #8
   blt  pp_loop
   orr  r9, r9, #16            @ bit 4: ping-pong served
   str  r9, [r10]

@ ==== collide one SWP with ARM9 on the shared SDK lock mirror ====
   ldr  r4, =0x02FFFFE8
   mov  r0, #1
   str  r0, [r4, #8]           @ ARM7 ready
1: ldr  r0, [r4, #4]
   cmp  r0, #1
   bne  1b
   mov  r0, #0x80
   swp  r0, r0, [r4]
   str  r0, [r4, #16]
2: ldr  r1, [r4, #12]
   cmn  r1, #1                 @ wait while ARM9 result is 0xFFFFFFFF
   beq  2b
   cmp  r1, #0
   cmpeq r0, #0x40
   beq  swp7_ok
   cmp  r0, #0
   cmpeq r1, #0x80
   bne  report_fail
swp7_ok:
   orr  r9, r9, #32            @ bit 5: cross-CPU SWP was atomic
   str  r9, [r10]

@ ==== done ====
   ldr  r0, =0xBEEF7777
   str  r0, [r10, #4]          @ 0x02FFFF14
hang:
   b    hang

report_fail:
   ldr  r10, =0x02FFFF10
   ldr  r1, =0xBAD00007
   str  r1, [r10, #4]
9: b    9b

   .ltorg
