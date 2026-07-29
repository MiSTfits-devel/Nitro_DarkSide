@ M5 frame-dump scene, ARM9 side: KIRBY'S ACTUAL VIDEO MODE.
@ Linked at 0x02000000, loaded by nds_loader (see build_nds_2dk.sh).
@
@ Kirby: Squeak Squad renders with (measured from melonDS, VIDLOG):
@   DISPCNT_A = 0x80211810  BG mode 0, BG3 + OBJ on, OBJ 1D mapping with
@                           tile boundary 2 (32<<2 = 128 B), display mode 1,
@                           bit 31 set
@   DISPCNT_B = 0x00211810  same, bit 31 clear
@   POWCNT1   = 0x820F      LCD + 2D A + 3D + 2D B + display swap
@
@ NOTE ON BIT 31. Per GBATEK (and rtl/reg_nds_display.vhd lines 39-40)
@ DISPCNT bit 30 is BG extended palettes and bit 31 is OBJ extended
@ palettes. Kirby therefore runs its BG3 as a 256-colour TEXT background
@ on the STANDARD palette (bit 30 clear) and its sprites on EXTENDED
@ palettes (bit 31 set). This ROM tests that combination.
@
@ What no other sample covers:
@   * 256-colour text BG with ext palettes DISABLED - the nds_drawer_text
@     branch that must fall back to the standard palette and IGNORE the
@     per-tile palno field. arm9_2dh/2dw only ever drive that BG with ext
@     palettes ON; arm9_2d's BG3 is affine, which never uses them.
@   * BG mode 0 (2d/2dh/2dw are all mode 1).
@   * BG3 in text mode, i.e. the BG2/3 ext-pal slot rule (slot 3).
@   * engine B rendering at all - no previous sample writes 0x04001000.
@
@ Layout:
@   VRAMCNT  A -> BG-A (0x06000000), B -> OBJ-A (0x06400000),
@            C -> BG-B (0x06200000), D -> OBJ-B (0x06600000),
@            E -> LCDC (0x06880000) then BG ext-pal slots 0-3 (MST=4),
@            F -> LCDC (0x06890000) then OBJ ext pal, engine A (MST=5)
@   BG3 (both engines): text, 256 colour, char base 1, screen base 4,
@            priority 1, 256x256. IDENTICAL tiles, map and standard
@            palette on A and B, so BG pixels must match between the two
@            screens exactly. The map carries a palno sweep 0..15 that
@            BOTH engines must ignore (bit 30 is clear on both).
@   TRAP:    bank E IS mapped as BG ext palettes and slot 3 (the slot BG3
@            would use) is filled with solid magenta 0x7C1F. If anything
@            in the RTL treats bit 31 as "BG ext palettes", or picks up a
@            mapped ext-pal bank without checking the enable, the top
@            screen turns solid magenta instead of a colour ramp.
@   OBJ:     spr0/spr1 are 4bpp on the standard OBJ palette; spr2..spr5
@            are 16x16 256-colour sprites reading the OBJ EXTENDED
@            palette at palno 5, 11, 0 and 11, so the palno*512 term is
@            exercised rather than palno 0 alone.
@            Engine B has bit 31 clear and no OBJ ext-pal bank, so its
@            256-colour sprites must come off the standard OBJ palette:
@            the ONLY A-vs-B differences should be those sprite pixels.
@
@ Mailbox (uncached main-RAM mirror): 0x02FFFF00 progress bitmask,
@ 0x02FFFF04 magic (0xCAFEBABE when the scene is fully programmed),
@ 0x02FFFF08 vblank counter.
@
@ Rules for images that must also run under the melonDS frame-diff oracle
@ (copied verbatim from arm9_2d.s - do not "simplify" these):
@   * no 4 GB PU catch-all region (melonDS computes 2<<31 = 0: covers
@     nothing -> data abort); use explicit SDK-style regions, and cover
@     the DTCM window too (melonDS checks PU before TCM)
@   * write POWCNT1 before any palette/OAM data - those writes are
@     dropped while the 2D engine is powered off

   .arch armv5te
   .arm
   .global _start

