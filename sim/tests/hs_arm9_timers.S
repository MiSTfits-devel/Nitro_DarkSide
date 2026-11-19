/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Executed by the real ARM9 slice. Mailbox values are intentionally independent
 * of CPU/bus latency: both running timers reload FFFF on every overflow. */
.syntax unified
.cpu arm946e-s
.arm
.text
    mov     r7, #0x02000000
    ldr     r0, =0x04000100     @ TM0CNT_L/H, TM1CNT_L/H
    ldr     r4, =0x04000208     @ IME
    ldr     r5, =0x04000210     @ IE, IF
    ldr     r2, [r5, #4]
    str     r2, [r7, #0]       @ IF initially 0
    mov     r1, #0x18
    str     r1, [r5]            @ enable timer 0 and timer 1 IRQs
    mov     r1, #1
    str     r1, [r4]            @ master IRQ enable
    ldr     r2, [r5]
    str     r2, [r7, #4]       @ IE = 0x18
    ldr     r2, [r4]
    str     r2, [r7, #8]       @ IME = 1
    ldr     r1, =0x00c4ffff
    str     r1, [r0, #4]       @ timer 1 cascade, IRQ, reload FFFF
    ldr     r1, =0x00c0ffff
    str     r1, [r0]            @ timer 0 F/1, IRQ, reload FFFF
    ldr     r2, [r5, #4]
    str     r2, [r7, #12]      @ both IF bits set: 0x18
    ldrh    r2, [r0]
    str     r2, [r7, #16]      @ timer 0 = FFFF
    ldrh    r2, [r0, #4]
    str     r2, [r7, #20]      @ timer 1 = FFFF
    mov     r1, #0
    strh    r1, [r0, #2]       @ stop source before acknowledging
    strh    r1, [r0, #6]       @ stop cascade
    ldrh    r2, [r0, #2]
    str     r2, [r7, #24]      @ stopped control = 0
    mov     r1, #8
    strb    r1, [r5, #4]       @ ARM9 byte write to IF is ignored
    ldr     r2, [r5, #4]
    str     r2, [r7, #28]      @ IF remains 0x18
    strh    r1, [r5, #4]       @ halfword W1C timer 0
    ldr     r2, [r5, #4]
    str     r2, [r7, #32]      @ IF = 0x10
    mov     r1, #0x10
    str     r1, [r5, #4]       @ W1C timer 1
    ldr     r2, [r5, #4]
    str     r2, [r7, #36]      @ IF = 0
    mov     r1, #0
    strb    r1, [r4]           @ disable IME by byte
    ldr     r2, [r4]
    str     r2, [r7, #40]      @ IME = 0
1:  b       1b
.ltorg
