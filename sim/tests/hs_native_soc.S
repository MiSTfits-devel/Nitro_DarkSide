/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * All-Haskell native SoC fixture: hs_native_slice.S's double-buffered
 * display, plus Nds.WholeCore.Arm9Io's timers and ARM9 IME/IE/IF, every
 * frame. The CPU keeps the reset CPSR (I=1), so the IRQ line Arm9Soc drives
 * into it is never taken as an exception. It polls the real IF latch instead:
 *   - timer 0, F/1 with IRQ enabled, reload 0xFF00: the CPU starts it, polls
 *     IF bit 3, write-one-clears it, stops the timer and reads the count;
 *   - the authoritative GPU's VBlank IRQ (DISPSTAT bit 3) latches IF bit 0;
 *     the CPU clears a stale latch, waits for the next one, then flips the
 *     displayed bank.
 * Mailbox in local RAM 0x02000000 (rewritten each frame):
 *   +0 TM0 count just after start      +4 IF when bit 3 was seen
 *   +8 IF polls until bit 3            +12 TM0 count after detection
 *   +16 IF after W1C bit 3             +20 TM0 count after stop
 *   +24 IF when VBlank (bit 0) seen    +28 buffer t just shown
 *   +32 IE readback, +36 IME readback (once, at boot)
 * The host checks every local read reply against its own timer arithmetic
 * and IF event model, and checks every frame against the pattern formula of
 * hs_native_slice.S (identical drawing code).
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
    add     r6, r7, #0x100      @ TM0CNT
    ldr     r5, =0x02000000     @ mailbox
    mov     r0, #1
    str     r0, [r7, #0x208]    @ IME = 1
    mov     r0, #9
    str     r0, [r7, #0x210]    @ IE = VBlank | timer 0
    mov     r0, #8
    strh    r0, [r7, #4]        @ DISPSTAT: VBlank IRQ enable
    ldr     r0, [r7, #0x210]
    str     r0, [r5, #32]
    ldr     r0, [r7, #0x208]
    str     r0, [r5, #36]
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

    /* Timer 0 overflow through the IF latch. */
    add     r6, r7, #0x100
    ldr     r5, =0x02000000
    ldr     r0, =0x0000ff00     @ stopped, reload 0xFF00
    str     r0, [r6]
    mov     r2, #8
    str     r2, [r7, #0x214]    @ drop an overflow latched after the last stop
    ldr     r1, =0x00c0ff00     @ start: F/1, IRQ enable
    str     r1, [r6]
    ldrh    r2, [r6]
    str     r2, [r5]
    mov     r3, #0
poll_timer:
    add     r3, r3, #1
    ldr     r2, [r7, #0x214]
    tst     r2, #8
    beq     poll_timer
    str     r2, [r5, #4]
    str     r3, [r5, #8]
    ldrh    r2, [r6]
    str     r2, [r5, #12]
    mov     r2, #8
    str     r2, [r7, #0x214]    @ W1C timer 0
    ldr     r2, [r7, #0x214]
    str     r2, [r5, #16]
    str     r0, [r6]            @ stop
    ldrh    r2, [r6]
    str     r2, [r5, #20]

    /* Flip on the GPU's VBlank IRQ latch. */
    mov     r2, #1
    str     r2, [r7, #0x214]    @ drop a stale VBlank latch
wait_vblank:
    ldr     r2, [r7, #0x214]
    tst     r2, #1
    beq     wait_vblank
    str     r13, [r7]           @ show the finished buffer from line 0
    str     r2, [r5, #24]
    str     r9, [r5, #28]
    eor     r10, r10, #0x00020000
    eor     r13, r13, #0x00040000
    add     r9, r9, #1
    b       frame
.ltorg