_start:
@ ==== crt0-shaped CP15 setup (arm9_2d.s) ====
   mov  r0, #0x20
   mcr  p15, 0, r0, c9, c1, 1  @ ITCM: 32 MB virtual
   ldr  r0, =0x027E000A
   mcr  p15, 0, r0, c9, c1, 0  @ DTCM at 0x027E0000, 16 KB
   ldr  r0, =0x04000033        @ region 0: IO/palette/VRAM/OAM, 64 MB
   mcr  p15, 0, r0, c6, c0, 0
   ldr  r0, =0x0200002B        @ region 1: main RAM 4 MB, cachable
   mcr  p15, 0, r0, c6, c1, 0
   ldr  r0, =0x02C0002B        @ region 2: main-RAM mirror (mailbox), uncached
   mcr  p15, 0, r0, c6, c2, 0
   ldr  r0, =0x027E001B        @ region 3: DTCM window, 16 KB
   mcr  p15, 0, r0, c6, c3, 0
   mov  r0, #0x02
   mcr  p15, 0, r0, c2, c0, 0
   mcr  p15, 0, r0, c2, c0, 1
   mcr  p15, 0, r0, c3, c0, 0
   ldr  r0, =0x33333333
   mcr  p15, 0, r0, c5, c0, 2
   mcr  p15, 0, r0, c5, c0, 3
   ldr  r0, =0x0005107D        @ PU + I/D caches + ITCM + DTCM
   mcr  p15, 0, r0, c1, c0, 0
   ldr  sp, =0x027E3F80

   ldr  r10, =0x02FFFF00       @ mailbox (mirror -> region 2 -> uncached)
   ldr  r11, =0x04000000
   mov  r9, #1                 @ bit 0: crt0 done
   str  r9, [r10]

@ ==== POWCNT1 first: palette/OAM writes are dropped while the engines
@ are off. Kirby's exact value: both 2D engines + display swap ====
   ldr  r0, =0x820F
   ldr  r1, =0x04000304
   strh r0, [r1]

