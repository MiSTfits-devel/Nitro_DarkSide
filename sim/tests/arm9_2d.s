@ M5 exit test, ARM9 side: SDK-shaped 2D scene for the nds_top frame dump.
@ Linked at 0x02000000, loaded by nds_loader (see build_nds_2d.sh).
@
@ Same crt0 shape as arm9_boot.s, then a NitroSDK-style 2D bring-up done
@ with plain CPU stores (no DMA yet):
@   VRAMCNT  A -> BG (0x06000000), B -> OBJ (0x06400000)
@   mode 1: BG0 text 4bpp (tiles+map procedural), BG3 affine 8bpp with a
@   rotation/scale matrix, 3 OBJs (16x16 quadrant sprite, 8x8 h-flipped,
@   16x16 at the screen edge for clipping)
@   palettes: BG + OBJ ramps (entry i = (i*0x421)|0x8000 masked to 555)
@
@ Mailbox (uncached main-RAM mirror): 0x02FFFF00 progress bitmask,
@ 0x02FFFF04 magic (0xCAFEBABE when the scene is fully programmed),
@ 0x02FFFF08 vblank counter (proof the DISPSTAT/IRQ path lives).
@
@ Rules for images that must also run under melonDS 0.9.5 (the frame-diff
@ oracle - copy THIS crt0 for new samples, not arm9_boot.s):
@   * no 4 GB PU catch-all region (melonDS computes 2<<31 = 0: covers
@     nothing -> data abort); use explicit SDK-style regions, and cover
@     the DTCM window too (melonDS checks PU before TCM)
@   * write POWCNT1 before any palette/OAM data - those writes are
@     dropped while the 2D engine is powered off

   .arch armv5te
   .arm
   .global _start

_start:
@ ==== crt0-shaped CP15 setup (arm9_boot.s) ====
   mov  r0, #0x20
   mcr  p15, 0, r0, c9, c1, 1  @ ITCM: 32 MB virtual
   ldr  r0, =0x027E000A
   mcr  p15, 0, r0, c9, c1, 0  @ DTCM at 0x027E0000, 16 KB
@ SDK-style explicit regions (a 4 GB catch-all like arm9_boot.s uses
@ covers nothing under melonDS 0.9.5: its PU model computes 2<<31 = 0)
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

   ldr  r10, =0x02FFFF00       @ mailbox (mirror -> region 0 -> uncached)
   ldr  r11, =0x04000000
   mov  r9, #1                 @ bit 0: crt0 done
   str  r9, [r10]

@ ==== POWCNT1 first: palette/OAM writes are dropped while the 2D
@ engine is off (melonDS models this; GX_Init powers up first too) ====
   ldr  r0, =0x8003            @ LCD + 2D engine A + A on top
   ldr  r1, =0x04000304
   strh r0, [r1]

