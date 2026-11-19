/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Public post-firmware fixture. The ARM9 entry sums all 512 words that
 * precede it (ROM 0x4000..47ff). Neither they nor the entry at ROM 0x4800
 * are available through main-mode B7. The ARM7 checks its own handoff LR. */
.syntax unified
.arm
.text
.macro timer_irq
    ldr r11, =0x04000214 @ IF; IME at -12, IE at -4
    mov r5, #1
    str r5, [r11, #-12]
    mov r5, #8
    str r5, [r11, #-4]
    mov r10, #0
    ldr r4, =0x04000100
    ldr r5, =0x00c0fffe
    str r5, [r4]        @ timer IRQ on; overflows in two ce7 ticks
    .rept 12
    mov r0, r0
    .endr
    mov r5, #0
    strh r5, [r4, #2]   @ stop; IF remains pending while CPSR.I is set
    msr cpsr_c, #0x53
    cmp r10, #8         @ handler must have acked before this can commit
    bne failed
.endm
.macro nonalias offset
    ldr r4, =0x02000000 + \offset
    ldr r5, =0x02300000 + \offset
    ldr r6, =0x02f00000 + \offset
    mov r7, #0x31
    mov r8, #0x72
    str r7, [r4]
    str r8, [r5]
    ldr r9, [r4]
    cmp r9, r7
    bne failed
    ldr r9, [r6]        @ true 4 MiB mirror, not a 4 KiB alias
    cmp r9, r8
    bne failed
.endm
.macro patch_next
    adr r4, target\@
    add r4, r4, #0x400000   @ write through another true main RAM mirror
    mov r5, #37
    strb r5, [r4]           @ change just the immediate in the next MOV
target\@: mov r9, #1
    cmp r9, #37
    bne failed
.endm
.ifdef ARM7
.ifndef WRAM_ONLY
    timer_irq
    nonalias 0xbf0
    patch_next
.endif
    @ 64 KiB of private storage, not the shared WRAM or main RAM.
    ldr r4, =0x03800000
    ldr r5, =0x03ff0000       @ last of 128 aliases of the same first word
    ldr r6, =0x12345678
    str r6, [r4]
    mov r7, #0xab
    strb r7, [r5, #1]
    ldr r7, =0xcdef
    strh r7, [r5, #2]
    ldrb r0, [r4, #1]
    cmp r0, #0xab
    bne failed
    ldrh r0, [r4, #2]
    cmp r0, r7
    bne failed
    ldr r0, [r5]
    ldr r7, =0xcdefab78
    cmp r0, r7
    bne failed

    @ Run ARM code at the end of private WRAM through a different alias.
    @ Patch through a third mirror, then branch to refetch the changed word
    @ rather than relying on the contents of the instruction prefetch queue.
    adr r5, private_code
    ldmia r5, {r0-r3}
    ldr r4, =0x0380fff0
    stmia r4, {r0-r3}
    ldr r4, =0x03908000
    ldr r0, private_thumb
    str r0, [r4]
    ldr r4, =0x03fffff0
    ldr r5, =0x03a0fff8
    ldr r6, =0x03808001
    adr r3, private_return
    mov r7, #37
    bx r4
private_code:
    strb r7, [r5]
    b 1f
1:  mov r1, #1                @ rewritten to MOV r1,#37
    bx r6
    .thumb
    .balign 4
private_thumb:
    adds r1, #6
    bx r3
    .arm
private_return:
    cmp r1, #43
    bne failed
    ldr r4, =0x03800000
    ldr r0, [r4]
    ldr r7, =0xcdefab78
    cmp r0, r7
    bne failed
.ifdef WRAM_ONLY
    @ Standalone independent ARM7 reference: publish the value returned
    @ by the same private ARM -> Thumb code, without unrelated peripherals.
    ldr r4, =0x02000ffc
    str r1, [r4]
    b .
.endif
    ldr r4, =0x06020000
    mov r5, #0x93
    strb r5, [r4, #3]
    ldrb r6, [r4, #3]
    cmp r6, r5
    bne failed
    ldr r4, =0x04000240
    ldrb r6, [r4]
    cmp r6, #3
    bne failed
    ldr r0, =0x02000ffc
    str lr, [r0]
1:  b 1b
.else
    .word 0xe7ffdeff, 0xe7ffdeff  @ post-firmware marker; no keys
.set i, 2
.rept 510
    .word (0x57400000 + 13*i)
    .set i, i+1
.endr
    mrc p15,0,r6,c1,c0,0
    ldr r5, =0x12078
    cmp r6,r5
    bne failed
    mcrne p15,0,r0,c1,c0,0      @ condition failed: must not write
    mrc p15,0,r4,c1,c0,0
    cmp r4,r6
    bne failed
    ldr r5, =0xf000607f         @ reserved bits ignored; V=1, RR=1
    bic r5, r5, #5              @ no MPU or D-cache in this slice
    mcr p15,0,r5,c1,c0,0
    mrc p15,0,r4,c1,c0,0
    ldr r5, =0x6078
    cmp r4,r5
    bne failed
    mrc p15,0,apsr_nzcv,c1,c0,0 @ Rd=15 sets flags, doesn't jump
    beq failed                  @ top nibble of c1 was zero => Z=0
    mcr p15,0,r6,c1,c0,0
    timer_irq
    nonalias 0xbf4
    patch_next
    ldr r0, =0x02100000
    adr lr, sum_done
    adr r3, thumb_sum
    add r3, r3, #1
    bx r3
.thumb
.balign 8
thumb_sum:
    movs r1, #0
    movs r2, #128
    lsls r2, r2, #2
1:  ldmia r0!, {r3}
    adds r1, r1, r3
    subs r2, r2, #1
    bne 1b
    bx lr
.arm
.align 2
sum_done:
    ldr r0, =0x02000ff8
    str r1, [r0]
2:  b 2b
.endif
failed: b failed
.ltorg
