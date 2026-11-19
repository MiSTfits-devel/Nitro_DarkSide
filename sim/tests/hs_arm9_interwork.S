/* SPDX-License-Identifier: GPL-3.0-or-later */
/* CPU-only interworking, multiply, CLZ, SWI and mode fixture for
 * Nds.WholeCore.Arm9Slice:
 *   * BX/BLX (register) ARM <-> Thumb, ARM BLX <imm> with H = 0 and 1,
 *     Thumb BLX <imm> to ARM from both halfword alignments (one with bit 1
 *     of the computed target set), Thumb BLX Rm to ARM and Thumb, BX pc,
 *     LDR pc / LDM {.., pc} / POP {pc} switching state on bit 0, and an
 *     exception return (MOVS pc, lr) into Thumb through SPSR.T;
 *   * MUL/MLA/UMULL/UMLAL/SMULL/SMLAL with N/Z and C/V kept, overlapping
 *     Rd/Rm and RdLo/RdHi/Rm operands, CLZ;
 *   * SWI from ARM and Thumb (high vector 0xffff0008, R14_svc, SPSR_svc,
 *     the comment field read back through LR), System and User modes with
 *     the shared R13/R14 bank, User-mode MSR writing only the flags, and
 *     SPSR access in SVC.
 * Mailbox words go to 0x02000000 + 4*slot in order (hand-derived values in
 * hs_arm9_interwork.expected); scratch is 0x020000e0..ff (word 0x38..0x3f).
 * The PRODUCT_ORACLE build first copies the CPSR into SPSR_svc: the product
 * RTL loads the CPSR flags and F from the old SPSR of the target mode on
 * exception entry instead of keeping them, which slot 37 would show.
 * NEG_* builds append one fault after the mailbox; `fault_site` names the
 * reported address. */
.syntax unified
.cpu arm946e-s
.text

