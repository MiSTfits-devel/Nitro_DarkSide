/* SPDX-License-Identifier: GPL-3.0-or-later */
/* ARM9 guest of the two-CPU fixture (Nds.WholeCore.DualSoc). Loaded by
 * hs_dual_boot9.S from the synthetic image to 0x02000400; position
 * independent. It and the ARM7 guest (hs_dual_arm7.S) step through phases
 * that each start when the other CPU's IPCSYNC output reaches an agreed
 * value, so everything they record is independent of memory timing:
 *
 *   A  IPCSYNC IRQs both ways (the other side's IRQ enable set first).
 *   B  16 words ARM9 -> ARM7 with the ARM7's receive IRQ off: FIFO full,
 *      a 17th send sets the error flag, acknowledged; the ARM7 then turns its
 *      receive IRQ on and drains under IRQ; this side's send-empty IRQ fires
 *      on enabling and again when the ARM7 empties the FIFO.
 *   C  8 words ARM7 -> ARM9, drained here under the receive IRQ; an empty
 *      read sets the error flag; the ARM7 sends 3 more and clears its send
 *      FIFO, after which an empty read here returns 0.
 *   D  a 32-word buffer through shared RAM (the ARM7 adds the index), then
 *      both CPUs store different bytes of the same 32 words at once.
 *   E  64 words ARM9 -> ARM7 streamed with flow control on the full flag,
 *      received under IRQ.
 *   F  both CPUs increment their own byte of the same 2 words at once
 *      (LDRB/ADD/STRB, no handshake between stores): byte-lane writes keep
 *      every increment; a whole-word write would lose the other CPU's.
 *
 * Mailbox: slots 6.. at 0x02000000 + 4*slot (slots 0-5 are the loader's);
 * IRQ counters at 0x02000F20-F34. Values come from hs_dual_oracle.py. */
.syntax unified
.cpu arm946e-s
.arm
.text

