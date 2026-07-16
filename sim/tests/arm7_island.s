@ ARM7 island smoke test (roadmap M2). Runs as the "BIOS" at 0x00000000.
@ Exercises main RAM, shared WRAM, VRAM-C-as-ARM7-WRAM, timer 0 (poll +
@ overflow IRQ) and IPC (SYNC echo + FIFO loopback, echoed by the testbench
@ playing ARM9). Reports progress to the mailbox at 0x02FFFF00, which the
@ testbench snoops on the main-RAM bus:
@   +0x00 test result bitmask (one bit per passed test, written incrementally)
@   +0x04 magic 0xCAFEBABE when everything passed
@ Build: sim/tests/build_arm7_island.sh (checked-in hex, toolchain not needed
@ on the sim host).

   .arch armv4t
   .arm
   .section .text
   .global _start

_start:
   b  reset          @ 0x00 reset
   b  hang           @ 0x04 undef
   b  hang           @ 0x08 swi
   b  hang           @ 0x0C prefetch abort
   b  hang           @ 0x10 data abort
   b  hang           @ 0x14 (reserved)
   b  irq_handler    @ 0x18 irq
   b  hang           @ 0x1C fiq

@ =====================================================================
reset:
   @ IRQ-mode stack, then switch to system mode with its own stack
   msr  cpsr_c, #0xD2          @ IRQ mode, I+F set
   ldr  sp, =0x03800F00
   msr  cpsr_c, #0xDF          @ system mode, I+F set
   ldr  sp, =0x03800E00

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
   @ byte + halfword granularity
   mov  r1, #0xAA
   strb r1, [r0, #2]
   ldr  r3, [r0]
   ldr  r4, =0x11AA3344
   cmp  r3, r4
   bne  report_fail
   orr  r9, r9, #1
   str  r9, [r10]

@ ---- test 2: shared WRAM (WRAMCNT=3: all 32K ours at 0x03000000) ----
   ldr  r0, =0x03000000
   ldr  r1, =0xDEAD0001
   str  r1, [r0]
   ldr  r2, =0x03007FFC        @ last word
   ldr  r3, =0xDEAD0002
   str  r3, [r2]
   ldr  r4, [r0]
   cmp  r4, r1
   bne  report_fail
   ldr  r4, [r2]
   cmp  r4, r3
   bne  report_fail
   orr  r9, r9, #2
   str  r9, [r10]

@ ---- test 3: VRAM bank C as ARM7 WRAM (VRAMCNT_C = ena|MST2|OFS0) ----
   ldr  r0, =0x06000000
   ldr  r1, =0xB000C000
   str  r1, [r0]
   ldr  r2, =0x0601FFFC        @ last word of the 128K bank
   ldr  r3, =0xB000C001
   str  r3, [r2]
   ldr  r4, [r0]
   cmp  r4, r1
   bne  report_fail
   ldr  r4, [r2]
   cmp  r4, r3
   bne  report_fail
   orr  r9, r9, #4
   str  r9, [r10]

@ ---- test 4: timer 0 polling (prescaler /1) ----
   ldr  r0, =0x04000100
   mov  r1, #0
   str  r1, [r0]               @ stop, reload 0
   ldr  r1, =0x00800000        @ enable (bit23 of CNT dword = CNT_H bit7)
   str  r1, [r0]
   mov  r2, #64                @ spin some cycles
1: subs r2, r2, #1
   bne  1b
   ldrh r3, [r0]               @ read count
   cmp  r3, #0
   beq  report_fail            @ must have advanced
   mov  r1, #0
   str  r1, [r0]               @ stop
   orr  r9, r9, #8
   str  r9, [r10]

@ ---- test 5: timer 0 overflow IRQ ----
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
   ldr  r11, =0                @ irq flag (r11 set by handler)
   ldr  r0, =0x04000100
   @ reload 0xFF00: 256-tick period, long enough that the handler finishes
   @ and the wait loop makes progress between overflows (0xFFF0 = 16 ticks
   @ re-enters the handler faster than it exits)
   ldr  r1, =0x00C0FF00        @ reload 0xFF00, enable + overflow IRQ
   str  r1, [r0]
   msr  cpsr_c, #0x1F          @ system mode, IRQs on
   mov  r2, #4096
2: subs r2, r2, #1
   cmp  r11, #0
   bne  3f
   cmp  r2, #0
   bne  2b
   b    report_fail            @ no IRQ arrived
3: msr  cpsr_c, #0xDF          @ IRQs off again
   mov  r1, #0
   str  r1, [r0]               @ stop timer
   orr  r9, r9, #16
   str  r9, [r10]

@ ---- test 6: IPCSYNC echo (tb echoes our nibble back) ----
   ldr  r0, =0x04000180
   mov  r1, #0x500             @ our data-out nibble = 5 (bits 11:8)
   str  r1, [r0]
   mov  r2, #4096
4: ldr  r3, [r0]
   and  r3, r3, #0x0F          @ data-in nibble
   cmp  r3, #5
   beq  5f
   subs r2, r2, #1
   bne  4b
   b    report_fail
5: orr  r9, r9, #32
   str  r9, [r10]

@ ---- test 7: IPC FIFO loopback (tb reads our word, sends it back +1) ----
   ldr  r0, =0x04000184
   ldr  r1, =0x0000C008        @ enable fifo, clear send, error ack
   str  r1, [r0]
   ldr  r2, =0x13572468
   ldr  r3, =0x04000188
   str  r2, [r3]               @ send
   mov  r4, #8192
6: ldr  r5, [r0]
   tst  r5, #0x100             @ recv empty?
   beq  7f
   subs r4, r4, #1
   bne  6b
   b    report_fail
7: ldr  r6, =0x04100000
   ldr  r5, [r6]               @ recv word
   add  r2, r2, #1
   cmp  r5, r2
   bne  report_fail
   orr  r9, r9, #64
   str  r9, [r10]

@ ---- all passed ----
   ldr  r1, =0xCAFEBABE
   str  r1, [r10, #4]
hang:
   b    hang

report_fail:
   ldr  r1, =0xBADBAD00
   str  r1, [r10, #4]
8: b    8b

@ =====================================================================
irq_handler:
   ldr  r12, =0x04000214
   ldr  r11, [r12]             @ read IF
   str  r11, [r12]             @ ack what fired
   cmp  r11, #0
   moveq r11, #1               @ ensure nonzero flag either way
   subs pc, lr, #4

   .ltorg
