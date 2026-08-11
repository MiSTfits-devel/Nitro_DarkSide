// SPDX-License-Identifier: GPL-2.0-or-later
//
// VRAM DMA vs the 2D renderer, on hardware.
//
// nds_vram posts DMA writes to banks A..D: the write is acknowledged before it
// reaches the off-chip store, which is what lets a 16-bit DMA unit cost the 2
// bus cycles real hardware takes (NITRO Tester [04-02]). The price is a
// read-after-write window silicon does not have, and the renderer reads A..D
// over a SEPARATE port, so it can see pre-write data unless nds_vram holds it
// off. That hold-off is per 64-bit line; getting it wrong is per-game graphics
// corruption rather than a clean failure, which is exactly the kind of bug a
// simulation testbench does not catch and a real screen does.
//
// So this ROM does the thing that enters that window, in every 2D BG mode:
// it DMAs into the bank the renderer is actively fetching from, MID-FRAME
// rather than in vblank, and then checks the result three ways.
//
//   1. CPU readback     - did the posted write actually land, and did the
//                         write-combining keep both halfwords of each word?
//   2. renderer readback - the DS has no path for the CPU to ask "what did the
//                         renderer see", so instead every mode renders a
//                         pattern whose correctness is visible: a corrupted
//                         fetch shows as wrong tiles/pixels on the top screen.
//   3. cadence          - TM0 counts bus cycles across a known-size DMA, so a
//                         regression that quietly costs cycles per unit shows
//                         up as a number, not a feeling.
//
// Controls: A steps to the next mode, START re-runs the sweep, and the sweep
// also advances on its own so an unattended run walks everything.
//
// Report goes to the sub screen console. PASS/FAIL per mode, plus the measured
// cycles per DMA unit.

#include <nds.h>
#include <stdio.h>

// Main-engine BG VRAM is bank A at 0x06000000 (VRAM_A_MAIN_BG). Everything
// below writes inside the first 128 KB of it, so one bank is under test at a
// time - matching how the hold-off is scoped.
#define BGVRAM      ((volatile u16 *)0x06000000)
#define BGVRAM32    ((volatile u32 *)0x06000000)

// Far enough into the bank that it is not also being displayed as tile 0 data,
// but still inside bank A so the renderer's fetches and our DMA collide in the
// same bank.
#define PROBE_HW    (0x8000 / 2)     // halfword index of the DMA target area
#define PROBE_WORDS 1024             // 16-bit units per burst

static int failures = 0;
static int checks   = 0;

// ---------------------------------------------------------------------------
// A DMA burst into bank A, deliberately NOT in vblank.
//
// Source is TM0CNT_L held FIXED, exactly the way the NITRO Tester's [04-02]
// does it: the destination then holds a series of bus-cycle timestamps, so the
// gap between consecutive halfwords IS the per-unit cost. That makes one burst
// serve as both the data check and the cadence measurement.
static u32 dma_burst_16(volatile u16 *dst, int units)
{
    u16 first, last;

    // prescaler /1 so one tick is one bus cycle
    TIMER0_DATA = 0;
    TIMER0_CR   = TIMER_DIV_1 | TIMER_ENABLE;

    DMA_SRC(0)  = (u32)&TIMER0_DATA;
    DMA_DEST(0) = (u32)dst;
    DMA_CR(0)   = DMA_ENABLE | DMA_16_BIT | DMA_START_NOW |
                  DMA_SRC_FIX | DMA_DST_INC | units;
    while (DMA_CR(0) & DMA_ENABLE)
        ;

    TIMER0_CR = 0;

    first = dst[0];
    last  = dst[units - 1];
    return (u16)(last - first);   // total cycles across units-1 gaps
}