@ ==== VRAMCNT ====
   mov  r0, #0x81              @ A: enable, MST=1 -> BG-A 0x06000000
   strb r0, [r11, #0x240]
   mov  r0, #0x82              @ B: enable, MST=2 -> OBJ-A 0x06400000
   strb r0, [r11, #0x241]
   mov  r0, #0x84              @ C: enable, MST=4 -> BG-B 0x06200000
   strb r0, [r11, #0x242]
   mov  r0, #0x84              @ D: enable, MST=4 -> OBJ-B 0x06600000
   strb r0, [r11, #0x243]
   mov  r0, #0x80              @ E: enable, MST=0 -> LCDC 0x06880000
   strb r0, [r11, #0x244]
   mov  r0, #0x80              @ F: enable, MST=0 -> LCDC 0x06890000
   strb r0, [r11, #0x245]

@ ==== standard palettes ====
   ldr  r4, =0x0421
   ldr  r5, =0x7FFF
@ engine A BG (0x05000000): colour ramp i*0x0421 - BG3 runs on THIS,
@ because DISPCNT bit 30 (BG ext palettes) is clear
   ldr  r0, =0x05000000
   bl   pal_ramp
@ engine A OBJ (0x05000200): inverted ramp
   ldr  r0, =0x05000200
   bl   pal_inv
@ engine B BG (0x05000400): same ramp as A, so the two BG3s must agree
   ldr  r0, =0x05000400
   bl   pal_ramp
@ engine B OBJ (0x05000600): same inverted ramp as A
   ldr  r0, =0x05000600
   bl   pal_inv

@ ==== BG ext palettes through bank E while it is LCDC: the TRAP ====
@ slots 0-2 zero, slot 3 (the slot BG3 would use) solid magenta. BG ext
@ palettes are DISABLED, so none of this may reach the screen.
   ldr  r0, =0x06880000
   mov  r1, #0
   ldr  r2, =6144              @ 24 KB = slots 0,1,2
1: str  r1, [r0], #4
   subs r2, r2, #1
   bne  1b
   ldr  r1, =0x7C1F7C1F        @ magenta, both halfwords
   ldr  r2, =2048              @ 8 KB = slot 3
2: str  r1, [r0], #4
   subs r2, r2, #1
   bne  2b

@ ==== OBJ extended palettes through bank F while it is LCDC ====
@ 16 palettes x 256 entries at 0x06890000.
@   entry(p,c) = (c&31) | (((2p+1)&31)<<5) | ((((c>>3)+3p+5)&31)<<10)
@ green is a pure function of palno, so a dropped palno*512 term shows up
@ as the wrong green on the whole sprite.
   ldr  r0, =0x06890000
   mov  r1, #0                 @ j = p*256 + c
3: and  r2, r1, #255           @ c
   mov  r3, r1, lsr #8         @ p (0..15)
   and  r7, r2, #31            @ red
   add  r6, r3, r3
   add  r6, r6, #1
   and  r6, r6, #31            @ green
   orr  r7, r7, r6, lsl #5
   add  r6, r3, r3, lsl #1     @ 3p
   add  r6, r6, r2, lsr #3
   add  r6, r6, #5
   and  r6, r6, #31            @ blue
   orr  r7, r7, r6, lsl #10
   strh r7, [r0], #2
   add  r1, r1, #1
   cmp  r1, #4096
   blt  3b

@ ==== remap E -> BG ext pal slots 0-3, F -> OBJ ext pal (engine A) ====
   mov  r0, #0x84
   strb r0, [r11, #0x244]
   mov  r0, #0x85
   strb r0, [r11, #0x245]

   orr  r9, r9, #2             @ bit 1: palettes (std + ext)
   str  r9, [r10]

@ ==== BG3 256-colour tiles, char base 1, on BOTH engines ====
   ldr  r0, =0x06004000
   bl   gen_tiles
   ldr  r0, =0x06204000
   bl   gen_tiles

@ ==== BG3 text map, screen base 4, on BOTH engines ====
   ldr  r0, =0x06002000
   bl   gen_map
   ldr  r0, =0x06202000
   bl   gen_map

   orr  r9, r9, #4             @ bit 2: BG data
   str  r9, [r10]

@ ==== OBJ tiles (1D, boundary 2 -> OAM tile number N at N*128) ====
   ldr  r0, =0x06400000
   bl   gen_obj
   ldr  r0, =0x06600000
   bl   gen_obj

@ ==== OAM for both engines ====
   ldr  r0, =0x07000000
   bl   gen_oam
   ldr  r0, =0x07000400
   bl   gen_oam

   orr  r9, r9, #8             @ bit 3: OBJ data
   str  r9, [r10]

@ ==== engine A: BG3CNT + offsets + Kirby's DISPCNT ====
   ldr  r0, =0x0485            @ pri 1, char base 1, 256c, screen base 4
   strh r0, [r11, #0x0E]       @ BG3CNT
   mov  r0, #0
   strh r0, [r11, #0x1C]       @ BG3HOFS
   strh r0, [r11, #0x1E]       @ BG3VOFS
   ldr  r0, =0x80211810        @ measured Kirby DISPCNT_A
   str  r0, [r11]

@ ==== engine B: same scene, bit 31 clear ====
   ldr  r12, =0x04001000
   ldr  r0, =0x0485
   strh r0, [r12, #0x0E]
   mov  r0, #0
   strh r0, [r12, #0x1C]
   strh r0, [r12, #0x1E]
   ldr  r0, =0x00211810        @ measured Kirby DISPCNT_B
   str  r0, [r12]

   orr  r9, r9, #16            @ bit 4: display programmed
   str  r9, [r10]
   ldr  r1, =0xCAFEBABE
   str  r1, [r10, #4]

@ ==== vblank counter: DISPSTAT poll, count rising edges ====
   mov  r6, #0
vb_loop:
4: ldrh r0, [r11, #4]
   tst  r0, #1
   bne  4b
5: ldrh r0, [r11, #4]
   tst  r0, #1
   beq  5b
   add  r6, r6, #1
   str  r6, [r10, #8]
   b    vb_loop

@ ================= subroutines (r0 = destination base) =================
@ r4 = 0x0421, r5 = 0x7FFF on entry to pal_ramp / pal_inv.

pal_ramp:
   mov  r1, #0
pr0:
   mul  r2, r1, r4
   and  r2, r2, r5
   add  r6, r1, #1
   mul  r3, r6, r4
   and  r3, r3, r5
   orr  r2, r2, r3, lsl #16
   str  r2, [r0], #4
   add  r1, r1, #2
   cmp  r1, #256
   blt  pr0
   bx   lr

pal_inv:
   mov  r1, #0
pi0:
   rsb  r6, r1, #255
   mul  r2, r6, r4
   and  r2, r2, r5
   rsb  r6, r1, #254
   mul  r3, r6, r4
   and  r3, r3, r5
   orr  r2, r2, r3, lsl #16
   str  r2, [r0], #4
   add  r1, r1, #2
   cmp  r1, #256
   blt  pi0
   bx   lr

@ 256-colour BG tiles: tile 0 fully transparent, tiles 1..3 are index
@ ramps 64..127 / 128..191 / 192..255 (byte k of the block = k). That
@ sweeps three quarters of the 256-entry palette, so the colour term of
@ the palette address is exercised across its range.
gen_tiles:
   mov  r1, #0
   mov  r2, #16                @ tile 0: 64 B of index 0
gt0:
   str  r1, [r0], #4
   subs r2, r2, #1
   bne  gt0
   mov  r1, #64                @ k, 4 pixels per store, no byte carries
   ldr  r7, =0x01010101
   ldr  r8, =0x03020100
gt1:
   mul  r2, r1, r7
   add  r2, r2, r8
   str  r2, [r0], #4
   add  r1, r1, #4
   cmp  r1, #256
   blt  gt1
   bx   lr

@ 32x32 text map: tile (x+y)&3 (0 = transparent hole -> backdrop),
@ palno (x>>1)&15, h-flip on odd rows. BG ext palettes are disabled on
@ both engines, so the palno field MUST be ignored.
gen_map:
   mov  r1, #0
gm0:
   and  r2, r1, #31            @ x
   mov  r3, r1, lsr #5         @ y
   add  r4, r2, r3
   and  r4, r4, #3             @ tile index
   tst  r3, #1
   orrne r4, r4, #0x0400       @ hflip
   mov  r5, r2, lsr #1
   and  r5, r5, #15            @ palno -> tileinfo(15:12), must be ignored
   orr  r4, r4, r5, lsl #12
   strh r4, [r0], #2
   add  r1, r1, #1
   cmp  r1, #1024
   blt  gm0
   ldr  r4, =0x0421            @ restore the palette constants
   ldr  r5, =0x7FFF
   bx   lr

@ OBJ tiles at 1D boundary 2 (128 B units):
@   tile number 1 (+0x080): 16x16 4bpp, quadrant colours 1/2/3/4
@   tile number 2 (+0x100):   8x8 4bpp, colour 6
@   tile number 4 (+0x200): 16x16 256-colour, byte k = k (k=0 -> 1)
@   tile number 6 (+0x300): 16x16 256-colour, byte k = 255-k (k=255 -> 1)
gen_obj:
   mov  r12, r0
   add  r0, r0, #0x80
   mov  r6, #1
go0:
   orr  r1, r6, r6, lsl #4
   orr  r1, r1, r1, lsl #8
   orr  r1, r1, r1, lsl #16
   mov  r2, #8
go1:
   str  r1, [r0], #4
   subs r2, r2, #1
   bne  go1
   add  r6, r6, #1
   cmp  r6, #5
   blt  go0
   ldr  r1, =0x66666666        @ now at +0x100 = tile number 2
   mov  r2, #8
go2:
   str  r1, [r0], #4
   subs r2, r2, #1
   bne  go2
   @ tile number 4: 256 bytes, byte k = k
   add  r0, r12, #0x200
   ldr  r7, =0x01010101
   ldr  r8, =0x03020100
   mov  r1, #0
go3:
   mul  r2, r1, r7
   add  r2, r2, r8
   str  r2, [r0], #4
   add  r1, r1, #4
   cmp  r1, #256
   blt  go3
   @ byte 0 would be index 0 = transparent; patch it to 1 with a WORD
   @ store. The ARM9 cannot byte-write VRAM (GBATEK: 8-bit writes to
   @ VRAM/palette/OAM are ignored), so strb here would be a no-op on
   @ hardware and under melonDS.
   ldr  r1, =0x03020101
   str  r1, [r12, #0x200]
   @ tile number 6: 256 bytes, byte k = 255-k
   ldr  r8, =0xFCFDFEFF
   mov  r1, #0
go4:
   mul  r2, r1, r7
   rsb  r2, r2, r8
   str  r2, [r0], #4
   add  r1, r1, #4
   cmp  r1, #256
   blt  go4
   ldr  r1, =0x01010203        @ same for the last byte of tile number 6
   str  r1, [r12, #0x3FC]
   bx   lr

@ OAM: 128 disabled sprites, then six visible ones.
gen_oam:
   mov  r3, r0
   ldr  r1, =0x00000200        @ attr0 bit 9 = disable (rotscale off)
   mov  r2, #128
gn0:
   str  r1, [r0], #4
   str  r1, [r0], #4
   subs r2, r2, #1
   bne  gn0
   mov  r0, r3
   @ spr0: 16x16 4bpp at (16,24), tile 1, std pal 0
   ldr  r1, =0x40100018
   str  r1, [r0]
   mov  r1, #1
   str  r1, [r0, #4]
   @ spr1: 8x8 4bpp at (100,80), h-flipped, tile 2, std pal 1
   ldr  r1, =0x10640050
   str  r1, [r0, #8]
   ldr  r1, =0x00001002
   str  r1, [r0, #12]
   @ spr2: 16x16 256-colour at (48,24), tile 4, ext palno 5
   ldr  r1, =0x40302018
   str  r1, [r0, #16]
   ldr  r1, =0x00005004
   str  r1, [r0, #20]
   @ spr3: 16x16 256-colour at (80,24), tile 6, ext palno 11
   ldr  r1, =0x40502018
   str  r1, [r0, #24]
   ldr  r1, =0x0000B006
   str  r1, [r0, #28]
   @ spr4: 16x16 256-colour at (112,24), tile 4, ext palno 0
   ldr  r1, =0x40702018
   str  r1, [r0, #32]
   ldr  r1, =0x00000004
   str  r1, [r0, #36]
   @ spr5: 16x16 256-colour at (248,100) - clips at the right edge
   ldr  r1, =0x40F82064
   str  r1, [r0, #40]
   ldr  r1, =0x0000B006
   str  r1, [r0, #44]
   bx   lr

   .ltorg
