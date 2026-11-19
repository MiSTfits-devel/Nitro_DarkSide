/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * All-Haskell native slice fixture: the Clash ARM9 slice draws an animated
 * pattern into real LCDC VRAM banks A/B, waits for the real DISPSTAT VBlank
 * flag and flips DISPCNT's VRAM-display bank, so every displayed frame is a
 * complete buffer. Only the slice's implemented subset is used (DP, B/BX,
 * pre-indexed immediate LDR/STR/LDRH/STRH without writeback, literal pool).
 *
 * Buffer t, pixel (x, y), BGR555:
 *   R = (((x + 4t) xor y) >> 3) & 31
 *   G = ((y >> 2) + t) & 31
 *   B = ((191 - y) >> 3) & 31
 * NativeSliceFrames.hs checks captured frames against this formula
 * independently of this program.
 */
.syntax unified
.cpu arm946e-s
.arm
.text

    mov     r7, #0x04000000     @ I/O base
    ldr     r0, =0x04000304     @ POWCNT1: LCD on, Engine A, A on top
    ldr     r1, =0x8003
    strh    r1, [r0]
    ldr     r0, =0x04000240
    mov     r1, #0x80
    strb    r1, [r0]            @ VRAMCNT_A: LCDC 0x06800000
    strb    r1, [r0, #1]        @ VRAMCNT_B: LCDC 0x06820000
    mov     r1, #0x00020000     @ DISPCNT: VRAM display, bank A
    str     r1, [r7]
    mov     r12, #31
    mov     r9, #0              @ t
    ldr     r10, =0x06820000    @ back buffer: bank B
    ldr     r13, =0x00060000    @ DISPCNT showing bank B

frame:
    mov     r8, r9, lsl #2      @ 4t
    mov     r3, r10
    mov     r6, #0              @ y
rows:
    add     r0, r9, r6, lsr #2
    and     r0, r0, #31         @ G
    rsb     r1, r6, #191
    and     r1, r12, r1, lsr #3 @ B
    mov     r11, r0, lsl #5
    orr     r11, r11, r1, lsl #10
    mov     r5, #0              @ x
cols:
    add     r4, r5, r8
    eor     r4, r4, r6
    and     r4, r12, r4, lsr #3
    orr     r4, r4, r11         @ pixel x
    add     r2, r5, r8
    add     r2, r2, #1
    eor     r2, r2, r6
    and     r2, r12, r2, lsr #3
    orr     r2, r2, r11         @ pixel x + 1
    orr     r4, r4, r2, lsl #16
    str     r4, [r3]
    add     r3, r3, #4
    add     r5, r5, #2
    cmp     r5, #256
    bne     cols
    add     r6, r6, #1
    cmp     r6, #192
    bne     rows

leave_vblank:                   @ a flip must land in a fresh VBlank
    ldrh    r0, [r7, #4]
    tst     r0, #1
    bne     leave_vblank
enter_vblank:
    ldrh    r0, [r7, #4]
    tst     r0, #1
    beq     enter_vblank
    str     r13, [r7]           @ show the finished buffer from line 0
    eor     r10, r10, #0x00020000
    eor     r13, r13, #0x00040000
    add     r9, r9, #1
    b       frame
.ltorg
