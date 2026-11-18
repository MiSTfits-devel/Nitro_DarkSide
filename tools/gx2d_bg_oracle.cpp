// Standalone background oracle: production SoftRenderer2D BG layer draw.
//
// Drives SoftRenderer2D::DrawScanline_BGOBJ directly with an explicit flat
// VRAM/ext-palette/palette fixture so the standalone Nds.Gpu2D.Line BG model
// can be compared against the reference without running the rest of the GPU.
//
// Two things are important for exactness:
//  * DrawScanline() normally clears StandardPaletteChecked before each line.
//    Calling DrawScanline_BGOBJ directly skips that per-line reset, so this
//    oracle resets the renderer through SoftRenderer2D::Reset() per case.
//  * Engine A and B read different flat VRAM banks (512 KiB vs 128 KiB masks),
//    different palette bases (0x000/0x400) and different BG ext-palette banks.
//    Both engines are exercised here.
#define private public
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <vector>
#include "NDS.h"
#include "GPU_Soft.h"
#include "GPU2D_Soft.h"
#undef private

using namespace melonDS;

namespace
{
// Fixture patterns shared verbatim with clash/test/BgCheck.hs.
u8 vramByte(u32 seed, u32 i) { return u8((seed * 37u + i * 13u + (i >> 9)) & 0xFF); }

u8 hashByte(u32 seed, u32 i)
{
    u32 h = seed * 2654435761u + i * 0x9E3779B1u;
    h ^= h >> 15;
    h *= 2246822519u;
    h ^= h >> 13;
    return u8(h >> 24);
}

u16 structuredWord(u32 seed, u32 k)
{
    u16 tile = u16((k * 7u + seed) & 0x3FFu);
    u16 attr = u16((((k >> 2) & 0xF) << 12) | (((k >> 3) & 1) << 11) |
                   (((k >> 4) & 1) << 10));
    return u16(tile | attr);
}

u8 fixtureByte(u32 pattern, u32 seed, u32 i)
{
    if (pattern == 1) return hashByte(seed, i);
    if (pattern == 2)
    {
        u16 w = structuredWord(seed, i >> 1);
        return u8(w >> (8 * (i & 1)));
    }
    return vramByte(seed, i);
}

u16 palWord(u32 seed, u32 i) { return u16((seed * 17u + i * 5u + 1u) & 0x7FFF); }

// BG ext-palette fixture always uses the generic byte pattern, independent of
// the BG VRAM pattern.
u16 extPalWord(u32 seed, u32 i)
{
    return u16(vramByte(seed, 2 * i) | (vramByte(seed, 2 * i + 1) << 8));
}

struct Case
{
    u32 dispcnt, line, seed, kind;
    u32 engine, bgnum, pattern, mosaic;
    u16 bgcnt, x, y;
    s16 pa, pb, pc, pd;
    s32 rx, ry;
};

struct D
{
    u32 engine, mode, bgnum;
    u16 bgcnt, x, y;
    s16 pa, pb, pc, pd;
    s32 rx, ry;
    u32 pattern, mosaic, dcExtra;
    bool enable;
};

Case directed(const D& d, u32 index)
{
    Case c{};
    c.seed = 1000u + index;
    c.kind = 1000u + index;
    c.engine = d.engine;
    c.bgnum = d.bgnum;
    c.bgcnt = d.bgcnt;
    c.x = d.x; c.y = d.y;
    c.pa = d.pa; c.pb = d.pb; c.pc = d.pc; c.pd = d.pd;
    c.rx = d.rx; c.ry = d.ry;
    c.pattern = d.pattern;
    c.mosaic = d.mosaic;
    c.line = u32((index * 37u) % 192u);
    c.dispcnt = (d.mode & 0x7u) | d.dcExtra;
    if (d.enable) c.dispcnt |= 1u << (8 + d.bgnum);
    return c;
}

std::vector<Case> directedCases()
{
    std::vector<D> ds;
    auto add = [&](u32 engine, u32 mode, u32 bg, u16 bgcnt, u16 x, u16 y,
                   s16 pa, s16 pb, s16 pc, s16 pd, s32 rx, s32 ry,
                   u32 pattern, u32 mosaic = 0, u32 dcExtra = 0,
                   bool enable = true) {
        ds.push_back(D{engine, mode, bg, bgcnt, x, y, pa, pb, pc, pd, rx, ry,
                       pattern, mosaic, dcExtra, enable});
    };

    // Engine A text backgrounds: 4bpp/8bpp, every BG, both map sizes, map
    // and tileset base blocks, mosaic and ext-palette on/off.
    add(0, 0, 0, 0x0000, 0, 0, 0, 0, 0, 0, 0, 0, 2);
    add(0, 0, 0, 0x0000, 3, 5, 0, 0, 0, 0, 0, 0, 1);
    add(0, 0, 0, 0x0080, 7, 9, 0, 0, 0, 0, 0, 0, 2);
    add(0, 0, 0, 0x2080, 7, 9, 0, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(0, 0, 1, 0x2080, 212, 83, 0, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(0, 0, 2, 0xC000, 42, 104, 0, 0, 0, 0, 0, 0, 2);
    add(0, 0, 2, 0x4080, 42, 104, 0, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(0, 0, 3, 0xC080, 218, 106, 0, 0, 0, 0, 0, 0, 2);
    add(0, 0, 3, 0x0080, 218, 106, 0, 0, 0, 0, 0, 0, 1, 0, 1u << 30);
    add(0, 0, 0, 0x0000, 5, 5, 0, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(0, 0, 0, 0x0080, 250, 240, 0, 0, 0, 0, 0, 0, 1, 0, 0x08000000u);
    add(0, 0, 1, 0x0080, 250, 240, 0, 0, 0, 0, 0, 0, 2, 0, 0x39000000u);
    add(0, 0, 0, 0x00C0, 100, 50, 0, 0, 0, 0, 0, 0, 2, 3);
    add(0, 0, 2, 0x0040, 40, 60, 0, 0, 0, 0, 0, 0, 1, 1);
    add(0, 0, 0, 0x0000, 11, 13, 0, 0, 0, 0, 0, 0, 2, 0, 0, false);

    // Mode 1 locks melonDS's BG2=text BG3=affine dispatch.
    add(0, 1, 2, 0x0080, 33, 44, 0, 0, 0, 0, 0, 0, 2);
    add(0, 1, 3, 0x0000, 33, 44, 0x100, 0, 0, 0, 0, 0, 2);

    // Affine tiled BG2/BG3 (8-bit map entries, no flips, no ext palette).
    add(0, 2, 2, 0x0000, 10, 20, 0x100, 0, 0, 0, 0, 0, 2);
    add(0, 2, 2, 0x0000, 10, 20, 0x180, 0x40, -0x60, 0x140,
        0x12345, -0x9876, 1);
    add(0, 2, 2, 0xE000, 10, 20, 0x100, 0, 0x100, 0, 0, 0, 2);
    add(0, 2, 3, 0x8000, 10, 20, -0x100, 0x21, 0x55, 0x100,
        0x1FFFF, 0x7FFF, 2);
    add(0, 2, 3, 0x4000, 10, 20, 0x100, 0, 0, 0, 0, 0, 2, 2);

    // Mode 3/4/5 extended: tiled 8bpp with ext palettes, bitmap indexed and
    // direct colour, map overflow and sizes.
    add(0, 3, 2, 0x0080, 10, 20, 0x100, 0, 0, 0, 0, 0, 2, 0, 0);
    add(0, 3, 2, 0x0084, 10, 20, 0x100, 0, 0, 0, 0x1000, 0, 2);
    add(0, 3, 3, 0x0000, 10, 20, 0x120, 0x30, -0x40, 0x110,
        0x20000, -0x10000, 2);
    add(0, 3, 3, 0x0000, 10, 20, 0x100, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(0, 4, 2, 0x2080, 10, 20, 0x100, 0, 0, 0, 0, 0, 1);
    add(0, 4, 3, 0x0000, 10, 20, 0x100, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(0, 5, 2, 0x0080, 10, 20, 0x100, 0, 0, 0, 0, 0, 2);
    add(0, 5, 2, 0x0000, 10, 20, 0x100, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(0, 5, 3, 0x0000, 10, 20, 0x100, 0, 0, 0, 0, 0, 2, 0, 1u << 30);

    // Mode 6 large bitmap, all four sizes plus mosaic.
    add(0, 6, 2, 0x0000, 0, 0, 0x100, 0, 0, 0, 0x10000, 0x8000, 2);
    add(0, 6, 2, 0x4000, 0, 0, 0x100, 0, 0x100, 0, -0x8000, 0x4000, 1);
    add(0, 6, 2, 0x8000, 0, 0, 0x100, 0, 0, 0, 0x2FFFF, 0xFFFF, 2);
    add(0, 6, 2, 0xC000, 0, 0, 0x80, 0, 0x80, 0, 0x8000, -0x8000, 2);
    add(0, 6, 2, 0x0040, 0, 0, 0x100, 0, 0, 0, 0x1234, 0x5678, 2, 2);

    // Engine B: same feature matrix, palette base 0x400, BBG ext palette,
    // 128 KiB VRAM mask, DISPCNT map/tileset base bits ignored.
    add(1, 0, 0, 0x0000, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0x39000000u);
    add(1, 0, 0, 0x0080, 7, 9, 0, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(1, 0, 1, 0x2080, 212, 83, 0, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(1, 0, 2, 0xC000, 42, 104, 0, 0, 0, 0, 0, 0, 2);
    add(1, 0, 3, 0xC080, 218, 106, 0, 0, 0, 0, 0, 0, 2);
    add(1, 0, 3, 0x0080, 218, 106, 0, 0, 0, 0, 0, 0, 1, 0, 1u << 30);
    add(1, 0, 0, 0x00C0, 100, 50, 0, 0, 0, 0, 0, 0, 2, 3);
    add(1, 0, 0, 0x0000, 5, 5, 0, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(1, 0, 1, 0x0000, 11, 13, 0, 0, 0, 0, 0, 0, 2, 0, 0, false);
    add(1, 1, 2, 0x0080, 33, 44, 0, 0, 0, 0, 0, 0, 2);
    add(1, 1, 3, 0x0000, 33, 44, 0x100, 0, 0, 0, 0, 0, 2);
    add(1, 2, 2, 0x0000, 10, 20, 0x180, 0x40, -0x60, 0x140,
        0x12345, -0x9876, 1);
    add(1, 2, 3, 0xE000, 10, 20, 0x100, 0, 0x100, 0, 0, 0, 2);
    add(1, 3, 2, 0x0080, 10, 20, 0x100, 0, 0, 0, 0, 0, 2);
    add(1, 3, 2, 0x0084, 10, 20, 0x100, 0, 0, 0, 0x1000, 0, 2);
    add(1, 3, 3, 0x0000, 10, 20, 0x120, 0x30, -0x40, 0x110,
        0x20000, -0x10000, 2, 0, 1u << 30);
    add(1, 4, 3, 0x0000, 10, 20, 0x100, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(1, 5, 2, 0x0000, 10, 20, 0x100, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(1, 5, 3, 0x0000, 10, 20, 0x100, 0, 0, 0, 0, 0, 2, 0, 1u << 30);
    add(1, 6, 2, 0x4000, 0, 0, 0x100, 0, 0x100, 0, -0x8000, 0x4000, 1);
    add(1, 6, 2, 0x0040, 0, 0, 0x100, 0, 0, 0, 0x1234, 0x5678, 2, 2);

    std::vector<Case> out;
    out.reserve(ds.size());
    for (size_t i = 0; i < ds.size(); ++i) out.push_back(directed(ds[i], u32(i)));
    return out;
}

// Random kinds. 0..23 are the plain variants, 24..47 the same shapes with
// DISPCNT bit 30 (BG extended palettes) set. Every shape is therefore checked
// with the extended palette both off and on, on both engines.
constexpr unsigned KindCount = 24;
constexpr unsigned RandomKindCount = KindCount * 2;

Case randomCase(unsigned kind, u32 seed)
{
    std::mt19937 rng(seed * 2654435761u + 9u);
    Case c{};
    c.seed = seed;
    c.kind = kind;
    unsigned k = kind % KindCount;
    c.engine = rng() & 1u;
    c.pattern = rng() % 3u == 0 ? 0u : 1u + (rng() & 1u);
    c.line = rng() % 192;
    c.bgcnt = u16(rng() & 0xFFFF);
    c.x = u16(rng() & 0xFF);
    c.y = u16(rng() % 256);
    c.pa = s16(rng()); c.pb = s16(rng());
    c.pc = s16(rng()); c.pd = s16(rng());
    c.rx = s32(rng()); c.ry = s32(rng());
    c.mosaic = (rng() >> 8) % 4;
    c.dispcnt = 0;
    switch (k)
    {
    case 0: c.bgnum = 0; c.bgcnt &= ~0x80; break;                       // text 4bpp BG0
    case 1: c.bgnum = 0; c.bgcnt |= 0x80; break;                        // text 8bpp BG0
    case 2: c.bgnum = 1; break;                                         // text BG1
    case 3: c.bgnum = 3; c.bgcnt |= 0x80; break;                        // text 8bpp BG3
    case 4: c.dispcnt = 2; c.bgnum = 2; c.bgcnt &= ~0x80; break;        // affine tiled BG2
    case 5: c.dispcnt = 2; c.bgnum = 3; c.bgcnt &= ~0x80; break;        // affine tiled BG3
    case 6: c.dispcnt = 1; c.bgnum = 2; break;                          // mode1 BG2 text
    case 7: c.dispcnt = 1; c.bgnum = 3; c.bgcnt &= ~0x80; break;        // mode1 BG3 affine
    case 8: c.dispcnt = 3; c.bgnum = 2; c.bgcnt = (c.bgcnt | 0x80) & ~0x4; break; // bitmap indexed
    case 9: c.dispcnt = 3; c.bgnum = 2; c.bgcnt |= 0x84; break;         // bitmap direct
    case 10: c.dispcnt = 4; c.bgnum = 2; c.bgcnt = (c.bgcnt | 0x80) & ~0x4; break;
    case 11: c.dispcnt = 5; c.bgnum = 2; c.bgcnt = (c.bgcnt | 0x80) & ~0x4; break;
    case 12: c.dispcnt = 6; c.bgnum = 2; break;                         // large bitmap
    case 13: c.dispcnt = 3; c.bgnum = 3; c.bgcnt &= ~0x80; break;       // extended tiled BG3
    case 14: c.dispcnt = 4; c.bgnum = 3; c.bgcnt &= ~0x80; break;
    case 15: c.dispcnt = 5; c.bgnum = 3; c.bgcnt &= ~0x80; break;
    case 16: c.dispcnt = 5; c.bgnum = 2; c.bgcnt &= ~0x80; break;       // extended tiled BG2
    case 17: c.bgnum = 2; c.bgcnt |= 0x80; break;                       // text 8bpp BG2
    case 18: c.bgnum = 0; c.bgcnt &= ~0x80; break;                      // text 4bpp BG0
    case 19: c.bgnum = 1; c.bgcnt |= 0x80; break;                       // text 8bpp BG1
    case 20: c.dispcnt = 2; c.bgnum = 2; c.bgcnt &= ~0x80; break;
    case 21: c.dispcnt = 2; c.bgnum = 3; c.bgcnt &= ~0x80; break;
    case 22: c.bgnum = 3; c.bgcnt &= ~0x80; break;                      // text 4bpp BG3
    default: c.dispcnt = 1; c.bgnum = 3; c.bgcnt &= ~0x80; break;
    }
    if (kind >= KindCount) c.dispcnt |= 1u << 30;
    c.dispcnt |= (1u << (8 + c.bgnum)) | (rng() & 0x3F000000u);
    return c;
}

void fillCase(const Case& c, GPU& gpu, GPU2D& e, SoftRenderer2D& r)
{
    // Engine-specific fixture seeds: a bank mixup in the reference (or in the
    // model's engine selection) must change the compared bytes.
    u32 vseed = c.seed + (c.engine ? 0x4000u : 0u);
    u8* vram = c.engine ? gpu.VRAMFlat_BBG : gpu.VRAMFlat_ABG;
    u32 vramSize = c.engine ? 128u * 1024u : 512u * 1024u;
    for (u32 i = 0; i < vramSize; i++) vram[i] = fixtureByte(c.pattern, vseed, i);
    for (u32 i = 0; i < 0x800; i++)
        gpu.Palette[i] = u8((palWord(c.seed, i / 2) >> (8 * (i & 1))) & 0xFF);
    for (u32 i = 0; i < 0x8000; i++)
    {
        gpu.VRAMFlat_ABGExtPal[i] = vramByte(c.seed + 3, i);
        gpu.VRAMFlat_BBGExtPal[i] = vramByte(c.seed + 3 + 0x40u, i);
    }

    // Same per-line state DrawScanline() establishes before DrawScanline_BGOBJ.
    r.Reset();
    e.Num = c.engine;
    e.DispCnt = c.dispcnt;
    e.LayerEnable = u8(((c.dispcnt >> 8) & 0x1F));
    e.BGCnt[c.bgnum] = c.bgcnt;
    e.BGXPos[c.bgnum] = c.x;
    e.BGYPos[c.bgnum] = c.y;
    u32 rot = c.bgnum > 1 ? c.bgnum - 2 : 0;
    e.BGRotA[rot] = c.pa;
    e.BGRotB[rot] = c.pb;
    e.BGRotC[rot] = c.pc;
    e.BGRotD[rot] = c.pd;
    e.BGXRefInternal[rot] = c.rx;
    e.BGYRefInternal[rot] = c.ry;
    e.BGMosaicSize[0] = u8(c.mosaic);
    e.OBJMosaicSize[0] = 0;
    e.BGMosaicLine = c.line;
    e.Enabled = true;
    e.OBJEnable = false;
    e.ForcedBlank = false;
    e.BlendCnt = 0;
    e.EVA = 0; e.EVB = 0; e.EVY = 0;
    std::memset(e.WinCnt, 0, sizeof(e.WinCnt));
    e.Win0Active = 0; e.Win1Active = 0;
    gpu.MasterBrightnessA = 0;
    gpu.MasterBrightnessB = 0;
}

void writeCase(const Case& c, const u32* line)
{
    fwrite(&c.dispcnt, 4, 1, stdout);
    fwrite(&c.line, 4, 1, stdout);
    fwrite(&c.seed, 4, 1, stdout);
    fwrite(&c.kind, 4, 1, stdout);
    fwrite(&c.engine, 4, 1, stdout);
    fwrite(&c.bgnum, 4, 1, stdout);
    fwrite(&c.pattern, 4, 1, stdout);
    fwrite(&c.mosaic, 4, 1, stdout);
    fwrite(&c.bgcnt, 2, 1, stdout);
    fwrite(&c.x, 2, 1, stdout);
    fwrite(&c.y, 2, 1, stdout);
    fwrite(&c.pa, 2, 1, stdout); fwrite(&c.pb, 2, 1, stdout);
    fwrite(&c.pc, 2, 1, stdout); fwrite(&c.pd, 2, 1, stdout);
    fwrite(&c.rx, 4, 1, stdout); fwrite(&c.ry, 4, 1, stdout);
    fwrite(line, 4, 256, stdout);
}
}

int main(int argc, char** argv)
{
    unsigned directed = 64, randomCases = 120;
    if (argc > 1) directed = std::stoul(argv[1]);
    if (argc > 2) randomCases = std::stoul(argv[2]);
    bool trace = std::getenv("BG_ORACLE_TRACE") != nullptr;

    NDSArgs args;
    args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args));
    nds->Reset();
    auto& gpu = nds->GPU;
    auto& parent = static_cast<SoftRenderer&>(nds->GetRenderer());
    SoftRenderer2D rA(gpu.GPU2D_A, parent);
    SoftRenderer2D rB(gpu.GPU2D_B, parent);
    rA.SpriteCache = nullptr; rA.SpriteSetup = nullptr;
    rB.SpriteCache = nullptr; rB.SpriteSetup = nullptr;
    SoftRenderer2D* renderers[2] = {&rA, &rB};
    GPU2D* engines[2] = {&gpu.GPU2D_A, &gpu.GPU2D_B};

    std::vector<Case> dir = directedCases();
    u32 dcount = std::min<u32>(u32(dir.size()), directed);
    u32 total = dcount + randomCases;

    fwrite("BGC2", 1, 4, stdout);
    fwrite(&total, 4, 1, stdout);
    for (u32 n = 0; n < total; n++)
    {
        Case c = n < dcount ? dir[n]
                            : randomCase((n - dcount) % RandomKindCount, n + 1);
        if (trace)
            fprintf(stderr, "case %u engine=%u kind=%u bg=%u dc=%08x bgcnt=%04x "
                            "x=%u y=%u pat=%u mosaic=%u\n",
                    n, c.engine, c.kind, c.bgnum, c.dispcnt, c.bgcnt,
                    c.x, c.y, c.pattern, c.mosaic);
        fillCase(c, gpu, *engines[c.engine], *renderers[c.engine]);
        renderers[c.engine]->DrawScanline_BGOBJ(c.line, parent.Output2D[c.engine]);
        writeCase(c, parent.Output2D[c.engine]);
    }
    return 0;
}
