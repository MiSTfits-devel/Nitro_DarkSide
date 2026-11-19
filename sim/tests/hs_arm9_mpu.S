/* SPDX-License-Identifier: GPL-3.0-or-later */
/* All addresses/words are synthetic. The runner supplies one RAM MCR which
 * revokes execute permission on its own page and must not execute its successor. */
.syntax unified
.arch armv5te
.arm
.text
    b start
.org 0x0c
    b prefetch_abort
    b data_abort
start:
    mov r7,#0                  @ data abort count
    mov r8,#0                  @ prefetch abort count
    mov sp,#0x84               @ SVC bank survives aborts
    ldr r1,=0xffff0017         @ region 0: boot/vector page (4 KiB)
    mcr p15,0,r1,c6,c0,0
    ldr r1,=0x02000019         @ region 1: 8 KiB RAM, executable, user RW
    mcr p15,0,r1,c6,c1,0
    ldr r1,=0x02001017         @ region 2: high 4 KiB, higher priority
    mcr p15,0,r1,c6,c2,0
    mrc p15,0,r3,c6,c2,0
    cmp r1,r3
    bne bad
    ldr r1,=0x533              @ data: AP5 overlay (priv RO, no user)
    mcr p15,0,r1,c5,c0,2
    mov r1,#0x33               @ code: no execution in overlay
    mcr p15,0,r1,c5,c0,3
    mrc p15,0,r0,c1,c0,0
    orr r0,r0,#1
    mcr p15,0,r0,c1,c0,0
    ldr r2,=0x02001000
    ldr r0,[r2]                @ allowed privileged read
    cmp r0,#0x6b
    bne bad
    mov r6,#0x13
    adr r4,ro_store+8
    adr r5,ro_store+4
ro_store:
    str r0,[r2]                @ denied store: no target access
    ldr r1,=0x04000244
    adr r4,no_region+8
    adr r5,no_region+4
no_region:
    strh r0,[r1]               @ no matching region, no graphics request
    ldr r1,=0x02000ffc
    adr r4,multiple+8
    adr r5,multiple+4
multiple:
    stmia r1!,{r2,r3}          @ first beat permitted, second denied, no final writeback
    ldr r3,=0x02000ffc
    cmp r1,r3
    bne bad
    cmp sp,#0x84
    bne bad
    mov r0,#3                  @ RAM's one instruction revokes region 1 execute
    ldr r4,=0x02000008         @ next ARM word, prefetch-abort LR = PC+4
    adr r5,revoked
    ldr r1,=0x02000000
    bx r1
revoked:
    msr cpsr_c,#0xd0           @ user, ARM, IRQ/FIQ masked
    mov r6,#0x10
    adr r4,user_load+8
    adr r5,user_load+4
user_load:
    ldr r0,[r2]                @ previously privileged-readable, now denied
    add r4,r2,#4
    adr r5,denied_fetch
    bx r2                      @ no instruction-bus transaction for denied page
denied_fetch:
    mov r6,#0x30               @ user + Thumb; abort enters ARM ABT mode
    adr r4,thumb_store+8
    adr r5,thumb_return
    adr r3,finish_arm
    adr r1,thumb_store
    add r1,r1,#1
    cmp r7,r7
    bx r1
.thumb
.align 2
thumb_store:
    str r0,[r2]
thumb_return:
    movs r0,#0x71
    bx r3
.arm
.align 2
finish_arm:
    cmp r0,#0x71
    bne bad
    cmp r7,#5
    bne bad
    cmp r8,#2
    bne bad
finished: .word 0xe7f000f0
prefetch_abort:
    add r8,r8,#1
    b check_abort
data_abort:
    add r7,r7,#1
check_abort:
    cmp lr,r4
    bne bad
    mrs r9,cpsr
    and r9,r9,#0xff
    cmp r9,#0xd7               @ ABT, ARM, interrupt masks preserved/set
    bne bad
    mrs r9,spsr
    tst r9,#0x40000000          @ faulting instructions preserved Z
    beq bad
    and r9,r9,#0x3f
    cmp r9,r6
    bne bad
    movs pc,r5                 @ exact resume address, T/mode/flags from SPSR_abt
bad: .word 0xe7f000f0
.ltorg
