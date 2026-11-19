/* SPDX-License-Identifier: GPL-3.0-or-later */
/* CPU-only Thumb fixture for Nds.WholeCore.Arm9Slice: the ARMv5T Thumb
 * formats — shifts, add/sub, 8-bit immediates, the 16 ALU operations (MUL
 * with Rd = Rm included), hi-register ops and ADD to PC, PC-relative loads
 * at both halfword alignments, ADD Rd, PC/SP, SP adjust, register,
 * immediate and SP-relative loads and stores, STMIA/LDMIA (base in the
 * list without writeback), PUSH/POP {.., pc}, conditional and
 * unconditional branches and BL. Flags are read by BLX to an ARM helper.
 *
 * Mailbox words go to 0x02000000 + 4*slot in order (hand-derived values in
 * hs_arm9_thumb.expected). Scratch is 0x020000c0..ff (word 0x30..0x3f):
 * S0..S7 at 0x020000c0 and the full-descending stack from 0x02000100.
 * NEG_* builds append one fault after the mailbox; `fault_site` names the
 * reported address. */
.syntax unified
.cpu arm946e-s
.text

.equ ROM, 0xffff0000            @ load address of .text
.set slot, 0
.macro put reg
    .if slot == 32
    adds    r7, #128                @ second mailbox window (sets flags)
    .endif
    str     \reg, [r7, #(slot & 31)*4]
    .set    slot, slot + 1
.endm

.arm
    mov     r7, #0x02000000
    add     sp, r7, #0x100
    adr     r0, thumb_code + 1
    bx      r0
@ R6 <- CPSR, then back to the Thumb caller (LR bit 0 set by BLX).
cpsr_to_r6:
    mrs     r6, cpsr
    bx      lr

.thumb
thumb_code:
/* Shift by immediate, MOV immediate; LSR #32 is encoded as #0. */
    movs    r0, #0x81
    lsls    r1, r0, #24
    blx     cpsr_to_r6
    put     r1
    put     r6
    lsrs    r2, r1, #25
    asrs    r3, r1, #4
    lsrs    r4, r1, #32
    blx     cpsr_to_r6
    put     r2
    put     r3
    put     r4
    put     r6

/* ADD/SUB register and 3-bit immediate; 8-bit immediate with overflow. */
    movs    r0, #5
    subs    r1, r0, #7
    adds    r2, r1, r0
    blx     cpsr_to_r6
    put     r1
    put     r2
    put     r6
    movs    r3, #1
    lsls    r3, r3, #31
    subs    r3, #1
    blx     cpsr_to_r6
    put     r3
    put     r6
    adds    r3, #1
    blx     cpsr_to_r6
    put     r6

/* ALU operations. */
    ldr     r0, =0x0f0f00ff
    ldr     r1, =0x00ff0f0f
    movs    r2, r0
    ands    r2, r1
    put     r2
    movs    r3, r0
    eors    r3, r1
    put     r3
    movs    r4, r0
    bics    r4, r1
    put     r4
    movs    r4, r0
    orrs    r4, r1
    put     r4
    movs    r2, #3
    rors    r1, r2
    put     r1
    lsls    r0, r2
    put     r0
    asrs    r1, r2
    put     r1
    negs    r3, r2
    muls    r3, r2, r3
    muls    r2, r2, r2              @ Rd = Rm
    put     r3
    put     r2
    movs    r4, #10
    movs    r5, #3
    cmp     r4, r5
    adcs    r4, r5
    sbcs    r4, r5
    blx     cpsr_to_r6
    put     r4
    put     r6
    mvns    r0, r5
    movs    r1, #4
    lsrs    r0, r1
    put     r0
    mvns    r2, r5
    cmn     r2, r1
    blx     cpsr_to_r6
    put     r6
    tst     r0, r1
    blx     cpsr_to_r6
    put     r6

/* Hi registers; ADD pc, Rm stays in Thumb. */
    mov     r8, r7
    add     r8, r8
    mov     r0, r8
    put     r0
    movs    r1, #4
    cmp     r8, r1
    blx     cpsr_to_r6
    put     r6
    movs    r1, #2
    add     pc, r1                  @ to pc + 4 + 2
    b       bad
    b       bad

/* PC-relative loads at both alignments and ADD Rd, PC. */
    .balign 4
    ldr     r0, lit_a               @ pc % 4 == 0
    ldr     r1, lit_b               @ pc % 4 == 2
    put     r0
    put     r1
    adr     r2, lit_b
    ldr     r3, [r2]
    put     r3

/* SP adjust and ADD Rd, SP. */
    sub     sp, #16
    add     r0, sp, #12
    add     sp, #8
    mov     r1, sp
    put     r0
    put     r1
    add     sp, #8

/* Loads and stores: immediate, register, halfword, signed, SP-relative. */
    movs    r6, #0x40               @ r7 = 0x02000080 from slot 32 on
    adds    r6, r6, r7              @ &S0
    ldr     r0, =0x89abcdef
    movs    r1, #0
    str     r0, [r6]
    str     r1, [r6, #4]
    strh    r0, [r6, #6]
    movs    r3, #5
    strb    r0, [r6, r3]
    ldr     r2, [r6, #4]
    put     r2
    ldrsb   r4, [r6, r3]
    put     r4
    movs    r3, #2
    ldrsh   r4, [r6, r3]
    put     r4
    ldrh    r4, [r6, r3]
    ldrb    r5, [r6, #7]
    lsls    r5, r5, #16
    orrs    r4, r5
    put     r4
    movs    r3, #8
    str     r4, [r6, r3]
    strh    r0, [r6, r3]
    ldr     r5, [r6, r3]
    put     r5
    ldrh    r5, [r6, #10]
    ldrb    r4, [r6, r3]
    lsls    r4, r4, #16
    orrs    r4, r5
    sub     sp, #8
    str     r4, [sp, #4]
    ldr     r5, [sp, #4]
    add     sp, #8
    put     r5

/* Branches, BL and PUSH/POP {.., pc}. */
    movs    r0, #0
    movs    r1, #5
1:  adds    r0, r0, r1
    subs    r1, #1
    bne     1b
    bgt     bad
    b       2f
    b       bad
2:  put     r0
    movs    r4, #0x44
    .balign 4
    bl      add_seven
after_bl:
    put     r0
    put     r4
    ldr     r2, ret_lit
    subs    r1, r1, r2
    put     r1

/* STMIA/LDMIA. */
    movs    r6, #0x40
    adds    r6, r6, r7
    movs    r0, #1
    movs    r1, #2
    movs    r2, #3
    stmia   r6!, {r0-r2}
    subs    r6, #12
    ldmia   r6!, {r3-r5}
    movs    r0, r6
    put     r0
    lsls    r4, r4, #4
    lsls    r5, r5, #8
    orrs    r3, r4
    orrs    r3, r5
    put     r3
    subs    r6, #8
    ldmia   r6, {r1, r6}            @ base in the list: no writeback
    lsls    r6, r6, #4
    orrs    r6, r1
    put     r6

/* Fault cases outside the subset, one per build. */
.ifdef NEG_BKPT
fault_site:
    bkpt    #0
.endif
.ifdef NEG_UNDEF_COND
fault_site:
    .short  0xde00                  @ B<cond> with cond 1110
.endif
.ifdef NEG_HI_LOW
fault_site:
    .short  0x4408                  @ hi-register ADD r0, r1: both low
.endif
.ifdef NEG_BX_SBZ
fault_site:
    .short  0x4701                  @ BX r0 with SBZ bits set
.endif
.ifdef NEG_BLX_PC
fault_site:
    .short  0x47f8                  @ BLX pc
.endif
.ifdef NEG_BLX_ODD
    .short  0xf000                  @ BL/BLX prefix, offset 0
fault_site:
    .short  0xe801                  @ BLX suffix with bit 0 set
.endif
.ifdef NEG_LDMIA_EMPTY
fault_site:
    .short  0xc800                  @ ldmia r0!, {}
.endif
.ifdef NEG_STMIA_BASE
    movs    r1, #0x40
    adds    r1, r1, r7
fault_site:
    .short  0xc103                  @ stmia r1!, {r0, r1}: base not lowest
.endif
.ifdef NEG_V6
fault_site:
    .short  0xb240                  @ ARMv6 SXTH
.endif
.ifdef NEG_POP_ARM_MISALIGNED
    ldr     r0, =ROM + pop_lit      @ SP at a ROM word: no store after the mailbox
    mov     sp, r0
    pop     {pc}                    @ to ARM at an address with bit 1 set
.endif
done:
    b       done

add_seven:
    push    {r4, lr}
    mov     r1, lr
    movs    r4, #7
    adds    r0, r0, r4
    pop     {r4, pc}

bad:
    movs    r0, #0xba
    put     r0
    b       done

    .balign 4
lit_a:
    .word   0x11223344
lit_b:
    .word   0x55667788
ret_lit:
    .word   ROM + after_bl + 1
.ltorg
.ifdef NEG_POP_ARM_MISALIGNED
    .balign 4
pop_lit:
    .word   ROM + arm_half
    .short  0
arm_half:
    .short  0
    .set    fault_site, arm_half
.endif