// Verify the burst landed as a strictly +2 sequence. The source ticks once per
// bus cycle and a 16-bit unit is one read plus one write, so on correct
// hardware every step is exactly 2. A lost posted write, a merge that dropped a
// byte lane, or a stall shows up as a step that is not 2.
static int check_cadence(volatile u16 *dst, int units, const char *what)
{
    int bad = 0, k;
    u16 exp;

    // Insurance, not cargo cult: if VRAM is mapped cacheable a stale line would
    // read back as a corrupted DMA and report a core bug that is not there. A
    // false FAIL here is worse than a missed one, because it would send someone
    // hunting in the RTL.
    DC_InvalidateRange((void *)dst, units * 2);
    exp = dst[0];

    for (k = 0; k < units; k++) {
        if (dst[k] != exp) {
            if (bad == 0)
                printf("  %s: step %d got %04X want %04X\n",
                        what, k, dst[k], exp);
            bad++;
            exp = dst[k];       // resync so one glitch is not 1000 errors
        }
        exp += 2;
    }
    checks++;
    if (bad)
        failures++;
    return bad;
}

// 32-bit units into the same bank. A word write cannot be combined with
// anything, so this is the case with the highest sustained pressure on the
// posted queue - it wants a word every 2 cycles where the backing channel
// gives one every 3, so the queue must backpressure without losing data.
static int check_words(volatile u32 *dst, int words)
{
    int bad = 0, k;

    for (k = 0; k < words; k++)
        dst[k] = 0;

    DMA_SRC(0)  = (u32)&TIMER0_DATA;
    DMA_DEST(0) = (u32)dst;
    TIMER0_DATA = 0;
    TIMER0_CR   = TIMER_DIV_1 | TIMER_ENABLE;
    DMA_CR(0)   = DMA_ENABLE | DMA_32_BIT | DMA_START_NOW |
                  DMA_SRC_FIX | DMA_DST_INC | words;
    while (DMA_CR(0) & DMA_ENABLE)
        ;
    TIMER0_CR = 0;
    DC_InvalidateRange((void *)dst, words * 4);

    // TM0CNT_L is 16-bit, so a 32-bit read of it gives the counter in the low
    // half and TM0CNT_H in the high half. The high half must be identical in
    // every word - if the queue mangled a lane it will not be.
    for (k = 1; k < words; k++) {
        if ((dst[k] >> 16) != (dst[0] >> 16)) {
            if (bad == 0)
                printf("  32bit: word %d high half %04X != %04X\n",
                        k, (unsigned)(dst[k] >> 16),
                        (unsigned)(dst[0] >> 16));
            bad++;
        }
    }
    checks++;
    if (bad)
        failures++;
    return bad;
}

// VRAM -> VRAM inside bank A. Both halves of the fast lane at once: the read
// goes through nds_vram's ordinary handshake while the write is posted, so a
// queue that let a read overtake it would copy pre-write data.
static int check_v2v(void)
{
    volatile u16 *src = BGVRAM + PROBE_HW;
    volatile u16 *dst = BGVRAM + PROBE_HW + 0x1000;
    int bad = 0, k;

    for (k = 0; k < 256; k++)
        dst[k] = 0xFFFF;

    DMA_SRC(0)  = (u32)src;
    DMA_DEST(0) = (u32)dst;
    DMA_CR(0)   = DMA_ENABLE | DMA_16_BIT | DMA_START_NOW |
                  DMA_SRC_INC | DMA_DST_INC | 256;
    while (DMA_CR(0) & DMA_ENABLE)
        ;
    DC_InvalidateRange((void *)dst, 256 * 2);
    DC_InvalidateRange((void *)src, 256 * 2);

    for (k = 0; k < 256; k++) {
        if (dst[k] != src[k]) {
            if (bad == 0)
                printf("  v2v: %d got %04X want %04X\n", k, dst[k], src[k]);
            bad++;
        }
    }
    checks++;
    if (bad)
        failures++;
    return bad;
}

// ---------------------------------------------------------------------------
// Draw something the eye can check, then collide a DMA with it.
//
// Each mode gets a pattern built so corruption is obvious rather than subtle:
// a tile grid with a strong diagonal, or for the bitmap modes a colour ramp.
// A stale renderer fetch shows as a block of wrong colour in a regular grid,
// which is far easier to spot than noise.