@ ==== VRAMCNT: A -> BG slot 0, B -> OBJ slot 0 ====
   mov  r0, #0x81              @ enable, MST=1 (BG 0x06000000)
   strb r0, [r11, #0x240]
   mov  r0, #0x82              @ enable, MST=2, OFS=0 (OBJ 0x06400000)
   strb r0, [r11, #0x241]

@ ==== BG palette: ramp, entry i = (i*0x421) & 0x7FFF ====
   ldr  r0, =0x05000000
   mov  r1, #0                 @ i (even entry)
   ldr  r4, =0x0421
   ldr  r5, =0x7FFF
1: mul  r2, r1, r4
   and  r2, r2, r5             @ low entry
   add  r6, r1, #1
   mul  r3, r6, r4
   and  r3, r3, r5
   orr  r2, r2, r3, lsl #16
   str  r2, [r0], #4
   add  r1, r1, #2
   cmp  r1, #256
   blt  1b

@ ==== OBJ palette: inverted ramp so sprites differ from BGs ====
   ldr  r0, =0x05000200
   mov  r1, #0
2: rsb  r6, r1, #255           @ 255-i
   mul  r2, r6, r4
   and  r2, r2, r5
   rsb  r6, r1, #254           @ 255-(i+1)
   mul  r3, r6, r4
   and  r3, r3, r5
   orr  r2, r2, r3, lsl #16
   str  r2, [r0], #4
   add  r1, r1, #2
   cmp  r1, #256
   blt  2b

   orr  r9, r9, #2             @ bit 1: palettes
   str  r9, [r10]

@ ==== BG0 4bpp tiles at 0x06000000 (char base 0) ====
@ tile 0: transparent; tile 1: solid color 1; tile 2: checker 2/3;
@ tile 3: horizontal stripes 4/5
   ldr  r0, =0x06000000
   mov  r1, #0
   mov  r2, #8
3: str  r1, [r0], #4           @ tile 0
   subs r2, r2, #1
   bne  3b
   ldr  r1, =0x11111111
   mov  r2, #8
4: str  r1, [r0], #4           @ tile 1
   subs r2, r2, #1
   bne  4b
   ldr  r1, =0x23232323
   ldr  r3, =0x32323232
   mov  r2, #4
5: str  r1, [r0], #4           @ tile 2: alternate rows
   str  r3, [r0], #4
   subs r2, r2, #1
   bne  5b
   ldr  r1, =0x44444444
   ldr  r3, =0x55555555
   mov  r2, #2
6: str  r1, [r0], #4           @ tile 3: 2-row stripes
   str  r1, [r0], #4
   str  r3, [r0], #4
   str  r3, [r0], #4
   subs r2, r2, #1
   bne  6b

@ ==== BG3 affine map at 0x06001800 (screen base 3): 16x16 bytes ====
@ entry(x,y) = 1 + ((x+y)&1)  (tiles 1/2 checkered)
   ldr  r0, =0x06001800
   mov  r1, #0                 @ y*16+x, byte pairs via halfword stores
7: and  r2, r1, #15            @ x of even byte
   mov  r3, r1, lsr #4         @ y
   add  r2, r2, r3
   and  r2, r2, #1
   add  r2, r2, #1             @ low byte
   add  r4, r1, #1
   and  r4, r4, #15
   add  r4, r4, r3
   and  r4, r4, #1
   add  r4, r4, #1
   orr  r2, r2, r4, lsl #8
   strh r2, [r0], #2
   add  r1, r1, #2
   cmp  r1, #256
   blt  7b

@ ==== BG0 map at 0x06002000 (screen base 4): 32x32 entries ====
@ entry(x,y): tile (x+y)&3 (0 = transparent hole - the affine BG3 and
@ backdrop must show through), subpal (x>>3)&3, hflip on odd x
   ldr  r0, =0x06002000
   mov  r1, #0                 @ index y*32+x
8: and  r2, r1, #31            @ x
   mov  r3, r1, lsr #5         @ y
   add  r4, r2, r3
   and  r4, r4, #3             @ tile 0..3
   tst  r2, #1
   orrne r4, r4, #0x0400       @ hflip
   and  r5, r2, #0x18          @ (x>>3)&3 -> bits 13:12
   orr  r4, r4, r5, lsl #9
   strh r4, [r0], #2
   add  r1, r1, #1
   ldr  r2, =1024
   cmp  r1, r2
   blt  8b

@ ==== BG3 8bpp tiles at 0x06004000 (char base 1) ====
@ tile 1: color 32+((row+col)&7); tile 2: color 64+(row^col)
   ldr  r0, =0x06004040        @ tile 1 (64 B per 8bpp tile)
   mov  r1, #0                 @ row*8+col
10:and  r2, r1, #7             @ col of byte 0... build word of 4 pixels
   mov  r3, r1, lsr #3         @ row
   add  r2, r2, r3
   and  r2, r2, #7
   add  r2, r2, #32            @ px0
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
   blt  10b
   @ tile 2
   mov  r1, #0
11:and  r2, r1, #7
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
   blt  11b

   orr  r9, r9, #4             @ bit 2: BG data
   str  r9, [r10]

@ ==== OBJ tiles at 0x06400040 (tile index 2, 32 B units, 1D) ====
@ 16x16 4bpp sprite = tiles 2..5: quadrants solid 1/2/3/4
   ldr  r0, =0x06400040
   mov  r6, #1                 @ quadrant color
12:orr  r1, r6, r6, lsl #4
   orr  r1, r1, r1, lsl #8
   orr  r1, r1, r1, lsl #16
   mov  r2, #8
13:str  r1, [r0], #4
   subs r2, r2, #1
   bne  13b
   add  r6, r6, #1
   cmp  r6, #5
   blt  12b
@ 8x8 sprite = tile 6: rows of color 6
   ldr  r1, =0x66666666
   mov  r2, #8
14:str  r1, [r0], #4
   subs r2, r2, #1
   bne  14b

@ ==== OAM: all disabled, then 3 sprites ====
   ldr  r0, =0x07000000
   ldr  r1, =0x00000200        @ attr1:attr0 = rotscale off + disable
   mov  r2, #128
15:str  r1, [r0], #4
   str  r1, [r0], #4           @ attr3:attr2 (fill word, harmless)
   subs r2, r2, #1
   bne  15b
   ldr  r0, =0x07000000
   @ sprite 0: 16x16 4bpp at (40,30), tiles 2, subpal 0
   ldr  r1, =0x4028001E        @ attr1=0x4028 (x=40,size 16x16), attr0=0x001E (y=30)
   str  r1, [r0]
   ldr  r1, =0x00000002        @ attr2: tile 2, pri 0, pal 0
   str  r1, [r0, #4]
   @ sprite 1: 8x8 at (100,80), tile 6, hflip, subpal 1
   ldr  r1, =0x10640050        @ attr1: x=100, hflip (bit12); attr0: y=80
   str  r1, [r0, #8]
   ldr  r1, =0x00001006        @ attr2: tile 6, pal 1
   str  r1, [r0, #12]
   @ sprite 2: 16x16 at (248,100) - clips at the right edge
   ldr  r1, =0x40F80064        @ attr1: x=248, size 16x16; attr0: y=100
   str  r1, [r0, #16]
   ldr  r1, =0x00000402        @ attr2: tile 2, pri 1, pal 0
   str  r1, [r0, #20]

   orr  r9, r9, #8             @ bit 3: OBJ data
   str  r9, [r10]

@ ==== BG control + affine matrix + display on ====
   ldr  r0, =0x0401            @ BG0: pri 1, char 0, screen base 4, 4bpp
   strh r0, [r11, #0x08]
   ldr  r0, =0x0306            @ BG3: pri 2, char 1, screen base 3, 128x128
   strh r0, [r11, #0x0E]
   mov  r0, #0
   strh r0, [r11, #0x10]       @ BG0HOFS
   strh r0, [r11, #0x12]       @ BG0VOFS
   ldr  r0, =0x00E0            @ PA: cos*scale
   strh r0, [r11, #0x30]
   ldr  r0, =0x0040            @ PB
   strh r0, [r11, #0x32]
   ldr  r0, =0xFFC0            @ PC = -PB
   strh r0, [r11, #0x34]
   ldr  r0, =0x00E0            @ PD
   strh r0, [r11, #0x36]
   mov  r0, #0
   str  r0, [r11, #0x38]       @ BG3X
   str  r0, [r11, #0x3C]       @ BG3Y
   ldr  r0, =0x00011911        @ mode 1, BG0+BG3+OBJ, OBJ 1D, display on
   str  r0, [r11]

   orr  r9, r9, #16            @ bit 4: display programmed
   str  r9, [r10]
   ldr  r1, =0xCAFEBABE
   str  r1, [r10, #4]

@ ==== vblank counter: DISPSTAT poll, count rising edges ====
   mov  r6, #0
vb_loop:
1: ldrh r0, [r11, #4]          @ wait out vblank
   tst  r0, #1
   bne  1b
2: ldrh r0, [r11, #4]          @ wait for vblank
   tst  r0, #1
   beq  2b
   add  r6, r6, #1
   str  r6, [r10, #8]
   b    vb_loop

   .ltorg
