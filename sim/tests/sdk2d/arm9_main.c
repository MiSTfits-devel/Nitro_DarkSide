// sdk2d ARM9 main: a devkitARM/libnds-built 2D scene for the M5 frame
// diff, packed by ndstool (the first real-toolchain ROM through nds_top).
//
// libnds is used for register definitions and the VRAM bank helpers only —
// no calico kernel, no DMA, no BIOS calls (see arm9_crt0.s). All graphics
// data is procedural. Scene (engine A, mode 1):
//   BG0  text 4bpp, ring/cross tiles with transparent holes, pri 0,
//        blend 1st target, light mosaic
//   BG1  text 256-color with BG EXT PALETTES (slot 1, per-tile palettes),
//        gradient tiles, pri 1
//   BG3  affine 8bpp, procedural rings, rotated 45deg and zoomed, pri 3
//   OBJ  quadrant sprite (mosaic), semi-transparent 8x8, 256-color OBJ
//        EXT PAL sprite, right-edge clipped sprite, mode-2 OBJ-window
//   WIN0 (40..199 x 30..149): BG0+BG1+OBJ, effects on
//   OBJWIN: BG3 only; WINOUT: BG1+BG3+OBJ (no BG0), effects on
//   BLDCNT alpha BG0+OBJ over BG1+BG3+BD, EVA/EVB 9/7; MOSAIC 0x2202
//
// Mailbox (uncached main-RAM mirror): 0x02FFFF00 progress, 0x02FFFF04
// magic 0xCAFEBABE when programmed, 0x02FFFF08 vblank counter.

#include <nds/arm9/video.h>
#include <nds/arm9/background.h>
#include <nds/memory.h>
#include <calico/nds/pm.h>

#define MAIL     ((volatile u32 *)0x02FFFF00)
#define OAM16    ((volatile u16 *)0x07000000)
#define BGPAL    ((volatile u16 *)0x05000000)
#define OBJPAL   ((volatile u16 *)0x05000200)
#define BG_CHAR  ((volatile u16 *)0x06000000)

static void wait_vblank(void)
{
    while (REG_DISPSTAT & DISPSTAT_IF_VBLANK) { }
    while (!(REG_DISPSTAT & DISPSTAT_IF_VBLANK)) { }
}

