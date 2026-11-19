/* SPDX-License-Identifier: GPL-3.0-or-later */
.syntax unified
.cpu arm946e-s
.arm
.text

/* This tiny boot image writes what the ARM9 actually loaded to main RAM. */
    mov     r7, #0x02000000
    ldr     r0, =0x04000304      @ POWCNT1
    ldr     r1, =0xffff
    strh    r1, [r0]
    ldrh    r2, [r0]            @ 0x820f, not the store value
    str     r2, [r7, #0]

    ldr     r0, =0x04000240
.ifdef UNSUPPORTED_IO
    ldrb    r2, [r0, #7]        @ WRAMCNT, not GPU-owned
    b       .
.endif
    mov     r1, #0x80
    strb    r1, [r0, #1]        @ VRAMCNT_B: map the bank to LCDC
    ldrb    r2, [r0, #1]
    str     r2, [r7, #4]

    ldr     r3, =0x06820000     @ LCDC bank B aperture
    ldr     r1, =0xa526
    strh    r1, [r3, #2]        @ the upper two byte lanes
    ldrh    r2, [r3, #2]
    str     r2, [r7, #8]

    mov     r1, #0x81
    strb    r1, [r0, #1]        @ remap bank B to Engine A BG, offset 0
    mov     r4, #0x06000000
    ldrh    r2, [r4, #2]
    str     r2, [r7, #12]
    ldr     r2, [r4]
    str     r2, [r7, #16]
    ldrh    r2, [r3, #2]        @ old mapping is no longer accessible
    str     r2, [r7, #20]
1:  b       1b
.ltorg
