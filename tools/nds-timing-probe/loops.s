/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Identical ARM-state instruction sequences, linked into separate regions. */
.syntax unified
.arm
.macro timing_loop name, section
.section \section,"ax",%progbits
.align 5
.global \name
.type \name, %function
\name:
1:  subs r0, r0, #1
    bne 1b
    bx lr
.size \name, .-\name
.endm

timing_loop loop_itcm, .itcm.timing
timing_loop loop_ram, .text.timing

.section .text.baseline,"ax",%progbits
.align 2
.global loop_empty
.type loop_empty, %function
loop_empty:
    bx lr
.size loop_empty, .-loop_empty
