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
    mov r0, #0
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
    @ 50 IRQs survived: write success marker
    ldr r0, =0x02001004
    ldr r1, =0xCAFEBABE
    str r1, [r0]
hang:
    b hang
    .ltorg
