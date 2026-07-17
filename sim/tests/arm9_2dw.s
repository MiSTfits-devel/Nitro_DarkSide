@ M5 windows + mosaic scene, ARM9 side: the arm9_2dh.s ext-pal/blending
@ scene with the window machinery and mosaic on top. Linked at 0x02000000
@ (see build_nds_2dw.sh).
@
@ Deltas vs arm9_2dh.s:
@   WIN0 (x 30..129, y 20..99):   BG0+BG1+OBJ visible, effects ON
@   WIN1 (x 100..219, y 60..159): BG1+BG3 visible, effects OFF
@   OBJWIN (16x16 mode-2 sprite at 140,30): BG3 only, effects ON
@   WINOUT:                       BG0+BG3+OBJ visible (no BG1), effects ON
@   MOSAIC 0x3323: BG h=3 v=2 on BG0 (text); OBJ h=v=3 on sprite 0
@     (h==v deliberately: melonDS 0.9.5 indexes the sprite X-mosaic table
@      with the V size - a later-fixed bug the compare must not trip on;
@      the affine BG stays mosaic-free, our affine mosaic is a known TODO)
@
@ Follows the melonDS 0.9.5 rules from arm9_2d.s (explicit PU regions,
@ POWCNT1 before palette/OAM writes). Mailbox as arm9_2d.s.

   .arch armv5te
   .arm
   .global _start

_start:
@ ==== crt0 (arm9_2d.s) ====
   mov  r0, #0x20
   mcr  p15, 0, r0, c9, c1, 1
   ldr  r0, =0x027E000A
   mcr  p15, 0, r0, c9, c1, 0
   ldr  r0, =0x04000033        @ region 0: IO/palette/VRAM/OAM, 64 MB
   mcr  p15, 0, r0, c6, c0, 0
   ldr  r0, =0x0200002B        @ region 1: main RAM 4 MB, cachable
   mcr  p15, 0, r0, c6, c1, 0
   ldr  r0, =0x02C0002B        @ region 2: main-RAM mirror (mailbox)
   mcr  p15, 0, r0, c6, c2, 0
   ldr  r0, =0x027E001B        @ region 3: DTCM window
   mcr  p15, 0, r0, c6, c3, 0
   mov  r0, #0x02
   mcr  p15, 0, r0, c2, c0, 0
   mcr  p15, 0, r0, c2, c0, 1
   mcr  p15, 0, r0, c3, c0, 0
   ldr  r0, =0x33333333
   mcr  p15, 0, r0, c5, c0, 2
   mcr  p15, 0, r0, c5, c0, 3
   ldr  r0, =0x0005107D
   mcr  p15, 0, r0, c1, c0, 0
   ldr  sp, =0x027E3F80

   ldr  r10, =0x02FFFF00
   ldr  r11, =0x04000000
   mov  r9, #1
   str  r9, [r10]

@ ==== POWCNT1 before any palette/OAM data ====
   ldr  r0, =0x8003
   ldr  r1, =0x04000304
   strh r0, [r1]