int main(void)
{
    // POWCNT before any palette/OAM data (they are dropped while the 2D
    // engine is off); then the VRAM banks
    REG_POWCNT = POWCNT_LCD | POWCNT_2D_GFX_A | POWCNT_LCD_SWAP;
    vramSetBankA(VRAM_A_MAIN_BG);          // BG   0x06000000
    vramSetBankB(VRAM_B_MAIN_SPRITE_0x06400000);
    vramSetBankE(VRAM_E_LCD);              // ext-pal staging
    vramSetBankF(VRAM_F_LCD);

    MAIL[0] = 1;

    // std palettes: BG hue-ish ramp, OBJ inverted
    for (int i = 0; i < 256; i++) {
        BGPAL[i]  = (u16)((i * 0x0421 + (i >> 3)) & 0x7FFF);
        OBJPAL[i] = (u16)(((255 - i) * 0x0421) & 0x7FFF);
    }

    // BG ext palettes via LCDC bank E (32 KB), OBJ ext via bank F
    for (int j = 0; j < 16384; j++)
        VRAM_E[j] = (u16)((j * 0x03B7 + 0x123) & 0x7FFF);
    for (int j = 0; j < 4096; j++)
        VRAM_F[j] = (u16)((j * 0x0299 + 0x321) & 0x7FFF);
    vramSetBankE(VRAM_E_BG_EXT_PALETTE);
    vramSetBankF(VRAM_F_SPRITE_EXT_PALETTE);

    MAIL[0] |= 2;

    // ---- BG0 4bpp tiles at char base 0: blank, ring, cross, solid ----
    for (int t = 0; t < 4; t++)
        for (int r = 0; r < 8; r++) {
            u32 row = 0;
            for (int c = 0; c < 8; c++) {
                int dx = 2*c - 7, dy = 2*r - 7, d2 = dx*dx + dy*dy;
                u32 px = 0;
                if (t == 1) px = (d2 > 20 && d2 < 60) ? 1u + ((u32)r >> 2) : 0u;
                if (t == 2) px = (c == r || c == 7 - r) ? 3u : 0u;
                if (t == 3) px = 4u + (((u32)c + (u32)r) & 3u);
                row |= px << (4 * c);
            }
            ((volatile u32 *)BG_CHAR)[t*8 + r] = row;
        }

    // ---- BG3 affine 8bpp tiles 1/2 at char base 1 (0x4000): rings ----
    for (int t = 1; t <= 2; t++)
        for (int r = 0; r < 8; r++) {
            u32 w0 = 0, w1 = 0;
            for (int c = 0; c < 8; c++) {
                int dx = 2*c - 7, dy = 2*r - 7, d2 = dx*dx + dy*dy;
                u32 px = (t == 1) ? (32u + (((u32)d2 >> 3) & 15u))
                                  : (64u + (((u32)(c ^ r)) & 7u));
                if (c < 4) w0 |= px << (8 * c);
                else       w1 |= px << (8 * (c - 4));
            }
            ((volatile u32 *)(0x06004000 + 64*t))[r*2]     = w0;
            ((volatile u32 *)(0x06004000 + 64*t))[r*2 + 1] = w1;
        }

    // ---- BG1 256c tiles 1/2 at char base 2 (0x8000): gradients ----
    for (int t = 1; t <= 2; t++)
        for (int r = 0; r < 8; r++) {
            u32 w0 = 0, w1 = 0;
            for (int c = 0; c < 8; c++) {
                u32 px = (t == 1) ? (1u + 16u*(u32)r + (u32)c)
                                  : (129u + 8u*(u32)c + (u32)r);
                if (c < 4) w0 |= px << (8 * c);
                else       w1 |= px << (8 * (c - 4));
            }
            ((volatile u32 *)(0x06008000 + 64*t))[r*2]     = w0;
            ((volatile u32 *)(0x06008000 + 64*t))[r*2 + 1] = w1;
        }

    // ---- maps ----
    // BG3 affine 16x16 byte map at 0x1800: tiles 1/2 checkered
    for (int i = 0; i < 128; i++) {
        int x = (2*i) & 15, y = i >> 3;
        u16 lo = (u16)(1 + ((x + y) & 1)), hi = (u16)(1 + ((x + 1 + y) & 1));
        ((volatile u16 *)0x06001800)[i] = (u16)(lo | (hi << 8));
    }
    // BG0 text map at screen base 4 (0x2000): tile (x*y+x+y)&3, subpal, flips
    for (int i = 0; i < 1024; i++) {
        int x = i & 31, y = i >> 5;
        u16 e = (u16)((x*y + x + y) & 3);
        if (x & 1) e |= 1 << 10;
        if (y & 2) e |= 1 << 11;
        e |= (u16)((x >> 3) & 3) << 12;
        ((volatile u16 *)0x06002000)[i] = e;
    }
    // BG1 map at screen base 5 (0x2800): tiles 0..2 with holes, ext pal 0..7
    for (int i = 0; i < 1024; i++) {
        int x = i & 31, y = i >> 5;
        u16 e = (u16)((x + 2*y) % 3);
        e |= (u16)(((x >> 2) + y) & 7) << 12;
        ((volatile u16 *)0x06002800)[i] = e;
    }

    MAIL[0] |= 4;

    // ---- OBJ tiles (1D, 32 B boundary) ----
    // tiles 2..5: 16x16 quadrants; tile 6: solid 8x8; tile 8+: 256c 16x16
    for (int q = 0; q < 4; q++) {
        u32 v = 0x11111111u * (u32)(q + 1);
        for (int r = 0; r < 8; r++)
            ((volatile u32 *)0x06400040)[q*8 + r] = v;
    }
    for (int r = 0; r < 8; r++)
        ((volatile u32 *)0x064000C0)[r] = 0x66666666u;
    for (int k = 0; k < 64; k++) {
        u32 w = 0;
        for (int b = 0; b < 4; b++)
            w |= (u32)(((4*k + b) * 5 + 9) & 0xFF) << (8 * b);
        ((volatile u32 *)0x06400100)[k] = w;
    }

    // ---- OAM: all hidden, then the 5 sprites ----
    for (int i = 0; i < 128; i++) {
        OAM16[i*4]     = 0x0200;
        OAM16[i*4 + 1] = 0;
        OAM16[i*4 + 2] = 0;
    }
    OAM16[0]  = 0x101E; OAM16[1]  = 0x4028; OAM16[2]  = 0x0002;  // quadrants, MOSAIC, (40,30)
    OAM16[4]  = 0x0450; OAM16[5]  = 0x0064; OAM16[6]  = 0x1006;  // semi-transp 8x8 (100,80)
    OAM16[8]  = 0x203C; OAM16[9]  = 0x40B4; OAM16[10] = 0x5008;  // 256c ext pal 5 (180,60)
    OAM16[12] = 0x0064; OAM16[13] = 0x40F8; OAM16[14] = 0x0402;  // edge clip (248,100)
    OAM16[16] = 0x0896; OAM16[17] = 0x40C8; OAM16[18] = 0x0002;  // OBJ window (200,150)

    MAIL[0] |= 8;

    // ---- BG control, affine, windows, blending, display ----
    REG_BG0CNT = BG_PRIORITY_0 | BG_TILE_BASE(0) | BG_MAP_BASE(4) | BG_MOSAIC_ON;
    REG_BG1CNT = BG_PRIORITY_1 | BG_TILE_BASE(2) | BG_MAP_BASE(5) | BG_COLOR_256;
    REG_BG3CNT = BG_PRIORITY_3 | BG_TILE_BASE(1) | BG_MAP_BASE(3) | BgSize_R_128x128;
    REG_BG0HOFS = 0;  REG_BG0VOFS = 0;
    REG_BG1HOFS = 0;  REG_BG1VOFS = 0;
    // 45deg rotation, ~1.4x zoom out, centered on the 128x128 map
    REG_BG3PA = 0x00B5;  REG_BG3PB = 0x00B5;
    REG_BG3PC = (u16)-0x00B5; REG_BG3PD = 0x00B5;
    REG_BG3X = -64 * 256; REG_BG3Y = 32 * 256;

    WIN0_X0 = 40;  WIN0_X1 = 200;
    WIN0_Y0 = 30;  WIN0_Y1 = 150;
    WIN_IN  = 0x0033;              // WIN0: BG0+BG1+OBJ, effects on
    WIN_OUT = 0x283A;              // OBJWIN: BG3+eff | OUT: BG1+BG3+OBJ+eff

    REG_MOSAIC   = 0x2202;         // BG h=2 v=0, OBJ h=v=2
    REG_BLDCNT   = 0x2A51;         // alpha: 1st BG0+OBJ, 2nd BG1+BG3+BD
    REG_BLDALPHA = 0x0709;         // EVA 9, EVB 7

    REG_DISPCNT = MODE_1_2D | DISPLAY_BG0_ACTIVE | DISPLAY_BG1_ACTIVE |
                  DISPLAY_BG3_ACTIVE | DISPLAY_SPR_ACTIVE |
                  DISPLAY_SPR_1D_LAYOUT | DISPLAY_WIN0_ON | DISPLAY_SPR_WIN_ON |
                  DISPLAY_BG_EXT_PALETTE | DISPLAY_SPR_EXT_PALETTE;

    MAIL[0] |= 16;
    MAIL[1] = 0xCAFEBABE;

    for (u32 n = 1;; n++) {
        wait_vblank();
        MAIL[2] = n;
    }
}
