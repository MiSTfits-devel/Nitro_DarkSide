// sdk2d ARM9 main: a devkitARM/libnds-built DUAL-SCREEN 2D scene for the
// M6 frame diff, packed by ndstool. Both engines render the same feature
// set with per-engine pattern variation:
//   BG0  text 4bpp, ring/cross tiles with transparent holes, pri 0,
//        blend 1st target, light mosaic (BG h+v, OBJ h only)
//   BG1  text 256-color with BG EXT PALETTES (per-tile palettes), pri 1
//   BG3  affine 8bpp, procedural rings, rotated +/-45deg, pri 3
//   OBJ  quadrant sprite (mosaic), semi-transparent 8x8, 256-color OBJ
//        EXT PAL sprite, right-edge clipped sprite, mode-2 OBJ-window
//   WIN0 + OBJWIN + blending (alpha 9/7), MOSAIC 0x2202
//
// libnds is used for register definitions and the VRAM bank helpers only —
// no calico kernel, no DMA, no BIOS calls (see arm9_crt0.s). All graphics
// data is procedural.
//
// Engine bases: regs +0x1000, palettes +0x400, OAM +0x400, BG VRAM
// 0x06000000/0x06200000 (banks A/C), OBJ VRAM 0x06400000/0x06600000
// (banks B/D), ext-pal staging via LCDC E/F (A) and H/I (B).
//
// Mailbox (uncached main-RAM mirror): 0x02FFFF00 progress, 0x02FFFF04
// magic 0xCAFEBABE when programmed, 0x02FFFF08 vblank counter.

#include <nds/arm9/video.h>
#include <nds/arm9/background.h>
#include <nds/memory.h>
#include <calico/nds/pm.h>

#define MAIL ((volatile u32 *)0x02FFFF00)

#define REG16(b, off)  (*(volatile u16 *)(0x04000000u + (u32)(b)*0x1000u + (off)))
#define REG32(b, off)  (*(volatile u32 *)(0x04000000u + (u32)(b)*0x1000u + (off)))
#define BGPAL(b)   ((volatile u16 *)(0x05000000u + (u32)(b)*0x400u))
#define OBJPAL(b)  ((volatile u16 *)(0x05000200u + (u32)(b)*0x400u))
#define OAM16(b)   ((volatile u16 *)(0x07000000u + (u32)(b)*0x400u))
#define BGVRAM(b)  (0x06000000u + (u32)(b)*0x200000u)
#define OBJVRAM(b) (0x06400000u + (u32)(b)*0x200000u)

static void wait_vblank(void)
{
    while (REG_DISPSTAT & DISPSTAT_IF_VBLANK) { }
    while (!(REG_DISPSTAT & DISPSTAT_IF_VBLANK)) { }
}

