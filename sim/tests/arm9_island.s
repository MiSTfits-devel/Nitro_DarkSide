@ ARM9 island smoke test (roadmap M3). Linked at 0xFFFF0000 and executed as
@ the ARM9 "BIOS" boot ROM (the testbench presets the boot PC the same way the
@ card loader will). Exercises the v5TE additions of nds_cpu9 plus CP15, the
@ TCMs and the high-vector IRQ path. Reports to the mailbox at 0x02FFFF00:
@   +0x00 test result bitmask (one bit per passed test, written incrementally)
@   +0x04 magic 0xCAFEBABE when everything passed / 0xBADBAD00 on failure
@ Build: sim/tests/build_arm9_island.sh (checked-in hex).

   .arch armv5te
   .arm
   .section .text
   .global _start

_start:
   b  reset          @ 0xFFFF0000 reset
   b  hang           @ +0x04 undef
   b  hang           @ +0x08 swi
   b  hang           @ +0x0C prefetch abort
   b  hang           @ +0x10 data abort
   b  hang           @ +0x14 (reserved)
   b  irq_handler    @ +0x18 irq
   b  hang           @ +0x1C fiq

@ =====================================================================
reset:
   @ IRQ-mode stack in main RAM, then system mode
   msr  cpsr_c, #0xD2          @ IRQ mode, I+F set
   ldr  sp, =0x02100F00
   msr  cpsr_c, #0xDF          @ system mode, I+F set
   ldr  sp, =0x02100E00

   ldr  r10, =0x02FFFF00       @ mailbox
   mov  r9, #0                 @ result bitmask

