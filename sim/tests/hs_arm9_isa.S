/* SPDX-License-Identifier: GPL-3.0-or-later */
/* CPU-only ARM-state ISA fixture for Nds.WholeCore.Arm9Slice. It touches only
 * the boot ROM and word stores to 0x02000000 + 4*slot, in slot order; the
 * hand-derived results are in hs_arm9_isa.expected. The default image is
 * also run on the product ARM9 RTL (sim/tb_arm9_isa_oracle.vhd). The NEG_*
 * variants append one fault after every mailbox store; `fault_site` names
 * the address the slice must report. OFFER_* variants append one GPU access
 * (sim/run_clash_arm9_isa.sh lists the exact held request). */
.syntax unified
.cpu arm946e-s
.arm
.text

.set slot, 0
.macro put reg
    str     \reg, [r11, #slot*4]
    .set    slot, slot + 1
.endm
/* r10 = r10 << 4 | NZCV */
.macro flags
    mrs     r9, cpsr
    mov     r9, r9, lsr #28
    orr     r10, r9, r10, lsl #4
.endm

    mov     r11, #0x02000000

/* Slots 0-15: for every NZCV value, which of EQ..AL pass (bit = cond). */
    mov     r1, #0
cond_loop:
    mov     r2, r1, lsl #28
    msr     cpsr_f, r2
    mov     r0, #0
    orreq   r0, r0, #0x0001
    orrne   r0, r0, #0x0002
    orrcs   r0, r0, #0x0004
    orrcc   r0, r0, #0x0008
    orrmi   r0, r0, #0x0010
    orrpl   r0, r0, #0x0020
    orrvs   r0, r0, #0x0040
    orrvc   r0, r0, #0x0080
    orrhi   r0, r0, #0x0100
    orrls   r0, r0, #0x0200
    orrge   r0, r0, #0x0400
    orrlt   r0, r0, #0x0800
    orrgt   r0, r0, #0x1000
    orrle   r0, r0, #0x2000
    orr     r0, r0, #0x4000
    add     r3, r11, r1, lsl #2
    str     r0, [r3]
    add     r1, r1, #1
    cmp     r1, #16
    bne     cond_loop
.set slot, 16

/* Slots 16-24: arithmetic results and flags. */
    mov     r10, #0
    ldr     r1, =0x7fffffff
    adds    r0, r1, #1
    put     r0
    flags
    mvn     r1, #0
    adds    r0, r1, #1
    put     r0
    flags
    mov     r1, #0
    subs    r0, r1, #1
    put     r0
    flags
    mov     r1, #0x80000000
    subs    r0, r1, #1
    put     r0
    flags
    mov     r1, #5
    rsbs    r0, r1, #3
    put     r0
    flags
    mvn     r1, #0              @ (1:ffffffff) + (2:1)
    mov     r2, #1
    mov     r3, #1
    mov     r4, #2
    adds    r0, r1, r3
    adcs    r5, r2, r4
    put     r5
    flags
    mov     r1, #0              @ (5:0) - (2:1)
    mov     r2, #5
    mov     r3, #1
    mov     r4, #2
    subs    r0, r1, r3
    sbcs    r5, r2, r4
    put     r5
    flags
    mov     r1, #3
    rscs    r0, r1, #0x10
    put     r0
    flags
    put     r10

/* Slots 25-33: shifter results and carry-out. */
    mov     r10, #0
    msr     cpsr_f, #0
    ldr     r1, =0x80000001
    movs    r0, r1, lsl #1
    put     r0
    flags
    movs    r0, r1, lsr #32
    put     r0
    flags
    mov     r2, #0x80000000
    movs    r0, r2, asr #32
    put     r0
    flags
    movs    r0, r1, rrx
    put     r0
    flags
    ldr     r3, =0x12345678
    movs    r0, r3, ror #8
    put     r0
    flags
    mov     r4, #0
    msr     cpsr_f, #0x20000000
    movs    r0, r3, lsl r4
    put     r0
    flags
    mov     r4, #32
    movs    r0, r1, lsl r4
    put     r0
    flags
    mov     r4, #33
    movs    r0, r1, lsr r4
    put     r0
    flags
    put     r10

/* Slots 34-38: large register shifts, immediate carry, compare/test ops. */
    mov     r10, #0
    mov     r4, #200
    movs    r0, r2, asr r4
    put     r0
    flags
    mov     r4, #32
    movs    r0, r3, ror r4
    put     r0
    flags
    mov     r4, #36
    movs    r0, r3, ror r4
    put     r0
    flags
    movs    r0, #0x80000000
    flags
    ands    r0, r3, #0xf0
    put     r0
    flags
    cmp     r3, r3
    flags
    cmn     r2, r2
    flags
    teq     r3, r3
    flags
    put     r10

/* Slots 39-43: logical forms keep V and take the shifter carry. */
    mov     r10, #0
    mov     r5, #1
    cmp     r5, r2
    flags
    eors    r0, r3, r3
    put     r0
    flags
    mvns    r0, r3
    put     r0
    flags
    bics    r0, r3, #0xff000000
    put     r0
    flags
    orrs    r0, r3, r1, lsl #31
    put     r0
    flags
    put     r10

/* Slot 44: SUBS/BNE loop. */
    mov     r0, #10
    mov     r1, #0
1:  add     r1, r1, r0
    subs    r0, r0, #1
    bne     1b
    put     r1

/* Slot 45: signed against unsigned predicates and branches. */
    mov     r8, #0
    mvn     r0, #0
    cmp     r0, #1
    orrlt   r8, r8, #0x01
    orrlo   r8, r8, #0x02
    orrhi   r8, r8, #0x04
    orrgt   r8, r8, #0x08
    blt     2f
    orr     r8, r8, #0x10
2:  bhs     3f
    orr     r8, r8, #0x20
3:  ble     4f
    orr     r8, r8, #0x40
4:  bgt     5f
    orr     r8, r8, #0x80
5:  put     r8

/* Slots 46-47: BL, BLX register, BX/MOV PC returns and the link value. */
    mov     r8, #0
    mov     r0, #3
    bl      sub_double
    mov     r1, r0
    adr     r4, sub_cond
    mov     r0, #0
    blx     r4
    mov     r0, #1
    blx     r4
    bl      sub_lr
ret_site:
    adr     r2, ret_site
    sub     r0, r0, r2
    orr     r0, r0, r1, lsl #8
    put     r0
    put     r8

/* Slot 48: computed jump through PC. */
    mov     r0, #2
    add     pc, pc, r0, lsl #2
    mov     r0, #0xee
    b       case0
    b       case1
    b       case2
    b       case3
case0:
    mov     r1, #0x10
    b       cases_done
case1:
    mov     r1, #0x11
    b       cases_done
case2:
    mov     r1, #0x12
    b       cases_done
case3:
    mov     r1, #0x13
cases_done:
    put     r1

/* Slots 49-53: failed predicates have no register, flag, link or bus
 * effect, including forms the slice does not implement and accesses that
 * would fault (unrouted WRAMCNT, misaligned word). */
    msr     cpsr_f, #0x40000000
    mov     r1, #0x5a
    mov     lr, #0x77
    ldr     r2, =0xcafef00d
    ldr     r6, =0x04000247
    strne   r2, [r11, #slot*4]
    ldrne   r1, [r11, #0]
    ldrbne  r1, [r6]
    ldrne   r1, [r11, #1]
    mulne   r1, r2, r3
    ldmne   r11, {r1, r2}
    swpne   r1, r2, [r11]
.ifndef PRODUCT_ORACLE
    /* Product nds_cpu9 deviates here: in SVC it clears r14 for this
     * cond-failed MOVS (CPSR is kept), so its oracle image omits it. */
    movsne  pc, lr
.endif
    addsne  r1, r1, #1
    cmpne   r1, r1
    bne     bad
    blne    bad
    put     r1
    streq   r2, [r11, #slot*4]
    .set    slot, slot + 1
    ldreq   r3, [r11, #(slot - 1)*4]
    put     r3
    put     lr
    mrs     r0, cpsr
    and     r0, r0, #0xf0000000
    put     r0

.ifdef NEG_NV
fault_site:
    .inst   0xf1a00000          @ MOV with cond NV: faults before predication
.endif
.ifdef NEG_MISALIGNED_PC
    adr     r0, misaligned
    add     r0, r0, #2
    mov     pc, r0
misaligned:
    .set    fault_site, misaligned + 2
.endif
.ifdef NEG_UNIMPLEMENTED
fault_site:
    swp     r1, r2, [r3]        @ executed (AL) form outside the subset
.endif
.ifdef NEG_VCOUNT_WRITE
    mov     r0, #0x04000000
    strh    r1, [r0, #6]        @ VCOUNT is read-only on this link
    .set    fault_site, 0x04000006
.endif
/* Route probes: the CPU-only harness never accepts, so the first GPU offer
 * must be exactly this held request. */
.ifdef OFFER_DISPCNT
    mov     r0, #0x04000000
    str     r1, [r0]            @ W4 04000000 0000005a
.endif
.ifdef OFFER_VCOUNT
    mov     r0, #0x04000000
    ldrh    r1, [r0, #6]        @ R2 04000006
.endif
done:
    b       done

bad:
    mov     r0, #0xba
    put     r0
    b       bad

sub_double:
    add     r0, r0, r0
    add     r8, r8, #1
    bx      lr
sub_cond:
    cmp     r0, #0
    addeq   r8, r8, #0x10
    moveq   pc, lr
    add     r8, r8, #0x100
    bx      lr
sub_lr:
    mov     r0, lr
    bx      lr
.ltorg
