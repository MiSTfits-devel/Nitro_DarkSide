/* SPDX-License-Identifier: GPL-3.0-or-later */
/* ARM9 binary of the synthetic boot image (hs_arm9_boot_oracle.py puts it
 * at ROM offset 0x8000 with header RAM address 0x02000400 and entry at the
 * `entry` symbol). Position-independent: hs_arm9_boot.S copies it into RAM
 * through the game-card data port and branches to the entry with r0 = RAM
 * address, r1 = size, r2 = header CRC16. It runs straight through to `done`
 * (the one branch before it is not taken) and writes mailbox slots 8..15. */
.syntax unified
.cpu arm946e-s
.arm
.text

table:
    .word   0x11111111, 0x02020202, 0x00300030, 0x40000004
    .word   0x05050505, 0x00600006, 0x70000007, 0x08080808

entry:
    mov     r11, #0x02000000
    str     r0, [r11, #32]          @ 8: RAM address from the loader
    str     r1, [r11, #36]          @ 9: size
    str     r2, [r11, #40]          @ 10: header CRC
    adr     r3, entry
    str     r3, [r11, #44]          @ 11: where this code runs
    ldr     r4, literal
    str     r4, [r11, #48]          @ 12: literal from its own RAM pool
    adr     r5, table
    ldmia   r5, {r6-r9}
    add     r6, r6, r7
    add     r6, r6, r8
    add     r6, r6, r9
    ldr     r7, [r5, #16]
    ldr     r8, [r5, #20]
    ldr     r9, [r5, #24]
    ldr     r10, [r5, #28]
    add     r6, r6, r7
    add     r6, r6, r8
    add     r6, r6, r9
    add     r6, r6, r10
    str     r6, [r11, #52]          @ 13: sum of the loaded table
    eor     r7, r6, r4
    str     r7, [r5]                @ overwrite table word 0 in RAM
    ldr     r8, [r5]
    str     r8, [r11, #56]          @ 14: read back
    cmp     r8, r7
    bne     fail                    @ not taken
    mov     r9, #0x5a
    str     r9, [r11, #60]          @ 15: done marker
done:
    b       done
fail:
    mov     r9, #0xba
    str     r9, [r11, #60]
    b       fail
literal:
    .word   0x600dcafe
