/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Host-assisted direct boot on actual CPU instructions; no BIOS or private
 * reset vectors. Visible r12/sp/lr and ARM9 c1 follow the matched local
 * TRACE-enabled melonDS direct boot. SVC mode, IRQ masked; no firmware
 * or peripheral initialization. */
.syntax unified
.arm
.text
    b reset
.ifdef ARM7
    .org 8
.ifdef TRAP_ALL_SWI
    .word 0xe7f000f0           @ no BIOS supplied: fail at the real vector
.else
    b swi7
.endif
.endif
.org 0x18
    b irq
reset:
.ifdef ARM7
    ldr sp, =0x0380fd80
.ifdef BAD_SWI
    swi 0x040000               @ unsupported, must fault instead of returning
    b .
.endif
    ldr r12, header_entry7
.else
    /* Matched TRACE9-enabled local melonDS: NDS::SetupDirectBoot writes
     * c1=0x12078. Use genuine MCR from reset 0x2078, not a CPU constant. */
    ldr r12, =0x12078
    mcr p15, 0, r12, c1, c0, 0
    ldr r12, =0x04000247
    mov lr, #3
    strb lr, [r12]             @ direct boot maps shared WRAM to ARM7
    ldr sp, =0x03002f7c
    ldr r12, header_entry9
.endif
    mov lr, r12
    bx r12
/* Public guest only: TM0 is already stopped, r11 points to IF. */
irq:
    mov r10, #8
    str r10, [r11]
    subs pc, lr, #4
.ifdef ARM7
.ifndef TRAP_ALL_SWI
/* Functional NDS7 SWI 03 (GBATEK, BIOS Misc Functions). SWI hardware
 * entered ARM/SVC, banked LR points after the call, SPSR is caller CPSR.
 * The service number is the byte at LR-2 for both Thumb imm8 and ARM
 * imm24[23:16]. No ROM dump and no other BIOS service is substituted.
 * Run the signed decrement loop in System mode with caller I/F masks.
 * Save SVC state across it so an IRQ issuing another SWI cannot destroy
 * this exception return. This is instruction execution, not calibrated
 * BIOS wall time. */
swi7:
    stmdb sp!, {r12,lr}
    mrs r12, spsr
    stmdb sp!, {r12}
    ldrb r12, [lr, #-2]
    cmp r12, #3
    bne unknown_swi7
    mrs r12, spsr
    and r12, r12, #0xc0
    orr r12, r12, #0x1f
    msr cpsr_c, r12
wait7:
    subs r0, r0, #1
    bgt wait7
    mrs r12, cpsr
    and r12, r12, #0x40
    orr r12, r12, #0x93        @ SVC, IRQ masked while restoring SPSR/LR
    msr cpsr_c, r12
    ldmia sp!, {r12}
    msr spsr_fsxc, r12
    ldmia sp!, {r12,lr}
    movs pc, lr
unknown_swi7:
    .word 0xe7f000f0
.endif
.endif
.ltorg
/* Harness supplies the header at ROM + 0xe00, as in hs_dual_boot9.S. */
.org 0xe24
header_entry9: .word 0
.org 0xe34
header_entry7: .word 0
