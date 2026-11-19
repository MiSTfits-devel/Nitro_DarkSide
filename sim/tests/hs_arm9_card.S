/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Read-only NTR game-card fixture for Nds.WholeCore.Arm9Soc. Two builds:
 *   default      raw power-up: release cart reset, 9F, 00 header, 90 chip ID
 *   DIRECT_BOOT  cart handed over in main data mode: B7 reads, B8 chip ID
 * against the synthetic image from hs_arm9_card_oracle.py, whose
 * expectations are hs_arm9_card_{raw,direct}.expected. Mailbox words go to
 * 0x02000000 + 4*slot in order; scratch is 0x020000c0.. (IRQ stack below
 * 0x020000e0, handler count at +0xf0, its IF & IE at +0xf4, a capture word
 * at +0xec, power-up registers at +0xf8/+0xfc). The PRODUCT_ORACLE build
 * stops where the product card differs (raw: 00 ignores its address; both:
 * no 4 KiB page wrap; direct: power-up register values). NEG_* builds append
 * one fault after the mailbox (or replace the cart-reset release). */
.syntax unified
.cpu arm946e-s
.arm
.text

.set slot, 0
.macro put reg
    str     \reg, [r11, #slot*4]
    .set    slot, slot + 1
.endm

/* Command bytes: byte 0 at 0x040001A8, address big-endian in bytes 1..4. */
.macro command op, addr
    ldr     r0, =(\op | ((((\addr) >> 24) & 0xff) << 8) | ((((\addr) >> 16) & 0xff) << 16) | ((((\addr) >> 8) & 0xff) << 24))
    ldr     r1, =((\addr) & 0xff)
    str     r0, [r10, #8]
    str     r1, [r10, #12]
.endm

/* One transfer through xfer: r2 = ROMCTRL, r3 = words, r8 = capture index. */
.macro run ctrl, words, capture
    ldr     r2, =\ctrl
    ldr     r3, =\words
    mov     r8, #\capture
    bl      xfer
.endm

    b       reset
    b       bad
    b       bad
    b       bad
    b       bad
    b       bad
    b       irq_entry
    b       bad

reset:
    mov     r11, #0x02000000
    ldr     r10, =0x040001a0        @ AUXSPICNT; ROMCTRL +4, command +8/+12
    ldr     r9, =0x04100010         @ data in
    ldrh    r0, [r10]
    str     r0, [r11, #0xf8]        @ power-up AUXSPICNT
    ldr     r0, [r10, #4]
    str     r0, [r11, #0xfc]        @ power-up ROMCTRL
    msr     cpsr_c, #0xd2
    add     sp, r11, #0xe0          @ IRQ stack
    msr     cpsr_c, #0xd3
    mov     r0, #0
    str     r0, [r11, #0xf0]
    ldr     r0, =0x04000208
    mov     r1, #1
    str     r1, [r0]                @ IME
    mov     r1, #0x00080000
    str     r1, [r0, #8]            @ IE = card transfer done

    mov     r0, #0xc000
    strh    r0, [r10]               @ slot enabled, ROM mode, transfer IRQ
    ldrh    r0, [r10]
    put     r0

.ifndef DIRECT_BOOT
/* ---------------- raw power-up ---------------- */
.ifndef NEG_RESET
    mov     r0, #0x20000000
    str     r0, [r10, #4]           @ release cart reset
.else
    command 0x9f, 0                 @ cart still in reset: faults here
    ldr     r0, =0x87000000
    str     r0, [r10, #4]
.endif
    ldr     r0, [r10, #4]
    put     r0

    command 0x9f, 0                 @ dummy, taken with the IRQ exception
    msr     cpsr_c, #0x53
    run     0xa1000000, 128, 0
1:  ldr     r0, [r11, #0xf0]
    cmp     r0, #1
    bne     1b
    msr     cpsr_c, #0xd3
    put     r5
    put     r12
    put     r0
    ldr     r0, [r11, #0xf4]
    put     r0

    run     0xa0000000, 0, 0        @ size 0: no data words
    bl      if_card
    put     r0

    command 0x00, 0                 @ header
    run     0xa1000000, 128, 3
    bl      if_card
    put     r4
    put     r6
    ldr     r0, [r11, #0xec]
    put     r0
    put     r7

    command 0x90, 0                 @ chip ID
    ldr     r2, =0xa7000000
    bl      chip
    put     r4
    put     r5
    put     r6
    put     r7

.ifndef PRODUCT_ORACLE
    command 0x00, 0xf00             @ header from F00 wraps inside 4 KiB
    run     0xa1000000, 128, 64
    bl      if_card
    put     r4
    put     r6
    ldr     r0, [r11, #0xec]
    put     r0
    put     r7
.endif

.else
/* ---------------- direct boot (main data mode) ---------------- */
    command 0xb7, 0x8000            @ taken with the IRQ exception
    msr     cpsr_c, #0x53
    run     0xa1000000, 128, 64
1:  ldr     r0, [r11, #0xf0]
    cmp     r0, #1
    bne     1b
    msr     cpsr_c, #0xd3
    put     r4
    put     r6
    ldr     r1, [r11, #0xec]
    put     r1
    put     r7
    put     r0
    ldr     r0, [r11, #0xf4]
    put     r0

    command 0xb7, 0x00000200        @ below 8000: redirected
    bl      single
    put     r1
    command 0xb7, 0x00001ffc
    bl      single
    put     r1
    command 0xb7, 0x00010100        @ past the image: mirrored, then redirected
    bl      single
    put     r1
    command 0xb7, 0x0001c000        @ mirrored
    bl      single
    put     r1

    command 0xb7, 0xc000
    run     0xa2000000, 256, 0
    bl      if_card
    put     r4
    put     r7

    command 0xb8, 0                 @ chip ID
    ldr     r2, =0xa7000000
    bl      chip
    put     r4
    put     r5
    put     r6
    put     r7

.ifndef PRODUCT_ORACLE
    ldr     r0, [r11, #0xf8]
    put     r0
    ldr     r0, [r11, #0xfc]
    put     r0
    command 0xb7, 0xaf00            @ wraps inside its 4 KiB page
    run     0xa1000000, 128, 64
    bl      if_card
    put     r4
    ldr     r0, [r11, #0xec]
    put     r0
    put     r7
.endif
.endif

/* Fault cases outside the subset, one per build. */
.ifdef NEG_KEY1
    command 0x3c, 0                 @ KEY1 needs BIOS keys
    ldr     r0, =0xa0000000
    str     r0, [r10, #4]
.endif
.ifdef NEG_RAW_B7
    command 0xb7, 0x8000            @ data-mode command in raw mode
    ldr     r0, =0xa7000000
    str     r0, [r10, #4]
.endif
.ifdef NEG_UNALIGNED
    command 0x00, 0x002
    ldr     r0, =0xa7000000
    str     r0, [r10, #4]
.endif
.ifdef NEG_DIRECT_9F
    command 0x9f, 0                 @ raw command in data mode
    ldr     r0, =0xa7000000
    str     r0, [r10, #4]
.endif
.ifdef NEG_DIRECT_UNALIGNED
    command 0xb7, 0x8002
    ldr     r0, =0xa7000000
    str     r0, [r10, #4]
.endif
.ifdef NEG_SPI_MODE
    mov     r0, #0xe000
    strh    r0, [r10]               @ backup SPI mode
    ldr     r0, =0xa7000000
    str     r0, [r10, #4]
.endif
.ifdef NEG_WRITE_DIR
    ldr     r0, =0xe7000000         @ ROMCTRL bit 30: card writes
    str     r0, [r10, #4]
.endif
.ifdef NEG_BUSY_WRITE
    command 0x9f, 0
    ldr     r0, =0xa1000000
    str     r0, [r10, #4]
    str     r0, [r10, #4]           @ again while busy
.endif
.ifdef NEG_NOT_READY
    ldr     r0, [r9]                @ no transfer, no word
.endif
.ifdef NEG_HALF_DATA
    ldrh    r0, [r9]
.endif
.ifdef NEG_CMD_READ
    ldr     r0, [r10, #8]           @ command bytes are write-only
.endif
.ifdef NEG_AUXSPIDATA
    ldrb    r0, [r10, #2]           @ backup SPI data is not routed
.endif
.ifdef NEG_LDM_DATA
    ldmia   r9, {r0, r1}            @ block transfers never reach the slot
.endif
done:
    b       done

bad:
    mov     r0, #0xba
    put     r0
    b       bad

/* Start the transfer, read every word as soon as ROMCTRL bit 23 says one
 * is ready, then wait for busy to clear. Results: r4 checksum (h * 33 + w),
 * r5 AND, r6 first, r7 last, r12 words read, capture word at +0xec. */
xfer:
    str     r2, [r10, #4]
    mov     r4, #0
    mvn     r5, #0
    mov     r6, #0
    mov     r7, #0
    mov     r12, #0
    cmp     r3, #0
    beq     3f
1:  ldr     r0, [r10, #4]
    tst     r0, #0x00800000
    beq     1b
    ldr     r1, [r9]
    add     r4, r4, r4, lsl #5
    add     r4, r4, r1
    and     r5, r5, r1
    cmp     r12, #0
    moveq   r6, r1
    cmp     r12, r8
    streq   r1, [r11, #0xec]
    mov     r7, r1
    add     r12, r12, #1
    cmp     r12, r3
    bne     1b
3:  ldr     r0, [r10, #4]
    tst     r0, #0x80000000
    bne     3b
    bx      lr

/* r0 = IF & card bit, acknowledged. */
if_card:
    ldr     r1, =0x04000214
    ldr     r0, [r1]
    and     r0, r0, #0x00080000
    str     r0, [r1]
    bx      lr

/* One-word B7 read (size 7): r1 = the word; IF acknowledged. */
single:
    mov     r12, lr
    ldr     r0, =0xa7000000
    str     r0, [r10, #4]
1:  ldr     r0, [r10, #4]
    tst     r0, #0x00800000
    beq     1b
    ldr     r1, [r9]
    str     r1, [r11, #0xec]
2:  ldr     r0, [r10, #4]
    tst     r0, #0x80000000
    bne     2b
    bl      if_card
    ldr     r1, [r11, #0xec]
    bx      r12

/* Chip ID with r2 = ROMCTRL: r4 = ROMCTRL while the word waits, r5 = the
 * ID, r6 = IF bit 19 after busy clears (acknowledged), r7 = ROMCTRL after. */
chip:
    mov     r12, lr
    str     r2, [r10, #4]
1:  ldr     r4, [r10, #4]
    tst     r4, #0x00800000
    beq     1b
    ldr     r5, [r9]
2:  ldr     r0, [r10, #4]
    tst     r0, #0x80000000
    bne     2b
    bl      if_card
    mov     r6, r0
    ldr     r7, [r10, #4]
    bx      r12
.ltorg

irq_entry:
    stmfd   sp!, {r0-r3}
    ldr     r2, =0x04000214
    ldr     r0, [r2]
    ldr     r1, [r2, #-4]
    and     r0, r0, r1
    str     r0, [r2]
    str     r0, [r11, #0xf4]
    ldr     r1, [r11, #0xf0]
    add     r1, r1, #1
    str     r1, [r11, #0xf0]
    ldmfd   sp!, {r0-r3}
    subs    pc, lr, #4
.ltorg