@ ---- test 1: main RAM rw ----
   ldr  r0, =0x02000000
   ldr  r1, =0x11223344
   str  r1, [r0]
   ldr  r2, =0x55667788
   str  r2, [r0, #4]
   ldr  r3, [r0]
   cmp  r3, r1
   bne  report_fail
   ldr  r3, [r0, #4]
   cmp  r3, r2
   bne  report_fail
   mov  r1, #0xAA
   strb r1, [r0, #2]
   ldr  r3, [r0]
   ldr  r4, =0x11AA3344
   cmp  r3, r4
   bne  report_fail
   orr  r9, r9, #1
   str  r9, [r10]

@ ---- test 2: CP15 ID code ----
   mrc  p15, 0, r0, c0, c0, 0
   ldr  r1, =0x41059461
   cmp  r0, r1
   bne  report_fail
   orr  r9, r9, #2
   str  r9, [r10]

@ ---- test 3: DTCM at 0x03800000 (16 KB, size code 5) ----
   ldr  r0, =0x0380000A        @ base | (5 << 1)
   mcr  p15, 0, r0, c9, c1, 0
   mrc  p15, 0, r1, c1, c0, 0
   orr  r1, r1, #0x00010000    @ DTCM enable (bit 16)
   mcr  p15, 0, r1, c1, c0, 0
   ldr  r0, =0x03800000
   ldr  r1, =0xD7C3D7C3
   str  r1, [r0]
   ldr  r2, =0x03803FFC        @ last word of 16 KB
   ldr  r3, =0xD7C3D7C4
   str  r3, [r2]
   ldr  r4, [r0]
   cmp  r4, r1
   bne  report_fail
   ldr  r4, [r2]
   cmp  r4, r3
   bne  report_fail
   orr  r9, r9, #4
   str  r9, [r10]

@ ---- test 4: ITCM (32 KB physical, 32 MB virtual, size code 16) ----
   mov  r0, #0x20              @ 16 << 1
   mcr  p15, 0, r0, c9, c1, 1
   mrc  p15, 0, r1, c1, c0, 0
   orr  r1, r1, #0x00040000    @ ITCM enable (bit 18)
   mcr  p15, 0, r1, c1, c0, 0
   mov  r0, #0
   ldr  r1, =0x17C317C3
   str  r1, [r0]
   ldr  r2, =0x01FFFFFC        @ top of the 32 MB mirror = phys 0x7FFC
   ldr  r3, =0x17C317C4
   str  r3, [r2]
   ldr  r4, [r0]
   cmp  r4, r1
   bne  report_fail
   ldr  r4, [r2]
   cmp  r4, r3
   bne  report_fail
   ldr  r5, =0x00001FFF        @ shifted register offset -> same 0x7FFC word
   ldr  r4, [r0, r5, lsl #2]  @ exercise address-shifter timing boundary
   cmp  r4, r3
   bne  report_fail
   orr  r9, r9, #8
   str  r9, [r10]

@ ---- test 5: CLZ ----
   ldr  r0, =0x00010000
   clz  r1, r0
   cmp  r1, #15
   bne  report_fail
   mov  r0, #0
   clz  r1, r0
   cmp  r1, #32
   bne  report_fail
   mov  r0, #0x80000000
   clz  r1, r0
   cmp  r1, #0
   bne  report_fail
   orr  r9, r9, #16
   str  r9, [r10]

@ ---- test 6: saturating arithmetic + Q flag ----
   msr  cpsr_f, #0             @ clear flags incl. Q
   ldr  r0, =0x7FFFFFFF
   mov  r1, #1
   qadd r2, r0, r1             @ saturates to 0x7FFFFFFF, sets Q
   cmp  r2, r0
   bne  report_fail
   mrs  r3, cpsr
   tst  r3, #0x08000000        @ Q set?
   beq  report_fail
   msr  cpsr_f, #0             @ clear Q
   mov  r0, #100
   mov  r1, #300
   qsub r2, r1, r0             @ 200, no saturation
   cmp  r2, #200
   bne  report_fail
   mrs  r3, cpsr
   tst  r3, #0x08000000
   bne  report_fail            @ Q must be clear
   ldr  r0, =0x40000000
   mov  r1, #0
   qdadd r2, r1, r0            @ 2*0x40000000 saturates to 0x7FFFFFFF, Q set
   ldr  r3, =0x7FFFFFFF
   cmp  r2, r3
   bne  report_fail
   mrs  r3, cpsr
   tst  r3, #0x08000000
   beq  report_fail
   orr  r9, r9, #32
   str  r9, [r10]

@ ---- test 7: DSP multiplies ----
   ldr  r0, =0x00047FFF        @ top = 4, bottom = 0x7FFF
   ldr  r1, =0xFFFE0003        @ top = -2, bottom = 3
   smulbb r2, r0, r1           @ 0x7FFF * 3 = 0x17FFD
   ldr  r3, =0x17FFD
   cmp  r2, r3
   bne  report_fail
   smultt r2, r0, r1           @ 4 * -2 = -8
   cmn  r2, #8
   bne  report_fail
   smulbt r2, r0, r1           @ 0x7FFF * -2 = -0xFFFE
   ldr  r3, =0xFFFF0002
   cmp  r2, r3
   bne  report_fail
   mov  r4, #100
   smlabb r2, r0, r1, r4       @ 0x17FFD + 100
   ldr  r3, =0x18061
   cmp  r2, r3
   bne  report_fail
   ldr  r0, =0x00010000        @ 65536
   ldr  r1, =0x00004000        @ bottom half 0x4000
   smulwb r2, r0, r1           @ (65536 * 0x4000) >> 16 = 0x4000
   cmp  r2, #0x4000
   bne  report_fail
   @ SMLALBB: 64-bit accumulate
   mov  r4, #1                 @ RdLo
   mov  r5, #2                 @ RdHi
   ldr  r0, =0x00007FFF
   ldr  r1, =0x00007FFF
   smlalbb r4, r5, r0, r1      @ acc += 0x7FFF*0x7FFF = 0x3FFF0001
   ldr  r3, =0x3FFF0002
   cmp  r4, r3
   bne  report_fail
   cmp  r5, #2
   bne  report_fail
   orr  r9, r9, #64
   str  r9, [r10]

@ ---- test 8: LDRD/STRD ----
   ldr  r0, =0x02000100
   ldr  r4, =0xAABBCCDD
   ldr  r5, =0x11223355
   strd r4, r5, [r0]
   ldr  r1, [r0]
   cmp  r1, r4
   bne  report_fail
   ldr  r1, [r0, #4]
   cmp  r1, r5
   bne  report_fail
   mov  r6, #0
   mov  r7, #0
   ldrd r6, r7, [r0]
   cmp  r6, r4
   bne  report_fail
   cmp  r7, r5
   bne  report_fail
   ldrd r6, r7, [r0], #8       @ post-indexed with base writeback
   ldr  r1, =0x02000108
   cmp  r0, r1
   bne  report_fail
   orr  r9, r9, #128
   str  r9, [r10]

@ ---- test 9: BLX imm + BLX reg (ARM <-> Thumb) ----
   mov  r6, #0
   blx  thumb_add              @ ARM -> Thumb, r6 += 7 (BLX imm)
   cmp  r6, #7
   bne  report_fail
   ldr  r0, =thumb_add
   orr  r0, r0, #1
   blx  r0                     @ ARM -> Thumb via register
   cmp  r6, #14
   bne  report_fail
   orr  r9, r9, #256
   str  r9, [r10]

@ ---- test 10: LDR-to-PC interworking (v5) ----
   mov  r6, #0
   adr  lr, 1f
   ldr  pc, =thumb_add + 1     @ v5: bit 0 switches to Thumb
1: cmp  r6, #7
   bne  report_fail
   orr  r9, r9, #512
   str  r9, [r10]

@ ---- test 11: high vectors + timer IRQ + wait-for-interrupt ----
   mrc  p15, 0, r1, c1, c0, 0
   orr  r1, r1, #0x00002000    @ vectors at 0xFFFF0000 (bit 13)
   mcr  p15, 0, r1, c1, c0, 0
   ldr  r0, =0x04000208
   mov  r1, #0
   str  r1, [r0]               @ IME = 0
   ldr  r0, =0x04000214
   mvn  r1, #0
   str  r1, [r0]               @ IF = ack everything
   ldr  r0, =0x04000210
   mov  r1, #8                 @ IE = timer0
   str  r1, [r0]
   ldr  r0, =0x04000208
   mov  r1, #1
   str  r1, [r0]               @ IME = 1
   mov  r11, #0
   ldr  r0, =0x04000100
   ldr  r1, =0x00C0FF00        @ reload 0xFF00, enable + overflow IRQ
   str  r1, [r0]
   msr  cpsr_c, #0x1F          @ system mode, IRQs on
   mcr  p15, 0, r0, c7, c0, 4  @ wait for interrupt (halt until timer fires)
   cmp  r11, #0
   beq  report_fail            @ woke without the handler running?
   msr  cpsr_c, #0xDF          @ IRQs off
   mov  r1, #0
   str  r1, [r0]               @ stop timer
   orr  r9, r9, #1024
   str  r9, [r10]

@ ---- test 12: DTCM store-forward (deferred port-B store hazard) ----
@ The DTCM store is presented on M10K port B one cycle AFTER the accept cycle,
@ so a load accepted in the cycle that store commits is a mixed-port
@ read-during-write on Cyclone V and the RAM returns OLD data. nds_membus9
@ merges the pending bytes into the read (see "DTCM deferred store" there).
@ Every pair below is a store immediately followed by a load with no
@ instruction between them, which is the only shape that can reach the hazard.
@ tb_arm9_island counts the port-A-read/port-B-write address collisions and
@ FAILS if the count is zero, so this test cannot pass vacuously.
   ldr  r0, =0x03800100

@ word store -> word load, same address
   ldr  r1, =0xA5A51234
   str  r1, [r0]
   ldr  r2, [r0]
   cmp  r2, r1
   bne  report_fail

@ byte store -> word load: the merge must replace exactly one lane
   ldr  r1, =0x11223344
   str  r1, [r0]
   mov  r3, #0xEE
   strb r3, [r0, #1]
   ldr  r2, [r0]
   ldr  r4, =0x1122EE44
   cmp  r2, r4
   bne  report_fail

@ halfword store -> word load: the merge must replace exactly two lanes
   ldr  r1, =0x55667788
   str  r1, [r0, #4]
   ldr  r3, =0x00009ABC
   strh r3, [r0, #6]
   ldr  r2, [r0, #4]
   ldr  r4, =0x9ABC7788
   cmp  r2, r4
   bne  report_fail

@ word store -> byte load of a lane inside it
   ldr  r1, =0x0F1E2D3C
   str  r1, [r0, #16]
   ldrb r2, [r0, #17]
   cmp  r2, #0x2D
   bne  report_fail

@ store to one address, load a DIFFERENT one: the bypass must NOT fire
   ldr  r1, =0x0BADF00D
   str  r1, [r0, #12]          @ seed the address we will read back
   ldr  r1, =0xDEADBEEF
   str  r1, [r0, #8]
   ldr  r2, [r0, #12]          @ must still be 0x0BADF00D, not 0xDEADBEEF
   ldr  r4, =0x0BADF00D
   cmp  r2, r4
   bne  report_fail
   ldr  r2, [r0, #8]           @ and the store itself must have landed
   ldr  r4, =0xDEADBEEF
   cmp  r2, r4
   bne  report_fail

   orr  r9, r9, #2048
   str  r9, [r10]

@ ---- all passed ----
   ldr  r1, =0xCAFEBABE
   str  r1, [r10, #4]
hang:
   b    hang

report_fail:
   ldr  r10, =0x02FFFF00
   ldr  r1, =0xBADBAD00
   str  r1, [r10, #4]
9: b    9b

@ =====================================================================
irq_handler:
   ldr  r12, =0x04000214
   ldr  r11, [r12]             @ read IF
   str  r11, [r12]             @ ack what fired
   cmp  r11, #0
   moveq r11, #1
   subs pc, lr, #4

@ =====================================================================
   .thumb
   .thumb_func
thumb_add:
   add  r6, #7
   bx   lr

   .arm
   .ltorg
