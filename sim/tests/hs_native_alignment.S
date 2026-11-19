/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Source-only ARM946E-S reset ROM. Real ARM/Thumb code and explicit expected
 * data. No stock images, no predicted ROMCTRL replies or firmware. */
.syntax unified
.cpu arm946e-s
.arm
.text
.global start
start:
    mrc p15,0,r0,c1,c0,0
    orr r1,r0,#2                      @ c1[1] is SBZ, NOT an alignment-fault switch
    mcr p15,0,r1,c1,c0,0
    mrc p15,0,r1,c1,c0,0
    cmp r0,r1
    bne failed
    adr r4, pattern
    ldr r0,[r4,#1]
    ldr r1,=0x11807f52
    cmp r0,r1
    bne failed
    ldr r0,[r4,#2]
    ldr r1,=0x5211807f
    cmp r0,r1
    bne failed
    ldr r0,[r4,#3]
    ldr r1,=0x7f521180
    cmp r0,r1
    bne failed
    ldrsh r0,[r4,#3]
    ldr r1,=0xffff807f
    cmp r0,r1
    bne failed
    ldrh r0,[r4,#1]
    ldr r1,=0x5211
    cmp r0,r1
    bne failed
    ldr r4,=0x04000204               @ independent external byte-array responder
    ldr r2,=0xace05178
    str r2,[r4,#1]!
    ldr r3,=0x04000205
    cmp r4,r3                        @ bus aligned, writeback is original odd address
    bne failed
    ldr r0,[r4],#2
    ldr r1,=0x78ace051
    cmp r0,r1
    bne failed
    add r3,r3,#2
    cmp r4,r3
    bne failed
    ldr r2,=0xd9a3
    strh r2,[r4]
    ldr r2,=0x34
    strb r2,[r4]
    ldr r0,[r4]
    ldr r1,=0xa3517834
    cmp r0,r1
    bne failed
    adr lr,thumb_return
    adr r0,thumb_start
    add r0,r0,#1
    bx r0
    .thumb
thumb_start:
    ldr r0,[r4]
    cmp r0,r1
    bne thumb_fail
    ldrh r0,[r4]
    ldr r1,=0x34a3
    cmp r0,r1
    bne thumb_fail
    movs r1,#0
    ldrsh r0,[r4,r1]
    ldr r1,=0x34a3
    cmp r0,r1
    bne thumb_fail
    bx lr
thumb_fail: .hword 0xde00
    .balign 4
    .arm
thumb_return:
passed: b passed
failed: .word 0xe7f000f0
pattern: .word 0x807f5211
.ltorg
