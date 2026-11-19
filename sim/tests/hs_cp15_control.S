/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Bounded negative probes for the wide ARM946 control subset. All tests
 * must fault at the intended instruction/address, never at the sentinel. */
.syntax unified
.arm
.text
.ifdef INVPROBE
    ldr r3, =0x02000000
    adr lr, seeded
    bx r3                   @ every word in test RAM is BX LR
seeded:
    ldr r3, resident_line   @ bus observer supplies actual last filled line
    cmp r3,r3
.ifdef SKIPINV
    mcrne p15,0,r0,c7,c5,0
.else
.ifdef DONLY
    mcr p15,0,r0,c7,c6,0   @ must not evict the instruction line
.else
    mcreq p15,0,r0,c7,c5,0
.endif
.endif
    adr lr, finished
    bx r3
finished: .word 0xe7f000f0
.ltorg
.org 0x800
resident_line: .word 0
.else
.ifdef ARM7
    mrc p15,0,r0,c1,c0,0   @ not an ARM7 coprocessor
.else
    mrc p15,0,r0,c1,c0,0
    ldr r1, =0x2078         @ real reset rather than host handoff value
    cmp r0,r1
    bne bad
.ifdef USERMODE
    msr cpsr_c,#0xd0
fault_at:
    mrc p15,0,r0,c1,c0,0
.endif
.ifdef BADREG
fault_at:
    mrc p15,0,r0,c1,c0,1   @ same CRn, different opcode2
.endif
.ifdef ENDIAN
    orr r0,r0,#0x80
fault_at:
    mcr p15,0,r0,c1,c0,0   @ big endian is not implemented: fail closed
.endif
.ifdef LOWVEC
    bic r0,r0,#0x2000
    mcr p15,0,r0,c1,c0,0
    swi 0                  @ low vector 8 has no mapped ARM9 ITCM
.endif
.ifdef BADINV
fault_at:
    mcr p15,0,r0,c7,c5,1   @ invalidate by address is a different operation
.endif
.ifdef USERINV
    msr cpsr_c,#0xd0
fault_at:
    mcr p15,0,r0,c7,c5,0
.endif
.ifdef GPUEDGE
    ldr r1, =0x04000248
    str r0, [r1]           @ touches 24a/24b even though H/I bytes are in range
.endif
.ifdef BADMPU
    ldr r0,=0x02001019     @ enabled 8 KiB region with a 4 KiB-only alignment
fault_at:
    mcr p15,0,r0,c6,c3,0
.endif
.ifdef USERMPU
    msr cpsr_c,#0xd0
fault_at:
    mrc p15,0,r0,c5,c0,2   @ MPU state is privileged even when c1.M is clear
.endif
.ifdef DCENABLE
    orr r0,r0,#4
fault_at:
    mcr p15,0,r0,c1,c0,0   @ no D data array: reject C=1
.endif
.ifdef BADDRN
fault_at:
    mcr p15,0,r0,c7,c10,5  @ not drain c7,c10,4
.endif
.ifdef DRAIN
    ldr r3, =0x02000080
    ldr r4, =0x04000244
    mov r2,#0x42
    strb r2,[r3,#1]
    mcr p15,0,r0,c7,c10,4  @ RAM ack deliberately withheld
    ldrb r1,[r3,#1]
    cmp r1,#0x42
    bne bad
    strh r1,[r4]
    mcr p15,0,r0,c7,c10,4  @ IO write reply deliberately withheld
    mcr p15,0,r0,c7,c6,0
    ldrb r1,[r3,#1]        @ independent writer updated byte on IO completion
    cmp r1,#0xbe
    bne bad
finished: .word 0xe7f000f0
.endif
.endif
bad: .word 0xe7f000f0
.ltorg
.endif
