/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Two real CPUs publish each phase in main RAM only after the previous
 * owner has finished. Both execute code installed by ARM9 through aliases. */
.syntax unified
.arm
.text
.macro phase n, reg
    mov r0, #\n
    str r0, [r10, #\reg]
.endm
.macro waitfor n, reg
1:  ldr r0, [r10, #\reg]
    cmp r0, #\n
    bne 1b
.endm
.macro check reg, expected
    ldr r3, =\expected
    cmp \reg, r3
    bne failed
.endm
.macro execute ptr, answer
    adr lr, 1f
    bx \ptr
1:  check r0, \answer
.endm
.ifndef ARM7
    .word 0xe7ffdeff, 0xe7ffdeff
    .org 0x800
.endif
    ldr r10, =0x02000fe0           @ ARM9 phase, ARM7 phase; then two result words
    ldr r11, =0x04000244
.ifdef ARM7
    ldr r8, =0x037f8000
    add r9, r8, #0x4000
    waitfor 1, 0
    ldrb r0, [r11, #-3]            @ ARM7 WRAMSTAT
    check r0, 0
    ldr r4, =0x03808000
    mov r0, #95
    str r0, [r8, #0x100]           @ mode 0: private alias, not shared bank A
    ldr r0, [r4, #0x100]
    check r0, 95
    phase 1, 4
    waitfor 2, 0
    ldrb r0, [r11, #-3]
    check r0, 1
    execute r9, 17                 @ mode 1: low 16 KiB at either mirror
    mov r0, #49
    strb r0, [r8]                  @ patch first instruction for ARM9
    phase 2, 4
    waitfor 3, 0
    ldrb r0, [r11, #-3]
    check r0, 2
    execute r8, 34                 @ mode 2: high 16 KiB in either mirror
    ldr r0, =0x12345678
    str r0, [r8, #8]
    ldr r0, =0xbeef
    strh r0, [r9, #10]
    mov r0, #0xab
    strb r0, [r9, #9]
    phase 3, 4
    waitfor 4, 0
    ldrb r0, [r11, #-3]
    check r0, 3
    execute r8, 49                 @ mode 3: both banks visible in order
    execute r9, 34
    ldr r0, [r9, #8]
    check r0, 0xbeefab78
    ldr r0, [r4, #0x100]           @ private RAM survived every remap
    check r0, 95

    @ Real exception entry/return in both ISAs. Test the registers of the
    @ caller's bank, nonvolatile registers and condition flags, not a
    @ precomputed delay result. The HDL observer also counts decrements.
    msr cpsr_c, #0xdf              @ System, both IRQ and FIQ masked
    ldr sp, =0x0380f000
    mov r5, sp
    ldr r6, =0x31f4a1e7
    mov lr, r6
    mov r12, r6
    mov r0, #3
    cmp r5, r5                     @ Z=C=1
    swi 0x030000
    bne failed
    bcc failed
    cmp r0, #0
    bne failed
    mrs r2, cpsr
    and r2, r2, #0xff
    check r2, 0xdf
    msr cpsr_c, #0x5f              @ System, IRQ enabled; no IRQ source
    adr r2, wait_thumb
    add r2, r2, #1
    adr r7, after_wait
    bx r2
    .thumb
    .balign 4
wait_thumb:
    movs r0, #5
    cmp r0, #6                     @ N=1, C=0
    swi 3
    bpl bad_thumb
    bcs bad_thumb
    cmp r0, #0
    bne bad_thumb
    bx r7
bad_thumb: b bad_thumb
    .arm
    .balign 4
after_wait:
    mrs r2, cpsr
    and r2, r2, #0xff
    check r2, 0x5f
    cmp sp, r5
    bne failed
    cmp lr, r6
    bne failed
    cmp r12, r6
    bne failed
    ldr r0, =0x7777beef
    str r0, [r10, #12]
.else
    ldr r8, =0x03ff8000            @ ARM9 high 8 MiB is also shared, not private
    add r9, r8, #0x4000
    ldrb r0, [r11, #3]             @ direct boot selected all shared for ARM7
    check r0, 3
    mov r0, #0
    strb r0, [r11, #3]
    adr r0, low_code
    ldmia r0, {r4,r5}
    stmia r8, {r4,r5}
    adr r0, high_code
    ldmia r0, {r4,r5}
    stmia r9, {r4,r5}
    execute r8, 17
    phase 1, 0
    waitfor 1, 4
    ldr r0, =0x01808080            @ E/F/G LCDC; WRAMCNT=1 in same word
    str r0, [r11]
    ldr r0, [r11]
    check r0, 0x01808080
    execute r8, 34
    phase 2, 0
    waitfor 2, 4
    ldr r0, =0x0281                @ bank G + WRAMCNT=2 in one halfword
    strh r0, [r11, #2]
    ldrh r0, [r11, #2]
    check r0, 0x0281
    execute r9, 49
    phase 3, 0
    waitfor 3, 4
    mov r0, #3
    strb r0, [r11, #3]
    ldrb r0, [r11, #3]
    check r0, 3
    str r0, [r8]                   @ ignored; must not corrupt ARM7's code
    ldr r0, [r8]
    check r0, 0
    phase 4, 0
    ldr r0, =0x9999cafe
    str r0, [r10, #8]
.endif
    b .
low_code: mov r0, #17
    bx lr
high_code: mov r0, #34
    bx lr
failed: b failed
.ltorg
