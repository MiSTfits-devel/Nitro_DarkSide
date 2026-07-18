@ Repro for M7 boot blocker #6: timer IRQ interrupting a calico-shaped
@ bx-lr idle loop; handler exits via conditional ldmia sp!,{r0-r3,r12,pc}^.
@ Success: counter at 0x02001000 reaches 50, 0xCAFEBABE lands at 0x02001004,
@ trace parks at `hang`. Failure: pc livelocks on one loop instruction.
    .arm
    .global _start
_start:
    b   reset
    b   hang            @ undef
    b   hang            @ svc
    b   hang            @ pabt
    b   hang            @ dabt
    b   hang            @ resv
    b   irq             @ +0x18
    b   hang            @ fiq

reset:
    @ high vectors (cp15 c1 bit13) so the IRQ vector lands in this ROM
    mrc p15, 0, r0, c1, c0, 0
    orr r0, r0, #0x2000
    mcr p15, 0, r0, c1, c0, 0

    msr cpsr_c, #0xD2           @ IRQ mode, IRQs off
    ldr sp, =0x02000F00
    msr cpsr_c, #0xDF           @ system mode, IRQs off
    ldr sp, =0x02000E00

    ldr r0, =0x02001000         @ irq counter + result word
    mov r1, #0
    str r1, [r0]
    str r1, [r0, #4]

    mov r12, #0x04000000
    mov r0, #8
    str r0, [r12, #0x210]       @ IE = timer0
    mov r0, #1
    str r0, [r12, #0x208]       @ IME = 1
    ldr r0, =0x00C0FF00         @ TM0CNT: enable+irq, reload 0xFF00
    str r0, [r12, #0x100]

    @ idle loop shaped like calico's armContextSwitch tail:
    @   loop_a: msr cpsr_c, r12 / loop_b: mov r0,#0 / loop_c: bx lr(=loop_a)
    mrs r12, cpsr
    bic r12, r12, #0xC0         @ IRQs stay enabled through the msr
    adr lr, loop_a
    msr cpsr_c, #0x1F           @ system mode, IRQs on
loop_a:
    msr cpsr_c, r12
loop_b:
    ldr r0, =0x02001000
    ldr r0, [r0]
    cmp r0, #50
    bge phase2
loop_c:
    bx lr

irq:
    sub lr, lr, #4
    stmdb sp!, {r0-r3, r12, lr}
    mov r12, #0x04000000
    add r12, r12, #0x210
    ldm r12, {r0, r1}           @ r0=IE, r1=IF
    ands r0, r0, r1
    mov r2, #8
    str r2, [r12, #4]           @ ack timer0
    ldr r0, =0x02001000
    ldr r1, [r0]
    add r1, r1, #1
    str r1, [r0]
    cmp r1, #50
    ldmltia sp!, {r0-r3, r12, pc}^   @ same conditional-ldm^ shape as calico
    cmp r1, #70
    ldmltia sp!, {r0-r3, r12, pc}^   @ 50..69: still return (thumb phase)
    cmp r1, #90
    ldmltia sp!, {r0-r3, r12, pc}^   @ 70..89: icache phase
    @ 90 IRQs survived: write final marker
    ldr r0, =0x0200100C
    ldr r1, =0xCAFEBABE
    str r1, [r0]
hang:
    b hang

    @ after 50 IRQs the ARM loop advances here: mark phase 1 done, then idle
    @ in THUMB so the remaining IRQ exits return into thumb code (the ldm^
    @ T-from-SPSR case; a wrong word-aligned fetch pops garbage immediately)
phase2:
    ldr r0, =0x02001004
    ldr r1, =0xCAFEBABE
    str r1, [r0]
    adr r0, tloop
    orr r0, r0, #1
    bx r0
    .thumb
    .align 1
    @ counting chain: an ldm^ exit that skips the halfword after a
    @ word-aligned return target drops one add - r7 misses 16 and the
    @ 0x0BAD0BAD fail marker lands at 0x02001010 (idempotent loops like
    @ ldr/cmp/b self-heal and never catch that skip)
tloop:
    mov r7, #0
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    cmp r7, #16
    bne tfail
    ldr r0, =0x02001000
    ldr r0, [r0]
    cmp r0, #70
    bge tdone
    b tloop
tfail:
    ldr r0, =0x02001010
    ldr r1, =0x0BAD0BAD
    str r1, [r0]
tfail_hang:
    b tfail_hang
tdone:
    ldr r0, =phase3
    bx r0
    .arm
    .align 2

    @ phase 3: MPU + icache on (region 0 = whole 4GB, cacheable), like
    @ calico's real config; keep taking IRQ exits in a thumb loop from
    @ cached code. Marker to 0x02001008 first.
phase3:
    ldr r0, =0x02001008
    ldr r1, =0xCAFEBABE
    str r1, [r0]
    mov r0, #0x3F               @ region 0: base 0, size 4GB, enabled
    mcr p15, 0, r0, c6, c0, 0
    mov r0, #1
    mcr p15, 0, r0, c2, c0, 1   @ icache cacheable in region 0
    mrc p15, 0, r0, c1, c0, 0
    orr r0, r0, #1              @ PU enable
    orr r0, r0, #0x1000         @ icache enable
    mcr p15, 0, r0, c1, c0, 0
    adr r0, t2loop
    orr r0, r0, #1
    bx r0
    .thumb
    .align 1
t2loop:
    mov r7, #0
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    add r7, #1
    cmp r7, #16
    bne t2fail
    b t2loop
t2fail:
    ldr r0, =0x02001010
    ldr r1, =0x0BAD0BAD
    str r1, [r0]
t2fail_hang:
    b t2fail_hang
    .arm
    .ltorg
