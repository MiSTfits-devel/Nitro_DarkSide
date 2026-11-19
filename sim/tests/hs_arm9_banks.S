/* SPDX-License-Identifier: GPL-3.0-or-later */
/* CPU-only register-bank fixture for Nds.WholeCore.Arm9Slice: SPSR_svc and
 * SPSR_irq and the three R13/R14 banks (User/System, SVC, IRQ) hold
 * different values at the same time and each reads back its own after the
 * others were written; R0-R12 are shared by every mode. Last, the RRX
 * carry-out on an operand whose bit 0 and bit 31 differ (the ISA fixture's
 * RRX operand has them equal). Mailbox words go to 0x02000000 + 4*slot in
 * order (hand-derived values in hs_arm9_banks.expected); the default image
 * also runs on the product ARM9 RTL. */
.syntax unified
.cpu arm946e-s
.arm
.text

.set slot, 0
.macro put reg
    str     \reg, [r11, #slot*4]
    .set    slot, slot + 1
.endm

    mov     r11, #0x02000000
    ldr     r0, =0x80000010         @ N, User
    msr     spsr_fsxc, r0           @ SPSR_svc
    mov     sp, #0x500
    mov     lr, #0x600
    msr     cpsr_c, #0xd2           @ IRQ
    ldr     r1, =0x4000001f         @ Z, System
    msr     spsr_fsxc, r1           @ SPSR_irq
    mov     sp, #0x100
    mov     lr, #0x200
    mov     r5, #0x55               @ unbanked
    msr     cpsr_c, #0xdf           @ System
    mov     sp, #0x300
    mov     lr, #0x400
    msr     cpsr_c, #0xd3           @ SVC
    mrs     r2, spsr
    put     r2
    put     sp
    put     lr
    put     r5
    msr     cpsr_c, #0xd2
    mrs     r2, spsr
    put     r2
    put     sp
    put     lr
    msr     cpsr_c, #0xdf
    put     sp
    put     lr
    msr     cpsr_c, #0xd3
    mrs     r2, spsr
    put     r2
    put     sp
    put     lr
    msr     cpsr_f, #0              @ C = 0
    mov     r1, #1
    movs    r0, r1, rrx             @ 0, C <- bit 0 = 1
    put     r0
    mrs     r0, cpsr
    put     r0
1:  b       1b
.ltorg
