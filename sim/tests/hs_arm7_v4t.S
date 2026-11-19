/* SPDX-License-Identifier: GPL-3.0-or-later */
/* CPU-only ARMv4T fixture for the ARM7 build of Nds.WholeCore.Arm9Slice
 * (Arch arm7Arch): exception vectors at 0x00000000 (SWI from ARM and from
 * Thumb lands at 0x08), loads to PC that keep the state (LDR pc and LDM
 * {pc} with bit 0 set stay in ARM; Thumb POP {pc} with bit 0 clear stays in
 * Thumb), BX both ways, the Thumb BL pair (LR = next | 1) and Thumb MOV pc.
 * On an ARMv5 core each state-keeping load would switch state and run the
 * wrong instruction set. Code reached by a load to PC with bit 0 set uses
 * no PC-relative operand and leaves through a register, so it does not
 * depend on whether bit 0 survives in R15. Mailbox words go to
 * 0x02000000 + 4*slot in order (hand-derived values in hs_arm7_v4t.expected);
 * scratch S[0..15] is 0x020000c0..ff, which also holds the System stack.
 * The image runs unchanged on the product ARM7 (gba_cpu + nds_membus7).
 * NEG_* builds end in an ARMv5-only instruction that must fault (code 1)
 * at `fault_site` on the ARM7 build. */
.syntax unified
.cpu arm7tdmi
.arm
.text

