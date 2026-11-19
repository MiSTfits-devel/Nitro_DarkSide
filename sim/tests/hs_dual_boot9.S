/* SPDX-License-Identifier: GPL-3.0-or-later */
/* ARM9 boot ROM (0xFFFF0000) of the two-CPU system Nds.WholeCore.DualSoc: a
 * stand-in for the BIOS and firmware launcher with explicit handoff rules.
 *
 *   * The launcher (sim/run_clash_dual_soc.sh) places the synthetic image's
 *     0x200-byte header in this ROM at 0xFFFF0E00, as hs_arm9_boot.S has it:
 *     a card in main data mode cannot read its own header.
 *   * CRC16 of the header against its 0x15E field; the ARM9 binary (fields
 *     0x020-0x02C) must fit 0x02000400-0x020008FF and the ARM7 binary (fields
 *     0x030-0x03C) 0x02000900-0x02000DFF, each from a 0x200-aligned ROM offset
 *     at or above 0x8000, with its entry inside it. (Main RAM is 4 KiB in this
 *     gate: mailboxes 0x000-0x1FF, guest buffers 0x200-0x3FF, binaries, stacks
 *     0xE00-0xEFF, handoff and IRQ words from 0xF00.)
 *   * Both binaries are copied into shared main RAM with B7 reads.
 *   * The ARM7 entry goes to the handoff word 0x02000F00; then this CPU sets
 *     its IPCSYNC output to 1, waits until the ARM7 boot ROM answers 1, and
 *     branches to the ARM9 entry (ARM state).
 *   * IRQs dispatch through the RAM word 0x02000F08 (the guest's handler,
 *     called with BX-style return in ARM state), as the DS BIOS dispatches
 *     through a RAM pointer.
 *
 * Mailbox: slot 0 CRC16 computed, 1 the header's CRC field, 2/3 ARM9 words
 * copied and their checksum (h * 33 + w), 4/5 the same for the ARM7. A
 * rejected header stores 0xE000 + reason in the next slot (1 CRC, 2 ARM9
 * ROM offset, 3 ARM9 size/RAM, 4 ARM9 entry, 0x12/0x13/0x14 the same for the
 * ARM7) and stops. */
.syntax unified
.cpu arm946e-s
.arm
.text

