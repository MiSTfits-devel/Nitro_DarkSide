/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Public ARM7 reset ROM. Native CPU makes all SPI transfers, polls busy,
 * verifies inputs + byte readback and acknowledges the SPI interrupt in IF.
 * On success only, it asks the PMIC to power down (no host boot flag). */
.syntax unified
.cpu arm7tdmi
.arm
.text
    ldr r4, =0x040001c0
    ldr r5, =0x8900
    ldr r6, =0x8100
    mov r8, #0
    strh r6, [r4]
    mov r0, #6                     @ WREN, one byte, no hold
    bl byte
    strh r5, [r4]
    mov r0, #2                     @ page program, byte address 0x0321ab
    bl byte
    bl addr3
    strh r6, [r4]
    mov r0, #0x9d
    bl byte
    cmp r0, #0x9d
    bne failed
    strh r5, [r4]
    mov r0, #5                     @ RDSR: WIP is the real slot-cache commit
    bl byte
    mov r0, #0
    bl byte
    tst r0, #1
    beq failed
2:  mov r0, #0
    bl byte
    tst r0, #1
    bne 2b
    strh r8, [r4]
    ldr r7, =0xc900                @ held firmware read, SPI IRQ enabled
    strh r7, [r4]
    mov r0, #3
    bl byte
    bl addr3
    mov r0, #0
    bl byte
    cmp r0, #0x9d
    bne failed
    strh r8, [r4]                  @ end transaction
    ldr r9, =0x04000214
    ldr r0, [r9]
    tst r0, #0x00800000
    beq failed
    mov r0, #0x00800000
    str r0, [r9]
    ldr r0, [r9]
    tst r0, #0x00800000
    bne failed
    ldr r9, =0x04000130
    ldrh r0, [r9]
    ldr r1, =0x3f7                 @ START pressed
    cmp r0, r1
    bne failed
    ldrh r0, [r9, #6]
    cmp r0, #0x3e                  @ X pressed, pen down, lid open
    bne failed
    ldr r7, =0x8a00
    strh r7, [r4]
    mov r0, #0xd0                  @ real two-byte ADC conversion
    bl byte
    mov r0, #0
    bl byte
    mov r9, r0, lsl #5
    mov r0, #0
    bl byte
    orr r9, r9, r0, lsr #3
    ldr r1, =2150                  @ X=120: 1000+(120-20)*(3300-1000)/(220-20)
    cmp r9, r1
    bne failed
    ldr r7, =0x8800
    strh r7, [r4]
    mov r0, #0
    bl byte
    mov r0, #0x40
    bl byte
    b .
addr3:
    mov r10, lr
    mov r0, #3
    bl byte
    mov r0, #0x21
    bl byte
    mov r0, #0xab
    bl byte
    bx r10
byte:
    strb r0, [r4, #2]
1:  ldrh r1, [r4]
    tst r1, #0x80
    bne 1b
    ldrb r0, [r4,#2]
    bx lr
failed:
    .word 0xe7f000f0
.ltorg