.set slot, 0
.macro put reg
    str     \reg, [r11, #slot*4]
    .set    slot, slot + 1
.endm

vectors:
    b       reset                   @ 0x00
    b       bad                     @ 0x04 undefined
    b       swi_entry               @ 0x08 SWI
    b       bad                     @ 0x0c prefetch abort
    b       bad                     @ 0x10 data abort
    b       bad                     @ 0x14
    b       bad                     @ 0x18 IRQ
    b       bad                     @ 0x1c FIQ

reset:
    mov     r11, #0x02000000
    msr     cpsr_c, #0xdf           @ System, I = F = 1
    add     sp, r11, #0x100         @ System stack at the top of scratch

/* A: SWI from ARM enters SVC at vector 0x08 with R14_svc = next. */
    msr     cpsr_f, #0x60000000     @ Z, C
    mov     r0, #0x99
    swi     0x12
swi_ret:
    put     r0                      @ 0: R14_svc - swi_ret = 0
    put     r2                      @ 1: comment field 0x12
    put     r3                      @ 2: handler CPSR & 0x9f = 0x93
    put     r4                      @ 3: SPSR_svc = 0x600000df
    mrs     r0, cpsr
    put     r0                      @ 4: back in System, flags kept: 0x600000df

/* B: LDR pc with bit 0 set stays in ARM (ARMv5 would enter Thumb). */
    adr     r6, after_ldr
    mov     r5, #0
    ldr     pc, =ldr_target + 1
    .word   0xe7f000f0              @ never executed
ldr_target:
    mov     r5, #0x11
    mov     pc, r6
after_ldr:
    put     r5                      @ 5: 0x11
    mrs     r0, cpsr
    and     r0, r0, #0x3f
    put     r0                      @ 6: ARM, System: 0x1f

/* C: LDM {pc} with bit 0 set stays in ARM. */
    adr     r6, after_ldm
    adr     r0, ldm_target + 1
    stmdb   sp!, {r0}
    mov     r5, #0
    ldmia   sp!, {pc}
    .word   0xe7f000f0
ldm_target:
    mov     r5, #0x22
    mov     pc, r6
after_ldm:
    put     r5                      @ 7: 0x22
    put     sp                      @ 8: 0x02000100

/* D: Thumb. POP {pc} with bit 0 clear stays in Thumb, and with bit 0 set;
 * the BL pair links next | 1; MOV pc, lr and MOV pc, r3 keep Thumb. */
    adr     r6, after_thumb
    add     r4, r11, #0xc0          @ &S[0]
    adr     r0, thumb_code + 1
    bx      r0
.thumb
.balign 4
thumb_code:
    adr     r0, pop_even            @ bit 0 clear
    push    {r0}
    movs    r5, #0
    pop     {pc}
    .hword  0xde00                  @ never executed
.balign 4
pop_even:
    movs    r5, #0x33
    str     r5, [r4, #0]            @ S[0] = 0x33
    adr     r0, pop_odd
    adds    r0, #1                  @ bit 0 set
    push    {r0}
    pop     {pc}
    .hword  0xde00
.balign 4
pop_odd:
    movs    r1, #5
    bl      t_add3                  @ r1 = 8, LR = bl_next | 1
bl_next:
    mov     r0, r12                 @ LR as t_add3 saw it
    adr     r3, mov_pc_target
    mov     pc, r3                  @ hi-register MOV to PC: stays Thumb
    .hword  0xde00
.balign 4
mov_pc_target:
    movs    r3, #0x44
    bx      r6                      @ back to ARM
t_add3:
    adds    r1, #3
    mov     r12, lr
    mov     pc, lr                  @ bit 0 of LR dropped, Thumb kept
.arm
.balign 4
after_thumb:
    ldr     r7, [r11, #0xc0]
    put     r7                      @ 9: 0x33, stored in Thumb after POP {pc} (bit 0 clear)
    put     r1                      @ 10: 8 (POP {pc} with bit 0 set reached BL to t_add3)
    adr     r7, bl_next + 1
    sub     r0, r0, r7
    put     r0                      @ 11: LR in t_add3 - (bl_next | 1) = 0
    put     r3                      @ 12: 0x44 after MOV pc, r3
    mrs     r0, cpsr
    and     r0, r0, #0x3f
    put     r0                      @ 13: ARM, System: 0x1f

/* E: SWI from Thumb lands at 0x08 too, with R14_svc = the next halfword. */
    adr     r0, thumb_swi + 1
    bx      r0
.thumb
.balign 4
thumb_swi:
    movs    r0, #0x77
    swi     0x34
thumb_swi_ret:
    adr     r1, back_arm
    bx      r1
.arm
.balign 4
back_arm:
    adr     r1, thumb_swi_ret
    sub     r0, r0, r1
    put     r0                      @ 14: R14_svc - thumb_swi_ret = 0
    put     r2                      @ 15: comment field 0x34
    put     r3                      @ 16: handler CPSR & 0x9f = 0x93 (T cleared on entry)
    and     r4, r4, #0x3f
    put     r4                      @ 17: SPSR_svc T and mode: 0x3f

.ifdef NEG_BLX_REG
fault_site:
    .inst   0xe12fff36              @ blx r6
.endif
.ifdef NEG_BLX_IMM
fault_site:
    .inst   0xfa000000              @ blx <imm>
.endif
.ifdef NEG_CLZ
fault_site:
    .inst   0xe16f0f10              @ clz r0, r0
.endif
.ifdef NEG_THUMB_BLX_REG
    adr     r0, thumb_blx_reg + 1
    bx      r0
.thumb
.balign 4
thumb_blx_reg:
fault_site:
    .hword  0x47b0                  @ blx r6
.arm
.balign 4
.endif
.ifdef NEG_THUMB_BLX_SUFFIX
    adr     r0, thumb_blx_suffix + 1
    bx      r0
.thumb
.balign 4
thumb_blx_suffix:
    .hword  0xf000                  @ BL/BLX prefix, offset 0
fault_site:
    .hword  0xe800                  @ BLX suffix (H = 01)
.arm
.balign 4
.endif
done:
    b       done

bad:
    mov     r0, #0xba
    put     r0
    b       done

/* SWI handler: r3 = CPSR & 0x9f, r4 = SPSR_svc; ARM caller: r2 = comment
 * (low 24 bits), r0 = R14_svc - swi_ret; Thumb caller (SPSR.T): r2 =
 * comment (low 8 bits), r0 = R14_svc, which the caller checks. */
swi_entry:
    mrs     r3, cpsr
    and     r3, r3, #0x9f
    mrs     r4, spsr
    tst     r4, #0x20
    bne     1f
    ldr     r2, [lr, #-4]
    bic     r2, r2, #0xff000000
    adr     r1, swi_ret
    sub     r0, lr, r1
    movs    pc, lr
1:  ldrh    r2, [lr, #-2]
    and     r2, r2, #0xff
    mov     r0, lr
    movs    pc, lr
.ltorg