.set slot, 6
.macro put reg
    str     \reg, [r11, #slot*4]
    .set    slot, slot + 1
.endm
/* Wait until the ARM7's IPCSYNC output is \val. */
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
/* Wait until the counter at 0x02000000 + \off reads \val. */
.macro waitctr off, val
1:  ldr     r0, [r11, #\off]
    cmp     r0, #\val
    bne     1b
.endm
.equ SYNCS, 0xf20               @ IPCSYNC IRQs taken
.equ SYNCIN, 0xf24              @ IPCSYNC input read in the last one
.equ SENDS, 0xf28               @ send-empty IRQs
.equ RECVS, 0xf2c               @ receive-not-empty IRQs
.equ WORDS, 0xf30               @ words received under IRQ
.equ SUM, 0xf34                 @ their checksum (h * 33 + w)

entry:
    mov     r11, #0x02000000
    mov     r10, #0x04000000
    add     r8, r10, #0x180         @ IPCSYNC; IPCFIFOCNT +4, IPCFIFOSEND +8
    mov     r9, #0x04100000         @ IPCFIFORECV
    mov     r0, #0
    add     r1, r11, #0xf00
    str     r0, [r1, #0x20]
    str     r0, [r1, #0x24]
    str     r0, [r1, #0x28]
    str     r0, [r1, #0x2c]
    str     r0, [r1, #0x30]
    str     r0, [r1, #0x34]
    adr     r0, irq9
    str     r0, [r11, #0xf08]       @ IRQ handler for the boot ROM's dispatch
    msr     cpsr_c, #0xd2           @ IRQ mode stack
    add     sp, r11, #0xe80
    msr     cpsr_c, #0xdf           @ System
    add     sp, r11, #0xe40
    mov     r0, #0x70000            @ IE: IPCSYNC, send empty, receive not empty
    str     r0, [r10, #0x210]
    mvn     r0, #0
    str     r0, [r10, #0x214]       @ clear IF
    mov     r0, #1
    str     r0, [r10, #0x208]       @ IME
    msr     cpsr_c, #0x5f           @ System, IRQs on

/* A */
    sync    0x4200                  @ output 2, IPCSYNC IRQ enabled
    waitctr SYNCS, 1                @ the ARM7's IRQ request
    ldr     r0, [r11, #SYNCIN]
    put     r0                      @ 6
    sync    0x6400                  @ output 4, IRQ to the ARM7

/* B */
    waitin  5
    cnt     0xc00c                  @ enable, acknowledge, clear, send-empty IRQ
    waitctr SENDS, 1
    put     r0                      @ 7
    mov     r1, #0
    ldr     r2, =0x9000
2:  add     r0, r2, r1, lsl #4
    add     r0, r0, r1              @ 0x9000 + 0x11 * k
    str     r0, [r8, #8]
    add     r1, r1, #1
    cmp     r1, #16
    bne     2b
    ldrh    r0, [r8, #4]
    put     r0                      @ 8: full
    ldr     r0, =0xdead
    str     r0, [r8, #8]            @ a 17th word
    ldrh    r0, [r8, #4]
    put     r0                      @ 9: error
    cnt     0xc004                  @ acknowledge
    ldrh    r0, [r8, #4]
    put     r0                      @ 10
    sync    0x4600                  @ output 6
    waitctr SENDS, 2                @ the ARM7 drained the FIFO
    put     r0                      @ 11
    waitin  7

/* C */
    cnt     0x8004                  @ receive IRQ off
    sync    0x4800                  @ output 8
    waitin  9
    ldrh    r0, [r8, #4]
    put     r0                      @ 12: 8 words waiting
    cnt     0x8404                  @ receive IRQ on
    waitctr WORDS, 8
    ldr     r0, [r11, #RECVS]
    put     r0                      @ 13
    ldr     r0, [r11, #WORDS]
    put     r0                      @ 14
    ldr     r0, [r11, #SUM]
    put     r0                      @ 15
    ldr     r0, [r9]                @ empty read
    ldrh    r0, [r8, #4]
    put     r0                      @ 16: error
    cnt     0xc004                  @ acknowledge, receive IRQ off
    sync    0x4a00                  @ output 10
    waitin  11
    ldrh    r0, [r8, #4]
    put     r0                      @ 17: the ARM7 cleared its FIFO
    ldr     r0, [r9]
    put     r0                      @ 18: empty read after a clear
    ldrh    r0, [r8, #4]
    put     r0                      @ 19: error
    cnt     0xc004                  @ acknowledge

/* D */
    add     r1, r11, #0x200
    mov     r2, #0
    ldr     r3, =0x01010101
    ldr     r4, =0x5a5aa5a5
2:  mul     r0, r2, r3
    eor     r0, r0, r4
    str     r0, [r1, r2, lsl #2]
    add     r2, r2, #1
    cmp     r2, #32
    bne     2b
    sync    0x4c00                  @ output 12: buffer A ready
    waitin  13                      @ buffer B ready; the ARM7 starts its bytes
    add     r1, r11, #0x280
    bl      sum32
    put     r3                      @ 20: buffer B
    add     r1, r11, #0x300
    mov     r2, #0
2:  eor     r0, r2, #0x93
    strb    r0, [r1, r2, lsl #2]    @ byte 0
    add     r0, r2, #0x29
    add     r4, r1, r2, lsl #2
    strb    r0, [r4, #2]            @ byte 2
    add     r2, r2, #1
    cmp     r2, #32
    bne     2b
    sync    0x4e00                  @ output 14
    waitin  15
    add     r1, r11, #0x300
    bl      sum32
    put     r3                      @ 21: both CPUs' bytes

/* E */
    cnt     0x8000                  @ send-empty IRQ off
    waitin  1
    mov     r2, #0
    ldr     r3, =0x9e3779b1
2:  ldrh    r0, [r8, #4]
    tst     r0, #2                  @ send FIFO full
    bne     2b
    mul     r0, r2, r3
    str     r0, [r8, #8]
    add     r2, r2, #1
    cmp     r2, #64
    bne     2b
    sync    0x4000                  @ output 0
    waitin  3

/* F: both CPUs increment their own byte of the same 2 words at once, with
 * no handshake between their stores: the ARM9 byte 0, 200 times (100 per
 * word); the ARM7 byte 1, 100 times (50 per word). Each LDRB/ADD/STRB
 * reads and writes the word, so if a store wrote the whole word the other
 * CPU's increments that landed in between would be lost. Both CPUs fetch
 * from the shared RAM, so the round-robin arbiter alone locks their loops
 * into one relative phase in which neither store window ever holds the
 * other CPU's write; the ARM9's 1-8 turn delay after each store sweeps
 * that phase. */
    add     r1, r11, #0x380
    mov     r0, #0
    str     r0, [r1]
    str     r0, [r1, #4]
    sync    0x4200                  @ output 2: start
    waitin  4                       @ the ARM7 starts too
    mov     r2, #0
2:  and     r4, r2, #1
    add     r4, r1, r4, lsl #2
    ldrb    r0, [r4]
    add     r0, r0, #1
    strb    r0, [r4]
    and     r5, r2, #7
3:  subs    r5, r5, #1
    bpl     3b
    add     r2, r2, #1
    cmp     r2, #200
    bne     2b
    sync    0x4500                  @ output 5: done
    waitin  6                       @ the ARM7 is done
    ldr     r0, [r1]
    ldr     r2, [r1, #4]
    add     r3, r0, r0, lsl #5
    add     r3, r3, r2
    put     r3                      @ 22: the 2 words both CPUs counted in
    ldr     r0, [r11, #SENDS]
    put     r0                      @ 23
    ldr     r0, [r11, #RECVS]
    put     r0                      @ 24
    ldr     r0, [r11, #SYNCS]
    put     r0                      @ 25
    ldr     r0, =0x600d9
    put     r0                      @ 26
done:
    b       done

/* r3 = h * 33 + w over the 32 words at r1. */
sum32:
    mov     r2, #0
    mov     r3, #0
1:  ldr     r0, [r1, r2, lsl #2]
    add     r3, r3, r3, lsl #5
    add     r3, r3, r0
    add     r2, r2, #1
    cmp     r2, #32
    bne     1b
    bx      lr

/* IRQ handler (IRQ mode, called by the boot ROM's dispatch, r0-r3 and r12
 * saved there): acknowledge IE & IF; count IPCSYNC IRQs and keep the
 * IPCSYNC input; count send-empty IRQs; on receive-not-empty drain the
 * receive FIFO into the word count and checksum. */
irq9:
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
    tst     r3, #0x100              @ receive FIFO empty
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
