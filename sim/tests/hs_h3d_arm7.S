/* SPDX-License-Identifier: GPL-3.0-or-later */
.syntax unified
.cpu arm7tdmi
.arm
.text
    ldr r1, =0x04000240             @ VRAMSTAT: wait until ARM9 assigns bank C
1:  ldrb r0, [r1]
    tst r0, #1
    beq 1b
    mov r1, #0x06000000
    ldr r0, =0xfedcba98
    str r0, [r1, #4]
2:  b 2b
    .ltorg