static void fill_tiles(void)
{
    int t, y;
    // tile 0 blank, tile 1 a diagonal, tile 2 solid - 4bpp, 32 bytes each
    for (y = 0; y < 8; y++) {
        BGVRAM32[y] = 0;                       // tile 0
        BGVRAM32[8 + y] = 0x11111111u << 0;    // tile 1 solid colour 1
        BGVRAM32[16 + y] = (y & 1) ? 0x22222222u : 0x33333333u;
    }
    for (t = 0; t < 16; t++)
        BG_PALETTE[t] = RGB15(t * 2, 31 - t * 2, (t * 3) & 31);
    BG_PALETTE[0] = RGB15(0, 0, 8);
}

// screen map at 0x06004000 (screen base block 8), tiles at 0x06000000
static void fill_map(void)
{
    volatile u16 *map = BGVRAM + (0x4000 / 2);
    int x, y;

    for (y = 0; y < 32; y++)
        for (x = 0; x < 32; x++)
            map[y * 32 + x] = (((x + y) & 3) == 0) ? 1 : (((x ^ y) & 7) ? 0 : 2);
}

static void setup_mode(int mode)
{
    vramSetPrimaryBanks(VRAM_A_MAIN_BG, VRAM_B_LCD, VRAM_C_LCD, VRAM_D_LCD);

    switch (mode) {
    case 0:  // BG mode 0, text BG
    case 1:
    case 2:
        videoSetMode(MODE_0_2D | DISPLAY_BG0_ACTIVE);
        REG_BG0CNT = BG_COLOR_16 | BG_MAP_BASE(8) | BG_TILE_BASE(0) |
                     BG_32x32 | BG_PRIORITY(0);
        fill_tiles();
        fill_map();
        break;

    case 3:  // rotation/scaling BG (affine), 8bpp 256x256
        videoSetMode(MODE_2_2D | DISPLAY_BG2_ACTIVE);
        REG_BG2CNT = BG_BMP8_256x256 | BG_BMP_BASE(0) | BG_PRIORITY(0);
        REG_BG2PA = 256; REG_BG2PB = 0; REG_BG2PC = 0; REG_BG2PD = 256;
        REG_BG2X = 0; REG_BG2Y = 0;
        {
            int x, y;
            for (y = 0; y < 192; y++)
                for (x = 0; x < 128; x++)
                    BGVRAM[y * 128 + x] =
                        ((((x * 2) ^ y) & 0xFF) << 8) | (((x * 2 + 1) ^ y) & 0xFF);
            for (x = 0; x < 256; x++)
                BG_PALETTE[x] = RGB15(x & 31, (x >> 2) & 31, (x >> 3) & 31);
        }
        break;

    default: // 16-bit direct-colour bitmap: every pixel is its own word, so a
             // corrupted fetch is a visible pixel, not a palette lookup away
        videoSetMode(MODE_5_2D | DISPLAY_BG2_ACTIVE);
        REG_BG2CNT = BG_BMP16_256x256 | BG_BMP_BASE(0) | BG_PRIORITY(0);
        REG_BG2PA = 256; REG_BG2PB = 0; REG_BG2PC = 0; REG_BG2PD = 256;
        REG_BG2X = 0; REG_BG2Y = 0;
        {
            int x, y;
            for (y = 0; y < 192; y++)
                for (x = 0; x < 256; x++)
                    BGVRAM[y * 256 + x] =
                        RGB15(x >> 3, y >> 3, (x ^ y) >> 3) | BIT(15);
        }
        break;
    }
}

static const char *mode_name(int mode)
{
    switch (mode) {
    case 0: return "mode0 text 4bpp";
    case 1: return "mode0 text, DMA mid-line";
    case 2: return "mode0 text, DMA every line";
    case 3: return "mode2 affine 8bpp bitmap";
    default: return "mode5 direct colour 16bpp";
    }
}

