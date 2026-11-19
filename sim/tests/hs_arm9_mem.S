/* SPDX-License-Identifier: GPL-3.0-or-later */
/* CPU-only addressing-mode fixture for Nds.WholeCore.Arm9Slice: register
 * offsets, pre-index writeback, post-index, signed loads, LDM/STM in all four
 * modes, stack push/pop and loads to PC. Mailbox words go to
 * 0x02000000 + 4*slot in slot order (hand-derived results in
 * hs_arm9_mem.expected); scratch S[0..15] is 0x020000c0..ff (word index
 * 0x30..0x3f) and every scratch result is read back into the mailbox. The
 * default image also runs on the product ARM9 RTL. NEG_* variants append one
 * fault after the mailbox; `fault_site` names the reported address. OFFER_*
 * variants append one link access (sim/run_clash_arm9_isa.sh lists the exact
 * held request). */
.syntax unified
.cpu arm946e-s
.arm
.text

.ifndef ROM
.equ ROM, 0xffff0000            @ load address of .text (ARM7 build: --defsym ROM=0)
.endif
.set slot, 0
.macro put reg
    str     \reg, [r11, #slot*4]
    .set    slot, slot + 1
.endm

    mov     r11, #0x02000000
    add     r12, r11, #0xc0         @ &S[0]

/* Post-index immediate fill: S[k] = (k+1) * 0x11111111, k = 0..7. */
    mov     r0, r12
    ldr     r1, =0x11111111
    mov     r2, r1
    add     r3, r12, #32
fill:
    str     r2, [r0], #4
    add     r2, r2, r1
    cmp     r0, r3
    bne     fill
    sub     r0, r0, r12
    put     r0

/* Pre-index immediate writeback. */
    add     r0, r12, #32
    ldr     r1, [r0, #-4]!          @ S[7], r0 = &S[7]
    ldr     r2, [r0, #-8]!          @ S[5], r0 = &S[5]
    add     r1, r1, r2
    put     r1
    sub     r0, r0, r12
    put     r0

/* Register offsets with every immediate shift type. */
    mov     r2, #3
    ldr     r1, [r12, r2, lsl #2]   @ S[3]
    put     r1
    add     r4, r12, #32
    mov     r2, #2
    ldr     r1, [r4, -r2, lsl #2]   @ S[6]
    put     r1
    mov     r3, #0x80000000
    ldr     r1, [r12, r3, lsr #28]  @ +8: S[2]
    put     r1
    add     r4, r12, #8
    mvn     r3, #0xf
    ldr     r1, [r4, r3, asr #2]    @ -4: S[1]
    put     r1
    ldr     r4, =0x220000d8         @ &S[6] + 0x20000000
    mov     r3, #2
    ldr     r1, [r4, -r3, ror #4]   @ -0x20000000: S[6]
    put     r1
    ldr     r4, =0x820000c8         @ &S[4] - 0x80000008
    mov     r3, #0x10
    msr     cpsr_f, #0x20000000     @ C = 1
    ldr     r1, [r4, r3, rrx]       @ +0x80000008: S[4]
    put     r1

/* Register post-index and pre-index writeback, byte load from a word. */
    mov     r0, r12
    mov     r2, #3
    ldr     r1, [r0], r2, lsl #2    @ S[0], r0 = &S[3]
    ldr     r3, [r0, r2, lsl #2]!   @ S[6], r0 = &S[6]
    add     r1, r1, r3
    put     r1
    ldr     r3, [r0], -r2           @ r0 = &S[5] + 1
    ldrb    r5, [r0], #-1           @ byte 1 of S[5], r0 = &S[5]
    sub     r0, r0, r12
    orr     r0, r0, r5, lsl #8
    put     r0

/* Stores with writeback, read back with LDMIA. */
    add     r0, r12, #32            @ &S[8]
    mov     r2, #4
    ldr     r1, =0xa5a5a5a5
    str     r1, [r0], r2            @ S[8], r0 = &S[9]
    mvn     r3, r1
    str     r3, [r0, r2]!           @ S[10], r0 = &S[10]
    str     r1, [r0, #-4]           @ S[9]
    eor     r1, r1, r3
    str     r1, [r0, -r2, lsl #1]!  @ S[8] again, r0 = &S[8]
    sub     r4, r0, r12
    put     r4
    ldmia   r0, {r4-r6}
    put     r4
    put     r5
    put     r6

/* Byte stores, signed byte and halfword loads. */
    add     r0, r12, #44            @ &S[11]
    mov     r1, #0x81
    strb    r1, [r0], #1
    mov     r1, #0x7f
    strb    r1, [r0], #1
    mov     r1, #0xfe
    mov     r2, #1
    strb    r1, [r0], r2
    mov     r1, #0x02
    strb    r1, [r0], #-3           @ r0 = &S[11]
    ldr     r1, [r0]
    put     r1
    ldrsb   r1, [r0]
    put     r1
    ldrsb   r1, [r0, r2]
    put     r1
    ldrsb   r1, [r0, #2]!           @ r0 = &S[11] + 2
    ldrsh   r3, [r0]
    add     r1, r1, r3
    put     r1
    ldrh    r3, [r0], #-2           @ r0 = &S[11]
    ldrsh   r1, [r0]
    orr     r1, r3, r1, lsl #16
    put     r1

/* Halfword stores and register-offset halfword addressing. */
    add     r0, r12, #48            @ &S[12]
    ldr     r1, =0x8001
    strh    r1, [r0], #2
    ldr     r1, =0x7ffe
    strh    r1, [r0]
    ldrsh   r2, [r0, #-2]!          @ r0 = &S[12]
    ldr     r3, [r0]
    put     r2
    put     r3
    mov     r2, #2
    ldrh    r1, [r0], r2            @ r0 = &S[12] + 2
    ldrsh   r3, [r0, -r2]!          @ r0 = &S[12]
    strh    r1, [r0, #6]            @ upper half of S[13] (still zero)
    ldr     r1, [r0, #4]
    add     r3, r3, r1
    put     r3

/* LDM in all four modes. */
    ldmia   r12, {r0-r3}
    add     r0, r0, r1
    add     r0, r0, r2
    add     r0, r0, r3
    put     r0
    add     r4, r12, #16            @ &S[4]
    ldmib   r4!, {r0, r1}           @ S[5], S[6]; r4 = &S[6]
    ldmda   r4, {r2, r3}            @ S[5], S[6]
    ldmdb   r4!, {r5, r6}           @ S[4], S[5]; r4 = &S[4]
    eor     r0, r0, r2
    eor     r1, r1, r3
    orr     r0, r0, r1
    add     r5, r5, r6
    add     r5, r5, r0
    put     r5
    sub     r4, r4, r12
    put     r4

/* STM in all four modes; STM! of its own lowest-numbered base. */
    mov     r0, #0xa
    mov     r1, #0xb
    mov     r2, #0xc
    mov     r3, #0xd
    add     r4, r12, #32            @ &S[8]
    stmia   r4!, {r0, r1}           @ S[8], S[9]; r4 = &S[10]
    stmib   r4, {r2, r3}            @ S[11], S[12]
    mov     r5, #0xe
    stmda   r4, {r5}                @ S[10]
    add     r6, r12, #64            @ 0x02000100: the top of scratch, never accessed
    mov     r7, #0x1f
    mov     r8, #0x2f
    stmdb   r6!, {r7, r8}           @ S[14], S[15]; r6 = &S[14]
    add     r9, r12, #52            @ &S[13]
    stmia   r9!, {r9}               @ S[13] = original base; r9 = &S[14]
    sub     r6, r6, r9
    put     r6
    add     r4, r12, #32
    ldmia   r4, {r0-r7}             @ base r4 in the list, no writeback
    add     r10, r11, #slot*4
    stmia   r10, {r0-r7}            @ eight mailbox words in slot order
    .set    slot, slot + 8

/* LDM from the boot ROM. */
    adr     r0, rom_table
    ldmia   r0, {r1-r3}
    put     r1
    put     r2
    put     r3

/* Full-descending stack: PUSH/POP {.., pc}, then STR!/LDR pc post-index. */
    add     sp, r12, #64
    mov     r0, #5
    bl      sum
    put     r0
    sub     r1, sp, r12
    put     r1
    mov     r0, #0
    bl      leaf
    put     r0
    ldr     pc, jump_lit
    b       bad
after_jump:
    mov     r0, #0x99
    put     r0

/* Condition-failed transfers of every new form, including UNPREDICTABLE
 * encodings, leave no register, memory or PC effect. */
    msr     cpsr_f, #0x40000000     @ Z: NE fails
    mov     r0, r12
    mov     r1, #0x5a
    mov     r2, #4
    ldrne   r1, [r0], #4
    strne   r1, [r0, #4]!
    ldrne   r1, [r0, r2]!
    ldrshne r1, [r0], #2
    ldmne   r0!, {r1, r2}
    stmne   r0!, {r1, r2}
    .inst   0x15b00004              @ ldrne r0, [r0, #4]!  (Rn = Rd writeback)
    .inst   0x18b00003              @ ldmne r0!, {r0, r1}  (LDM! base in list)
    .inst   0x18900000              @ ldmne r0, {}         (empty list)
    .inst   0x18808002              @ stmne r0, {r1, pc}   (STM of R15)
    .inst   0x18d00002              @ ldmne r0, {r1}^      (user bank)
    ldrne   pc, [r0]
    popne   {pc}
    put     r0
    put     r1
    mrs     r3, cpsr
    put     r3
    ldmia   r12, {r4, r5}           @ S[0], S[1] untouched by the skipped stores
    add     r4, r4, r5
    put     r4

/* Fault cases: one per build, after the complete mailbox. */
.ifdef NEG_WB_RD
fault_site:
    .inst   0xe5b11004              @ ldr r1, [r1, #4]!
.endif
.ifdef NEG_WB_PC
fault_site:
    .inst   0xe5bf1004              @ ldr r1, [pc, #4]!
.endif
.ifdef NEG_RM_PC
fault_site:
    .inst   0xe792100f              @ ldr r1, [r2, pc]
.endif
.ifdef NEG_WB_RM_RN
fault_site:
    .inst   0xe7b21002              @ ldr r1, [r2, r2]!
.endif
.ifdef NEG_LDRT
fault_site:
    .inst   0xe4b01004              @ ldrt r1, [r0], #4
.endif
.ifdef NEG_LDRD
fault_site:
    .inst   0xe1c020d0              @ ldrd r2, [r0]
.endif
.ifdef NEG_HALF_SBZ
fault_site:
    .inst   0xe19011b2              @ ldrh r1, [r0, r2] with bits 11..8 = 1
.endif
.ifdef NEG_HALF_POST_WB
fault_site:
    .inst   0xe0f010f2              @ ldrsh, P = 0 and W = 1
.endif
.ifdef NEG_LDRB_PC
fault_site:
    .inst   0xe5d0f000              @ ldrb pc, [r0]
.endif
.ifdef NEG_STR_PC
fault_site:
    .inst   0xe580f000              @ str pc, [r0]
.endif
.ifdef NEG_LDM_WB_BASE
fault_site:
    .inst   0xe8b10006              @ ldmia r1!, {r1, r2}
.endif
.ifdef NEG_STM_WB_BASE
fault_site:
    .inst   0xe8a10003              @ stmia r1!, {r0, r1}: base not lowest
.endif
.ifdef NEG_STM_PC
fault_site:
    .inst   0xe8808002              @ stmia r0, {r1, pc}
.endif
.ifdef NEG_LDM_EMPTY
fault_site:
    .inst   0xe8900000              @ ldmia r0, {}
.endif
.ifdef NEG_LDM_USER
fault_site:
    .inst   0xe8d00002              @ ldmia r0, {r1}^
.endif
.ifdef NEG_LDM_PC_BASE
fault_site:
    .inst   0xe89f0002              @ ldmia pc, {r1}
.endif
.ifdef NEG_BLOCK_MISALIGNED
    ldr     r0, =0x020000c2
    ldmia   r0, {r1}
    .set    fault_site, 0x020000c2
.endif
.ifdef NEG_BLOCK_PAST_RAM
    ldr     r0, =0x02000ff8
    stmia   r0, {r1-r3}             @ third beat has no route: nothing stored
    .set    fault_site, 0x02001000
.endif
.ifdef NEG_BLOCK_LINK_STORE
    ldr     r0, =0x06800000
    stmia   r0, {r1, r2}            @ VRAM is single-transfer only
    .set    fault_site, 0x06800000
.endif
.ifdef NEG_BLOCK_LINK_LOAD
    mov     r0, #0x04000000
    ldmia   r0, {r1, r2}            @ DISPCNT/DISPSTAT
    .set    fault_site, 0x04000000
.endif
.ifdef NEG_BLOCK_ROM_STORE
    adr     r0, rom_table
    stmia   r0, {r1}
    .set    fault_site, rom_table
.endif
.ifdef NEG_BLOCK_OAM
    mov     r0, #0x07000000
    ldmia   r0, {r1, r2}            @ OAM is single-transfer only
    .set    fault_site, 0x07000000
.endif
.ifdef NEG_PAST_ENGINE_A
    mov     r0, #0x04000000
    ldr     r1, [r0, #0x70]         @ first word after BLDY: no route
    .set    fault_site, 0x04000070
.endif
.ifdef NEG_PAST_PALETTE
    mov     r0, #0x05000000
    ldr     r1, [r0, #0x800]        @ first word after the palettes: no route
    .set    fault_site, 0x05000800
.endif
/* Link probes: the CPU-only harness never accepts, so the first offer must
 * be exactly this held request. */
.ifdef OFFER_POST_INDEX
    mov     r0, #0x04000000
    ldrh    r1, [r0], #4            @ R2 04000000
.endif
.ifdef OFFER_REG_WRITEBACK
    ldr     r0, =0x06800000
    mov     r2, #8
    str     r1, [r0, r2, lsl #1]!   @ W4 06800010 0000005a
.endif
.ifdef OFFER_TIMER
    ldr     r0, =0x04000100
    strh    r1, [r0, #2]            @ W2 04000102 0000005a
.endif
.ifdef OFFER_IE
    ldr     r0, =0x04000210
    ldr     r1, [r0]                @ R4 04000210
.endif
.ifdef OFFER_DISPSTAT
    mov     r0, #0x04000000
    strh    r1, [r0, #4]            @ W2 04000004 0000005a
.endif
.ifdef OFFER_ENGINE_A
    mov     r0, #0x04000000
    strh    r1, [r0, #0x6e]         @ W2 0400006e 0000005a (last halfword)
.endif
.ifdef OFFER_ENGINE_B
    ldr     r0, =0x04001000
    ldr     r1, [r0, #0x6c]         @ R4 0400106c (last word)
.endif
.ifdef OFFER_PALETTE
    mov     r0, #0x05000000
    strb    r1, [r0, #0x7ff]        @ W1 050007ff 0000005a (last byte)
.endif
.ifdef OFFER_OAM
    mov     r0, #0x07000000
    str     r1, [r0]                @ W4 07000000 0000005a
.endif
.ifdef OFFER_IPCSYNC
    mov     r0, #0x04000000
    add     r0, r0, #0x180
    strh    r1, [r0]                @ W2 04000180 0000005a
.endif
.ifdef OFFER_IPCRECV
    mov     r0, #0x04100000
    ldr     r1, [r0]                @ R4 04100000
.endif
done:
    b       done

bad:
    mov     r0, #0xba
    put     r0
    b       bad

/* sum(n) = n + sum(n - 1), sum(1) = 1, with a two-word frame per level. */
sum:
    cmp     r0, #1
    movls   pc, lr
    push    {r4, lr}
    mov     r4, r0
    sub     r0, r0, #1
    bl      sum
    add     r0, r0, r4
    pop     {r4, pc}
leaf:
    str     lr, [sp, #-4]!
    add     r0, r0, #7
    ldr     pc, [sp], #4

    .align  2
rom_table:
    .word   0xdeadbeef, 0x01234567, 0x89abcdef
jump_lit:
    .word   ROM + after_jump
.ltorg
