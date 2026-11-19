/* SPDX-License-Identifier: GPL-3.0-or-later */
.syntax unified
.arm
.cpu arm946e-s
.text
    mov r4, #0x04000000
    ldr r0, =0x820f
    str r0, [r4, #0x304]          @ enable LCD and both engines, A on top
    mov r0, #0x10000
    str r0, [r4]                  @ normal display, backdrop only
    add r1, r4, #0x1000
    str r0, [r1]
    mov r1, #0x05000000
    mov r0, #31
    strh r0, [r1]                 @ upper red, lower green
    add r1, r1, #0x400
    mov r0, #0x3e0
    strh r0, [r1]
    mov r0, #0x81
    strb r0, [r4, #0x240]         @ map A for main BG
.ifdef DUAL
    mov r0, #0x82                 @ map C to ARM7; release its VRAMSTAT poll
    strb r0, [r4, #0x242]
.endif
    mov r1, #0x06000000
    ldr r0, =0xaabbccdd
    str r0, [r1]
    mov r0, #1
    str r0, [r4, #0x440]          @ position matrix
    mov r0, #0
    str r0, [r4, #0x454]          @ identity
    mov r0, #0x2400
    str r0, [r4, #0x46c]          @ MTX_SCALE, X=2.25, Y=Z=1
    mov r0, #0x1000
    str r0, [r4, #0x46c]
    str r0, [r4, #0x46c]
    ldr r0, [r4, #0x640]          @ clip[0], requires actual HPS reply
    mov r1, #0x02000000
    str r0, [r1]
.ifdef TRIANGLE
    ldr r0, =0x10108              @ BG0 enabled, source GPU3D
    str r0, [r4]
    mov r0, #0
    str r0, [r4, #0x454]          @ reset position matrix after checked fence
    ldr r0, =0xbfff0000
    str r0, [r4, #0x580]          @ viewport 0,0..255,191
    mov r0, #0x7c00               @ opaque blue, untextured
    str r0, [r4, #0x480]
    ldr r0, =0x001f00c0
    str r0, [r4, #0x4a4]          @ both faces, alpha 31
    mov r0, #0
    str r0, [r4, #0x500]          @ BEGIN_VTXS triangles
    ldr r0, =0xf83e0
    str r0, [r4, #0x490]          @ VTX_10 (-0.5,-0.5,0)
    ldr r0, =0xf8020
    str r0, [r4, #0x490]          @ (0.5,-0.5,0)
    mov r0, #0x8000
    str r0, [r4, #0x490]          @ (0,0.5,0)
    mov r0, #0
    str r0, [r4, #0x504]          @ END_VTXS
    str r0, [r4, #0x540]          @ SWAP_BUFFERS
.endif
    b .
    .ltorg
