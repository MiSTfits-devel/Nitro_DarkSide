/* SPDX-License-Identifier: GPL-3.0-or-later */
/* ARM9 IRQ exception fixture for Nds.WholeCore.Arm9Soc: SVC/IRQ banking,
 * CPSR/SPSR, masking by CPSR.I, IME and IE, entry at instruction boundaries
 * and both return forms (SUBS pc, lr, #4 and LDM {.., pc}^), with the
 * interrupt raised by a real timer 0 overflow through IF.
 *
 * Mailbox words go to 0x02000000 + 4*slot in order (hand-derived values in
 * hs_arm9_irq.expected). Scratch is 0x020000c0..ff: the handler's log
 * S0..S7, an STM target S8..S10 and the IRQ stack below 0x02000100. The
 * PRODUCT_ORACLE build stops after slot 33: the later slots check the exact
 * entry point after an MSR and CPSR.F (where the product RTL differs) and
 * need the harness's external IRQ sources (IF bit 0 raised while a link
 * read is in flight, IF bit 1 raised at the first beat of an STM). NEG_*
 * builds append one fault after the mailbox; `fault_site` names the
 * reported address. */
.syntax unified
.cpu arm946e-s
.arm
.text

.set slot, 0
.macro put reg
    str     \reg, [r11, #slot*4]
    .set    slot, slot + 1
.endm

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
    mov     r10, #0                 @ handler return form: SUBS pc, lr, #4
    mov     r9, #0                  @ handler never stops timer 0
    mov     sp, #0x1000             @ SVC R13/R14 sentinels, never used as a stack
    mov     lr, #0x2000

/* Banked R13/R14 across MSR mode switches. */
    msr     cpsr_c, #0xd2           @ IRQ mode, I = F = 1
    add     sp, r11, #0x100         @ IRQ stack: full descending from 0x02000100
    mov     lr, #0x3000
    mrs     r0, cpsr
    put     r0
    msr     cpsr_c, #0xd3           @ SVC
    mrs     r0, cpsr
    put     r0
    put     sp
    put     lr
    msr     cpsr_c, #0xd2
    sub     r0, sp, r11
    mov     r1, lr
    msr     cpsr_c, #0xd3
    put     r0
    put     r1

/* A pending timer IRQ is held off by CPSR.I, then taken at the first
 * boundary after the MSR that clears I. */
    ldr     r4, =0x04000208         @ IME
    ldr     r5, =0x04000210         @ IE; IF at +4
    ldr     r6, =0x04000100         @ TM0CNT
    add     r7, r11, #0xc0          @ handler log
    mov     r0, #8
    str     r0, [r5]                @ IE = timer 0
    mov     r0, #1
    str     r0, [r4]                @ IME = 1
    ldr     r0, =0x00c0fff0
    str     r0, [r6]                @ timer 0: reload fff0, F/1, IRQ, start
1:  ldr     r0, [r5, #4]
    tst     r0, #8
    beq     1b
    mov     r0, #0
    strh    r0, [r6, #2]            @ stop timer 0
    ldr     r0, [r5, #4]
    put     r0
    ldr     r0, [r7]
    put     r0
    mov     r8, #0
    msr     cpsr_f, #0xa0000000     @ N, C
    msr     cpsr_c, #0x53           @ SVC, I = 0, F = 1
irq_point:
    mov     r8, #1
    mrs     r0, cpsr
    put     r0
    put     r8
    put     sp
    put     lr
    ldmia   r7, {r0-r6}
    put     r0
    bic     r1, r1, #0x40           @ handler CPSR without F (product clears it)
    put     r1
    put     r2
    put     r3
    adr     r0, irq_point
    sub     r4, r4, r0              @ 0: taken right after the MSR; 4: one later
    ldr     r0, [r7, #28]           @ interrupted R8: 0 or 1 to match
    sub     r0, r4, r0, lsl #2
    put     r0
    put     r5
    sub     r6, r6, r11
    put     r6
    cmp     r4, #4
    movls   r0, #1
    movhi   r0, #0
    put     r0

/* IME and IE mask a pending source; enabling IE then lets it in. */
    ldr     r4, =0x04000208
    ldr     r5, =0x04000210
    ldr     r6, =0x04000100
    mov     r0, #0
    str     r0, [r4]                @ IME = 0 (CPSR.I is clear)
    ldr     r0, =0x00c0fff0
    str     r0, [r6]
1:  ldr     r0, [r5, #4]
    tst     r0, #8
    beq     1b
    mov     r0, #0
    strh    r0, [r6, #2]
    ldr     r0, [r7]
    put     r0
    mov     r0, #0x10
    str     r0, [r5]                @ IE = timer 1 only
    mov     r0, #1
    str     r0, [r4]                @ IME = 1
    ldr     r0, [r5, #4]
    put     r0
    ldr     r0, [r7]
    put     r0
    mov     r0, #8
    str     r0, [r5]                @ IE = timer 0: the pending IRQ is taken
1:  ldr     r0, [r7]
    cmp     r0, #2
    bne     1b
    ldr     r0, [r7, #12]
    put     r0
    ldr     r0, [r5, #4]
    put     r0

/* A free-running timer interrupts a polling loop five more times; the
 * handler returns with LDM {.., pc}^ and stops the timer on IRQ 7. */
    mov     r10, #1
    mov     r9, #7
    ldr     r0, =0x00c0ff00
    str     r0, [r6]
1:  ldr     r0, [r7]
    cmp     r0, #7
    bne     1b
    put     r0
    ldrh    r0, [r6, #2]
    put     r0
    ldr     r0, [r5, #4]
    put     r0
    ldr     r0, [r7, #4]
    and     r0, r0, #0xbf           @ handler CPSR mode/I byte without F
    put     r0
    ldr     r0, [r7, #8]
    and     r0, r0, #0xff
    put     r0
    ldr     r0, [r7, #24]
    sub     r0, r0, r11
    put     r0
    mrs     r0, cpsr
    and     r0, r0, #0xff
    put     r0
    put     sp
    put     lr

.ifndef PRODUCT_ORACLE
/* Exact entry point and F: the pending IRQ is taken at the very next
 * boundary after the MSR that clears I, and entry keeps CPSR.F. The product
 * RTL executes one more instruction first and clears F, so these slots are
 * not in its build. */
    mov     r10, #0
    mov     r9, #0
    msr     cpsr_c, #0xd3
    ldr     r0, =0x00c0fff0
    str     r0, [r6]
1:  ldr     r0, [r5, #4]
    tst     r0, #8
    beq     1b
    mov     r0, #0
    strh    r0, [r6, #2]
    mov     r8, #0
    msr     cpsr_c, #0x53
msr_point:
    mov     r8, #1
    ldr     r0, [r7, #16]
    adr     r1, msr_point
    sub     r0, r0, r1
    put     r0
    ldr     r0, [r7, #28]
    put     r0
    ldr     r0, [r7, #4]
    and     r0, r0, #0xff
    put     r0

/* IRQs raised while an instruction's bus access is still in flight are
 * taken only after it completes. */
    mov     r0, #3
    str     r0, [r5]                @ IE = VBlank | HBlank (external sources)
    mov     r8, #7
    ldr     r0, =0x06000000
    ldr     r1, [r0]                @ harness raises IF bit 0 while this read waits
load_done:
    mov     r8, #2
    ldr     r0, [r7]
    put     r0
    ldr     r0, [r7, #12]
    put     r0
    ldr     r0, [r7, #16]
    adr     r2, load_done
    sub     r0, r0, r2
    put     r0
    ldr     r0, [r7, #20]
    put     r0
    ldr     r0, [r7, #28]
    put     r0
    ldr     r1, =0x5ca1ab1e
    mvn     r2, r1
    mov     r3, #0x33
    add     r0, r11, #0xe0          @ S8: harness raises IF bit 1 at this beat
    stmia   r0, {r1-r3}
stm_done:
    ldr     r0, [r7]
    put     r0
    ldr     r0, [r7, #12]
    put     r0
    ldr     r0, [r7, #16]
    adr     r1, stm_done
    sub     r0, r0, r1
    put     r0
    add     r0, r11, #0xe0
    ldmia   r0, {r1-r3}
    put     r1
    put     r2
    put     r3
.endif

/* Fault cases outside the subset, one per build. */
.ifdef NEG_SUBS_SYSTEM
    msr     cpsr_c, #0xdf
fault_site:
    subs    pc, lr, #4              @ System mode has no SPSR
.endif
.ifdef NEG_MRS_SPSR_SYSTEM
    msr     cpsr_c, #0xdf
fault_site:
    mrs     r0, spsr
.endif
.ifdef NEG_MSR_FIQ
fault_site:
    msr     cpsr_c, #0xd1           @ FIQ mode is outside the subset
.endif
.ifdef NEG_MSR_THUMB
fault_site:
    msr     cpsr_c, #0xf3           @ T bit
.endif
.ifdef NEG_MSR_Q
fault_site:
    msr     cpsr_f, #0x08000000     @ Q flag
.endif
.ifdef NEG_MSR_NO_FIELDS
fault_site:
    .inst   0xe320f000              @ MSR with an empty field mask
.endif
.ifdef NEG_LDM_USER_IRQ
    msr     cpsr_c, #0xd2
fault_site:
    ldmia   r11, {r1}^              @ user-bank transfer
.endif
.ifdef NEG_STM_USER_IRQ
    msr     cpsr_c, #0xd2
fault_site:
    stmia   r7, {r1}^
.endif
.ifdef NEG_SPSR_FIQ
    msr     cpsr_c, #0xd2
    mov     r0, #0x11
    msr     spsr_fsxc, r0           @ stored as written
    adr     lr, done
fault_site:
    movs    pc, lr                  @ restoring FIQ mode faults here
.endif
done:
    b       done

bad:
    mov     r0, #0xba
    put     r0
    b       bad

/* Handler log: S0 IRQ count, S1 CPSR, S2 SPSR, S3 IF & IE acknowledged,
 * S4 return address, S5 interrupted R1, S6 IRQ SP at entry, S7 interrupted
 * R8. Uses only R0-R3; R7-R11 belong to the main program. */
.macro log_entry
    str     r0, [r11, #0xd0]
    str     r1, [r11, #0xd4]
    str     r2, [r11, #0xd8]
    str     r3, [r11, #0xdc]
    add     r3, r11, #0xc0
    ldr     r0, [r3]
    add     r0, r0, #1
    str     r0, [r3]
    mrs     r0, cpsr
    mrs     r1, spsr
    msr     spsr_fsxc, r1           @ SPSR written back unchanged
    stmib   r3, {r0, r1}
    ldr     r2, =0x04000214
    ldr     r0, [r2]
    ldr     r1, [r2, #-4]
    and     r0, r0, r1
    str     r0, [r2]                @ acknowledge the enabled pending sources
    str     r0, [r3, #12]
    ldr     r0, [r3]
    cmp     r0, r9
    ldreq   r2, =0x04000100
    moveq   r0, #0
    strheq  r0, [r2, #2]            @ stop timer 0 on IRQ number r9
.endm

irq_entry:
    cmp     r10, #0
    bne     irq_ldm
    stmfd   sp!, {r0-r3}
    sub     r0, lr, #4
    add     r2, sp, #16
    mov     r3, r8
    log_entry
    ldmfd   sp!, {r0-r3}
    subs    pc, lr, #4
irq_ldm:
    sub     lr, lr, #4
    stmfd   sp!, {r0-r3, lr}
    mov     r0, lr
    add     r2, sp, #20
    mov     r3, r8
    log_entry
    ldmfd   sp!, {r0-r3, pc}^
.ltorg
