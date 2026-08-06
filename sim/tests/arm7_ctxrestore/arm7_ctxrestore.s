@ ARM7 exception-return regression: CPSR restored from a SOFTWARE-WRITTEN SPSR.
@
@ This is the DS firmware's task-switch tail, verbatim. The firmware's ARM7
@ scheduler lives at 0x037FE270 in the decompressed boot block and reads:
@
@     msr  spsr_fsxc, r1        @ E16FF001  saved CPSR of the task to resume
@     ldr  sp,  [r0, #0x40]     @ E590D040  handler-mode sp
@     ldr  lr,  [r0, #0x3C]     @ E590E03C  handler-mode lr = resume address
@     ldm  r0,  {r0-lr}^        @ E8D07FFF  restore the USER/SYSTEM bank
@     nop                       @ E1A00000  required delay slot after ldm ^
@     subs pc,  lr, #4          @ E25EF004  return: pc = lr-4, CPSR = SPSR
@
@ The T bit of the resumed task therefore comes from a value SOFTWARE put in
@ SPSR, not from one the hardware saved on exception entry. Nothing in the GBA
@ library code exercises that: a GBA IRQ handler returns through the SPSR the
@ hardware wrote for it, so `msr spsr` -> `subs pc, lr, #4` could be wrong for
@ years without a single GBA title noticing. A preemptive scheduler notices
@ immediately, because resuming a Thumb task is the common case.
@
@ Failure signature to expect if T is lost - it is why thumb_resume opens with
@ these two specific instructions. As Thumb they are two harmless `mov`s; the
@ word they assemble to is 0x1C0E1C05, which as ARM is condition NE with
@ bits 27-25 = 110, i.e. a coprocessor load/store that ARM7TDMI does not
@ implement. So a lost T bit reports, byte for byte, the same thing firmware
@ boot reports at 1.588 s:
@
@     ARM7 decode: unhandled opcode 1C0E1C05 thumb=0 pc=...
@
@ Mailbox at 0x02FFFF00, snooped by tb_arm7_island on the main-RAM bus:
@   +0x00 bitmask of passed sub-tests
@   +0x04 0xCAFEBABE once all of them passed (bitmask 0xF)
@
@ Build: sim/tests/arm7_ctxrestore/build.sh   (checked-in hex; no toolchain
@ needed on the sim host)
@ Run:   HEXFILE=sim/tests/arm7_ctxrestore.hex TIMEOUT_MS=45 sim/run_arm7_island.sh

   .arch armv4t
   .arm
   .section .text
   .global _start

_start:
   b  reset          @ 0x00 reset
   b  hang           @ 0x04 undef
   b  swi_handler    @ 0x08 swi
   b  hang           @ 0x0C prefetch abort
   b  hang           @ 0x10 data abort
   b  hang           @ 0x14 (reserved)
   b  irq_handler    @ 0x18 irq
   b  hang           @ 0x1C fiq

@ =====================================================================
reset:
   msr  cpsr_c, #0xD2          @ IRQ mode, I+F set. sp_irq is banked and the IRQ
   ldr  sp, =0x03800F80        @ handler pushes, so it needs its own stack -
                               @ without this the push lands at address 0
   msr  cpsr_c, #0xD3          @ Supervisor, I+F set
   ldr  sp, =0x03800F00
   msr  cpsr_c, #0xDF          @ System, I+F set
   ldr  sp, =0x03800E00

   ldr  r10, =0x02FFFF00       @ mailbox, for the ARM sections
   mov  r4, r10                @ ...and a LOW register for the Thumb sections:
                               @ Thumb-16 str cannot use r8-r12 as a base
   mov  r1, #0
   str  r1, [r10]

@ ---------------------------------------------------------------------
@ Sub-test 0: does `msr spsr_fsxc, Rm` actually land in SPSR, T bit and all?
@ Checked with mrs before anything depends on it, so a broken SPSR write is
@ distinguishable from a broken exception return.
@ ---------------------------------------------------------------------
   msr  cpsr_c, #0xD3          @ Supervisor: has an SPSR
   ldr  r1, =0x0000003F        @ System mode + T set + IRQs enabled
   msr  spsr_fsxc, r1
   mrs  r2, spsr
   msr  cpsr_c, #0xDF          @ back to System
   cmp  r2, r1
   bne  fail
   mov  r1, #1
   str  r1, [r10]

@ ---------------------------------------------------------------------
@ Sub-test 1: the SAVE side. Take a real exception from THUMB state and check
@ the hardware put T into SPSR, then return through it.
@
@ Sub-test 2 below writes SPSR by hand, so it cannot see a broken exception
@ ENTRY. This one can: if entry drops T, `mrs r1, spsr` shows bit 5 clear, and
@ `movs pc, lr` would return to Thumb code in ARM state.
@ ---------------------------------------------------------------------
   ldr  r5, =arm_after_swi     @ even -> bx returns to ARM
   adr  r0, thumb_swi
   orr  r0, r0, #1             @ odd -> bx enters Thumb
   bx   r0

   .balign 4
   .thumb
   .thumb_func
thumb_swi:
   swi  #0                     @ SPSR_svc must capture System mode + T
   movs r0, #3                 @ sub-tests 0 and 1 passed
   str  r0, [r4]
   bx   r5

   .arm
arm_after_swi:

@ ---------------------------------------------------------------------
@ Sub-test 2: an IRQ taken from THUMB state, which is how a preemptive
@ scheduler actually gets in. Sub-test 1 used `swi`, and IRQ entry is a separate
@ decode path in gba_cpu (decode_functions_detail = IRQ vs
@ software_interrupt_detail) with its own lr arithmetic, so a T bit lost on IRQ
@ entry alone would sail straight through sub-test 1.
@ ---------------------------------------------------------------------
   mov  r12, #0x04000000
   mov  r0, #8
   str  r0, [r12, #0x210]      @ IE = timer 0
   mov  r0, #1
   str  r0, [r12, #0x208]      @ IME = 1
   ldr  r0, =0x00C0FF00        @ TM0CNT: enable + IRQ, reload 0xFF00
   str  r0, [r12, #0x100]

   ldr  r6, =irqcount          @ r6 survives IRQ mode: only r13/r14 are banked
   mov  r0, #0
   str  r0, [r6]

   ldr  r5, =arm_after_irq     @ even -> bx returns to ARM
   adr  r0, thumb_irqwait
   orr  r0, r0, #1
   msr  cpsr_c, #0x1F          @ System, IRQs ENABLED
   bx   r0

   .balign 4
   .thumb
   .thumb_func
thumb_irqwait:
   ldr  r0, [r6]               @ each of these IRQs interrupts THUMB code
   cmp  r0, #3
   blt  thumb_irqwait
   bx   r5

   .arm
arm_after_irq:
   msr  cpsr_c, #0xDF          @ System, IRQs off again
   mov  r1, #7                 @ sub-tests 0, 1, 2 passed
   str  r1, [r10]

@ ---------------------------------------------------------------------
@ Sub-test 3: the firmware's context restore, resuming a THUMB task.
@ ---------------------------------------------------------------------
   @ Build the saved-context block. Layout is the firmware's: r0..r14 at
   @ +0x00..+0x38, the resume address at +0x3C, handler sp at +0x40. Note
   @ +0x38 (r14_user) and +0x3C (resume address) are DIFFERENT slots - a core
   @ whose `ldm ^` wrote the current mode's r14 instead of the user bank would
   @ return to r14_user and land nowhere near thumb_resume.
   ldr  r0, =ctxblock
   mov  r1, #0
   mov  r2, #15                @ zero r0..r14 slots
zeroloop:
   str  r1, [r0], #4
   subs r2, r2, #1
   bne  zeroloop

   ldr  r0, =ctxblock
   ldr  r1, =0xCAFEBABE
   str  r1, [r0, #0x0C]        @ r3  = magic
   ldr  r1, =0x02FFFF00
   str  r1, [r0, #0x10]        @ r4  = mailbox
   @ Distinctive values for the registers `ldm ^` has to bring back. r12 is the
   @ one that matters most: the firmware's scheduler resumes a task inside the
   @ BIOS SWI dispatcher one instruction before `bx ip`, so a wrong r12 is a
   @ branch to whatever that word happens to be - measured on hardware as a jump
   @ to 0x04000138 (the RTC register) and a runaway PC.
   @
   @ On ARM7TDMI only r13/r14 are banked outside FIQ - r8-r12 are banked ONLY in
   @ FIQ - so `ldm ^` executed in Supervisor must land r8-r12 in the very same
   @ registers Supervisor and System already share.
   ldr  r1, =arm_check          @ r2 = even address -> bx returns to ARM
   str  r1, [r0, #0x08]
   ldr  r1, =0x77777777
   str  r1, [r0, #0x1C]        @ r7
   ldr  r1, =0x88888888
   str  r1, [r0, #0x20]        @ r8
   ldr  r1, =0x99999999
   str  r1, [r0, #0x24]        @ r9
   ldr  r1, =0xAAAAAAAA
   str  r1, [r0, #0x28]        @ r10
   ldr  r1, =0xBBBBBBBB
   str  r1, [r0, #0x2C]        @ r11
   ldr  r1, =0xCCCCCCCC
   str  r1, [r0, #0x30]        @ r12
   ldr  r1, =0x03800D00
   str  r1, [r0, #0x34]        @ r13 = a usable System stack
   ldr  r1, =0xDEADBEEF
   str  r1, [r0, #0x38]        @ r14_user: must NOT become the return address
   ldr  r1, =thumb_resume+4  @ +0x3C: subs pc, lr, #4 -> thumb_resume
   str  r1, [r0, #0x3C]
   ldr  r1, =0x03800F00
   str  r1, [r0, #0x40]        @ handler-mode sp

   @ ---- the sequence under test, instruction for instruction ----
   msr  cpsr_c, #0xD3          @ Supervisor, as the firmware's handler is
   ldr  r0, =ctxblock
   ldr  r1, =0x0000003F        @ resume in System mode, THUMB, IRQs enabled
   msr  spsr_fsxc, r1
   ldr  sp, [r0, #0x40]
   ldr  lr, [r0, #0x3C]
   ldm  r0, {r0-r12, sp, lr}^
   nop
   subs pc, lr, #4

@ ---------------------------------------------------------------------
   .balign 4
   .thumb
   .thumb_func
thumb_resume:
   @ 0x1C05 then 0x1C0E -> the word 0x1C0E1C05. See the header: this is the
   @ opcode a lost T bit reports, and it is deliberately the firmware's.
   @ Emitted as raw halfwords because gas will not assemble the Thumb-16
   @ `adds rD, rN, #0` form these encode, and the exact word is the point.
   .short 0x1C05               @ adds r5, r0, #0   (clobbers r5)
   .short 0x1C0E               @ adds r6, r1, #0   (clobbers r6)
   bx   r2                     @ -> arm_check, where r8-r12 are reachable

@ ---------------------------------------------------------------------
@ Sub-test 3b: did `ldm ^` actually restore r7-r12? Thumb-16 cannot compare the
@ high registers, hence the trip back to ARM. r5/r6 are deliberately NOT checked:
@ the two filler halfwords above overwrite them, which is the price of keeping
@ the exact 0x1C0E1C05 word at the resume target.
   .arm
   .balign 4
arm_check:
   @ Report EVERY mismatch, not just the first: bit N set = rN came back wrong.
   @ The bitmask is OR'd with 0x10000 so it cannot be mistaken for a normal
   @ sub-test bitmask in the tb's report.
   mov  r1, #0
   ldr  r0, =0x77777777
   cmp  r7, r0
   orrne r1, r1, #(1 << 7)
   ldr  r0, =0x88888888
   cmp  r8, r0
   orrne r1, r1, #(1 << 8)
   ldr  r0, =0x99999999
   cmp  r9, r0
   orrne r1, r1, #(1 << 9)
   ldr  r0, =0xAAAAAAAA
   cmp  r10, r0
   orrne r1, r1, #(1 << 10)
   ldr  r0, =0xBBBBBBBB
   cmp  r11, r0
   orrne r1, r1, #(1 << 11)
   ldr  r0, =0xCCCCCCCC
   cmp  r12, r0
   orrne r1, r1, #(1 << 12)
   cmp  r1, #0
   bne  failreg
   mov  r0, #15                @ all four sub-tests passed
   str  r0, [r4, #0]
   str  r3, [r4, #4]           @ 0xCAFEBABE -> tb reports PASS
thumb_park:
   b    thumb_park

@ ---------------------------------------------------------------------
@ IRQ handler. r6 and r10 are not banked in IRQ mode, so the counter and the
@ mailbox pointer are both reachable from here.
   .arm
irq_handler:
   push {r0-r3, r12, lr}
   mrs  r1, spsr
   and  r2, r1, #0x20          @ it interrupted Thumb, so T must be set
   cmp  r2, #0x20
   bne  fail
   ldr  r12, =0x04000214
   ldr  r2, [r12]
   str  r2, [r12]              @ ack whatever fired
   ldr  r2, [r6]
   add  r2, r2, #1
   str  r2, [r6]
   pop  {r0-r3, r12, lr}
   subs pc, lr, #4             @ return: CPSR = SPSR, so back into Thumb

@ ---------------------------------------------------------------------
@ SWI handler. Runs in Supervisor; r10 is not banked, so the mailbox pointer
@ survives a branch to `fail` from here.
   .arm
swi_handler:
   mrs  r1, spsr
   and  r2, r1, #0x20          @ T must be set: the swi came from Thumb
   cmp  r2, #0x20
   bne  fail
   and  r2, r1, #0x1F          @ ...and the mode must be the caller's, System
   cmp  r2, #0x1F
   bne  fail
   movs pc, lr                 @ return: CPSR = SPSR, so back into Thumb

@ ---------------------------------------------------------------------
   .arm
failreg:
   ldr  r10, =0x02FFFF00
   orr  r1, r1, #0x10000
   str  r1, [r10]              @ which registers came back wrong
   ldr  r1, =0xBADBAD00
   str  r1, [r10, #4]
   b    hang

   .arm
fail:
   @ Reload the mailbox pointer rather than trusting r10: sub-test 3 restores
   @ r10 = 0xAAAAAAAA from the context block, so a failure reported through the
   @ old r10 would store to 0xAAAAAAAE and the tb would see nothing at all.
   ldr  r10, =0x02FFFF00
   ldr  r1, =0xBADBAD00
   str  r1, [r10, #4]
hang:
   b    hang

   .balign 4
   .section .bss
   .equ ctxblock, 0x02000200
   .equ irqcount, 0x02000100
