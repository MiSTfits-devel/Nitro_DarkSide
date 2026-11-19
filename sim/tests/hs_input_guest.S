/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Public reset programs. r12 markers only pace the controller driver; the
 * CPUs read and validate the actual MMIO words and acknowledge their own IF. */
.syntax unified
.arm
.text
.macro check addr, offs, want
    ldrh r0,[\addr,#\offs]
    ldr r1,=\want
    cmp r0,r1
    bne failed
.endm
.macro wait_half addr, offs, want
    ldr r1,=\want
1:  ldrh r0,[\addr,#\offs]
    cmp r0,r1
    bne 1b
.endm
.macro irq want, mask
    ldr r0,[r5]
    and r0,r0,#\mask
    cmp r0,#\want
    bne failed
.endm
    b start
    .rept 5
    b failed
    .endr
    b irq_entry
    b failed
start:
    ldr r4,=0x04000130
    ldr r5,=0x04000214
    check r4,0,0x3ff
    check r4,2,0
    irq 0,0x1000
.ifdef ARM9
    ldr r2,=0x4003                 @ A OR B
.else
    check r4,6,0x7f
    irq 0,0x400000
    ldr r2,=0xc003                 @ A AND B
.endif
    strh r2,[r4,#2]
    ldrh r0,[r4,#2]
    cmp r0,r2
    bne failed
    mov r12,#1
    wait_half r4,0,0x3fe
.ifdef ARM9
    irq 0x1000,0x1000
    mov r2,#0x1000
    bl service
.endif
    irq 0,0x1000
    mov r12,#2
    wait_half r4,0,0x3fc
.ifdef ARM9
    irq 0,0x1000                   @ already matched, no second edge
    mov r12,#3
    wait_half r4,0,0x3f6
    irq 0,0x400000
    mov r12,#4
    b .
.else
    irq 0x1000,0x1000
    mov r2,#0x1000
    bl service
    irq 0,0x1000
    mov r12,#3
    wait_half r4,0,0x3ff
    mov r0,#0
    strh r0,[r4,#2]
    mov r6,#1
    mov r12,#4
walk:
    ldr r2,=0x3ff
    bic r2,r2,r6
    mov r3,#0x7f
    bic r3,r3,r6,lsr #10
1:  ldrh r0,[r4]
    cmp r0,r2
    bne 1b
    ldrh r0,[r4,#6]
    cmp r0,r3
    bne 1b
    mov r12,#5
    mov r6,r6,lsl #1
    cmp r6,#0x1000
    bne walk
    wait_half r4,6,0x7f
    mov r12,#6
    ldr r6,=0x040001c0
    ldr r0,=0x8a00
    strh r0,[r6]
    wait_half r4,6,0xbf             @ lid closed, pen down
    irq 0,0x400000
    mov r0,#0xd0
    bl adc
    ldr r1,=770                     @ stick raw X=1 maps to 0 (stock quirk)
    cmp r0,r1
    bne failed
    mov r0,#0x90
    bl adc
    ldr r1,=948                     @ Y=191, reversed calibration slope
    cmp r0,r1
    bne failed
    mov r0,#0xe0
    bl adc
    ldr r1,=0xfff
    cmp r0,r1
    bne failed
    mov r12,#7
    wait_half r4,6,0xbe             @ host added X after moving mouse
    mov r0,#0xd0
    bl adc
    ldr r1,=2426                    @ X=128+16
    cmp r0,r1
    bne failed
    mov r0,#0x90
    bl adc
    ldr r1,=1800                    @ Y=(128-(-32))*3/4
    cmp r0,r1
    bne failed
    mov r12,#8
    wait_half r4,6,0xfe             @ mouse up, held pad touch is not owner
    mov r0,#0xd0
    bl adc
    cmp r0,#0
    bne failed
    mov r0,#0x90
    bl adc
    ldr r1,=0xfff
    cmp r0,r1
    bne failed
    mov r12,#9
    wait_half r4,6,0xbe             @ right stick moved again, regain owner
    mov r0,#0xd0
    bl adc
    ldr r1,=3702                    @ X=255, truncated division
    cmp r0,r1
    bne failed
    mov r0,#0x90
    bl adc
    ldr r1,=3240                    @ Y=0
    cmp r0,r1
    bne failed
    mov r12,#10
    wait_half r4,6,0x7f
    irq 0x400000,0x400000            @ opening lid wakes ARM7 only
    mov r2,#0x400000
    bl service
    irq 0,0x400000
    mov r12,#11
    wait_half r4,0,0x3f6
    wait_half r4,6,0xbe
    mov r12,#12                     @ reset with A/X/touch/lid held
    b .
adc:
    mov r8,lr
    bl spi_byte
    mov r0,#0
    bl spi_byte
    mov r7,r0,lsl #5
    mov r0,#0
    bl spi_byte
    orr r0,r7,r0,lsr #3
    bx r8
spi_byte:
    strb r0,[r6,#2]
1:  ldrh r1,[r6]
    tst r1,#0x80
    bne 1b
    ldrb r0,[r6,#2]
    bx lr
.endif
/* Enable delivery of this pending IF, enter the real IRQ vector, W1C,
 * and return using the banked LR/SPSR before continuing the test. */
service:
    mov r9,#0
    mov r0,#1
    str r2,[r5,#-4]                 @ IE
    str r0,[r5,#-12]                @ IME
    msr cpsr_c,#0x53
1:  cmp r9,#0
    beq 1b
    msr cpsr_c,#0xd3
    cmp r9,#1
    bne failed
    bx lr
irq_entry:
    ldr r11,[r5]
    ands r11,r11,r2
    beq failed
    str r11,[r5]
    add r9,r9,#1
    subs pc,lr,#4
failed:
    .word 0xe7f000f0
.ltorg
