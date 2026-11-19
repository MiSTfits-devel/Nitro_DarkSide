/* SPDX-License-Identifier: GPL-3.0-or-later */
/* ARM7 guest of the two-CPU fixture (Nds.WholeCore.DualSoc), ARMv4T. Loaded
 * by hs_dual_boot9.S from the synthetic image to 0x02000900 and started by
 * hs_dual_boot7.S; position independent. The other side of the phases in
 * hs_dual_arm9.S:
 *
 *   A  IPCSYNC IRQs both ways.
 *   B  a send while this FIFO is disabled is dropped without error; then
 *      receive 16 words: full while the receive IRQ is off, drained under
 *      the IRQ once it is enabled; an empty read sets the error flag.
 *   C  send 8 words; then 3 more and clear the send FIFO.
 *   D  read buffer A, write buffer B = A + index; then store bytes 1 and 3
 *      of 32 words while the ARM9 stores bytes 0 and 2.
 *   E  receive 64 streamed words under IRQ.
 *   F  increment byte 1 of 2 words 100 times while the ARM9 increments
 *      byte 0 of the same words.
 *
 * Mailbox: slots 0.. at 0x02000100 + 4*slot; IRQ counters at
 * 0x02000F40-F54. Values come from hs_dual_oracle.py. */
.syntax unified
.cpu arm7tdmi
.arm
.text

