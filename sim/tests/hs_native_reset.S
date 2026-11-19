/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Public pin/CPU diagnostic, not a BIOS implementation. */
.syntax unified
.arm
.ifdef ARM7
.cpu arm7tdmi
.else
.cpu arm946e-s
.endif
.text
.global start, passed, failed
start:
    mrs r0, cpsr
    and r0, r0, #255
    cmp r0, #0xd3
    bne failed
.ifdef ARM7
    ldr r2, =0x04000308
    ldrh r0, [r2]
    cmp r0, #0
    bne failed
    ldr r1, =0x201
    strh r1, [r2]
    mov r1, #0x400
    strh r1, [r2]
    ldr r0, [r2]
    cmp r0, #0x200
    bne failed
    b upper7
.else
    mrc p15, 0, r0, c1, c0, 0
    ldr r1, =0x2078
    cmp r0, r1
    bne failed
    ldr r2, =0xffff0ffb
    ldrb r0, [r2]
    cmp r0, #0xa9
    bne failed
    ldr r2, =0x04000204
    ldrh r0, [r2]
    cmp r0, #0x900
    bne failed
    b last_word
.endif
.ltorg
passed: b passed
failed: .word 0xe7f000f0
.ifdef ARM7
.org 0x100
    .word 0xa7b1c2d3
.org 0x3000
upper7:
    mov r2, #0x100
    ldr r0, [r2]
    cmn r0, #1
    bne failed
    ldr r2, =0x3ffa
    ldrh r0, [r2]
    ldr r1, =0xa7b1
    cmp r0, r1
    bne failed
    ldr r2, =0x04000204
    ldrh r0, [r2]
    cmp r0, #0x700
    bne failed
    b last_word
.ltorg
.org 0x3ff8
    .word 0xa7b1c2d3
.else
.org 0xff8
    .word 0xa9b1c2d3
.endif
last_word: b passed
