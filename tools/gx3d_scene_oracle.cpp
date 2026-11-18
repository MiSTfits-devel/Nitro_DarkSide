// Directed/seeded full-frame 3D+2D scene oracle.
//
// For each case this harness generates a real GX geometry stream and real 2D
// engine state, drives production GPU3D + SoftRenderer2D, and streams a v12
// NSD2 trace. Recorded type3 3D lines and type8 screen lines are expected-only;
// the Haskell bridge consumes only the raw inputs (type26 writes, power,
// VBlank/render-start, memory and maps).
#define private public
#define protected public
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>
#include "NDS.h"
#include "GPU_Soft.h"
#include "GPU2D_Soft.h"
#include "GPU3D_Soft.h"
#include "NDS4MiSTer_2DTrace.h"
#undef protected
#undef private

using namespace melonDS;

namespace
{
FILE* g_trace = nullptr;
FILE* g_cases = nullptr;

void traceSink(const void* d, size_t n, void*)
{
    if (n) fwrite(d, 1, n, g_trace);
}

u8 hashByte(u32 seed, u32 i)
{
    u32 h = seed * 2654435761u + i * 0x9E3779B1u;
    h ^= h >> 15;
    h *= 2246822519u;
    h ^= h >> 13;
    return u8(h >> 24);
}

const u8 NumParams[256] =
{
    0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 0, 1, 1, 1, 0, 16, 12, 16, 12, 9, 3, 3,
    0, 0, 0,
    1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0,
    1, 1, 1, 1, 32,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    3, 2, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

struct EngCfg
{
    u32 dispcnt = 0, layerEnable = 0, objEnable = 0, forcedBlank = 0, enabled = 1;
    u16 bgcnt[4] = {}, bgx[4] = {}, bgy[4] = {};
    u8 win0[4] = {}, win1[4] = {}, wincnt[4] = {};
    u8 win0active = 0, win1active = 0;
    u8 bgmosaic[2] = {}, objmosaic[2] = {};
    u16 blendcnt = 0;
    u8 eva = 0, evb = 0, evy = 0;
};

struct Case
{
    std::string name;
    u32 kind = 0, seed = 0, line = 0;
    EngCfg eng[2];
    u32 screensEnabled = 1, screenSwap = 0;
    u16 masterA = 0, masterB = 0;
    u32 craftBG = 0;
    int spriteSet = -1;
    // 3D scene
    u32 vcount = 0;         // display frame index base
    u32 color0 = 0x001Fu, color1 = 0x03E0u, color2 = 0x7C00u;
    int polyAlpha = 31;
    s32 zView = -0x3000;
    s32 vscale = 0x800;
    int prim = 0;           // 0 triangles, 1 quads
    bool translucent = false;
};

void writeFlat(GPU& gpu, int engine, u32 addr, u8 value)
{
    if (engine == 0) gpu.VRAM[(addr >> 17) & 3][addr & 0x1FFFF] = value;
    else gpu.VRAM[2][addr & 0x1FFFF] = value;
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
        u16 w = u16((hashByte(seed, 2 * i) | (hashByte(seed, 2 * i + 1) << 8)) & 0x7FFF);
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
    if (bgcnt & 0x80) return;
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
}

void configureVRAM(GPU& gpu)
{
    for (u32 slot = 0; slot < 32; slot++) gpu.VRAMMap_ABG[slot] = 1u << (slot / 8);
    for (u32 slot = 0; slot < 16; slot++) gpu.VRAMMap_AOBJ[slot] = 1u << (slot / 8);
    for (u32 slot = 0; slot < 8; slot++)
    {
        gpu.VRAMMap_BBG[slot] = 1u << 2;
        gpu.VRAMMap_BOBJ[slot] = 1u << 2;
    }
    for (u32 i = 0; i < 4; i++)
    {
        gpu.VRAMMap_ABGExtPal[i] = 0;
        gpu.VRAMMap_BBGExtPal[i] = 0;
    }
    gpu.VRAMMap_AOBJExtPal = 0;
    gpu.VRAMMap_BOBJExtPal = 0;
    for (u32 i = 0; i < 4; i++) gpu.VRAMMap_Texture[i] = 0;
    for (u32 i = 0; i < 8; i++) gpu.VRAMMap_TexPal[i] = 0;
}

void applyEngine(GPU2D& e, const EngCfg& c)
{
    e.Enabled = c.enabled != 0;
    e.DispCnt = c.dispcnt;
    e.DispCntLatch[0] = e.DispCntLatch[1] = e.DispCntLatch[2] = c.dispcnt;
    e.LayerEnable = u8(c.layerEnable);
    e.OBJEnable = u8(c.objEnable);
    e.ForcedBlank = c.forcedBlank != 0;
    memcpy(e.BGCnt, c.bgcnt, sizeof(e.BGCnt));
    memcpy(e.BGXPos, c.bgx, sizeof(e.BGXPos));
    memcpy(e.BGYPos, c.bgy, sizeof(e.BGYPos));
    memcpy(e.Win0Coords, c.win0, sizeof(e.Win0Coords));
    memcpy(e.Win1Coords, c.win1, sizeof(e.Win1Coords));
    memcpy(e.WinCnt, c.wincnt, sizeof(e.WinCnt));
    e.Win0Active = c.win0active;
    e.Win1Active = c.win1active;
    memcpy(e.BGMosaicSize, c.bgmosaic, sizeof(e.BGMosaicSize));
    memcpy(e.OBJMosaicSize, c.objmosaic, sizeof(e.OBJMosaicSize));
    e.BlendCnt = c.blendcnt;
    e.EVA = c.eva; e.EVB = c.evb; e.EVY = c.evy;
    e.BGMosaicLine = 0; e.OBJMosaicLine = 0;
}

u8 verticalActive(const u8* coords, u32 line)
{
    return (line >= coords[2] && line < coords[3]) ? 1 : 0;
}

// ---- GX scene generation -------------------------------------------------

std::array<s32, 16> perspectiveM(s32 a, s32 b, s32 c, s32 d)
{
    return {a, 0, 0, 0, 0, b, 0, 0, 0, 0, c, -0x1000, 0, 0, d, 0};
}

std::array<s32, 16> identityM()
{
    return {0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000};
}

void runGeom(GPU3D& g)
{
    g.Run();
}

// Game-style GXFIFO writes: one command byte word (its payload is not a
// parameter) followed by the command's parameter words.
void gxFifo(NDS& nds, GPU3D& g, u32 word)
{
    nds.ARM9Timestamp += 0x200;
    g.Write32(0x04000400u, word);
    runGeom(g);
}

void gxCmd(NDS& nds, GPU3D& g, u8 op, std::initializer_list<u32> params)
{
    u32 n = NumParams[op];
    gxFifo(nds, g, op);
    std::vector<u32> p(params);
    p.resize(n, 0);
    for (u32 v : p) gxFifo(nds, g, v);
}

void gxMatrix(NDS& nds, GPU3D& g, u8 op, const std::array<s32, 16>& m, u32 count)
{
    gxFifo(nds, g, op);
    for (u32 i = 0; i < count; i++) gxFifo(nds, g, u32(m[i]));
}

void build3D(NDS& nds, GPU3D& g, const Case& c)
{
    nds.ARM9Timestamp += 0x400;
    g.Write32(0x04000060, 0); // DISP3DCNT: shading off
    g.Write32(0x04000350, 0); // clear color
    g.Write32(0x04000354, 0x7FFF); // clear depth: far
    runGeom(g);
    gxCmd(nds, g, 0x60, {0xBFFF0000u});                       // viewport 0,0..255,191
    gxCmd(nds, g, 0x10, {0});                                 // projection
    gxMatrix(nds, g, 0x16, identityM(), 16);
    gxCmd(nds, g, 0x10, {1});                                 // view
    gxCmd(nds, g, 0x15, {});
    gxCmd(nds, g, 0x10, {2});                                 // model
    gxCmd(nds, g, 0x15, {});

    u32 attr = 0xC0u | (c.translucent ? (2u << 4) : 0u) | (u32(c.polyAlpha & 0x1F) << 16);
    gxCmd(nds, g, 0x29, {attr});                              // polygon attr
    gxCmd(nds, g, 0x40, {u32(c.prim)});                       // begin vtxs
    auto vtx = [&](s32 x, s32 y, s32 z, u32 color) {
        gxCmd(nds, g, 0x20, {color});
        gxCmd(nds, g, 0x23, {(u32(x) & 0xFFFF) | ((u32(y) & 0xFFFF) << 16),
                             u32(z) & 0xFFFF});
    };
    s32 v = c.vscale;
    if (c.prim == 1)
    {
        vtx(-v, -v, 0, c.color0);
        vtx( v, -v, 0, c.color1);
        vtx( v,  v, 0, c.color2);
        vtx(-v,  v, 0, c.color0 ^ c.color1);
    }
    else
    {
        vtx(-v, -v, 0, c.color0);
        vtx( v, -v, 0, c.color1);
        vtx( 0,  v, 0, c.color2);
    }
    gxCmd(nds, g, 0x41, {});                                  // end vtxs
    gxCmd(nds, g, 0x50, {0});                                 // swap buffers
    nds.ARM9Timestamp += 0x10000;
    runGeom(g);
    runGeom(g);
}

// ---- cases ---------------------------------------------------------------

EngCfg textBG(int bg, int prio, u16 x, u16 y)
{
    EngCfg e;
    e.bgcnt[bg] = u16(0x1000 | 0x0010 | (prio & 3));
    e.bgx[bg] = x;
    e.bgy[bg] = y;
    return e;
}

std::vector<Case> buildCases()
{
    std::vector<Case> cases;
    u32 seed = 0x600D5EEDu;
    u32 frame = 0;
    auto add = [&](Case c, const char* name, u32 kind) {
        c.name = name; c.kind = kind; c.seed = seed; seed += 0x9E37u;
        c.vcount = frame; frame += 2;
        cases.push_back(c);
    };

    auto base3d = [](u16 bg1Prio, bool win) {
        Case c;
        c.eng[0].dispcnt = 1u | (1u << 16) | (1u << 3);
        c.eng[0].layerEnable = 0x01;      // 3D on BG0
        c.eng[0].bgcnt[0] = 0x0000;       // priority 0
        c.eng[0].objEnable = 0;
        if (bg1Prio < 4)
        {
            c.eng[0].layerEnable |= 1u << 1;
            c.eng[0].bgcnt[1] = u16(0x1000 | 0x0010 | bg1Prio);
            c.eng[0].bgx[1] = 5; c.eng[0].bgy[1] = 3;
            c.craftBG |= 1u << 0;
        }
        if (win)
        {
            c.eng[0].dispcnt |= (1u << 13);
            c.eng[0].win0[0] = 40; c.eng[0].win0[1] = 200;
            c.eng[0].win0[2] = 0; c.eng[0].win0[3] = 192;
            c.eng[0].wincnt[0] = 0x03;  // BG0+3D + BG1
            c.eng[0].wincnt[2] = 0x02;  // outside: BG1 only
        }
        return c;
    };

    { Case c = base3d(1, false); c.line = 0; add(c, "3D over BG1 (3D prio0, BG1 prio1)", 1); }
    { Case c = base3d(0, false); c.line = 1; c.kind = 2;
      c.eng[0].bgcnt[0] = 0x0003; add(c, "BG1 (prio0) over 3D (prio3)", 2); }
    {
        Case c = base3d(1, false); c.line = 2;
        c.eng[0].layerEnable |= 0x10; c.eng[0].objEnable = 1;
        c.eng[0].dispcnt |= 1u << 12;
        c.spriteSet = 0; c.kind = 3;
        add(c, "OBJ priorities over 3D+BG1", 3);
    }
    {
        Case c = base3d(1, false); c.line = 3;
        c.eng[0].layerEnable |= 0x10; c.eng[0].objEnable = 1;
        c.eng[0].dispcnt |= 1u << 12;
        c.spriteSet = 1; c.kind = 4;
        c.eng[0].blendcnt = 0x0010 | (1u << 6) | (1u << 9); // OBJ -> BG1
        c.eng[0].eva = 8; c.eng[0].evb = 8;
        add(c, "translucent OBJ over 3D", 4);
    }
    {
        Case c = base3d(1, true); c.line = 4; c.kind = 5;
        add(c, "WIN0 excludes 3D in region", 5);
    }
    {
        Case c = base3d(1, false); c.line = 5; c.kind = 6;
        c.eng[0].layerEnable |= 0x10; c.eng[0].objEnable = 1;
        c.eng[0].dispcnt |= (1u << 15);
        c.eng[0].wincnt[3] = 0x02;    // OBJ window: BG1
        c.eng[0].wincnt[2] = 0x01;    // outside: 3D
        c.spriteSet = 2;
        add(c, "OBJ window over 3D", 6);
    }
    {
        Case c = base3d(1, false); c.line = 6; c.kind = 7;
        c.translucent = true; c.polyAlpha = 16;
        c.eng[0].blendcnt = 0x0001 | (1u << 9); // 3D first, BG1 second
        c.eng[0].eva = 8; c.eng[0].evb = 8;
        add(c, "translucent 3D blended with BG1", 7);
    }
    {
        Case c = base3d(1, false); c.line = 7; c.kind = 8;
        c.eng[0].blendcnt = 0x0001 | (2u << 6);
        c.eng[0].evy = 8;
        add(c, "master/BG brightness with 3D", 8);
    }
    {
        Case c = base3d(1, false); c.line = 8; c.kind = 9;
        c.eng[1] = textBG(0, 0, 0, 0);
        c.eng[1].dispcnt = 1u | (1u << 16);
        c.eng[1].layerEnable = 1;
        c.craftBG |= 1u << 1;
        c.screenSwap = 1;
        add(c, "dual screen: A 3D+BG1, B 2D, swap", 9);
    }
    {
        Case c = base3d(1, false); c.line = 9; c.kind = 10;
        c.prim = 1; c.color0 = 0x001F; c.color1 = 0x03E0; c.color2 = 0x7C00;
        add(c, "3D quad scene", 10);
    }
    {
        Case c = base3d(1, false); c.line = 10; c.kind = 11;
        c.vscale = 0x400; c.zView = -0x2000;
        add(c, "3D small near quad", 11);
    }

    const u32 seeded = 24;
    for (u32 i = 0; i < seeded; i++)
    {
        u32 s = 0xC0FFEE00u + i * 0x10001u;
        auto hb = [&](u32 salt) { return hashByte(s + salt, i + 5); };
        Case c = base3d(u32(hb(1) & 3), (hb(2) & 1) != 0);
        c.seed = s;
        c.line = 8 + (hb(3) % 176);
        c.kind = 100 + i;
        c.prim = hb(4) & 1;
        c.vscale = s32(0x400 + (hb(5) % 0x400));
        c.zView = -s32(0x2000 + (hb(6) % 0x2000));
        c.color0 = (hb(7) & 0x7FFF);
        c.color1 = (hb(8) & 0x7FFF);
        c.color2 = (hb(9) & 0x7FFF);
        c.translucent = (hb(10) & 3) == 0;
        c.polyAlpha = int(hb(11) % 32);
        c.eng[0].blendcnt = u16(hb(12) | (hb(13) << 8));
        c.eng[0].eva = u8(hb(14) & 31);
        c.eng[0].evb = u8(hb(15) & 31);
        c.eng[0].evy = u8(hb(16) & 31);
        if (hb(17) & 1)
        {
            c.eng[0].layerEnable |= 0x10; c.eng[0].objEnable = 1;
            c.eng[0].dispcnt |= 1u << 12;
            c.spriteSet = int(hb(18) % 3) - 1;
        }
        if (hb(19) & 1)
        {
            c.eng[0].win0[0] = u8(hb(20)); c.eng[0].win0[1] = u8(hb(21));
            c.eng[0].win0[2] = u8(hb(22)); c.eng[0].win0[3] = u8(hb(23));
            c.eng[0].dispcnt |= (u32(hb(24) & 1) << 13) | (u32(hb(25) & 1) << 15);
            for (int k = 0; k < 4; k++) c.eng[0].wincnt[k] = u8(hb(26 + k));
        }
        if (hb(30) & 1)
        {
            c.eng[0].dispcnt |= (u32(hb(31) & 1) << 14);
            c.eng[0].win1[0] = u8(hb(32)); c.eng[0].win1[1] = u8(hb(33));
            c.eng[0].win1[2] = u8(hb(34)); c.eng[0].win1[3] = u8(hb(35));
        }
        c.masterA = u16((hb(36) & 1 ? (1u << 14) : (2u << 14)) | (hb(37) & 0x1F));
        c.screenSwap = hb(38) & 1;
        add(c, "seeded scene", 200 + i);
    }
    return cases;
}
}

int main(int argc, char** argv)
{
    if (argc < 2) { fprintf(stderr, "usage: gx3d_scene_oracle OUT.nsd2\n"); return 2; }
    std::string path = argv[1];
    g_trace = fopen(path.c_str(), "wb");
    if (!g_trace) { perror(path.c_str()); return 2; }
    std::string casesPath = path + ".cases";
    g_cases = fopen(casesPath.c_str(), "w");
    if (!g_cases) { perror(casesPath.c_str()); return 2; }

    NDSArgs args; args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args));
    nds->Reset();
    auto& gpu = nds->GPU;
    auto& parent = static_cast<SoftRenderer&>(nds->GetRenderer());
    parent.PackedOutput = false;
    parent.EngineAOnly = false;
    parent.EngineBOnly = false;
    parent.Parallel2D = false;
    configureVRAM(gpu);

    NDS4MiSTer::SetTrace2DRaw3DInputs(true);
    auto header = NDS4MiSTer::MakeTrace2DFileHeader();
    fwrite(&header, sizeof(header), 1, g_trace);
    NDS4MiSTer::SetTrace2DSink(traceSink, nullptr);
    nds->ARM9Timestamp = 0x1000;
    gpu.GPU3D.SetEnabled(true, true);
    NDS4MiSTer::EmitTrace3DInitialState(gpu);

    auto cases = buildCases();
    for (const Case& c : cases)
    {
        nds->NumFrames = c.vcount;
        gpu.VCount = 0;
        nds->ARM9Timestamp += 0x1000;
        fillBanks(gpu, c.seed);
        fillPalette(gpu, c.seed);
        memset(gpu.OAM, 0, sizeof(gpu.OAM));
        EngCfg e0 = c.eng[0], e1 = c.eng[1];
        e0.win0active = verticalActive(e0.win0, c.line);
        e0.win1active = verticalActive(e0.win1, c.line);
        e1.win0active = verticalActive(e1.win0, c.line);
        e1.win1active = verticalActive(e1.win1, c.line);
        for (int n = 0; n < 2; n++)
        {
            EngCfg& cfg = n == 0 ? e0 : e1;
            if (c.craftBG & (1u << n))
                for (int bg = 1; bg < 4; bg++)
                    if (cfg.layerEnable & (1u << bg)) craftText(gpu, n, cfg, int(c.line), bg);
            craftSprites(gpu, n, c, int(c.line));
        }
        applyEngine(gpu.GPU2D_A, e0);
        applyEngine(gpu.GPU2D_B, e1);
        parent.Rend2D_A->Reset();
        parent.Rend2D_B->Reset();
        gpu.ScreensEnabled = c.screensEnabled != 0;
        gpu.ScreenSwap = c.screenSwap != 0;
        gpu.MasterBrightnessA = c.masterA;
        gpu.MasterBrightnessB = c.masterB;
        gpu.VRAMMap_LCDC = 0;
        for (int bank = 0; bank < 9; bank++) gpu.VRAMDirty[bank].SetRange(0, 256);
        gpu.PaletteDirty = 0xFF;
        gpu.OAMDirty = 0xFF;
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

        build3D(*nds, gpu.GPU3D, c);

        nds->ARM9Timestamp += 0x1000;
        gpu.VCount = 192;
        NDS4MiSTer::EmitTrace3DVBlank(c.vcount, 192, nds->ARM9Timestamp);
        gpu.GPU3D.VBlank();

        gpu.VCount = 215;
        NDS4MiSTer::EmitTrace3DRenderStart(gpu, c.vcount, 215, nds->ARM9Timestamp, false);
        parent.Get3DRenderer()->RenderFrame();
        parent.Finish3DRendering();

        nds->NumFrames = c.vcount + 1;
        for (u32 line = 0; line < 192; line++)
        {
            gpu.VCount = u16(line);
            NDS4MiSTer::EmitTrace2DSpritePhase(gpu, line);
            parent.DrawSprites(line);
            NDS4MiSTer::EmitTrace2DScanline(gpu, line);
            parent.DrawScanline(line);
        }
        NDS4MiSTer::EmitTrace3DFrameEnd(c.vcount + 1, 262, nds->ARM9Timestamp);
        fprintf(g_cases, "%u %u %u %s\n", c.vcount + 1, c.line, c.kind, c.name.c_str());
    }

    NDS4MiSTer::SetTrace2DSink(nullptr, nullptr);
    fclose(g_trace);
    fclose(g_cases);
    printf("gx3d-scene-oracle: %zu cases -> %s\n", cases.size(), path.c_str());
    return 0;
}