@ ==== VRAMCNT: A -> BG, B -> OBJ, E/F -> LCDC for ext-pal writes ====
   mov  r0, #0x81
   strb r0, [r11, #0x240]      @ A: BG 0x06000000
   mov  r0, #0x82
   strb r0, [r11, #0x241]      @ B: OBJ 0x06400000
   mov  r0, #0x80
   strb r0, [r11, #0x244]      @ E: LCDC 0x06880000
   strb r0, [r11, #0x245]      @ F: LCDC 0x06890000

@ ==== std BG palette ramp (BG0 4bpp + BG3 8bpp) ====
   ldr  r0, =0x05000000
   mov  r1, #0
   ldr  r4, =0x0421
   ldr  r5, =0x7FFF
1: mul  r2, r1, r4
   and  r2, r2, r5
   add  r6, r1, #1
   mul  r3, r6, r4
   and  r3, r3, r5
   orr  r2, r2, r3, lsl #16
   str  r2, [r0], #4
   add  r1, r1, #2
   cmp  r1, #256
   blt  1b

@ ==== std OBJ palette: inverted ramp ====
   ldr  r0, =0x05000200
   mov  r1, #0
2: rsb  r6, r1, #255
   mul  r2, r6, r4
   and  r2, r2, r5
   rsb  r6, r1, #254
   mul  r3, r6, r4
   and  r3, r3, r5
   orr  r2, r2, r3, lsl #16
   str  r2, [r0], #4
   add  r1, r1, #2
   cmp  r1, #256
   blt  2b

@ ==== BG ext palettes via LCDC bank E: 32 KB, e(j) = (j*0x3F1)&0x7FFF ====
   ldr  r0, =0x06880000
   mov  r1, #0                 @ j (even)
   ldr  r4, =0x03F1
3: mul  r2, r1, r4
   and  r2, r2, r5
   add  r6, r1, #1
   mul  r3, r6, r4
   and  r3, r3, r5
   orr  r2, r2, r3, lsl #16
   str  r2, [r0], #4
   add  r1, r1, #2
   ldr  r6, =16384
   cmp  r1, r6
   blt  3b

@ ==== OBJ ext palettes via LCDC bank F: 8 KB used, e(j) = (j*0x295+0x1111)&0x7FFF ====
   ldr  r0, =0x06890000
   mov  r1, #0
   ldr  r4, =0x0295
   ldr  r7, =0x1111
4: mul  r2, r1, r4
   add  r2, r2, r7
   and  r2, r2, r5
   add  r6, r1, #1
   mul  r3, r6, r4
   add  r3, r3, r7
   and  r3, r3, r5
   orr  r2, r2, r3, lsl #16
   str  r2, [r0], #4
   add  r1, r1, #2
   ldr  r6, =4096
   cmp  r1, r6
   blt  4b

@ ==== remap: E -> BG ext pal slots 0-3, F -> OBJ ext pal ====
   mov  r0, #0x84
   strb r0, [r11, #0x244]
   mov  r0, #0x85
   strb r0, [r11, #0x245]

   orr  r9, r9, #2             @ bit 1: palettes (std + ext)
   str  r9, [r10]

@ ==== BG0 4bpp tiles at 0x06000000: 0 clear, 1 solid, 2 checker, 3 stripes ====
   ldr  r0, =0x06000000
   mov  r1, #0
   mov  r2, #8
5: str  r1, [r0], #4
   subs r2, r2, #1
   bne  5b
   ldr  r1, =0x11111111
   mov  r2, #8
6: str  r1, [r0], #4
   subs r2, r2, #1
   bne  6b
   ldr  r1, =0x23232323
   ldr  r3, =0x32323232
   mov  r2, #4
7: str  r1, [r0], #4
   str  r3, [r0], #4
   subs r2, r2, #1
   bne  7b
   ldr  r1, =0x44444444
   ldr  r3, =0x55555555
   mov  r2, #2
8: str  r1, [r0], #4
   str  r1, [r0], #4
   str  r3, [r0], #4
   str  r3, [r0], #4
   subs r2, r2, #1
   bne  8b

@ ==== BG3 affine map at 0x06001800: 16x16, tiles 1/2 checkered ====
   ldr  r0, =0x06001800
   mov  r1, #0
9: and  r2, r1, #15
   mov  r3, r1, lsr #4
   add  r2, r2, r3
   and  r2, r2, #1
   add  r2, r2, #1
   add  r4, r1, #1
   and  r4, r4, #15
   add  r4, r4, r3
   and  r4, r4, #1
   add  r4, r4, #1
   orr  r2, r2, r4, lsl #8
   strh r2, [r0], #2
   add  r1, r1, #2
   cmp  r1, #256
   blt  9b

@ ==== BG0 map at 0x06002000: tile (x+y)&3 (0 = hole), subpal, hflip ====
   ldr  r0, =0x06002000
   mov  r1, #0
10:and  r2, r1, #31
   mov  r3, r1, lsr #5
   add  r4, r2, r3
   and  r4, r4, #3
   tst  r2, #1
   orrne r4, r4, #0x0400
   and  r5, r2, #0x18
   orr  r4, r4, r5, lsl #9
   strh r4, [r0], #2
   add  r1, r1, #1
   ldr  r2, =1024
   cmp  r1, r2
   blt  10b

@ ==== BG1 map at 0x06002800: tile (x+y)%3 (0 = hole), ext palette (x>>2)&7 ====
   ldr  r0, =0x06002800
   mov  r1, #0
11:and  r2, r1, #31
   mov  r3, r1, lsr #5
   add  r4, r2, r3
12:cmp  r4, #3
   subge r4, r4, #3
   bge  12b
   and  r5, r2, #0x1C          @ (x>>2)&7 -> bits 15:12
   orr  r4, r4, r5, lsl #10
   tst  r3, #1
   orrne r4, r4, #0x0800       @ vflip odd rows
   strh r4, [r0], #2
   add  r1, r1, #1
   ldr  r2, =1024
   cmp  r1, r2
   blt  11b

@ ==== BG3 8bpp tiles at 0x06004040/80 (char base 1) ====
   ldr  r0, =0x06004040
   mov  r1, #0
13:and  r2, r1, #7
   mov  r3, r1, lsr #3
   add  r2, r2, r3
   and  r2, r2, #7
   add  r2, r2, #32
   add  r4, r1, #1
   and  r4, r4, #7
   add  r4, r4, r3
   and  r4, r4, #7
   add  r4, r4, #32
   orr  r2, r2, r4, lsl #8
   add  r4, r1, #2
   and  r4, r4, #7
   add  r4, r4, r3
   and  r4, r4, #7
   add  r4, r4, #32
   orr  r2, r2, r4, lsl #16
   add  r4, r1, #3
   and  r4, r4, #7
   add  r4, r4, r3
   and  r4, r4, #7
   add  r4, r4, #32
   orr  r2, r2, r4, lsl #24
   str  r2, [r0], #4
   add  r1, r1, #4
   cmp  r1, #64
   blt  13b
   mov  r1, #0
14:and  r2, r1, #7
   mov  r3, r1, lsr #3
   eor  r2, r2, r3
   add  r2, r2, #64
   add  r4, r1, #1
   and  r4, r4, #7
   eor  r4, r4, r3
   add  r4, r4, #64
   orr  r2, r2, r4, lsl #8
   add  r4, r1, #2
   and  r4, r4, #7
   eor  r4, r4, r3
   add  r4, r4, #64
   orr  r2, r2, r4, lsl #16
   add  r4, r1, #3
   and  r4, r4, #7
   eor  r4, r4, r3
   add  r4, r4, #64
   orr  r2, r2, r4, lsl #24
   str  r2, [r0], #4
   add  r1, r1, #4
   cmp  r1, #64
   blt  14b

@ ==== BG1 256-color tiles at 0x06008040/80 (char base 2) ====
@ tile 1: byte = 1 + ((r*8+c)&0x7E); tile 2: byte = 0x80 | ((r*8+c)&0x7F)
   ldr  r0, =0x06008040
   mov  r1, #0                 @ r*8+c
15:and  r2, r1, #0x7E
   add  r2, r2, #1
   add  r4, r1, #1
   and  r4, r4, #0x7E
   add  r4, r4, #1
   orr  r2, r2, r4, lsl #8
   add  r4, r1, #2
   and  r4, r4, #0x7E
   add  r4, r4, #1
   orr  r2, r2, r4, lsl #16
   add  r4, r1, #3
   and  r4, r4, #0x7E
   add  r4, r4, #1
   orr  r2, r2, r4, lsl #24
   str  r2, [r0], #4
   add  r1, r1, #4
   cmp  r1, #64
   blt  15b
   mov  r1, #0
16:and  r2, r1, #0x7F
   orr  r2, r2, #0x80
   add  r4, r1, #1
   and  r4, r4, #0x7F
   orr  r4, r4, #0x80
   orr  r2, r2, r4, lsl #8
   add  r4, r1, #2
   and  r4, r4, #0x7F
   orr  r4, r4, #0x80
   orr  r2, r2, r4, lsl #16
   add  r4, r1, #3
   and  r4, r4, #0x7F
   orr  r4, r4, #0x80
   orr  r2, r2, r4, lsl #24
   str  r2, [r0], #4
   add  r1, r1, #4
   cmp  r1, #64
   blt  16b

   orr  r9, r9, #4             @ bit 2: BG data
   str  r9, [r10]

@ ==== OBJ tiles ====
@ tiles 2..5 at 0x06400040: 16x16 4bpp quadrants 1/2/3/4
   ldr  r0, =0x06400040
   mov  r6, #1
17:orr  r1, r6, r6, lsl #4
   orr  r1, r1, r1, lsl #8
   orr  r1, r1, r1, lsl #16
   mov  r2, #8
18:str  r1, [r0], #4
   subs r2, r2, #1
   bne  18b
   add  r6, r6, #1
   cmp  r6, #5
   blt  17b
@ tile 6: 8x8 solid color 6 (the semi-transparent sprite)
   ldr  r1, =0x66666666
   mov  r2, #8
19:str  r1, [r0], #4
   subs r2, r2, #1
   bne  19b
@ tile 8 at 0x06400100: 16x16 256-color, byte = (k*3+5)&0xFF (0 -> holes ok)
   ldr  r0, =0x06400100
   mov  r1, #0                 @ k
20:mov  r2, #0
   mov  r3, #0                 @ build word: bytes k..k+3
   mov  r6, #0
21:add  r4, r1, r6
   add  r4, r4, r4, lsl #1     @ k*3
   add  r4, r4, #5
   and  r4, r4, #0xFF
   orr  r3, r3, r4, lsl r2
   add  r2, r2, #8
   add  r6, r6, #1
   cmp  r6, #4
   blt  21b
   str  r3, [r0], #4
   add  r1, r1, #4
   cmp  r1, #256
   blt  20b

@ ==== OAM: all hidden, then 4 sprites ====
   ldr  r0, =0x07000000
   ldr  r1, =0x00000200
   mov  r2, #128
22:str  r1, [r0], #4
   str  r1, [r0], #4
   subs r2, r2, #1
   bne  22b
   ldr  r0, =0x07000000
   @ spr0: 16x16 4bpp at (40,30), tiles 2, pal 0, MOSAIC (blend 1st target)
   ldr  r1, =0x4028101E
   str  r1, [r0]
   ldr  r1, =0x00000002
   str  r1, [r0, #4]
   @ spr1: 8x8 semi-transparent (gfx mode 1) at (100,80), tile 6, pal 1
   ldr  r1, =0x00640450        @ attr1: x=100; attr0: y=80 | mode1<<10
   str  r1, [r0, #8]
   ldr  r1, =0x00001006
   str  r1, [r0, #12]
   @ spr2: 16x16 256-color ext-pal slot 5 at (180,60)
   ldr  r1, =0x40B4203C        @ attr1: x=180 size16; attr0: y=60 | 256c bit13
   str  r1, [r0, #16]
   ldr  r1, =0x00005008        @ attr2: tile 8, ext palette 5
   str  r1, [r0, #20]
   @ spr3: 16x16 4bpp at (248,100) - right-edge clip
   ldr  r1, =0x40F80064
   str  r1, [r0, #24]
   ldr  r1, =0x00000402
   str  r1, [r0, #28]
   @ spr4: 16x16 OBJ-window sprite (gfx mode 2) at (140,30), tiles 2
   ldr  r1, =0x408C081E        @ attr1: x=140 size16; attr0: y=30 | mode2
   str  r1, [r0, #32]
   ldr  r1, =0x00000002
   str  r1, [r0, #36]

   orr  r9, r9, #8             @ bit 3: OBJ data
   str  r9, [r10]

@ ==== BG control + affine + blending + display on ====
   ldr  r0, =0x0440            @ BG0: pri 0, char 0, screen 4, 4bpp, MOSAIC
   strh r0, [r11, #0x08]
   ldr  r0, =0x0589            @ BG1: pri 1, char 2, 256c (ext pal), screen 5
   strh r0, [r11, #0x0A]
   ldr  r0, =0x0307            @ BG3: pri 3, char 1, screen 3, 128x128
   strh r0, [r11, #0x0E]
   mov  r0, #0
   strh r0, [r11, #0x10]
   strh r0, [r11, #0x12]
   strh r0, [r11, #0x14]       @ BG1HOFS
   strh r0, [r11, #0x16]       @ BG1VOFS
   ldr  r0, =0x00E0
   strh r0, [r11, #0x30]
   ldr  r0, =0x0040
   strh r0, [r11, #0x32]
   ldr  r0, =0xFFC0
   strh r0, [r11, #0x34]
   ldr  r0, =0x00E0
   strh r0, [r11, #0x36]
   mov  r0, #0
   str  r0, [r11, #0x38]
   str  r0, [r11, #0x3C]
   ldr  r0, =0x2A51            @ BLDCNT: alpha, 1st BG0+OBJ, 2nd BG1+BG3+BD
   strh r0, [r11, #0x50]
   ldr  r0, =0x0709            @ BLDALPHA: EVA=9, EVB=7
   strh r0, [r11, #0x52]
   ldr  r0, =0x64DC1E82        @ WIN1H: 100..220 | WIN0H: 30..130
   str  r0, [r11, #0x40]
   ldr  r0, =0x3CA01464        @ WIN1V: 60..160  | WIN0V: 20..100
   str  r0, [r11, #0x44]
   ldr  r0, =0x28390A33        @ WINOUT/OBJWIN | WININ (win1/win0)
   str  r0, [r11, #0x48]
   ldr  r0, =0x3323            @ MOSAIC: OBJ h=v=3, BG h=3 v=2
   strh r0, [r11, #0x4C]
   ldr  r0, =0xC001FB11        @ mode 1, BG0+BG1+BG3+OBJ, all windows,
   str  r0, [r11]              @ 1D, ext pals, display on

   orr  r9, r9, #16
   str  r9, [r10]
   ldr  r1, =0xCAFEBABE
   str  r1, [r10, #4]

@ ==== vblank counter ====
   mov  r6, #0
vb_loop:
23:ldrh r0, [r11, #4]
   tst  r0, #1
   bne  23b
24:ldrh r0, [r11, #4]
   tst  r0, #1
   beq  24b
   add  r6, r6, #1
   str  r6, [r10, #8]
   b    vb_loop

   .ltorg