// one engine's full scene; b = 0 engine A, 1 engine B. Ext palettes are
// staged by the caller (bank mapping order differs per engine).
static void scene(int b)
{
    u32 vary = (u32)b * 3u;      // pattern/color variation between screens

    // std palettes
    for (int i = 0; i < 256; i++) {
        BGPAL(b)[i]  = (u16)((i * (0x0421 + vary * 8) + (i >> 3)) & 0x7FFF);
        OBJPAL(b)[i] = (u16)(((255 - i) * (0x0421 + vary * 4)) & 0x7FFF);
    }

    // ---- BG0 4bpp tiles at char base 0: blank, ring, cross, solid ----
    for (int t = 0; t < 4; t++)
        for (int r = 0; r < 8; r++) {
            u32 row = 0;
            for (int c = 0; c < 8; c++) {
                int dx = 2*c - 7, dy = 2*r - 7, d2 = dx*dx + dy*dy;
                u32 px = 0;
                if (t == 1) px = (d2 > (int)(20 - vary*2) && d2 < 60) ? 1u + ((u32)r >> 2) : 0u;
                if (t == 2) px = (c == r || c == 7 - r) ? 3u : 0u;
                if (t == 3) px = 4u + (((u32)c + (u32)r) & 3u);
                row |= px << (4 * c);
            }
            ((volatile u32 *)BGVRAM(b))[t*8 + r] = row;
        }

    // ---- BG3 affine 8bpp tiles 1/2 at char base 1 (0x4000): rings ----
    for (int t = 1; t <= 2; t++)
        for (int r = 0; r < 8; r++) {
            u32 w0 = 0, w1 = 0;
            for (int c = 0; c < 8; c++) {
                int dx = 2*c - 7, dy = 2*r - 7, d2 = dx*dx + dy*dy;
                u32 px = (t == 1) ? (32u + vary + (((u32)d2 >> 3) & 15u))
                                  : (64u + (((u32)(c ^ r)) & 7u));
                if (c < 4) w0 |= px << (8 * c);
                else       w1 |= px << (8 * (c - 4));
            }
            ((volatile u32 *)(BGVRAM(b) + 0x4000 + 64u*(u32)t))[r*2]     = w0;
            ((volatile u32 *)(BGVRAM(b) + 0x4000 + 64u*(u32)t))[r*2 + 1] = w1;
        }

    // ---- BG1 256-color tiles 1/2 at char base 2 (0x8000): gradients ----
    for (int t = 1; t <= 2; t++)
        for (int r = 0; r < 8; r++) {
            u32 w0 = 0, w1 = 0;
            for (int c = 0; c < 8; c++) {
                u32 px = (t == 1) ? (1u + 16u*(u32)r + (u32)c)
                                  : (129u + 8u*(u32)c + (u32)r);
                if (c < 4) w0 |= px << (8 * c);
                else       w1 |= px << (8 * (c - 4));
            }
            ((volatile u32 *)(BGVRAM(b) + 0x8000 + 64u*(u32)t))[r*2]     = w0;
            ((volatile u32 *)(BGVRAM(b) + 0x8000 + 64u*(u32)t))[r*2 + 1] = w1;
        }

    // ---- maps ----
    // BG3 affine 16x16 byte map at 0x1800: tiles 1/2 checkered
    for (int i = 0; i < 128; i++) {
        int x = (2*i) & 15, y = i >> 3;
        u16 lo = (u16)(1 + ((x + y) & 1)), hi = (u16)(1 + ((x + 1 + y) & 1));
        ((volatile u16 *)(BGVRAM(b) + 0x1800))[i] = (u16)(lo | (hi << 8));
    }
    // BG0 text map at screen base 4 (0x2000)
    for (int i = 0; i < 1024; i++) {
        int x = i & 31, y = i >> 5;
        u16 e = (u16)((x*y + x + y + (int)vary) & 3);
        if (x & 1) e |= 1 << 10;
        if (y & 2) e |= 1 << 11;
        e |= (u16)((x >> 3) & 3) << 12;
        ((volatile u16 *)(BGVRAM(b) + 0x2000))[i] = e;
    }
    // BG1 map at screen base 5 (0x2800): holes + ext palettes 0..7
    for (int i = 0; i < 1024; i++) {
        int x = i & 31, y = i >> 5;
        u16 e = (u16)((x + 2*y + (int)vary) % 3);
        e |= (u16)(((x >> 2) + y) & 7) << 12;
        ((volatile u16 *)(BGVRAM(b) + 0x2800))[i] = e;
    }

    // ---- OBJ tiles (1D, 32 B boundary) ----
    for (int q = 0; q < 4; q++) {
        u32 v = 0x11111111u * (u32)(q + 1);
        for (int r = 0; r < 8; r++)
            ((volatile u32 *)(OBJVRAM(b) + 0x40))[q*8 + r] = v;
    }
    for (int r = 0; r < 8; r++)
        ((volatile u32 *)(OBJVRAM(b) + 0xC0))[r] = 0x66666666u;
    for (int k = 0; k < 64; k++) {
        u32 w = 0;
        for (int c = 0; c < 4; c++)
            w |= (u32)(((4*k + c) * 5 + 9 + (int)vary) & 0xFF) << (8 * c);
        ((volatile u32 *)(OBJVRAM(b) + 0x100))[k] = w;
    }

    // ---- OAM: all hidden, then the 5 sprites (B shifts them a bit) ----
    for (int i = 0; i < 128; i++) {
        OAM16(b)[i*4]     = 0x0200;
        OAM16(b)[i*4 + 1] = 0;
        OAM16(b)[i*4 + 2] = 0;
    }
    u16 sh = (u16)(b * 12);
    OAM16(b)[0]  = 0x101E; OAM16(b)[1]  = (u16)(0x4028 + sh); OAM16(b)[2]  = 0x0002;
    OAM16(b)[4]  = 0x0450; OAM16(b)[5]  = (u16)(0x0064 + sh); OAM16(b)[6]  = 0x1006;
    OAM16(b)[8]  = 0x203C; OAM16(b)[9]  = (u16)(0x40B4 + sh); OAM16(b)[10] = 0x5008;
    OAM16(b)[12] = 0x0064; OAM16(b)[13] = 0x40F8;             OAM16(b)[14] = 0x0402;
    OAM16(b)[16] = 0x0896; OAM16(b)[17] = (u16)(0x40C8 + sh); OAM16(b)[18] = 0x0002;

    // ---- BG control, affine, windows, blending, display ----
    REG16(b, 0x08) = 0x0400 | BIT(6);          // BG0: pri 0, mosaic
    REG16(b, 0x0A) = 0x0589;                   // BG1: 256c ext pal
    REG16(b, 0x0E) = 0x0307;                   // BG3: affine 128x128, pri 3
    REG16(b, 0x10) = 0; REG16(b, 0x12) = 0;
    REG16(b, 0x14) = 0; REG16(b, 0x16) = 0;
    // +/-45deg rotation, ~1.4x zoom out
    if (b == 0) {
        REG16(b, 0x30) = 0x00B5; REG16(b, 0x32) = 0x00B5;
        REG16(b, 0x34) = (u16)-0x00B5; REG16(b, 0x36) = 0x00B5;
        REG32(b, 0x38) = (u32)(-64 * 256); REG32(b, 0x3C) = (u32)(32 * 256);
    } else {
        REG16(b, 0x30) = 0x00B5; REG16(b, 0x32) = (u16)-0x00B5;
        REG16(b, 0x34) = 0x00B5; REG16(b, 0x36) = 0x00B5;
        REG32(b, 0x38) = (u32)(32 * 256); REG32(b, 0x3C) = (u32)(-64 * 256);
    }

    REG16(b, 0x40) = (u16)((40 + b*8) << 8 | (200 - b*8));   // WIN0H
    REG16(b, 0x44) = (u16)((30 + b*8) << 8 | (150 - b*8));   // WIN0V
    REG16(b, 0x48) = 0x0033;                   // WININ: BG0+BG1+OBJ, eff on
    REG16(b, 0x4A) = 0x283A;                   // WINOUT/OBJWIN
    // OBJ V mosaic stays 0: melonDS's OBJ mosaic-Y counter free-runs
    // across frames (never vblank-reset, unlike the BG one), so its block
    // anchor depends on which line the MOSAIC write lands on - not
    // reproducible across emulator/RTL timing. BG V + OBJ/BG H are
    // deterministic.
    REG16(b, 0x4C) = 0x0232;                   // MOSAIC: BG h=2 v=3, OBJ h=2
    REG16(b, 0x50) = 0x2A51;                   // BLDCNT
    REG16(b, 0x52) = 0x0709;                   // BLDALPHA

    REG32(b, 0x00) = MODE_1_2D | DISPLAY_BG0_ACTIVE | DISPLAY_BG1_ACTIVE |
                     DISPLAY_BG3_ACTIVE | DISPLAY_SPR_ACTIVE |
                     DISPLAY_SPR_1D_LAYOUT | DISPLAY_WIN0_ON | DISPLAY_SPR_WIN_ON |
                     DISPLAY_BG_EXT_PALETTE | DISPLAY_SPR_EXT_PALETTE;
}

