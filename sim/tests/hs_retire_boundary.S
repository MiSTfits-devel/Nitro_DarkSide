/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Public, synthetic two-CPU retirement-boundary fixture. Four independent
 * builds use BOOT9, BOOT7, ARM9 and ARM7 respectively. The host supplies
 * two controlled external IRQ pulses; IPC itself is the real SoC device. */
.syntax unified
.arm
.text
.ifdef BOOT9
.cpu arm946e-s
    ldr     pc, =0x02001000
    .org    0x18
    b       irq_handler
irq_handler:
    stmdb   sp!, {r0-r2, lr}
    ldr     r0, =0x02000300
    ldr     r1, [r0]
    add     r2, r0, r1, lsl #2
    str     lr, [r2, #4]        @ architectural LR_irq, once per exception
    add     r1, r1, #1
    str     r1, [r0]
    mov     r1, #1
    mov     r2, #0x04000000
    str     r1, [r2, #0x214]   @ W1C external IF bit
    ldmia   sp!, {r0-r2, lr}
    subs    pc, lr, #4          @ restore CPSR and retry interrupted PC
.ltorg
.else
.ifdef BOOT7
.cpu arm7tdmi
    ldr     pc, =0x02002000
.ltorg
.else
.ifdef ARM9
.cpu arm946e-s
.global preirq, pred_read, branch, wrong_read, recv1, recv2, recv3, done
    mov     r10, #0x04000000
    add     r8, r10, #0x180
    mov     r9, #0x04100000
    ldr     r7, =0x02000300
    mov     r0, #0
    str     r0, [r7]           @ IRQ count
    ldr     r0, =0x8000
    strh    r0, [r8, #4]       @ FIFO enable
    mov     r0, #1
    str     r0, [r7, #0x20]    @ ARM7 may send
    str     r0, [r10, #0x210]  @ IE bit 0
    str     r0, [r10, #0x208]  @ IME
    msr     cpsr_c, #0xd2
    ldr     sp, =0x02002f00
    msr     cpsr_c, #0xdf      @ System, IRQ masked
1:  ldr     r0, [r7, #0x24]
    cmp     r0, #1
    bne     1b
    mov     r4, #0x77
    cmp     r4, #0
pred_read:
    ldreq   r4, [r9]           @ must retire condition-failed, never pop
    str     r4, [r7, #0x28]
    .balign 8
    nop
branch:
    b       after_wrong
wrong_read:
    ldr     r4, [r9]           @ sequentially fetched, must never retire/pop
after_wrong:
preirq:
    mov     r12, r12           @ host raises IF while CPSR.I is still set
    msr     cpsr_c, #0x5f      @ unmask; IRQ must precede recv1
recv1:
    ldr     r4, [r9]
    str     r4, [r7, #0x2c]
recv2:
    ldr     r4, [r9]           @ host raises IF once request is accepted
    str     r4, [r7, #0x30]
recv3:
    ldr     r4, [r9]
    str     r4, [r7, #0x34]
    ldr     r0, [r7]
    str     r0, [r7, #0x38]
    ldr     r0, =0x600d9009
    str     r0, [r7, #0x3c]
done:
    b       done
.ltorg
.else
.cpu arm7tdmi
    mov     r10, #0x04000000
    add     r8, r10, #0x180
    ldr     r7, =0x02000300
1:  ldr     r0, [r7, #0x20]
    cmp     r0, #1
    bne     1b
    ldr     r0, =0x8000
    strh    r0, [r8, #4]
    ldr     r0, =0x12345678
    str     r0, [r8, #8]
    ldr     r0, =0x9abcdef0
    str     r0, [r8, #8]
    ldr     r0, =0x0badc0de
    str     r0, [r8, #8]
    mov     r0, #1
    str     r0, [r7, #0x24]
2:  b       2b
.ltorg
.endif
.endif
.endif