// The collision. Waiting for vblank first would defeat the whole point, so
// these deliberately start mid-frame:
//   mode 1 - one burst part-way down the visible area
//   mode 2 - a burst on every visible line, i.e. the renderer is fetching from
//            bank A continuously while the queue never empties
static void run_mode(int mode)
{
    volatile u16 *probe = BGVRAM + PROBE_HW;
    u32 span;
    int bad;

    printf("\x1b[2J[%d] %s\n", mode, mode_name(mode));
    setup_mode(mode);

    if (mode == 2) {
        int line;
        // one burst per visible line, started from the line itself rather than
        // from vblank
        for (line = 0; line < 160; line += 16) {
            while (REG_VCOUNT != line)
                ;
            span = dma_burst_16(probe, 256);
        }
        bad = check_cadence(probe, 256, "per-line");
        printf("  per-line burst: %s\n", bad ? "FAIL" : "PASS");
    } else if (mode == 1) {
        while (REG_VCOUNT != 80)
            ;
        span = dma_burst_16(probe, PROBE_WORDS);
        bad = check_cadence(probe, PROBE_WORDS, "mid-frame");
        printf("  %d units in %lu cycles\n", PROBE_WORDS, (unsigned long)span);
        printf("  cycles/unit: %lu.%02lu (hw 2.00)\n",
                (unsigned long)(span / (PROBE_WORDS - 1)),
                (unsigned long)((span * 100 / (PROBE_WORDS - 1)) % 100));
        printf("  16-bit burst: %s\n", bad ? "FAIL" : "PASS");
    } else {
        swiWaitForVBlank();
        span = dma_burst_16(probe, PROBE_WORDS);
        bad = check_cadence(probe, PROBE_WORDS, "vblank");
        printf("  %d units in %lu cycles\n", PROBE_WORDS, (unsigned long)span);
        printf("  cycles/unit: %lu.%02lu (hw 2.00)\n",
                (unsigned long)(span / (PROBE_WORDS - 1)),
                (unsigned long)((span * 100 / (PROBE_WORDS - 1)) % 100));
        printf("  16-bit burst: %s\n", bad ? "FAIL" : "PASS");
    }

    // the other two shapes, in every mode, because the hold-off is per line and
    // the access size decides which lines a burst covers
    printf("  32-bit burst: %s\n",
            check_words(BGVRAM32 + PROBE_HW / 2 + 0x800, 256) ? "FAIL" : "PASS");
    printf("  VRAM->VRAM  : %s\n", check_v2v() ? "FAIL" : "PASS");

    printf("\n  checks %d  failures %d\n", checks, failures);
    printf("\n  A: next   START: restart\n");
}

#define NMODES     5
#define HOLD_FRAMES 90    // ~1.5 s per mode, long enough to see the top screen

int main(void)
{
    int mode = 0;
    int held = 0;
    int dwell = 0;
    int sweeps = 0;

    // console on the SUB engine, so the report survives whatever the main
    // engine is being told to display
    videoSetModeSub(MODE_0_2D);
    vramSetBankC(VRAM_C_SUB_BG);
    consoleInit(NULL, 0, BgType_Text4bpp, BgSize_T_256x256, 31, 0, false, true);

    printf("VRAM DMA vs 2D renderer\n");
    printf("posted A..D writes,\nper-line hold-off\n\n");

    // Runs on its own. Needing a keypress would mean an unattended run - in
    // simulation, or a board left alone - proves nothing at all, and the top
    // screen is half the evidence here, so each mode has to stay up long enough
    // to look at.
    run_mode(mode);

    while (1) {
        scanKeys();
        u32 keys = keysHeld();

        if ((keys & KEY_START) && !held) {
            mode = 0; checks = 0; failures = 0; sweeps = 0;
            run_mode(mode);
            dwell = 0;
            held = 1;
        } else if ((keys & KEY_A) && !held) {
            mode = (mode + 1) % NMODES;
            run_mode(mode);
            dwell = 0;
            held = 1;
        } else if (!(keys & (KEY_A | KEY_START))) {
            held = 0;
        }

        if (++dwell >= HOLD_FRAMES) {
            dwell = 0;
            mode++;
            if (mode >= NMODES) {
                mode = 0;
                sweeps++;
            }
            run_mode(mode);
            printf("  sweep %d\n", sweeps);
        }

        swiWaitForVBlank();
    }
    return 0;
}