int main(void)
{
    // POWCNT before any palette/OAM data (writes are dropped while the
    // owning 2D engine is off); then the VRAM banks
    REG_POWCNT = POWCNT_LCD | POWCNT_2D_GFX_A | POWCNT_2D_GFX_B | POWCNT_LCD_SWAP;
    vramSetBankA(VRAM_A_MAIN_BG);              // A BG    0x06000000
    vramSetBankB(VRAM_B_MAIN_SPRITE_0x06400000);
    vramSetBankC(VRAM_C_SUB_BG);               // B BG    0x06200000
    vramSetBankD(VRAM_D_SUB_SPRITE);           // B OBJ   0x06600000
    vramSetBankE(VRAM_E_LCD);                  // ext-pal staging
    vramSetBankF(VRAM_F_LCD);
    vramSetBankH(VRAM_H_LCD);
    vramSetBankI(VRAM_I_LCD);

    MAIL[0] = 1;

    // ext palettes via LCDC, then remap to their ext-pal roles
    for (int j = 0; j < 16384; j++)
        VRAM_E[j] = (u16)((j * 0x03B7 + 0x123) & 0x7FFF);
    for (int j = 0; j < 4096; j++)
        VRAM_F[j] = (u16)((j * 0x0299 + 0x321) & 0x7FFF);
    for (int j = 0; j < 16384; j++)
        VRAM_H[j] = (u16)((j * 0x03A1 + 0x231) & 0x7FFF);
    for (int j = 0; j < 4096; j++)
        VRAM_I[j] = (u16)((j * 0x028D + 0x132) & 0x7FFF);
    vramSetBankE(VRAM_E_BG_EXT_PALETTE);
    vramSetBankF(VRAM_F_SPRITE_EXT_PALETTE);
    vramSetBankH(VRAM_H_SUB_BG_EXT_PALETTE);
    vramSetBankI(VRAM_I_SUB_SPRITE_EXT_PALETTE);

    MAIL[0] |= 2;

    scene(0);
    MAIL[0] |= 4;
    scene(1);
    MAIL[0] |= 8;

    MAIL[0] |= 16;
    MAIL[1] = 0xCAFEBABE;

    for (u32 n = 1;; n++) {
        wait_vblank();
        MAIL[2] = n;
    }
}
