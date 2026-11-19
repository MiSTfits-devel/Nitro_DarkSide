/* SPDX-License-Identifier: GPL-3.0-or-later */
/* ARM7 boot ROM (0x00000000, ARMv4T) of Nds.WholeCore.DualSoc: the ARM7 side
 * of the handoff in hs_dual_boot9.S. It waits until the ARM9's IPCSYNC
 * output reads 1, takes the ARM7 entry from the handoff word 0x02000F00,
 * answers with its own IPCSYNC output 1 and branches to the entry (ARM
 * state). IRQs dispatch through the RAM word 0x02000F04 (the guest's
 * handler, called in ARM state with LR as the return), as the DS ARM7 BIOS
 * dispatches through a RAM pointer. It stores nothing. */
.syntax unified
.cpu arm7tdmi
.arm
.text

vectors:
    b       reset                   @ 0x00
    b       .                       @ 0x04 undefined
    b       .                       @ 0x08 SWI
    b       .                       @ 0x0c
    b       .                       @ 0x10
    b       .                       @ 0x14
    b       irq_dispatch            @ 0x18 IRQ
    b       .                       @ 0x1c FIQ

reset:
    mov     r11, #0x02000000
    ldr     r10, =0x04000180        @ IPCSYNC
1:  ldrh    r0, [r10]
    and     r0, r0, #0xf
    cmp     r0, #1
    bne     1b
    ldr     r1, [r11, #0xf00]
    mov     r0, #0x100              @ output 1
    strh    r0, [r10]
    bx      r1

irq_dispatch:
    stmdb   sp!, {r0-r3, r12, lr}
    mov     r0, #0x02000000
    mov     lr, pc
    ldr     pc, [r0, #0xf04]
    ldmia   sp!, {r0-r3, r12, lr}
    subs    pc, lr, #4
.ltorg
