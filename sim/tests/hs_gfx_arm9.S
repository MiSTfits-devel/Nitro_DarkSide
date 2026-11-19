/* SPDX-License-Identifier: GPL-3.0-or-later */
/* CPU + VRAM display prototype: draw one 256x192 BGR555 frame through the
 * ARM9 slice's GPU link into LCDC bank A and show it in display mode 2. A
 * shaded triangle is rasterised with three incremental edge functions over
 * a background gradient. Mailbox words at 0x02000000 record what the CPU
 * read back from the GPU. The program ends at `b .` (0xeafffffe). */
.syntax unified
.cpu arm946e-s
.arm
.text

    mov     r7, #0x02000000
    ldr     r0, =0x04000304     @ POWCNT1
    ldr     r1, =0x8003         @ LCDs on, engine A on, engine A on top LCD
    strh    r1, [r0]
    ldrh    r2, [r0]
    str     r2, [r7, #0]

    ldr     r0, =0x04000240
    mov     r1, #0x80
    strb    r1, [r0]            @ VRAMCNT_A: bank A to LCDC
.ifdef UNSUPPORTED_BANK
    strb    r1, [r0, #2]        @ VRAMCNT_C: bank C is not implemented
    b       .
.endif

    mov     r0, #0x04000000     @ DISPCNT_A
    mov     r1, #0x00020000     @ display mode 2 (VRAM), bank A
    str     r1, [r0]
    ldr     r2, [r0]
    str     r2, [r7, #4]
.ifdef UNSUPPORTED_MODE
    mov     r1, #0x00010000     @ display mode 1 (BG/OBJ) is not implemented
    str     r1, [r0]
    b       .
.endif
.ifdef UNSUPPORTED_STATUS
    ldrh    r2, [r0, #6]        @ VCOUNT: no DS LCD schedule here
    b       .
.endif
.ifdef UNSUPPORTED_ENGINE_A
    strh    r1, [r0, #8]        @ BG0CNT_A: engine A backgrounds are not implemented
    b       .
.endif
.ifdef UNSUPPORTED_ENGINE_B
    add     r3, r0, #0x1000
    ldr     r2, [r3]            @ DISPCNT_B: engine B is not implemented
    b       .
.endif
.ifdef UNSUPPORTED_PALETTE
    mov     r3, #0x05000000
    strh    r1, [r3]            @ palette RAM is not implemented
    b       .
.endif
.ifdef UNSUPPORTED_OAM
    mov     r3, #0x07000000
    ldr     r2, [r3]            @ OAM is not implemented
    b       .
.endif
.ifdef UNSUPPORTED_IPC_SYNC
    add     r3, r0, #0x180
    strh    r1, [r3]            @ IPCSYNC: no second CPU behind this link
    b       .
.endif
.ifdef UNSUPPORTED_IPC_RECV
    mov     r3, #0x04100000
    ldr     r2, [r3]            @ IPCFIFORECV
    b       .
.endif

    /* Edge E(P) = (P.x-a.x)*(b.y-a.y) - (P.y-a.y)*(b.x-a.x) for the
     * triangle (140,14) (30,178) (232,150); each is 0..30048 inside. */
    mov     r4, #0x06800000     @ LCDC bank A, pixel (0,0)
    ldr     r0, =-24500         @ (140,14)->(30,178) at (0,0); blue
    ldr     r1, =36796          @ (30,178)->(232,150); red
    ldr     r2, =17752          @ (232,150)->(140,14); green
    mov     r8, #0              @ y
row:
    mov     r9, r8, lsr #4      @ background: green from y,
    mov     r9, r9, lsl #5
    orr     r9, r9, #0x2800     @ constant blue,
    mov     r10, r0
    mov     r11, r1
    mov     r12, r2
    mov     r5, #0              @ x
pixel:
    orr     r3, r10, r11
    orrs    r3, r3, r12
    orrmi   r6, r9, r5, lsr #4  @ and red from x when outside
    bmi     plot
    mov     r6, r11, lsr #10    @ inside: red, green, blue = edges >> 10
    mov     r3, r12, lsr #10
    orr     r6, r6, r3, lsl #5
    mov     r3, r10, lsr #10
    orr     r6, r6, r3, lsl #10
plot:
    strh    r6, [r4]
    add     r4, r4, #2
    add     r10, r10, #164
    sub     r11, r11, #28
    sub     r12, r12, #136
    add     r5, r5, #1
    cmp     r5, #256
    blt     pixel
    add     r0, r0, #110
    sub     r1, r1, #202
    add     r2, r2, #92
    add     r8, r8, #1
    cmp     r8, #192
    blt     row

    ldr     r0, =0x0680c918     @ pixel (140,100)
    ldrh    r2, [r0]
    str     r2, [r7, #8]
    mov     r1, #0xff
    strb    r1, [r0]            @ ARM9 byte writes to VRAM are ignored
    ldrh    r2, [r0]
    str     r2, [r7, #12]
done:
    b       done
.ltorg
