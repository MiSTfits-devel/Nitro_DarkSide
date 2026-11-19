/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Two independent cold BIOSes. The host never answers a POST read/write. */
.syntax unified
.cpu arm7tdmi
.arm
.text
.global start
start: b reset
       b failed
       b warm                        @ guest SWI -> vector -> reset entry, no chip reset
reset:
    ldr r4, =0x04000300
    ldrb r0, [r4]
    tst r0, #1
    bne passed_warm
    cmp r0, #0
    bne failed
.ifdef REJECT
    mov r0,#0x8000
    .ifdef ARM7
        .if REJECT==1
            ldr r0,[r4]              @ ARM7 word read isn't a POST register
        .elseif REJECT==2
            strh r0,[r4]             @ overlaps HALTCNT halt command
        .else
            str r0,[r4]              @ ARM7 word write
        .endif
    .else
        str r0,[r4]                  @ ARM9 word write unsupported
    .endif
    b failed
.endif
.ifdef ARM7
    ldr r5,=0x04000180
1:  ldrh r0,[r5]
    and r0,r0,#0xf
    cmp r0,#0xa                      @ ARM9 sets its sticky bit before sending
    bne 1b
    ldrb r0,[r4]
    cmp r0,#0                        @ ARM9's set must not affect ARM7
    bne failed
    @ Run the actual store/BX instruction pair in ARM7 private WRAM. The
    @ immediately following redirect targets BIOS but cannot authorize STRB.
    ldr r2, =0x03800100
    adr r3, copy
    ldmia r3, {r5,r6,r7}
    stmia r2, {r5,r6,r7}
    mov r1,#1
    adr lr, arm_return
    bx r2
arm_return:
    ldrb r0,[r4]
    cmp r0,#0
    bne failed
    add r2,r2,#9                     @ Thumb source two halfwords at offset 8
    adr lr, thumb_return
    bx r2
thumb_return:
    ldrh r0,[r4]
    cmp r0,#0
    bne failed
    bl edge_denied                   @ ARM tagged R15 = 4000: rejected
    ldrh r0,[r4]
    cmp r0,#0
    bne failed
    msr cpsr_c,#0xd0                 @ User in BIOS may set it; SVC in WRAM could not
    mrs r0,cpsr
    and r0,r0,#0x1f
    cmp r0,#0x10
    bne failed
    mov r1,#0xff
    bl edge_allowed                  @ ARM tagged R15 = 3ffc: accepted
    ldrh r0,[r4]
    cmp r0,#1                        @ reserved bits, incl bit 1, read as 0
    bne failed
    mov r1,#0
    strh r1,[r4]
.else
    bl edge_end
    mov r0,#0xfe
    strb r0,[r4]
    ldrh r0,[r4]
    cmp r0,#2
    bne failed
    mov r0,#3
    strh r0,[r4]
    ldr r0,[r4]
    cmp r0,#3
    bne failed
    mov r0,#0
    strb r0,[r4]                     @ b0 sticky, b1 clears
    ldr r5,=0x04000180
    mov r0,#0xa00
    strh r0,[r5]
.endif
    ldrb r0,[r4]
    cmp r0,#1
    bne failed
    swi 0
    b failed
warm: b start
passed_warm:
    cmp r0,#1
    bne failed
passed: b passed
failed: .word 0xe7f000f0
.ltorg
.ifdef ARM7
copy:
    strb r1,[r4]
    bx lr
    .thumb
    strb r1,[r4]
    bx lr
    .arm
    .org 0x3ff4
edge_allowed: strh r1,[r4]
edge_denied:  strb r1,[r4]
edge_end:     bx lr
.else
    .org 0xffc
edge_end: bx lr
.endif
