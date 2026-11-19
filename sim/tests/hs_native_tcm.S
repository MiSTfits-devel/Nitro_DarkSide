/* SPDX-License-Identifier: GPL-3.0-or-later */
.syntax unified
.cpu arm946e-s
.arm
.text
.global start
start:
.ifdef ARM7
    ldr r4,=0x04000180
1:  ldrh r0,[r4]
    and r0,r0,#0xf
    cmp r0,#0xc
    bne 1b
    mov r5,#0x200
    ldr r0,[r5]                     @ private ARM7 BIOS, not ARM9 ITCM
    ldr r1,=0xbeef0717
    cmp r0,r1
    bne fail
    b passed
    .org 0x200
    .word 0xbeef0717
.else
    mrc p15,0,r0,c0,c0,2
    ldr r1,=0x140180                @ physical 32 KiB I, 16 KiB D
    cmp r0,r1
    bne fail
    mrc p15,0,r0,c9,c1,0
    cmp r0,#10
    bne fail
    mrc p15,0,r0,c9,c1,1
    cmp r0,#12
    bne fail
    mov r0,#0x3f                    @ MPU region 0 spans 4 GiB
    mcr p15,0,r0,c6,c0,0
    mov r0,#3
    mcr p15,0,r0,c5,c0,0
    mcr p15,0,r0,c5,c0,1
    mrc p15,0,r8,c1,c0,0
    orr r8,r8,#1
    mcr p15,0,r8,c1,c0,0
    ldr r7,=0xffff000e              @ 64 KiB D window overlays high BIOS
    mcr p15,0,r7,c9,c1,0
    mrc p15,0,r0,c6,c0,0           @ TCM configuration must not change MPU state
    cmp r0,#0x3f
    bne fail
    mrc p15,0,r0,c9,c1,0
    cmp r0,r7
    bne fail
    orr r9,r8,#0x30000              @ D enabled+load: writes to D, reads underlay
    mcr p15,0,r9,c1,c0,0
    adr r4,underlay
    ldr r5,=0x90613427
    str r5,[r4]
    ldr r0,[r4]
    ldr r1,=0xabcdef12
    cmp r0,r1
    bne fail
    bic r9,r9,#0x20000
    mcr p15,0,r9,c1,c0,0
    ldr r0,[r4]
    cmp r0,r5
    bne fail
    add r4,r4,#0x4000               @ physical D mirror
    ldr r0,[r4]
    cmp r0,r5
    bne fail
    mov r0,#0x49
    strb r0,[r4,#1]
    mov r0,#0xa2
    strh r0,[r4,#2]
    ldr r1,[r4]
    mov r2,#0x27
    orr r2,r2,#0x4900
    orr r2,r2,#0xa20000
    cmp r1,r2
    bne fail
    mcr p15,0,r8,c1,c0,0
    adr r4,underlay
    ldr r0,[r4]
    ldr r1,=0xabcdef12
    cmp r0,r1
    bne fail
    mov r0,#46                      @ full address space, I load mode
    mcr p15,0,r0,c9,c1,1
    orr r9,r8,#0xc0000
    mcr p15,0,r9,c1,c0,0            @ fetch must still come from high BIOS
    str r5,[r4]
    ldr r0,[r4]                     @ data also reads real BIOS in load mode
    cmp r0,r1
    bne fail
    mcr p15,0,r8,c1,c0,0
    mov r0,#14                      @ 64KiB windows at zero; NTR physical banks mirror
    mcr p15,0,r0,c9,c1,0
    mcr p15,0,r0,c9,c1,1
    orr r9,r8,#0x10000
    mcr p15,0,r9,c1,c0,0
    mov r4,#0x200
    ldr r5,=0xfeed2910
    str r5,[r4]
    orr r9,r9,#0xc0000              @ I enabled+load mode, D enabled normal
    mcr p15,0,r9,c1,c0,0
    adr r10,code
    ldmia r10,{r0-r2}
    stmia r4,{r0-r2}                @ load-mode writes win I; reads fall to D
    ldr r0,[r4]
    cmp r0,r5
    bne fail
    bic r9,r9,#0x80000
    mcr p15,0,r9,c1,c0,0
    ldr r0,[r4]
    ldr r1,[r10]
    cmp r0,r1
    bne fail
    add r4,r4,#0x8000               @ same physical I; execute via alias
    mov r6,#0
    blx r4
    cmp r6,#0x31
    bne fail
    add r4,r4,#9
    blx r4                          @ Thumb instruction pair
    cmp r6,#0x59
    bne fail
    mcr p15,0,r8,c1,c0,0
    orr r9,r8,#0x10000
    mcr p15,0,r9,c1,c0,0
    mov r4,#0x200
    ldr r0,[r4]
    cmp r0,r5                       @ independent D retained after I disabled
    bne fail
    mcr p15,0,r8,c1,c0,0
    ldr r4,=0x02000000
    ldr r5,=0xa1b2c3d4
    str r5,[r4]                     @ real, separately observed external RAM
    mov r0,#0xe7
    strb r0,[r4,#1]
    ldr r5,=0xa1b2e7d4
    ldr r0,[r4]
    cmp r0,r5
    bne fail
    orr r0,r4,#10
    mcr p15,0,r0,c9,c1,0
    orr r9,r8,#0x30000
    mcr p15,0,r9,c1,c0,0
    ldr r6,=0x7253fa19
    str r6,[r4]                     @ D load mode writes privately
    ldr r0,[r4]                     @ D load mode reads main RAM
    cmp r0,r5
    bne fail
    bic r9,r9,#0x20000
    mcr p15,0,r9,c1,c0,0
    ldr r0,[r4]
    cmp r0,r6
    bne fail
    mov r0,#0x66
    strh r0,[r4,#2]
    ldr r7,=0x0066fa19
    ldr r0,[r4]
    cmp r0,r7
    bne fail
    add r3,r4,#0x4000
    orr r0,r3,#10
    mcr p15,0,r0,c9,c1,0            @ moved window retains its physical bank
    ldr r0,[r3]
    cmp r0,r7
    bne fail
    ldr r0,[r4]                     @ uncovered RAM preserved through remap
    cmp r0,r5
    bne fail
    mcr p15,0,r8,c1,c0,0
    ldr r0,[r4]
    cmp r0,r5
    bne fail
    ldr r4,=0x04000180
    mov r0,#0xc00
    strh r0,[r4]
    b passed
code:
    mov r6,#0x31
    bx lr
    .thumb
    movs r6,#0x59
    bx lr
    .arm
underlay: .word 0xabcdef12
.endif
fail: .word 0xe7f000f0
passed: b passed
.ltorg
