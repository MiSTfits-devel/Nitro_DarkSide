// Standalone composed-scanline oracle: production melonDS scanout.
//
// Per case this harness installs the full true phase inputs (both engines'
// registers, OAM, palette, physical VRAM banks + maps, windows, colour
// effects, master brightness, screen enable/swap, display mode/FIFO), streams
// a real NSD2 v10 trace through the production phase emitter, then runs the
// production sprite phase and scanline composite. Framebuffer records emitted
// by that production scanout are the expected top/bottom lines.
//
// Outputs:
//   <out>         NSD2 v10 trace (phase inputs + expected framebuffer lines)
//   <out>.cases   text table: frame line kind description (labels only)
#define private public
#define protected public
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include "NDS.h"
#include "GPU_Soft.h"
#include "GPU2D_Soft.h"
#include "NDS4MiSTer_2DTrace.h"
#undef private

using namespace melonDS;

namespace
{
FILE* g_trace = nullptr;
FILE* g_cases = nullptr;

void traceSink(const void* data, size_t size, void*)
{
    if (size) fwrite(data, 1, size, g_trace);
}

u8 hashByte(u32 seed, u32 i)
{
    u32 h = seed * 2654435761u + i * 0x9E3779B1u;
    h ^= h >> 15;
    h *= 2246822519u;
    h ^= h >> 13;
    return u8(h >> 24);
}

struct EngCfg
{
    u32 dispcnt = 0, layerEnable = 0, objEnable = 0, forcedBlank = 0, enabled = 1;
    u16 bgcnt[4] = {}, bgx[4] = {}, bgy[4] = {};
    s32 refx[2] = {}, refy[2] = {};
    s16 rota[2] = {}, rotb[2] = {}, rotc[2] = {}, rotd[2] = {};
    u8 win0[4] = {}, win1[4] = {}, wincnt[4] = {};
    u8 win0active = 0, win1active = 0;
    u8 bgmosaic[2] = {}, objmosaic[2] = {};
    u16 blendcnt = 0, blendalpha = 0;
    u8 eva = 0, evb = 0, evy = 0;
    u32 bgmosaicline = 0, objmosaicline = 0;
};

struct Case
{
    std::string name;
    u32 frame = 0, kind = 0, seed = 0, line = 0;
    EngCfg eng[2];
    u32 screensEnabled = 1, screenSwap = 0;
    u16 masterA = 0, masterB = 0;
    u32 lcdc = 0, captureCnt = 0, fifoSeed = 0;
    u32 craftBG = 0;     // bit n: craft solid 4bpp text rows for engine n
    int spriteSet = -1;  // -1 none, 0 normal, 1 translucent, 2 OBJ window
};

u16 palWord(u32 seed, u32 i)
{
    return u16((hashByte(seed, 2 * i) | (hashByte(seed, 2 * i + 1) << 8)) & 0x7FFF);
}

void writeFlat(GPU& gpu, int engine, u32 addr, u8 value)
{
    if (engine == 0)
        gpu.VRAM[(addr >> 17) & 3][addr & 0x1FFFF] = value;
    else
        gpu.VRAM[2][addr & 0x1FFFF] = value;
}

void fillBanks(GPU& gpu, u32 seed)
{
    for (int bank = 0; bank < 4; bank++)
        for (u32 i = 0; i < 128 * 1024; i++)
            gpu.VRAM[bank][i] = hashByte(seed + u32(bank) * 0x1000u, i);
}

void fillPalette(GPU& gpu, u32 seed)
{
    for (u32 i = 0; i < 1024; i++)
    {
        u16 w = palWord(seed, i);
        gpu.Palette[2 * i] = u8(w);
        gpu.Palette[2 * i + 1] = u8(w >> 8);
    }
}

void setOAM(u8* base, int index, u16 a0, u16 a1, u16 a2, u16 a3)
{
    u8* p = base + index * 8;
    p[0] = u8(a0); p[1] = u8(a0 >> 8);
    p[2] = u8(a1); p[3] = u8(a1 >> 8);
    p[4] = u8(a2); p[5] = u8(a2 >> 8);
    p[6] = u8(a3); p[7] = u8(a3 >> 8);
}

void craftText(GPU& gpu, int engine, const EngCfg& e, int line, int n)
{
    u16 bgcnt = e.bgcnt[n];
    if (bgcnt & 0x80) return; // 4bpp text only
    u32 yoff = e.bgy[n] + u32(line);
    u32 dcMap = engine == 0 ? ((e.dispcnt & 0x38000000u) >> 11) : 0;
    u32 dcTile = engine == 0 ? ((e.dispcnt & 0x07000000u) >> 8) : 0;
    u32 tileset = dcTile + ((bgcnt & 0x003Cu) << 12);
    u32 mapRow = dcMap + ((bgcnt & 0x1F00u) << 3) + ((yoff & 0xF8u) << 3);
    for (u32 i = 0; i < 32; i++) writeFlat(gpu, engine, tileset + i, 0x11);
    for (u32 t = 0; t < 32; t++)
    {
        u16 entry = u16(u32(n) << 12);
        writeFlat(gpu, engine, mapRow + t * 2, u8(entry));
        writeFlat(gpu, engine, mapRow + t * 2 + 1, u8(entry >> 8));
    }
}

void craftSprites(GPU& gpu, int engine, const Case& c, int line)
{
    if (c.spriteSet < 0) return;
    u8* oam = gpu.OAM + (engine ? 0x400 : 0);
    memset(oam, 0, 0x400);
    for (u32 i = 0; i < 2048; i++) writeFlat(gpu, engine, i, 0x11);

    auto sprite = [&](int idx, int x, int ytop, int prio, int pal, int mode,
                      int sizeLog, int tile) {
        u16 a0 = u16(ytop & 0xFF) | u16(mode << 10);
        u16 a1 = u16(x & 0x1FF) | u16((sizeLog & 3) << 14);
        u16 a2 = u16(tile & 0x3FF) | u16((prio & 3) << 10) | u16((pal & 0xF) << 12);
        setOAM(oam, idx, a0, a1, a2, 0);
    };

    if (c.spriteSet == 0 || c.spriteSet == 1)
    {
        int mode = c.spriteSet == 1 ? 1 : 0;
        sprite(0, 40, line - 2, 0, 0, mode, 0, 0);
        sprite(1, 60, line - 3, 1, 1, mode, 0, 0);
        sprite(2, 80, line - 4, 2, 2, mode, 0, 0);
        sprite(3, 100, line - 5, 3, 3, mode, 0, 0);
    }
    else if (c.spriteSet == 2)
    {
        sprite(0, 48, line - 8, 0, 0, 2, 3, 0);
        sprite(1, 112, line - 8, 0, 0, 2, 3, 0);
    }
    else if (c.spriteSet == 3)
    {
        // Visible normal and translucent sprites plus an OBJ window, all on
        // the same line, so priority, alpha and OBJ-window composition are
        // exercised together.
        sprite(0, 32, line - 2, 0, 0, 0, 0, 0);
        sprite(1, 52, line - 3, 1, 1, 1, 0, 0);
        sprite(2, 72, line - 4, 2, 2, 0, 0, 0);
        sprite(3, 92, line - 5, 3, 3, 1, 0, 0);
        sprite(4, 40, line - 8, 0, 0, 2, 3, 0);
        sprite(5, 120, line - 8, 0, 0, 2, 3, 0);
    }
}

void configureVRAM(GPU& gpu)
{
    for (u32 slot = 0; slot < 32; slot++)
        gpu.VRAMMap_ABG[slot] = 1u << (slot / 8);
    for (u32 slot = 0; slot < 16; slot++)
        gpu.VRAMMap_AOBJ[slot] = 1u << (slot / 8);
    for (u32 slot = 0; slot < 8; slot++)
    {
        gpu.VRAMMap_BBG[slot] = 1u << 2;  // bank C
        gpu.VRAMMap_BOBJ[slot] = 1u << 2;
    }
    for (u32 i = 0; i < 4; i++)
    {
        gpu.VRAMMap_ABGExtPal[i] = 0;
        gpu.VRAMMap_BBGExtPal[i] = 0;
    }
    gpu.VRAMMap_AOBJExtPal = 0;
    gpu.VRAMMap_BOBJExtPal = 0;
}

void applyEngine(GPU2D& e, const EngCfg& c)
{
    e.Enabled = c.enabled != 0;
    e.DispCnt = c.dispcnt;
    e.DispCntLatch[0] = c.dispcnt;
    e.DispCntLatch[1] = c.dispcnt;
    e.DispCntLatch[2] = c.dispcnt;
    e.LayerEnable = u8(c.layerEnable);
    e.OBJEnable = u8(c.objEnable);
    e.ForcedBlank = c.forcedBlank != 0;
    memcpy(e.BGCnt, c.bgcnt, sizeof(e.BGCnt));
    memcpy(e.BGXPos, c.bgx, sizeof(e.BGXPos));
    memcpy(e.BGYPos, c.bgy, sizeof(e.BGYPos));
    memcpy(e.BGXRef, c.refx, sizeof(e.BGXRef));
    memcpy(e.BGYRef, c.refy, sizeof(e.BGYRef));
    memcpy(e.BGXRefInternal, c.refx, sizeof(e.BGXRefInternal));
    memcpy(e.BGYRefInternal, c.refy, sizeof(e.BGYRefInternal));
    memcpy(e.BGRotA, c.rota, sizeof(e.BGRotA));
    memcpy(e.BGRotB, c.rotb, sizeof(e.BGRotB));
    memcpy(e.BGRotC, c.rotc, sizeof(e.BGRotC));
    memcpy(e.BGRotD, c.rotd, sizeof(e.BGRotD));
    memcpy(e.Win0Coords, c.win0, sizeof(e.Win0Coords));
    memcpy(e.Win1Coords, c.win1, sizeof(e.Win1Coords));
    memcpy(e.WinCnt, c.wincnt, sizeof(e.WinCnt));
    e.Win0Active = c.win0active;
    e.Win1Active = c.win1active;
    memcpy(e.BGMosaicSize, c.bgmosaic, sizeof(e.BGMosaicSize));
    memcpy(e.OBJMosaicSize, c.objmosaic, sizeof(e.OBJMosaicSize));
    e.BlendCnt = c.blendcnt;
    e.BlendAlpha = c.blendalpha;
    e.EVA = c.eva; e.EVB = c.evb; e.EVY = c.evy;
    e.BGMosaicLine = c.bgmosaicline;
    e.OBJMosaicLine = c.objmosaicline;
}

u8 verticalActive(const u8* coords, u32 line)
{
    return (line >= coords[2] && line < coords[3]) ? 1 : 0;
}

void applyCase(GPU& gpu, SoftRenderer& parent, GPU2D& eA, GPU2D& eB,
               const Case& c)
{
    gpu.NDS.NumFrames = c.frame;
    gpu.VCount = u16(c.line);
    gpu.ScreensEnabled = c.screensEnabled != 0;
    gpu.ScreenSwap = c.screenSwap != 0;
    gpu.MasterBrightnessA = c.masterA;
    gpu.MasterBrightnessB = c.masterB;
    gpu.CaptureEnable = false;
    gpu.CaptureCnt = c.captureCnt;
    gpu.VRAMMap_LCDC = c.lcdc;
    gpu.DispFIFOReadPtr = u8(c.fifoSeed);
    gpu.DispFIFOWritePtr = u8(c.fifoSeed >> 8);
    for (u32 i = 0; i < 16; i++)
        gpu.DispFIFO[i] = u16(hashByte(c.seed, 0x100 + i) | (hashByte(c.seed, 0x200 + i) << 8));
    for (u32 i = 0; i < 256; i++)
        gpu.DispFIFOBuffer[i] = u16(hashByte(c.seed, 0x300 + 2 * i) |
                                    (hashByte(c.seed, 0x500 + 2 * i) << 8));

    fillBanks(gpu, c.seed);
    fillPalette(gpu, c.seed);
    memset(gpu.OAM, 0, sizeof(gpu.OAM));

    EngCfg e0 = c.eng[0];
    EngCfg e1 = c.eng[1];
    e0.win0active = verticalActive(e0.win0, c.line);
    e0.win1active = verticalActive(e0.win1, c.line);
    e1.win0active = verticalActive(e1.win0, c.line);
    e1.win1active = verticalActive(e1.win1, c.line);

    for (int n = 0; n < 2; n++)
    {
        EngCfg& cfg = n == 0 ? e0 : e1;
        if (c.craftBG & (1u << n))
            for (int bg = 0; bg < 4; bg++)
                if (cfg.layerEnable & (1u << bg))
                    craftText(gpu, n, cfg, int(c.line), bg);
        craftSprites(gpu, n, c, int(c.line));
    }

    for (int bank = 0; bank < 9; bank++)
        gpu.VRAMDirty[bank].SetRange(0, 256);
    gpu.PaletteDirty = 0xFF;
    gpu.OAMDirty = 0xFF;

    // Rebuild the flat views explicitly. Renderer coherency clears shared
    // bank dirty bits, so sprite and background consumers cannot each rely on
    // seeing the same dirty set.
    {
        NonStupidBitField<512 * 1024 / VRAMDirtyGranularity> dABG;
        dABG.SetRange(0, 512 * 1024 / VRAMDirtyGranularity);
        gpu.MakeVRAMFlat_ABGCoherent(dABG);
        NonStupidBitField<128 * 1024 / VRAMDirtyGranularity> dB;
        dB.SetRange(0, 128 * 1024 / VRAMDirtyGranularity);
        gpu.MakeVRAMFlat_BBGCoherent(dB);
        gpu.MakeVRAMFlat_BOBJCoherent(dB);
        NonStupidBitField<256 * 1024 / VRAMDirtyGranularity> dAOBJ;
        dAOBJ.SetRange(0, 256 * 1024 / VRAMDirtyGranularity);
        gpu.MakeVRAMFlat_AOBJCoherent(dAOBJ);
    }

    applyEngine(eA, e0);
    applyEngine(eB, e1);

    parent.Rend2D_A->Reset();
    parent.Rend2D_B->Reset();
}

// Text BG with a repeated map row and a solid tile.
EngCfg textBG(int bg, int prio, u16 x, u16 y)
{
    EngCfg e;
    e.bgcnt[bg] = u16(0x1000 | 0x0010 | (prio & 3));
    e.bgx[bg] = x;
    e.bgy[bg] = y;
    return e;
}

EngCfg fourTextBGs(u32 prioMask)
{
    EngCfg e;
    for (int bg = 0; bg < 4; bg++)
    {
        e.bgcnt[bg] = u16(0x1000 | 0x0010 | ((prioMask >> (2 * bg)) & 3));
        e.bgx[bg] = u16(13 * bg + 3);
        e.bgy[bg] = u16(7 * bg + 1);
    }
    return e;
}

std::vector<Case> buildCases()
{
    std::vector<Case> cases;
    u32 seed = 0x5EEDu;

    auto add = [&](Case c, const char* name, u32 kind) {
        c.name = name;
        c.kind = kind;
        c.seed = seed;
        seed += 0x9E37u;
        c.frame = u32(cases.size());
        cases.push_back(c);
    };

    // ---- directed: engine A composition basics ----
    {
        Case c;
        c.line = 40;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16);       // mode 0, regular display
        c.eng[0].layerEnable = 1u << 0;
        c.craftBG = 1;
        add(c, "A mode0 BG0 only", 1);
    }
    {
        Case c;
        c.line = 41;
        c.eng[0] = fourTextBGs(0xE4);             // BG0 prio0, BG1 1, BG2 2, BG3 3
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 0xF;
        c.craftBG = 1;
        add(c, "A four BGs priority 0123", 2);
    }
    {
        Case c;
        c.line = 42;
        c.eng[0] = fourTextBGs(0x1B);             // BG3 on top
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 0xF;
        c.craftBG = 1;
        add(c, "A four BGs priority 3210", 3);
    }
    {
        Case c;
        c.line = 43;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].bgcnt[1] = u16(0x1000 | 0x0010 | 1);
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 0x3;
        c.eng[0].blendcnt = 0x0001 | (1u << 6) | (1u << 9);  // alpha, BG0 -> BG1
        c.eng[0].eva = 8; c.eng[0].evb = 8;
        c.craftBG = 1;
        add(c, "A alpha blend BG0 over BG1", 4);
    }
    {
        Case c;
        c.line = 44;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 1;
        c.eng[0].blendcnt = 0x0001 | (2u << 6);   // brightness up BG0
        c.eng[0].evy = 8;
        c.craftBG = 1;
        add(c, "A brightness up BG0", 5);
    }
    {
        Case c;
        c.line = 45;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 1;
        c.eng[0].blendcnt = 0x0001 | (3u << 6);   // brightness down BG0
        c.eng[0].evy = 9;
        c.craftBG = 1;
        add(c, "A brightness down BG0", 6);
    }
    {
        Case c;
        c.line = 46;
        c.eng[0] = fourTextBGs(0xE4);
        c.eng[0].dispcnt = 1u | (1u << 16) | (1u << 13);
        c.eng[0].layerEnable = 0xF;
        c.eng[0].win0[0] = 40; c.eng[0].win0[1] = 80;
        c.eng[0].win0[2] = 30; c.eng[0].win0[3] = 60;
        c.eng[0].wincnt[0] = 0x21;   // inside: BG0 + effects
        c.eng[0].wincnt[2] = 0x02;   // outside: BG1
        c.craftBG = 1;
        add(c, "A WIN0 inside BG0 outside BG1", 7);
    }
    {
        Case c;
        c.line = 47;
        c.eng[0] = fourTextBGs(0xE4);
        c.eng[0].dispcnt = 1u | (1u << 16) | (1u << 14);
        c.eng[0].layerEnable = 0xF;
        c.eng[0].win1[0] = 120; c.eng[0].win1[1] = 160;
        c.eng[0].win1[2] = 0; c.eng[0].win1[3] = 192;
        c.eng[0].wincnt[1] = 0x24;   // inside: BG2 + effects
        c.eng[0].wincnt[2] = 0x0F;   // outside: all BG
        c.craftBG = 1;
        add(c, "A WIN1 inside BG2 outside all", 8);
    }
    {
        Case c;
        c.line = 48;
        c.eng[0] = fourTextBGs(0xE4);
        c.eng[0].dispcnt = 1u | (1u << 16) | (1u << 15);
        c.eng[0].layerEnable = 0xF;
        c.eng[0].wincnt[3] = 0x21;   // OBJ window: BG0 + effects
        c.eng[0].wincnt[2] = 0x0E;   // outside: BG1..3
        c.spriteSet = 2;
        c.craftBG = 1;
        add(c, "A OBJ window BG0 vs BG1..3", 9);
    }
    {
        Case c;
        c.line = 49;
        c.eng[0] = textBG(0, 1, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16) | (1u << 12);
        c.eng[0].layerEnable = 0x11;  // BG0 + OBJ
        c.eng[0].objEnable = 1;
        c.spriteSet = 0;
        c.craftBG = 1;
        add(c, "A sprites prio 0..3 vs BG0 prio1", 10);
    }
    {
        Case c;
        c.line = 50;
        c.eng[0] = textBG(0, 1, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16) | (1u << 12);
        c.eng[0].layerEnable = 0x11;
        c.eng[0].objEnable = 1;
        c.eng[0].blendcnt = 0x0010 | (1u << 6) | (1u << 8);  // OBJ alpha over BG0
        c.spriteSet = 1;
        c.craftBG = 1;
        add(c, "A translucent sprites over BG0", 11);
    }
    {
        Case c;
        c.line = 51;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 1;
        c.eng[0].forcedBlank = 1;
        c.craftBG = 1;
        add(c, "A forced blank", 12);
    }
    {
        Case c;
        c.line = 52;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 1;
        c.masterA = u16((1u << 14) | 8);   // master brightness up
        c.craftBG = 1;
        add(c, "A master brightness up", 13);
    }
    {
        Case c;
        c.line = 53;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 1;
        c.masterA = u16((2u << 14) | 7);   // master brightness down
        c.craftBG = 1;
        add(c, "A master brightness down", 14);
    }
    {
        Case c;
        c.line = 54;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 1;
        c.screenSwap = 1;
        c.craftBG = 1;
        add(c, "A screen swap", 15);
    }
    {
        Case c;
        c.line = 55;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 1;
        c.screensEnabled = 0;
        c.craftBG = 1;
        add(c, "A screens disabled", 16);
    }
    {
        Case c;
        c.line = 56;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u;             // display mode 0 (screen off)
        c.eng[0].layerEnable = 1;
        c.masterA = u16((1u << 14) | 8);
        c.craftBG = 1;
        add(c, "A display mode0 + brightness", 17);
    }
    {
        Case c;
        c.line = 57;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u | (2u << 16) | (1u << 18);  // mode 2, bank 1
        c.eng[0].layerEnable = 1;
        c.lcdc = 1u << 1;
        c.masterA = u16((2u << 14) | 5);
        c.craftBG = 1;
        add(c, "A display mode2 VRAM bank1 + brightness", 18);
    }
    {
        Case c;
        c.line = 58;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u | (3u << 16);  // FIFO display
        c.eng[0].layerEnable = 1;
        c.fifoSeed = 0x21;
        c.craftBG = 1;
        add(c, "A display mode3 FIFO", 19);
    }

    // ---- directed: engine B and dual-screen ----
    {
        Case c;
        c.line = 60;
        c.eng[0].enabled = 0;
        c.eng[1] = fourTextBGs(0xE4);
        c.eng[1].dispcnt = 1u | (1u << 16);
        c.eng[1].layerEnable = 0xF;
        c.craftBG = 2;
        add(c, "B only four BGs", 20);
    }
    {
        Case c;
        c.line = 61;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 1;
        c.eng[1] = textBG(0, 0, 0, 0);
        c.eng[1].dispcnt = 1u | (1u << 16);
        c.eng[1].layerEnable = 1;
        c.craftBG = 3;
        add(c, "A+B both regular", 21);
    }
    {
        Case c;
        c.line = 62;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 1;
        c.eng[1] = textBG(0, 0, 0, 0);
        c.eng[1].dispcnt = 1u | (1u << 16);
        c.eng[1].layerEnable = 1;
        c.screenSwap = 1;
        c.masterB = u16((1u << 14) | 10);
        c.craftBG = 3;
        add(c, "A+B swap + B brightness", 22);
    }
    {
        Case c;
        c.line = 63;
        c.eng[0].enabled = 0;
        c.eng[1] = fourTextBGs(0xE4);
        c.eng[1].dispcnt = 1u | (1u << 16) | (1u << 13);
        c.eng[1].layerEnable = 0xF;
        c.eng[1].win0[0] = 30; c.eng[1].win0[1] = 200;
        c.eng[1].win0[2] = 0; c.eng[1].win0[3] = 192;
        c.eng[1].wincnt[0] = 0x26;   // BG2 + effects
        c.eng[1].wincnt[2] = 0x03;
        c.craftBG = 2;
        add(c, "B only WIN0 BG2 vs BG1", 23);
    }
    {
        Case c;
        c.line = 64;
        c.eng[0].enabled = 0;
        c.eng[1] = textBG(0, 1, 0, 0);
        c.eng[1].dispcnt = 1u | (1u << 16) | (1u << 12);
        c.eng[1].layerEnable = 0x11;
        c.eng[1].objEnable = 1;
        c.eng[1].blendcnt = 0x0010 | (1u << 6) | (1u << 8);
        c.spriteSet = 1;
        c.craftBG = 2;
        add(c, "B translucent sprites over BG0", 24);
    }
    {
        Case c;
        c.line = 65;
        c.eng[0].enabled = 0;
        c.eng[1] = textBG(0, 0, 0, 0);
        c.eng[1].dispcnt = 1u | (1u << 16);
        c.eng[1].layerEnable = 1;
        c.eng[1].forcedBlank = 1;
        c.craftBG = 2;
        add(c, "B forced blank", 25);
    }
    {
        Case c;
        c.line = 66;
        c.eng[0].enabled = 0;
        c.eng[1] = textBG(0, 0, 0, 0);
        c.eng[1].dispcnt = 1u | (1u << 16);
        c.eng[1].layerEnable = 1;
        c.masterB = u16((2u << 14) | 9);
        c.craftBG = 2;
        add(c, "B master brightness down", 26);
    }
    {
        Case c;
        c.line = 67;
        c.eng[0] = fourTextBGs(0xE4);
        c.eng[0].dispcnt = 1u | (1u << 16) | (1u << 13);
        c.eng[0].layerEnable = 0xF;
        c.eng[0].win0[0] = 64; c.eng[0].win0[1] = 192;
        c.eng[0].win0[2] = 0; c.eng[0].win0[3] = 192;
        c.eng[0].wincnt[0] = 0x21;
        c.eng[0].wincnt[2] = 0x1E;
        c.eng[0].blendcnt = 0x0001 | (1u << 6) | (1u << 9);
        c.eng[0].eva = 12; c.eng[0].evb = 4;
        c.craftBG = 1;
        add(c, "A WIN0 + alpha over BG1", 27);
    }
    {
        Case c;
        c.line = 68;
        c.eng[0] = textBG(0, 0, 0, 0);
        c.eng[0].bgcnt[0] |= 0x40;            // BG0 mosaic enable
        c.eng[0].dispcnt = 1u | (1u << 16);
        c.eng[0].layerEnable = 1;
        c.eng[0].bgmosaic[0] = 3;
        c.eng[0].bgmosaicline = 68;
        c.craftBG = 1;
        add(c, "A BG0 X mosaic 3", 28);
    }
    {
        Case c;
        c.line = 69;
        c.eng[0] = textBG(0, 1, 0, 0);
        c.eng[0].dispcnt = 1u | (1u << 16) | (1u << 12);
        c.eng[0].layerEnable = 0x11;
        c.eng[0].objEnable = 1;
        c.eng[0].objmosaic[0] = 2;
        c.eng[0].objmosaicline = 69;
        c.spriteSet = 0;
        c.craftBG = 1;
        add(c, "A OBJ X mosaic 2", 29);
    }

    // ---- seeded coverage ----
    const u32 randomCases = 140;
    for (u32 i = 0; i < randomCases; i++)
    {
        u32 s = 0xA5A50000u + i * 0x10001u;
        auto hb = [&](u32 salt) { return hashByte(s + salt, i + 3); };
        Case c;
        c.seed = s;
        c.line = 5 + (hb(1) % 180);
        c.screensEnabled = (hb(2) % 16) != 0;
        c.screenSwap = hb(3) & 1;

        for (int n = 0; n < 2; n++)
        {
            EngCfg& e = c.eng[n];
            u32 r1 = hb(0x10 + n);
            u32 r2 = hb(0x20 + n);
            u32 r3 = hb(0x30 + n);
            u32 mode = r1 % 7;
            e.dispcnt = mode | (1u << 16);
            u32 layers = r2 & 0xF;
            if ((r3 & 3) == 0) layers = 0xF;
            e.objEnable = (r3 >> 2) & 1;
            e.layerEnable = layers | (e.objEnable ? 0x10u : 0u);
            e.dispcnt |= layers << 8;
            if (e.objEnable) e.dispcnt |= 1u << 12;
            e.forcedBlank = ((r3 >> 4) % 8) == 0;
            for (int bg = 0; bg < 4; bg++)
            {
                e.bgcnt[bg] = u16((hashByte(s + bg, i * 7 + 1) & 0xF03Cu) |
                                  (hashByte(s + bg, i * 7 + 2) & 3u));
                e.bgx[bg] = u16(hashByte(s + bg, i * 7 + 3));
                e.bgy[bg] = u16(hashByte(s + bg, i * 7 + 4));
            }
            e.refx[0] = s32(hashByte(s, i + 0x40) * 2654435761u);
            e.refy[0] = s32(hashByte(s, i + 0x41) * 2246822519u);
            e.refx[1] = s32(hashByte(s, i + 0x42) * 3266489917u);
            e.refy[1] = s32(hashByte(s, i + 0x43) * 668265263u);
            for (int r = 0; r < 2; r++)
            {
                e.rota[r] = s16(hashByte(s, i + 0x50 + r));
                e.rotb[r] = s16(hashByte(s, i + 0x52 + r));
                e.rotc[r] = s16(hashByte(s, i + 0x54 + r));
                e.rotd[r] = s16(hashByte(s, i + 0x56 + r));
            }
            u32 w = hb(0x60 + n);
            if (w & 3)
            {
                e.win0[0] = u8(hb(0x61));
                e.win0[1] = u8(hb(0x62));
                e.win0[2] = u8(hb(0x63));
                e.win0[3] = u8(hb(0x64));
                e.win1[0] = u8(hb(0x65));
                e.win1[1] = u8(hb(0x66));
                e.win1[2] = u8(hb(0x67));
                e.win1[3] = u8(hb(0x68));
                e.dispcnt |= (w & 3) << 13;
                if (e.objEnable) e.dispcnt |= 1u << 15;
                for (int k = 0; k < 4; k++)
                    e.wincnt[k] = u8(hb(0x70 + k));
            }
            e.blendcnt = u16(hb(0x80 + n) | (hb(0x82 + n) << 8));
            e.eva = u8(hb(0x84));
            e.evb = u8(hb(0x85));
            e.evy = u8(hb(0x86));
            e.bgmosaic[0] = u8(hb(0x87) & 3);
            e.objmosaic[0] = u8(hb(0x88) & 3);
            e.bgmosaicline = c.line;
            e.objmosaicline = c.line;
        }

        c.masterA = u16(hb(0x90) | (hb(0x91) << 8));
        c.masterB = u16(hb(0x92) | (hb(0x93) << 8));
        if ((hb(0x94) & 7) == 0)
            c.masterA = u16((1u << 14) | (hb(0x95) & 0x1F));
        if ((hb(0x96) & 7) == 0)
            c.masterB = u16((2u << 14) | (hb(0x97) & 0x1F));

        // Occasionally exercise VRAM display (engine A modes 2) and FIFO
        // display (mode 3); both are real display-mode inputs.
        u32 dm = hb(0x98);
        if (dm % 5 == 0)
        {
            c.eng[0].dispcnt = (c.eng[0].dispcnt & ~(3u << 16)) |
                               (u32(2 + (hb(0x99) & 1)) << 16);
            c.lcdc = 1u << ((c.eng[0].dispcnt >> 18) & 3);
            c.fifoSeed = hb(0x9A);
        }
        u32 sp = hb(0xA0);
        c.spriteSet = (sp % 8 < 5) ? int(sp % 3) : -1;
        c.craftBG = hb(0xA1) & 3;
        add(c, "random", 100 + i);
    }

    // ---- combined per-line matrix ---------------------------------------
    // One trace frame per feature configuration; each of its 192 scanlines
    // enables several BGs, OBJ, windows, blend/brightness and mosaic together
    // on both engines. The fixture seed is fixed per frame so only the
    // per-line map row/OAM changes are emitted as memory deltas.
    auto addFixed = [&](Case c, const char* name, u32 kind) {
        c.name = name;
        c.kind = kind;
        c.frame = u32(cases.size());
        cases.push_back(c);
    };

    auto combinedBase = [&](u32 frameSeed) {
        Case c;
        c.seed = frameSeed;
        c.spriteSet = 3;
        c.craftBG = 3;
        c.screensEnabled = 1;
        for (int n = 0; n < 2; n++)
        {
            EngCfg& e = c.eng[n];
            e.dispcnt = 1u | (1u << 16);
            e.layerEnable = 0x0F | 0x10;
            e.objEnable = 1;
            e.dispcnt |= (1u << 12);
            e.dispcnt |= 0x0F << 8;
            for (int bg = 0; bg < 4; bg++)
            {
                e.bgcnt[bg] = u16(0x1000 | 0x0010 | (bg & 3));
                e.bgx[bg] = u16(11 * bg + 3);
                e.bgy[bg] = u16(5 * bg + 1);
            }
        }
        return c;
    };

    // Six directed combined configurations, 192 lines each.
    for (int variant = 0; variant < 6; variant++)
    {
        u32 fs = 0x9000u + u32(variant) * 0x101u;
        for (int line = 0; line < 192; line++)
        {
            Case c = combinedBase(fs);
            c.line = u32(line);
            for (int n = 0; n < 2; n++)
            {
                EngCfg& e = c.eng[n];
                e.bgmosaic[0] = 0; e.objmosaic[0] = 0;
                e.bgmosaicline = u32(line); e.objmosaicline = u32(line);
                e.blendcnt = 0;
                e.eva = e.evb = e.evy = 0;
                switch (variant)
                {
                case 0: // priority matrix plus BG0->BG1 alpha
                    for (int bg = 0; bg < 4; bg++) e.bgcnt[bg] = u16(0x1000 | 0x0010 | (u32(bg) ^ u32(n)));
                    e.blendcnt = 0x0001 | (1u << 6) | (1u << 9);
                    e.eva = 8; e.evb = 8;
                    break;
                case 1: // WIN0/WIN1/OBJ window with masks
                    e.dispcnt |= (1u << 13) | (1u << 14) | (1u << 15);
                    e.win0[0] = 24; e.win0[1] = 120; e.win0[2] = 0; e.win0[3] = 192;
                    e.win1[0] = 100; e.win1[1] = 220; e.win1[2] = 0; e.win1[3] = 192;
                    e.wincnt[0] = 0x21; e.wincnt[1] = 0x12; e.wincnt[2] = 0x04; e.wincnt[3] = 0x0E;
                    e.blendcnt = 0x0002 | (1u << 6) | (1u << 10);
                    e.eva = 12; e.evb = 4;
                    break;
                case 2: // brightness targets and master brightness
                    e.blendcnt = 0x0001 | (u32((n + 2) & 3) << 6);
                    e.evy = u8(4 + n * 3);
                    c.masterA = u16((1u << 14) | 8);
                    c.masterB = u16((2u << 14) | 6);
                    c.screenSwap = 1;
                    break;
                case 3: // BG and OBJ mosaic
                    for (int bg = 0; bg < 4; bg++) e.bgcnt[bg] |= 0x0040;
                    e.bgmosaic[0] = u8(2 + n);
                    e.objmosaic[0] = u8(1 + n);
                    break;
                case 4: // combined: windows + alpha + brightness + mosaic
                    e.dispcnt |= (1u << 13) | (1u << 15);
                    e.win0[0] = 16 + n * 30; e.win0[1] = 200; e.win0[2] = 0; e.win0[3] = 192;
                    e.wincnt[0] = 0x31; e.wincnt[2] = 0x0A; e.wincnt[3] = 0x21;
                    for (int bg = 0; bg < 4; bg++) e.bgcnt[bg] |= 0x0040;
                    e.bgmosaic[0] = 2; e.objmosaic[0] = 3;
                    e.blendcnt = 0x0001 | (1u << 6) | (1u << 10);
                    e.eva = 6; e.evb = 10; e.evy = 9;
                    c.masterA = u16((2u << 14) | 5);
                    c.screenSwap = u32(line & 1);
                    break;
                default: // WIN1 + translucent OBJ over blended BGs
                    e.dispcnt |= (1u << 14);
                    e.win1[0] = 40; e.win1[1] = 210; e.win1[2] = 0; e.win1[3] = 192;
                    e.wincnt[1] = 0x22; e.wincnt[2] = 0x0F;
                    e.blendcnt = 0x0010 | (1u << 6) | (1u << 8);
                    e.eva = 9; e.evb = 7;
                    break;
                }
            }
            addFixed(c, "combined directed", 300 + u32(variant));
        }
    }

    // Seeded combined frames: every scanline gets its own feature mix.
    for (int f = 0; f < 3; f++)
    {
        u32 fs = 0xAA00u + u32(f) * 0x1001u;
        for (int line = 0; line < 192; line++)
        {
            Case c = combinedBase(fs);
            c.line = u32(line);
            auto hbf = [&](u32 salt) { return hashByte(fs + salt, u32(line) + 7); };
            for (int n = 0; n < 2; n++)
            {
                auto hb = [&](u32 salt) { return hashByte(fs + salt + u32(n) * 0x100u, u32(line) + 7); };
                EngCfg& e = c.eng[n];
                for (int bg = 0; bg < 4; bg++)
                {
                    e.bgcnt[bg] = u16(0x1000 | 0x0010 | (hb(u32(bg)) & 3)
                                      | (hb(0x10 + bg) & 1 ? 0x40 : 0));
                    e.bgx[bg] = u16(hb(0x20 + bg));
                    e.bgy[bg] = u16(hb(0x30 + bg));
                }
                e.dispcnt |= (1u << 13) | (1u << 14) | (1u << 15);
                e.win0[0] = u8(hb(0x40)); e.win0[1] = u8(hb(0x41));
                e.win0[2] = 0; e.win0[3] = 192;
                e.win1[0] = u8(hb(0x42)); e.win1[1] = u8(hb(0x43));
                e.win1[2] = 0; e.win1[3] = 192;
                for (int k = 0; k < 4; k++) e.wincnt[k] = u8(hb(0x50 + k));
                e.blendcnt = u16(hb(0x60) | (hb(0x61) << 8));
                e.eva = u8(hb(0x62) & 31);
                e.evb = u8(hb(0x63) & 31);
                e.evy = u8(hb(0x64) & 31);
                e.bgmosaic[0] = u8(hb(0x65) & 3);
                e.objmosaic[0] = u8(hb(0x66) & 3);
                e.bgmosaicline = u32(line);
                e.objmosaicline = u32(line);
            }
            c.masterA = u16((u32(hbf(0x70) & 3) << 14) | (hbf(0x71) & 0x1F));
            c.masterB = u16((u32(hbf(0x72) & 3) << 14) | (hbf(0x73) & 0x1F));
            c.screenSwap = u32(hbf(0x74) & 1);
            addFixed(c, "combined seeded", 400 + u32(f));
        }
    }

    // Invalid/unsupported video mode 7: the Haskell path must fail explicitly
    // (production still draws melonDS's mode7 text path as expected pixels).
    for (int line : {0, 57, 140})
    {
        Case c = combinedBase(0x7777u + u32(line));
        c.line = u32(line);
        c.eng[0].dispcnt = 7u | (1u << 16) | (0x03u << 8) | (1u << 12);
        c.eng[0].layerEnable = 0x03 | 0x10;
        c.eng[0].objEnable = 1;
        for (int bg = 0; bg < 4; bg++)
            c.eng[0].bgcnt[bg] = u16(0x1000 | 0x0010 | (u32(bg) & 3));
        c.spriteSet = 0;
        c.craftBG = 1;
        addFixed(c, "invalid video mode 7", 500);
    }

    return cases;
}
}

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        fprintf(stderr, "usage: gx2d_compose_oracle OUT.nsd2 [cases]\n");
        return 2;
    }
    std::string path = argv[1];
    g_trace = fopen(path.c_str(), "wb");
    if (!g_trace) { perror(path.c_str()); return 2; }
    std::string casesPath = path + ".cases";
    g_cases = fopen(casesPath.c_str(), "w");
    if (!g_cases) { perror(casesPath.c_str()); return 2; }

    NDSArgs args;
    args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args));
    nds->Reset();
    auto& gpu = nds->GPU;
    auto& parent = static_cast<SoftRenderer&>(nds->GetRenderer());
    parent.PackedOutput = false;
    parent.EngineAOnly = false;
    parent.EngineBOnly = false;
    parent.Parallel2D = false;
    configureVRAM(gpu);

    NDS4MiSTer::SetTrace2DExtensions(true);
    auto header = NDS4MiSTer::MakeTrace2DFileHeader();
    fwrite(&header, sizeof(header), 1, g_trace);
    NDS4MiSTer::SetTrace2DSink(traceSink, nullptr);

    std::vector<Case> cases = buildCases();
    for (const Case& c : cases)
    {
        applyCase(gpu, parent, gpu.GPU2D_A, gpu.GPU2D_B, c);
        NDS4MiSTer::EmitTrace2DSpritePhase(gpu, c.line);
        parent.DrawSprites(c.line);
        NDS4MiSTer::EmitTrace2DScanline(gpu, c.line);
        parent.DrawScanline(c.line);
        fprintf(g_cases, "%u %u %u %s\n", c.frame, c.line, c.kind, c.name.c_str());
    }

    NDS4MiSTer::SetTrace2DSink(nullptr, nullptr);
    fclose(g_trace);
    fclose(g_cases);
    printf("compose-oracle: %zu cases -> %s\n", cases.size(), path.c_str());
    return 0;
}
