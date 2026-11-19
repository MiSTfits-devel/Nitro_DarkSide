/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Thumb IRQ fixture for Nds.WholeCore.Arm9Soc: IRQ entry from Thumb state
 * (R14_irq = next instruction + 4, SPSR_irq.T) and return to Thumb through
 * SPSR.T by both forms (SUBS pc, lr, #4 and LDM {.., pc}^), with real timer
 * 0 overflows through IF, and an IRQ taken between the two halves of a
 * Thumb BL, which must still reach its target with the right link.
 *
 *   A  timer 0 IF pending under CPSR.I; MOVS pc, lr with SPSR = Thumb, I
 *      clear: the IRQ is taken before the first Thumb instruction.
 *   B  timer 0 restarted from Thumb, IRQ during a Thumb loop, LDM^ return.
 *   C  IF bit 1 raised by the harness in the cycle the BL prefix at
 *      `bl_prefix` retires: the IRQ is taken before the suffix.
 *
 * Mailbox words go to 0x02000000 + 4*slot in order (hand-derived values in
 * hs_arm9_thumb_irq.expected). Scratch is 0x020000c0..ff: the handler's
 * log S0..S3 and the IRQ stack below 0x02000100. The product RTL has no
 * harness IRQ source, so its PRODUCT_ORACLE run checks slots 0..6 (A, B). */
.syntax unified
.cpu arm946e-s
.text

.equ ROM, 0xffff0000            @ load address of .text
.set slot, 0
.macro tput reg                 @ Thumb; r7 = 0x02000000
    str     \reg, [r7, #slot*4]
    .set    slot, slot + 1
.endm

.arm
/* High vectors at 0xffff0000. */
    b       reset
    b       bad                     @ undefined instruction
    b       bad                     @ SWI
    b       bad                     @ prefetch abort
    b       bad                     @ data abort
    b       bad                     @ reserved
    b       irq_entry               @ IRQ
    b       bad                     @ FIQ

reset:
    mov     r11, #0x02000000
    mov     r7, r11
    mov     r10, #0                 @ handler return form: SUBS pc, lr, #4
    msr     cpsr_c, #0xd2
    add     sp, r11, #0x100         @ IRQ stack
    msr     cpsr_c, #0xd3
    ldr     r4, =0x04000208         @ IME
    ldr     r5, =0x04000210         @ IE; IF at +4
    ldr     r6, =0x04000100         @ TM0CNT
    mov     r0, #0
    str     r0, [r11, #0xc8]        @ S2: IRQ count
    mov     r0, #8
    str     r0, [r5]                @ IE = timer 0
    mov     r0, #1
    str     r0, [r4]                @ IME = 1
    ldr     r0, =0x00c0fff0
    str     r0, [r6]                @ timer 0: reload fff0, F/1, IRQ, start
1:  ldr     r0, [r5, #4]
    tst     r0, #8
    beq     1b

/* A: exception return into Thumb with the IRQ pending. */
    ldr     r0, =0x60000033         @ Z, C, Thumb, SVC, I = F = 0
    msr     spsr_fsxc, r0
    adr     lr, t_a
    movs    pc, lr
.thumb
.balign 4
t_a:
    movs    r0, #0x11
    movs    r3, #0xc0
    adds    r3, r3, r7              @ &S0
    ldr     r1, [r3]
    tput    r1
    ldr     r1, [r3, #4]
    ldr     r2, =ROM + t_a
    subs    r1, r1, r2
    tput    r1
    tput    r0
    ldr     r1, [r3, #8]
    tput    r1

/* B: IRQ during a Thumb loop, LDM^ return. */
    movs    r0, #1
    mov     r10, r0
    ldr     r0, =0x00c0fff0
    str     r0, [r6]
    movs    r1, #2
1:  ldr     r0, [r3, #8]
    cmp     r0, r1
    bne     1b
    tput    r0
    ldr     r0, [r3]
    lsls    r0, r0, #24
    lsrs    r0, r0, #24
    tput    r0
    ldr     r0, [r3, #12]
    tput    r0

.ifdef PRODUCT_ORACLE
    b       done
.endif

/* C: IRQ between the BL prefix and suffix (harness IF bit 1). */
    movs    r0, #0
    mov     r10, r0
    movs    r0, #0x0a
    str     r0, [r5]                @ IE = timer 0 | HBlank
    movs    r0, #5
bl_prefix:
    bl      t_add3
bl_done:
    tput    r0
    ldr     r0, [r3]
    lsls    r0, r0, #24
    lsrs    r0, r0, #24
    tput    r0
    ldr     r0, [r3, #4]
    ldr     r2, =ROM + bl_prefix
    subs    r0, r0, r2
    tput    r0
    mov     r0, r12
    ldr     r2, =ROM + bl_done + 1
    subs    r0, r0, r2
    tput    r0
    ldr     r0, [r3, #8]
    tput    r0
done:
    b       done

t_add3:
    adds    r0, #3
    mov     r12, lr
    bx      lr
.ltorg

.arm
.balign 4
/* IRQ: log SPSR (S0), R14_irq (S1), the return form (S3); count (S2);
 * acknowledge IF; stop timer 0. r10 = 0: SUBS pc, lr, #4; else LDM^. The
 * choice is a branch: a cond-failed SUBS pc corrupts the banks on the
 * product RTL (the known skipped MOVSNE pc, lr deviation). */
irq_entry:
    stmfd   sp!, {r0-r2}
    mrs     r0, spsr
    str     r0, [r11, #0xc0]
    str     lr, [r11, #0xc4]
    str     r10, [r11, #0xcc]
    ldr     r0, [r11, #0xc8]
    add     r0, r0, #1
    str     r0, [r11, #0xc8]
    ldr     r1, =0x04000100
    mov     r2, #0
    strh    r2, [r1, #2]            @ stop timer 0
    ldr     r1, =0x04000214
    ldr     r2, [r1]
    str     r2, [r1]                @ acknowledge every pending IF bit
    cmp     r10, #0
    ldmfd   sp!, {r0-r2}
    bne     ldm_return
    subs    pc, lr, #4
ldm_return:
    sub     lr, lr, #4
    stmfd   sp!, {r0-r2, lr}
    ldmfd   sp!, {r0-r2, pc}^

bad:
    mov     r0, #0xba
    str     r0, [r11, #0x80]
    b       bad
.ltorg