.equ HANDOFF, 0xffff0e00
.set slot, 0
.macro put reg
    str     \reg, [r11, #slot*4]
    .set    slot, slot + 1
.endm
.macro failif cond, code
    mov\cond r0, #\code
    mov\cond r1, #slot*4
    b\cond  reject
.endm

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
    add     sp, r11, #0xe40         @ SVC stack for the loader
    ldr     r10, =0x040001a0        @ AUXSPICNT; ROMCTRL +4, command +8/+12
    ldr     r9, =0x04100010         @ data in
    mov     r0, #0x8000
    strh    r0, [r10]               @ slot enabled, ROM mode
    ldr     r12, =HANDOFF
    bl      crc16
    add     r1, r12, #0x15c
    ldrh    r1, [r1, #2]            @ 0x15E
    put     r0
    put     r1
    cmp     r0, r1
    failif  ne, 1

    /* ARM9 binary: 0x02000400-0x020008FF. */
    ldr     r4, [r12, #0x20]        @ ROM offset
    ldr     r5, [r12, #0x24]        @ entry
    ldr     r6, [r12, #0x28]        @ RAM address
    ldr     r7, [r12, #0x2c]        @ size
    cmp     r4, #0x8000
    failif  lo, 2
    ldr     r1, =0x1ff
    tst     r4, r1
    failif  ne, 2
    cmp     r7, #0
    failif  eq, 3
    tst     r7, #3
    failif  ne, 3
    ldr     r1, =0x02000400
    cmp     r6, r1
    failif  lo, 3
    tst     r6, #3
    failif  ne, 3
    add     r2, r6, r7
    ldr     r1, =0x02000900
    cmp     r2, r1
    failif  hi, 3
    cmp     r5, r6
    failif  lo, 4
    cmp     r5, r2
    failif  hs, 4
    tst     r5, #3
    failif  ne, 4
    stmdb   sp!, {r5}               @ ARM9 entry
    bl      copy
    put     r0
    put     r1

    /* ARM7 binary: 0x02000900-0x02000DFF. */
    ldr     r4, [r12, #0x30]
    ldr     r5, [r12, #0x34]
    ldr     r6, [r12, #0x38]
    ldr     r7, [r12, #0x3c]
    cmp     r4, #0x8000
    failif  lo, 0x12
    ldr     r1, =0x1ff
    tst     r4, r1
    failif  ne, 0x12
    cmp     r7, #0
    failif  eq, 0x13
    tst     r7, #3
    failif  ne, 0x13
    ldr     r1, =0x02000900
    cmp     r6, r1
    failif  lo, 0x13
    tst     r6, #3
    failif  ne, 0x13
    add     r2, r6, r7
    ldr     r1, =0x02000e00
    cmp     r2, r1
    failif  hi, 0x13
    cmp     r5, r6
    failif  lo, 0x14
    cmp     r5, r2
    failif  hs, 0x14
    tst     r5, #3
    failif  ne, 0x14
    str     r5, [r11, #0xf00]       @ handoff: ARM7 entry
    bl      copy
    put     r0
    put     r1

    /* Start the ARM7, wait for its answer, run the ARM9 binary. */
    ldr     r10, =0x04000180        @ IPCSYNC
    mov     r0, #0x100              @ output 1
    strh    r0, [r10]
1:  ldrh    r0, [r10]
    and     r0, r0, #0xf
    cmp     r0, #1
    bne     1b
    ldmia   sp!, {r5}
    bx      r5

reject:
    add     r0, r0, #0xe000
    str     r0, [r11, r1]
1:  b       1b

/* Copy a binary with B7: r4 = ROM offset, r6 = RAM address, r7 = size.
 * Returns r0 = words stored, r1 = their checksum (h * 33 + w). Whole
 * 0x200-byte blocks are read; words past the binary are drained, not
 * stored. */
copy:
    stmdb   sp!, {r4-r8, r12, lr}
    mov     r1, r6                  @ destination
    mov     r2, r7                  @ bytes left to store
    mov     r3, r4                  @ ROM address of the next block
    mov     r12, #0                 @ checksum
    mov     lr, #0                  @ words stored
block:
    mov     r0, #0xb7               @ B7, address big-endian in bytes 1..4
    mov     r4, r3, lsr #24
    orr     r0, r0, r4, lsl #8
    mov     r4, r3, lsr #16
    and     r4, r4, #0xff
    orr     r0, r0, r4, lsl #16
    mov     r4, r3, lsr #8
    and     r4, r4, #0xff
    orr     r0, r0, r4, lsl #24
    str     r0, [r10, #8]
    and     r0, r3, #0xff
    str     r0, [r10, #12]
    ldr     r0, =0xa1000000
    str     r0, [r10, #4]
    mov     r4, #128
word:
    ldr     r0, [r10, #4]
    tst     r0, #0x00800000
    beq     word
    ldr     r0, [r9]
    cmp     r2, #0
    beq     skip
    str     r0, [r1], #4
    sub     r2, r2, #4
    add     r12, r12, r12, lsl #5
    add     r12, r12, r0
    add     lr, lr, #1
skip:
    subs    r4, r4, #1
    bne     word
1:  ldr     r0, [r10, #4]
    tst     r0, #0x80000000
    bne     1b
    add     r3, r3, #0x200
    cmp     r2, #0
    bne     block
    mov     r0, lr
    mov     r1, r12
    ldmia   sp!, {r4-r8, r12, lr}
    bx      lr

/* CRC-16 (poly 0xA001 reflected, init 0xFFFF) over [r12, r12 + 0x15E). */
crc16:
    ldr     r0, =0xffff
    ldr     r3, =0xa001
    mov     r1, #0
1:  ldrb    r2, [r12, r1]
    eor     r0, r0, r2
    mov     r2, #8
2:  movs    r0, r0, lsr #1
    eorcs   r0, r0, r3
    subs    r2, r2, #1
    bne     2b
    add     r1, r1, #1
    ldr     r2, =0x15e
    cmp     r1, r2
    bne     1b
    bx      lr

/* IRQ: save the caller-saved registers, call the handler whose address the
 * guest stored at 0x02000F08, restore, return. */
irq_dispatch:
    stmdb   sp!, {r0-r3, r12, lr}
    mov     r0, #0x02000000
    mov     lr, pc
    ldr     pc, [r0, #0xf08]
    ldmia   sp!, {r0-r3, r12, lr}
    subs    pc, lr, #4
.ltorg
