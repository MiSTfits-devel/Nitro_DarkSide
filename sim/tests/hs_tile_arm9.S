/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Kirby-mode tile scene for Nds.WholeCore.TileSoc, as a boot-ROM program for
 * the Clash ARM9 slice (high vectors at 0xffff0000, 4 KiB local RAM at
 * 0x02000000, no CP15, single transfers to GPU registers and memory).
 *
 * The scene is arm9_2dk.s's, built by the same subroutines (our own data,
 * no game assets): Kirby: Squeak Squad's measured video mode, BG mode 0 with
 * BG3 as a 256-colour text background on the STANDARD palette (DISPCNT bit
 * 30 clear, the per-tile palette numbers must be ignored) and OBJ with 1D
 * mapping, tile boundary 2 and OBJ extended palettes on engine A (DISPCNT
 * bit 31), on both engines (DISPCNT_A 0x80211810, DISPCNT_B 0x00211810,
 * POWCNT1 0x820f: engine A on the top screen). Bank E is the BG
 * extended-palette trap (slot 3 solid magenta, never shown), bank F holds
 * engine A's OBJ extended palettes. See arm9_2dk.s for the scene.
 *
 * Then IRQs animate it: DISPSTAT bits 3 and 5 (VBlank and VCount, VCount
 * setting 96), IE bits 0 and 2, IME, CPSR.I clear. The VBlank handler, n
 * being its own count, sets BG3HOFS = 3n and BG3VOFS = n on both engines and
 * moves sprite 0 to x = 16 + 4n (both OAMs). The VCount handler, at the
 * start of line 96, sets engine A's BG3HOFS = -3n: from line 96 down, engine
 * A's background scrolls the other way (a mid-frame register write, sampled
 * by the line's HBlank job). Each acknowledges its IF bit and returns with
 * SUBS pc, lr, #4. The main loop counts its iterations (a CPU-throughput
 * witness), reads DISPSTAT/VCOUNT as one word each time (the gate compares
 * every read with the reference's value at that cycle) and writes the count
 * to engine B's backdrop colour (0x05000400, its BG palette entry 0): the transparent holes
 * of the bottom screen show which value each line's HBlank sampled, and the
 * writes land while the engine draws (they must wait for the line's jobs).
 *
 * Mailbox in local RAM: 0x02000000 progress bits (1 start, 2 palettes,
 * 4 BG data, 8 OBJ data, 16 display programmed and IRQ armed),
 * 0x02000004 0xCAFEBABE when the scene is programmed, 0x02000008 VBlank IRQ
 * count n, 0x0200000c main-loop iterations, 0x02000010 the last
 * DISPSTAT/VCOUNT word read, 0x02000014 VCount IRQ count. IRQ stack: full
 * descending from 0x02001000.
 *
 * Fail-closed variants (--defsym NAME=1) must stop the SoC: NEG_MASTER_BRIGHT
 * (a MASTER_BRIGHT write, not implemented: link error at 0x0400006c),
 * NEG_PAL_BYTE (an ARM9 byte write to the palette: link error at
 * 0x05000000), NEG_VRAM_WINDOW (a write past bank A's implemented 32 KiB:
 * link error at 0x06008000), NEG_BG_MODE (DISPCNT_A in BG mode 1: the
 * engine refuses the first line, GPU fault bit 0). */
.syntax unified
.cpu arm946e-s
.arm
.text

/* High vectors at 0xffff0000. */
    b       reset
    b       bad                     @ undefined instruction
    b       bad                     @ SWI
    b       bad                     @ prefetch abort
    b       bad                     @ data abort
    b       bad                     @ reserved
    b       irq_entry               @ IRQ
    b       bad                     @ FIQ
bad:
    b       bad

reset:
    ldr     r10, =0x02000000        @ mailbox / local RAM
    msr     cpsr_c, #0xd2           @ IRQ mode, I = F = 1
    add     sp, r10, #0x1000        @ IRQ stack at the top of local RAM
    msr     cpsr_c, #0xd3           @ SVC, I = F = 1
    ldr     r11, =0x04000000
    mov     r9, #1
    str     r9, [r10]

/* POWCNT1 first: palette/OAM writes need the engines powered. */
    ldr     r0, =0x820F
    ldr     r1, =0x04000304
    strh    r0, [r1]
.ifdef NEG_MASTER_BRIGHT
    mov     r0, #0
    strh    r0, [r11, #0x6C]
.endif
.ifdef NEG_PAL_BYTE
    mov     r0, #1
    ldr     r1, =0x05000000
    strb    r0, [r1]
.endif

/* VRAMCNT: A BG-A, B OBJ-A, C BG-B, D OBJ-B, E and F LCDC for now. */
    mov     r0, #0x81
    strb    r0, [r11, #0x240]
    mov     r0, #0x82
    strb    r0, [r11, #0x241]
    mov     r0, #0x84
    strb    r0, [r11, #0x242]
    mov     r0, #0x84
    strb    r0, [r11, #0x243]
    mov     r0, #0x80
    strb    r0, [r11, #0x244]
    mov     r0, #0x80
    strb    r0, [r11, #0x245]
.ifdef NEG_VRAM_WINDOW
    mov     r0, #0
    ldr     r1, =0x06008000
    str     r0, [r1]
.endif

/* Standard palettes. */
    ldr     r4, =0x0421
    ldr     r5, =0x7FFF
    ldr     r0, =0x05000000         @ engine A BG: colour ramp
    bl      pal_ramp
    ldr     r0, =0x05000200         @ engine A OBJ: inverted ramp
    bl      pal_inv
    ldr     r0, =0x05000400         @ engine B BG
    bl      pal_ramp
    ldr     r0, =0x05000600         @ engine B OBJ
    bl      pal_inv

/* BG extended palettes through bank E while it is LCDC: the trap. */
    ldr     r0, =0x06880000
    mov     r1, #0
    ldr     r2, =6144
1:  str     r1, [r0], #4
    subs    r2, r2, #1
    bne     1b
    ldr     r1, =0x7C1F7C1F
    ldr     r2, =2048
2:  str     r1, [r0], #4
    subs    r2, r2, #1
    bne     2b

/* OBJ extended palettes through bank F while it is LCDC:
 * entry(p,c) = (c&31) | (((2p+1)&31)<<5) | ((((c>>3)+3p+5)&31)<<10). */
    ldr     r0, =0x06890000
    mov     r1, #0
3:  and     r2, r1, #255
    mov     r3, r1, lsr #8
    and     r7, r2, #31
    add     r6, r3, r3
    add     r6, r6, #1
    and     r6, r6, #31
    orr     r7, r7, r6, lsl #5
    add     r6, r3, r3, lsl #1
    add     r6, r6, r2, lsr #3
    add     r6, r6, #5
    and     r6, r6, #31
    orr     r7, r7, r6, lsl #10
    strh    r7, [r0], #2
    add     r1, r1, #1
    cmp     r1, #4096
    blt     3b

/* E -> BG ext pal slots 0-3, F -> OBJ ext pal (engine A). */
    mov     r0, #0x84
    strb    r0, [r11, #0x244]
    mov     r0, #0x85
    strb    r0, [r11, #0x245]
    orr     r9, r9, #2
    str     r9, [r10]

/* BG3: 256-colour tiles at char base 1 and the text map at screen base 4,
 * on both engines. */
    ldr     r0, =0x06004000
    bl      gen_tiles
    ldr     r0, =0x06204000
    bl      gen_tiles
    ldr     r0, =0x06002000
    bl      gen_map
    ldr     r0, =0x06202000
    bl      gen_map
    orr     r9, r9, #4
    str     r9, [r10]

/* OBJ tiles (1D, boundary 2) and OAM, both engines. */
    ldr     r0, =0x06400000
    bl      gen_obj
    ldr     r0, =0x06600000
    bl      gen_obj
    ldr     r0, =0x07000000
    bl      gen_oam
    ldr     r0, =0x07000400
    bl      gen_oam
    orr     r9, r9, #8
    str     r9, [r10]

/* BG3CNT, offsets and DISPCNT on both engines. */
    ldr     r0, =0x0485             @ pri 1, char base 1, 256c, screen base 4
    strh    r0, [r11, #0x0E]
    mov     r0, #0
    strh    r0, [r11, #0x1C]
    strh    r0, [r11, #0x1E]
.ifdef NEG_BG_MODE
    ldr     r0, =0x80211811
.else
    ldr     r0, =0x80211810
.endif
    str     r0, [r11]
    ldr     r12, =0x04001000
    ldr     r0, =0x0485
    strh    r0, [r12, #0x0E]
    mov     r0, #0
    strh    r0, [r12, #0x1C]
    strh    r0, [r12, #0x1E]
    ldr     r0, =0x00211810
    str     r0, [r12]

/* IRQs: DISPSTAT VBlank and VCount IRQ enables with VCount setting 96, IE
 * bits 0 and 2, IME, then CPSR.I clear. */
    ldr     r0, =0x6028
    strh    r0, [r11, #4]
    mov     r0, #5
    ldr     r1, =0x04000210
    str     r0, [r1]
    mov     r0, #1
    ldr     r1, =0x04000208
    str     r0, [r1]
    orr     r9, r9, #16
    str     r9, [r10]
    ldr     r1, =0xCAFEBABE
    str     r1, [r10, #4]
    msr     cpsr_c, #0x53           @ SVC, I = 0, F = 1

main:
    ldr     r0, [r10, #12]
    add     r0, r0, #1
    str     r0, [r10, #12]
    ldr     r1, [r11, #4]           @ DISPSTAT | VCOUNT << 16 (a GPU link read)
    str     r1, [r10, #16]
    ldr     r2, =0x05000400
    strh    r0, [r2]                @ engine B backdrop = iteration count
    b       main

irq_entry:
    stmfd   sp!, {r0-r3, r12, lr}
    ldr     r12, =0x04000000
    ldr     r2, =0x04000214
    ldr     r1, [r2]                @ IF
    tst     r1, #4
    beq     irq_vblank
    ldr     r0, [r10, #20]          @ VCount IRQ count
    add     r0, r0, #1
    str     r0, [r10, #20]
    ldr     r0, [r10, #8]           @ n
    add     r1, r0, r0, lsl #1
    rsb     r1, r1, #0              @ -3n
    strh    r1, [r12, #0x1C]        @ BG3HOFS, engine A, from this line on
    mov     r1, #4
    str     r1, [r2]                @ acknowledge IF bit 2
    b       irq_done
irq_vblank:
    ldr     r0, [r10, #8]
    add     r0, r0, #1
    str     r0, [r10, #8]
    add     r1, r0, r0, lsl #1      @ 3n
    strh    r1, [r12, #0x1C]        @ BG3HOFS, engine A
    strh    r0, [r12, #0x1E]        @ BG3VOFS, engine A
    ldr     r2, =0x04001000
    strh    r1, [r2, #0x1C]         @ engine B
    strh    r0, [r2, #0x1E]
    mov     r3, r0, lsl #2
    add     r3, r3, #16             @ x = 16 + 4n
    mov     r3, r3, lsl #23
    mov     r3, r3, lsr #23         @ 9-bit x
    orr     r3, r3, #0x4000         @ size 1 (16x16, square)
    ldr     r2, =0x07000002
    strh    r3, [r2]                @ sprite 0 attribute 1, engine A
    add     r2, r2, #0x400
    strh    r3, [r2]                @ engine B
    mov     r1, #1
    ldr     r2, =0x04000214
    str     r1, [r2]                @ acknowledge IF bit 0
irq_done:
    ldmfd   sp!, {r0-r3, r12, lr}
    subs    pc, lr, #4

/* ================ subroutines (r0 = destination base) ================
 * As arm9_2dk.s. r4 = 0x0421, r5 = 0x7FFF on entry to pal_ramp/pal_inv. */
pal_ramp:
    mov     r1, #0
pr0:
    mul     r2, r1, r4
    and     r2, r2, r5
    add     r6, r1, #1
    mul     r3, r6, r4
    and     r3, r3, r5
    orr     r2, r2, r3, lsl #16
    str     r2, [r0], #4
    add     r1, r1, #2
    cmp     r1, #256
    blt     pr0
    bx      lr

pal_inv:
    mov     r1, #0
pi0:
    rsb     r6, r1, #255
    mul     r2, r6, r4
    and     r2, r2, r5
    rsb     r6, r1, #254
    mul     r3, r6, r4
    and     r3, r3, r5
    orr     r2, r2, r3, lsl #16
    str     r2, [r0], #4
    add     r1, r1, #2
    cmp     r1, #256
    blt     pi0
    bx      lr

/* 256-colour BG tiles: tile 0 transparent, tiles 1..3 index ramps
 * 64..127 / 128..191 / 192..255. */
gen_tiles:
    mov     r1, #0
    mov     r2, #16
gt0:
    str     r1, [r0], #4
    subs    r2, r2, #1
    bne     gt0
    mov     r1, #64
    ldr     r7, =0x01010101
    ldr     r8, =0x03020100
gt1:
    mul     r2, r1, r7
    add     r2, r2, r8
    str     r2, [r0], #4
    add     r1, r1, #4
    cmp     r1, #256
    blt     gt1
    bx      lr

/* 32x32 text map: tile (x+y)&3, palno (x>>1)&15 (must be ignored), h-flip
 * on odd rows. */
gen_map:
    mov     r1, #0
gm0:
    and     r2, r1, #31
    mov     r3, r1, lsr #5
    add     r4, r2, r3
    and     r4, r4, #3
    tst     r3, #1
    orrne   r4, r4, #0x0400
    mov     r5, r2, lsr #1
    and     r5, r5, #15
    orr     r4, r4, r5, lsl #12
    strh    r4, [r0], #2
    add     r1, r1, #1
    cmp     r1, #1024
    blt     gm0
    ldr     r4, =0x0421
    ldr     r5, =0x7FFF
    bx      lr

/* OBJ tiles at 1D boundary 2: tile 1 16x16 4bpp quadrants 1/2/3/4, tile 2
 * 8x8 4bpp colour 6, tile 4 16x16 256-colour byte k = k (k=0 -> 1), tile 6
 * 16x16 256-colour byte k = 255-k (k=255 -> 1). */
gen_obj:
    mov     r12, r0
    add     r0, r0, #0x80
    mov     r6, #1
go0:
    orr     r1, r6, r6, lsl #4
    orr     r1, r1, r1, lsl #8
    orr     r1, r1, r1, lsl #16
    mov     r2, #8
go1:
    str     r1, [r0], #4
    subs    r2, r2, #1
    bne     go1
    add     r6, r6, #1
    cmp     r6, #5
    blt     go0
    ldr     r1, =0x66666666
    mov     r2, #8
go2:
    str     r1, [r0], #4
    subs    r2, r2, #1
    bne     go2
    add     r0, r12, #0x200
    ldr     r7, =0x01010101
    ldr     r8, =0x03020100
    mov     r1, #0
go3:
    mul     r2, r1, r7
    add     r2, r2, r8
    str     r2, [r0], #4
    add     r1, r1, #4
    cmp     r1, #256
    blt     go3
    ldr     r1, =0x03020101
    str     r1, [r12, #0x200]
    ldr     r8, =0xFCFDFEFF
    mov     r1, #0
go4:
    mul     r2, r1, r7
    rsb     r2, r2, r8
    str     r2, [r0], #4
    add     r1, r1, #4
    cmp     r1, #256
    blt     go4
    ldr     r1, =0x01010203
    str     r1, [r12, #0x3FC]
    bx      lr

/* OAM: 128 disabled sprites, then six visible ones. */
gen_oam:
    mov     r3, r0
    ldr     r1, =0x00000200
    mov     r2, #128
gn0:
    str     r1, [r0], #4
    str     r1, [r0], #4
    subs    r2, r2, #1
    bne     gn0
    mov     r0, r3
    ldr     r1, =0x40100018         @ spr0: 16x16 4bpp at (16,24), tile 1, pal 0
    str     r1, [r0]
    mov     r1, #1
    str     r1, [r0, #4]
    ldr     r1, =0x10640050         @ spr1: 8x8 4bpp at (100,80), h-flip, tile 2, pal 1
    str     r1, [r0, #8]
    ldr     r1, =0x00001002
    str     r1, [r0, #12]
    ldr     r1, =0x40302018         @ spr2: 16x16 256c at (48,24), tile 4, ext palno 5
    str     r1, [r0, #16]
    ldr     r1, =0x00005004
    str     r1, [r0, #20]
    ldr     r1, =0x40502018         @ spr3: 16x16 256c at (80,24), tile 6, ext palno 11
    str     r1, [r0, #24]
    ldr     r1, =0x0000B006
    str     r1, [r0, #28]
    ldr     r1, =0x40702018         @ spr4: 16x16 256c at (112,24), tile 4, ext palno 0
    str     r1, [r0, #32]
    ldr     r1, =0x00000004
    str     r1, [r0, #36]
    ldr     r1, =0x40F82064         @ spr5: 16x16 256c at (248,100), clips right
    str     r1, [r0, #40]
    ldr     r1, =0x0000B006
    str     r1, [r0, #44]
    bx      lr

    .ltorg