.equ ROM, 0xffff0000            @ load address of .text
.set slot, 0
.macro put reg                  @ ARM; r11 = 0x02000000
    str     \reg, [r11, #slot*4]
    .set    slot, slot + 1
.endm
.macro tput reg                 @ Thumb; r7 = 0x02000000, 0x02000080 from slot 32
    str     \reg, [r7, #(slot & 31)*4]
    .set    slot, slot + 1
.endm

.arm
/* High vectors at 0xffff0000. */
    b       reset
    b       bad                     @ undefined instruction
    b       swi_entry               @ SWI
    b       bad                     @ prefetch abort
    b       bad                     @ data abort
    b       bad                     @ reserved
    b       bad                     @ IRQ
    b       bad                     @ FIQ

reset:
    mov     r11, #0x02000000
    mov     r7, r11
    add     sp, r11, #0x100

/* BX to Thumb and back. */
    adr     r0, t_bx + 1
    bx      r0
    b       bad
.thumb
t_bx:
    movs    r1, #0x5a
    ldr     r2, =ROM + a_back
    bx      r2
.arm
.balign 4
a_back:
    put     r1
    mrs     r0, cpsr
    put     r0

/* ARM BLX register and immediate (H = 0 and H = 1) into Thumb. */
    mov     r0, #21
    ldr     r3, =ROM + t_double + 1
    blx     r3
blx_ret:
    put     r0
    adr     r1, blx_ret
    sub     r2, lr, r1
    put     r2
    blx     t_inc_h                 @ H = 1: target at pc % 4 == 2
    put     r0
    blx     t_double                @ H = 0
    put     r0

/* Thumb calls into ARM and Thumb: BLX Rm both ways, BLX <imm> from both
 * halfword alignments. */
    adr     r0, t_calls + 1
    bx      r0
.thumb
t_calls:
    movs    r0, #1
    ldr     r3, =ROM + a_add16
    blx     r3                      @ to ARM
    ldr     r3, =ROM + t_shl1 + 1
    blx     r3                      @ to Thumb
    tput    r0
    .balign 4
    blx     a_add16                 @ pc % 4 == 0
    movs    r1, r1
blx_odd:
    blx     a_add16                 @ pc % 4 == 2: (pc + 4 + offset) has bit 1 set
after_odd:
    tput    r0
    mov     r1, r12
    ldr     r2, =ROM + after_odd + 1
    subs    r1, r1, r2
    tput    r1
    .balign 4
    bx      pc                      @ to ARM at pc + 4
    nop
.arm
/* LDR pc into Thumb, POP {pc} back to ARM. */
    ldr     pc, =ROM + t_ldr + 1
.thumb
t_ldr:
    movs    r0, #0x77
    ldr     r1, =ROM + a_pop
    push    {r1}
    pop     {pc}                    @ bit 0 clear: ARM
.ltorg
.arm
.balign 4
a_pop:
    put     r0
    mrs     r0, cpsr
    and     r0, r0, #0xff
    put     r0

/* LDM {.., pc} into Thumb; BX pc back. */
    add     r0, r11, #0xe0
    mov     r2, #0x33
    ldr     r1, =ROM + t_ldm + 1
    str     r2, [r0]
    str     r1, [r0, #4]
    ldmia   r0, {r2, pc}
.thumb
.balign 4
t_ldm:
    adds    r2, #1
    tput    r2
    bx      pc
    nop
.arm

/* Exception return into Thumb: SPSR_svc with T, MOVS pc, lr. */
    ldr     r0, =0x200000f3         @ C, I, F, T, SVC
    msr     spsr_fsxc, r0
    mrs     r1, spsr
    put     r1
    adr     lr, t_ret
    movs    pc, lr
.thumb
.balign 4
t_ret:
    movs    r0, #0x66               @ keeps C from the SPSR
    tput    r0
    bx      pc
    nop
.arm
    mrs     r0, cpsr
    put     r0

/* Multiplies: N/Z set, C/V kept. */
    msr     cpsr_f, #0x30000000     @ C, V
    ldr     r1, =0x12345678
    ldr     r2, =0x9abcdef0
    muls    r0, r1, r2
    mrs     r3, cpsr
    put     r0
    put     r3
    mov     r4, #0x100
    mla     r5, r1, r2, r4
    put     r5
    mov     r4, #7
    mov     r5, #6
    .inst   0xe0040594              @ mul r4, r4, r5 (Rd = Rm)
    put     r4
    umulls  r4, r5, r1, r2
    mrs     r3, cpsr
    put     r4
    put     r5
    put     r3
    mov     r4, #0x100
    mov     r5, #1
    umlal   r4, r5, r1, r2
    put     r4
    put     r5
    smull   r4, r5, r1, r2
    put     r4
    put     r5
    mvn     r4, #0
    mvn     r5, #0
    smlals  r4, r5, r1, r2
    mrs     r3, cpsr
    put     r4
    put     r5
    put     r3
    mov     r0, #3
    .inst   0xe0810290              @ umull r0, r1, r0, r2 (RdLo = Rm)
    put     r0
    put     r1
    mov     r2, #5
    mov     r3, #-4
    mov     r4, #0x10
    .inst   0xe0e32493              @ smlal r2, r3, r3, r4 (RdHi = Rm)
    put     r2
    put     r3
    mov     r6, #0
    muls    r0, r2, r6
    mrs     r3, cpsr
    put     r3

/* CLZ. */
    mov     r0, #0
    mov     r1, #1
    mov     r2, #0x80000000
    mov     r3, #0x00010000
    clz     r0, r0
    clz     r1, r1
    clz     r2, r2
    clz     r3, r3
    orr     r0, r0, r1, lsl #8
    orr     r0, r0, r2, lsl #16
    orr     r0, r0, r3, lsl #24
    put     r0

/* SWI from SVC (ARM). */
    msr     cpsr_f, #0x40000000     @ Z
.ifdef PRODUCT_ORACLE
    mrs     r0, cpsr
    msr     spsr_fsxc, r0
.endif
    swi     #0x123456
swi_ret:
    put     r10
    put     r12
    put     r8
    adr     r0, swi_ret
    sub     r0, r9, r0
    put     r0

/* System mode: SWI keeps R13/R14_sys and sets R14_svc. */
    msr     cpsr_c, #0xdf
    mov     sp, #0x1000
    mov     lr, #0x2000
    swi     #0x10
sys_ret:
    put     r12
    mrs     r0, cpsr
    put     r0
    add     r0, sp, lr
    put     r0
    msr     cpsr_c, #0xd3
    adr     r0, sys_ret
    sub     r0, lr, r0
    put     r0

/* User mode: shares the System bank; MSR writes only the flags. */
    msr     cpsr_c, #0xdf
    msr     cpsr_c, #0xd0
    add     r0, sp, lr
    put     r0
    msr     cpsr_c, #0xd3           @ ignored in User mode
    ldr     r0, =0x600000df
    msr     cpsr_fc, r0             @ flags only
    mrs     r0, cpsr
    put     r0
    swi     #0x40                   @ handler continues in SVC
    put     r12
    mrs     r0, cpsr
    put     r0

/* SWI from Thumb; the handler returns to Thumb through SPSR.T. */
    msr     cpsr_f, #0
    add     r7, r11, #0x80
    adr     r0, t_swi + 1
    bx      r0
.thumb
.balign 4
t_swi:
    svc     #0x12
t_swi_ret:
    mov     r0, r10
    tput    r0
    mov     r0, r12
    tput    r0
    mov     r0, r9
    ldr     r1, =ROM + t_swi_ret
    subs    r0, r0, r1
    tput    r0
    .balign 4
    bx      pc
    nop
.arm

/* Fault cases outside the subset, one per build. */
.ifdef NEG_MRS_SPSR_USER
    msr     cpsr_c, #0xd0
fault_site:
    mrs     r0, spsr                @ User mode has no SPSR
.endif
.ifdef NEG_MOVS_PC_USER
    msr     cpsr_c, #0xd0
    adr     lr, done
fault_site:
    movs    pc, lr                  @ exception return from User mode
.endif
.ifdef NEG_MUL_PC
fault_site:
    .inst   0xe00f0291              @ mul pc, r1, r2
.endif
.ifdef NEG_MUL_SBZ
fault_site:
    .inst   0xe0001291              @ mul r0, r1, r2 with Rn field 1
.endif
.ifdef NEG_UMULL_SAME
fault_site:
    .inst   0xe0844291              @ umull r4, r4, r1, r2
.endif
.ifdef NEG_SMLAL_PC
fault_site:
    .inst   0xe0e4f291              @ smlal pc, r4, r1, r2
.endif
.ifdef NEG_CLZ_PC
fault_site:
    .inst   0xe16fff10              @ clz pc, r0
.endif
.ifdef NEG_LDM_USER_SVC
fault_site:
    ldmia   r11, {r1}^              @ user-bank transfer
.endif
done:
    b       done

/* SWI handler: r10 = comment field, r12 = SPSR, r8 = CPSR in the handler,
 * r9 = R14_svc. SWI 0x40 continues in SVC; the rest return. */
swi_entry:
    mrs     r12, spsr
    mrs     r8, cpsr
    mov     r9, lr
    tst     r12, #0x20
    ldrhne  r10, [lr, #-2]
    andne   r10, r10, #0xff
    ldreq   r10, [lr, #-4]
    biceq   r10, r10, #0xff000000
    cmp     r10, #0x40
    moveq   pc, lr
    movs    pc, lr

a_add16:
    add     r0, r0, #16
    mov     r12, lr
    bx      lr

bad:
    mov     r0, #0xba
    put     r0
    b       done

.thumb
.balign 4
t_double:
    adds    r0, r0, r0
    bx      lr
    adds    r0, #0x40               @ reached only if BLX <imm> ignores H
.thumb_func
t_inc_h:                            @ pc % 4 == 2
    adds    r0, #1
    bx      lr
t_shl1:
    lsls    r0, r0, #1
    bx      lr
.ltorg
