/* SPDX-License-Identifier: GPL-3.0-or-later */
/* ARM9 boot-ROM loader for the synthetic DS image from hs_arm9_boot_oracle.py
 * on Nds.WholeCore.Arm9Soc. The launcher (sim/run_clash_arm9_boot.sh) builds
 * the boot ROM as this code followed, at 0xFFFF0E00, by the image's own
 * 0x200-byte cartridge header: the handoff a real BIOS makes by copying the
 * header to 0x027FFE00 before starting a game, needed here because a card in
 * main data mode cannot read its header (B7 below 0x8000 is redirected).
 * Nothing else of the image is placed anywhere; the ARM9 binary comes from
 * the card.
 *
 * default (card strap CARD_DIRECT_BOOT, main data mode):
 *   CRC16 of the handed-off header (0x000-0x15D) against its 0x15E field;
 *   ARM9 ROM offset/entry/RAM address/size from 0x020-0x02C, checked against
 *   this loader's limits; the binary copied into RAM with B7 reads of whole
 *   0x200-byte blocks from the ROM offset; BX to the entry with r0 = RAM
 *   address, r1 = size, r2 = CRC. The payload then writes slots 8..15.
 * RAW_HEADER (raw power-up strap): release cart reset, read the header from
 *   the card itself with command 00, CRC16 it, report its fields and the
 *   number of words that differ from the handed-off copy. Nothing runs from
 *   RAM.
 * A rejected header stores 0xE000 + reason (1 CRC, 2 ROM offset, 3 size or
 * RAM range, 4 entry) in the next slot and stops without branching. */
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

reset:
    mov     r11, #0x02000000
    ldr     r10, =0x040001a0        @ AUXSPICNT; ROMCTRL +4, command +8/+12
    ldr     r9, =0x04100010         @ data in
    mov     r0, #0x8000
    strh    r0, [r10]               @ slot enabled, ROM mode

.ifdef RAW_HEADER
    mov     r0, #0x20000000
    str     r0, [r10, #4]           @ release cart reset
    mov     r0, #0                  @ command 00 at 0: header
    str     r0, [r10, #8]
    str     r0, [r10, #12]
    ldr     r0, =0xa1000000         @ 0x200 bytes
    str     r0, [r10, #4]
    add     r12, r11, #0x200        @ header copy in RAM
    mov     r1, #0
1:  ldr     r0, [r10, #4]
    tst     r0, #0x00800000
    beq     1b
    ldr     r0, [r9]
    str     r0, [r12, r1, lsl #2]
    add     r1, r1, #1
    cmp     r1, #128
    bne     1b
2:  ldr     r0, [r10, #4]
    tst     r0, #0x80000000
    bne     2b
.else
    ldr     r12, =HANDOFF
.endif

    bl      crc16
    mov     r8, r0
    add     r1, r12, #0x15c
    ldrh    r1, [r1, #2]            @ 0x15E
    put     r0
    put     r1
    cmp     r0, r1
    failif  ne, 1
    ldr     r4, [r12, #0x20]        @ ARM9 ROM offset
    ldr     r5, [r12, #0x24]        @ ARM9 entry
    ldr     r6, [r12, #0x28]        @ ARM9 RAM address
    ldr     r7, [r12, #0x2c]        @ ARM9 size
    put     r4
    put     r5
    put     r6
    put     r7

.ifdef RAW_HEADER
    ldr     r0, [r12, #0x0c]
    put     r0                      @ game code
    ldr     r3, =HANDOFF
    mov     r1, #0
    mov     r2, #0
3:  ldr     r0, [r12, r1, lsl #2]
    ldr     lr, [r3, r1, lsl #2]
    cmp     r0, lr
    addne   r2, r2, #1
    add     r1, r1, #1
    cmp     r1, #128
    bne     3b
    put     r2                      @ words that differ from the handoff
done:
    b       done
.else
    /* Limits: whole 0x200-byte blocks from 0x8000 up (B7 below 0x8000 is
     * redirected); a word-sized binary in RAM above the mailbox and
     * scratch (0x02000400-0x02000FFF); the entry inside it. */
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
    add     r2, r6, r7              @ end of the binary in RAM
    ldr     r1, =0x02001000
    cmp     r2, r1
    failif  hi, 3
    cmp     r5, r6
    failif  lo, 4
    cmp     r5, r2
    failif  hs, 4
    tst     r5, #3
    failif  ne, 4

    /* Copy: one B7 block of 128 words per 0x200 bytes; words past the end
     * of the binary are read (the transfer must drain) but not stored. */
    mov     r1, r6                  @ destination
    mov     r2, r7                  @ bytes left to store
    mov     r3, r4                  @ ROM address of the next block
    mov     r12, #0                 @ checksum of the stored words
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
    put     lr                      @ words stored
    put     r12                     @ their checksum (h * 33 + w)
    mov     r0, r6
    mov     r1, r7
    mov     r2, r8
    bx      r5
.endif

reject:
    add     r0, r0, #0xe000
    str     r0, [r11, r1]
1:  b       1b

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
.ltorg