.set slot, 0
.macro put reg
    str     \reg, [r11, #slot*4]
    .set    slot, slot + 1
.endm
.macro waitin val
1:  ldrh    r0, [r8]
    and     r0, r0, #0xf
    cmp     r0, #\val
    bne     1b
.endm
.macro sync val
    ldr     r0, =\val
    strh    r0, [r8]
.endm
.macro cnt val
    ldr     r0, =\val
    strh    r0, [r8, #4]
.endm
.macro waitctr off, val
1:  ldr     r0, [r7, #\off]
    cmp     r0, #\val
    bne     1b
.endm
.equ SYNCS, 0xf40
.equ SYNCIN, 0xf44
.equ RECVS, 0xf48
.equ WORDS, 0xf4c
.equ SUM, 0xf50
.equ SENDS, 0xf54

entry:
    mov     r7, #0x02000000
    add     r11, r7, #0x100         @ mailbox
    mov     r10, #0x04000000
    add     r8, r10, #0x180
    mov     r9, #0x04100000
    mov     r0, #0
    add     r1, r7, #0xf00
    str     r0, [r1, #0x40]
    str     r0, [r1, #0x44]
    str     r0, [r1, #0x48]
    str     r0, [r1, #0x4c]
    str     r0, [r1, #0x50]
    str     r0, [r1, #0x54]
    adr     r0, irq7
    str     r0, [r7, #0xf04]
    msr     cpsr_c, #0xd2
    add     sp, r7, #0xf00
    msr     cpsr_c, #0xdf
    add     sp, r7, #0xec0
    mov     r0, #0x70000
    str     r0, [r10, #0x210]
    mvn     r0, #0
    str     r0, [r10, #0x214]
    mov     r0, #1
    str     r0, [r10, #0x208]
    msr     cpsr_c, #0x5f

/* A */
    waitin  2
    sync    0x6300                  @ output 3, IRQ to the ARM9, IRQ enabled
    waitctr SYNCS, 1
    ldr     r0, [r7, #SYNCIN]
    put     r0                      @ 0

/* B */
    ldr     r0, =0x1234
    str     r0, [r8, #8]            @ FIFO disabled: dropped, no error
    ldrh    r0, [r8, #4]
    put     r0                      @ 1
    cnt     0xc000                  @ enable, acknowledge
    sync    0x4500                  @ output 5
    waitin  6
    ldrh    r0, [r8, #4]
    put     r0                      @ 2: receive FIFO full
    cnt     0x8400                  @ receive IRQ on
    waitctr WORDS, 16
    ldr     r0, [r7, #RECVS]
    put     r0                      @ 3
    ldr     r0, [r7, #WORDS]
    put     r0                      @ 4
    ldr     r0, [r7, #SUM]
    put     r0                      @ 5
    ldr     r0, [r9]                @ empty read
    ldrh    r0, [r8, #4]
    put     r0                      @ 6: error
    cnt     0xc000                  @ acknowledge, receive IRQ off
    sync    0x4700                  @ output 7

/* C */
    waitin  8
    mov     r1, #0
    ldr     r2, =0x7000
2:  add     r0, r2, r1, lsl #8
    add     r0, r0, r1              @ 0x7000 + 0x101 * k
    str     r0, [r8, #8]
    add     r1, r1, #1
    cmp     r1, #8
    bne     2b
    sync    0x4900                  @ output 9
    waitin  10
    mov     r1, #0
    ldr     r2, =0x3333
2:  add     r0, r2, r1
    str     r0, [r8, #8]
    add     r1, r1, #1
    cmp     r1, #3
    bne     2b
    cnt     0x8008                  @ clear the send FIFO
    ldrh    r0, [r8, #4]
    put     r0                      @ 7
    sync    0x4b00                  @ output 11

/* D */
    waitin  12
    add     r1, r7, #0x200          @ buffer A
    add     r4, r7, #0x280          @ buffer B
    mov     r2, #0
    mov     r3, #0
2:  ldr     r0, [r1, r2, lsl #2]
    add     r3, r3, r3, lsl #5
    add     r3, r3, r0
    add     r0, r0, r2
    str     r0, [r4, r2, lsl #2]
    add     r2, r2, #1
    cmp     r2, #32
    bne     2b
    put     r3                      @ 8: buffer A
    sync    0x4d00                  @ output 13
    add     r1, r7, #0x300
    mov     r2, #0
2:  add     r4, r1, r2, lsl #2
    eor     r0, r2, #0x71
    strb    r0, [r4, #1]            @ byte 1
    add     r0, r2, #0x37
    strb    r0, [r4, #3]            @ byte 3
    add     r2, r2, #1
    cmp     r2, #32
    bne     2b
    sync    0x4f00                  @ output 15
    waitin  14
    add     r1, r7, #0x300
    mov     r2, #0
    mov     r3, #0
2:  ldr     r0, [r1, r2, lsl #2]
    add     r3, r3, r3, lsl #5
    add     r3, r3, r0
    add     r2, r2, #1
    cmp     r2, #32
    bne     2b
    put     r3                      @ 9: both CPUs' bytes

/* E */
    mov     r0, #0
    str     r0, [r7, #WORDS]
    str     r0, [r7, #SUM]
    cnt     0x8400                  @ receive IRQ on
    sync    0x4100                  @ output 1
    waitctr WORDS, 64
    put     r0                      @ 10
    ldr     r0, [r7, #SUM]
    put     r0                      @ 11
    ldr     r0, [r7, #SYNCS]
    put     r0                      @ 12
    sync    0x4300                  @ output 3

/* F: increment byte 1 of the same 2 words the ARM9 counts in byte 0, 100
 * times (50 per word), no handshake between the stores. */
    waitin  2
    sync    0x4400                  @ output 4: started
    add     r1, r7, #0x380
    mov     r2, #0
2:  and     r4, r2, #1
    add     r4, r1, r4, lsl #2
    ldrb    r0, [r4, #1]
    add     r0, r0, #1
    strb    r0, [r4, #1]
    add     r2, r2, #1
    cmp     r2, #100
    bne     2b
    sync    0x4600                  @ output 6: done
    waitin  5
    ldr     r0, [r1]
    ldr     r2, [r1, #4]
    add     r3, r0, r0, lsl #5
    add     r3, r3, r2
    put     r3                      @ 13: the 2 words both CPUs counted in
    ldr     r0, =0x700d7
    put     r0                      @ 14
done:
    b       done

/* IRQ handler, as on the ARM9 (hs_dual_arm9.S), with this CPU's counters. */
irq7:
    stmdb   sp!, {r4, r5, lr}
    mov     r0, #0x04000000
    ldr     r1, [r0, #0x214]
    ldr     r2, [r0, #0x210]
    and     r1, r1, r2
    str     r1, [r0, #0x214]
    mov     r2, #0x02000000
    add     r4, r0, #0x180
    tst     r1, #0x10000
    beq     1f
    ldr     r3, [r2, #SYNCS]
    add     r3, r3, #1
    str     r3, [r2, #SYNCS]
    ldrh    r3, [r4]
    and     r3, r3, #0xf
    str     r3, [r2, #SYNCIN]
1:  tst     r1, #0x20000
    beq     1f
    ldr     r3, [r2, #SENDS]
    add     r3, r3, #1
    str     r3, [r2, #SENDS]
1:  tst     r1, #0x40000
    beq     3f
    ldr     r3, [r2, #RECVS]
    add     r3, r3, #1
    str     r3, [r2, #RECVS]
2:  ldrh    r3, [r4, #4]
    tst     r3, #0x100
    bne     3f
    mov     r3, #0x04100000
    ldr     r3, [r3]
    ldr     r5, [r2, #SUM]
    add     r5, r5, r5, lsl #5
    add     r5, r5, r3
    str     r5, [r2, #SUM]
    ldr     r5, [r2, #WORDS]
    add     r5, r5, #1
    str     r5, [r2, #WORDS]
    b       2b
3:  ldmia   sp!, {r4, r5, lr}
    bx      lr
.ltorg
