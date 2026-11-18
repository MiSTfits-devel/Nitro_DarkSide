// Standalone sprite oracle: runs melonDS's production SoftRenderer2D::DrawSprites
// and emits the raw OBJLine/OBJWindow pair for each case. Never links the
// Haskell model; the checker compares against these bytes.
#define private public
#include <algorithm>
#include <array>
#include <cstdio>
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
constexpr u32 ObjBytes = 0x40000; // engine A's full 256 KiB flat OBJ view
constexpr u32 ObjMask = ObjBytes - 1;

struct Case
{
    u8 enabled, objEnabled, mosaic;
    u32 dispcnt, mosaicLine, line;
    std::array<u8, 1024> oam;
    std::array<u8, ObjBytes> obj;
};

void put16(std::array<u8, 1024>& o, unsigned idx, u16 v)
{
    o[idx * 2] = v & 0xFF;
    o[idx * 2 + 1] = v >> 8;
}

Case makeCase(unsigned mode, u32 seed)
{
    std::mt19937 rng(seed * 2654435761u + 1u);
    Case c{};
    c.enabled = 1;
    c.objEnabled = 1;
    c.mosaic = 1 + (rng() % 3);
    c.dispcnt = 0;
    c.mosaicLine = 20 + (rng() % 120);
    c.line = 20 + (rng() % 120);
    for (auto& b : c.oam) b = rng();
    for (auto& b : c.obj) b = rng();
    // All sprites disabled unless the directed setup below enables one.
    for (unsigned i = 0; i < 128; i++) put16(c.oam, i * 4, 0x0200);

    auto sprite = [&](unsigned num, u16 a0, u16 a1, u16 a2) {
        put16(c.oam, num * 4, a0);
        put16(c.oam, num * 4 + 1, a1);
        put16(c.oam, num * 4 + 2, a2);
    };
    const u16 y = 20, x = 16;
    switch (mode)
    {
    case 0: sprite(0, y | (0 << 8) | 0x0000, x | 0x0000, 0x0000); break; // 8x8 16-color
    case 1: sprite(0, y | 0x2000, x, 0x0010); break;                       // 256-color
    case 2: sprite(0, y | 0x0000, x | 0x1000, 0x0020); break;              // xflip
    case 3: sprite(0, y | 0x0000, x | 0x2000 | 0x1000, 0x0030); break;     // yflip
    case 4: sprite(0, y | 0x0000, x, 0x0000);                              // 1D mapping
            c.dispcnt |= 0x10; break;
    case 5: sprite(0, y | 0x2000, x, 0x0010); c.dispcnt |= 0x10; break;    // 1D 256
    case 6: sprite(0, y | 0x0000, x | 0x2000, 0x0040); break;              // bitmap 2D
    case 7: sprite(0, y | 0x0000, x | 0x2000, 0x0040); c.dispcnt |= 0x20; break;
    case 8: sprite(0, y | 0x0000, x | 0x2000, 0x0040); c.dispcnt |= 0x60 | 0x100000; break;
    case 9: sprite(0, y | (1 << 8) | 0x0800, x, 0x0000);                   // affine 16
            put16(c.oam, ((0) * 16) + 3 + 0, 0x0100);
            put16(c.oam, ((0) * 16) + 3 + 4, 0);
            put16(c.oam, ((0) * 16) + 3 + 8, 0);
            put16(c.oam, ((0) * 16) + 3 + 12, 0x0100); break;
    case 10: sprite(0, y | (1 << 8) | 0x2000, x, 0x0010);                  // affine 256
            put16(c.oam, 3, 0x0180);
            put16(c.oam, 7, 0);
            put16(c.oam, 11, 0);
            put16(c.oam, 15, 0x0180); break;
    case 11: sprite(0, y | (3 << 8) | 0x0000, x, 0x0000);                  // double affine
            put16(c.oam, 3, 0x0100); put16(c.oam, 7, 0);
            put16(c.oam, 11, 0); put16(c.oam, 15, 0x0100); break;
    case 12: sprite(0, y | (2 << 8) | (2 << 10), x, 0x0000);               // OBJ window
            sprite(1, (y + 4) | (2 << 10), x + 4, 0x0000); break;
    case 13: sprite(0, y | 0x1000, x, 0x0000); break;                      // mosaic Y
    case 14: sprite(0, y | 0x0000, x, 0x0000);
             sprite(1, y | 0x0000, x + 3, 0x0100); break;                 // overlap priority
    case 15: c.enabled = 0; sprite(0, y, x, 0); break;
    case 16: c.objEnabled = 0; sprite(0, y, x, 0); break;
    case 17: sprite(0, y | 0x3000 | 0x2000, x | 0x2000, 0x0040);         // 64x64 bitmap
             c.dispcnt |= 0x40; break;
    case 18: sprite(0, y | 0x4000 | 0x1000, x | 0x8000, 0x00F0);         // 32x32 256
             break;
    case 19: sprite(0, y | 0x8000 | 0x2000, x | 0x4000, 0x00A5);         // 16x16 16
             break;
    default: {
        // Random but structurally valid: up to four enabled sprites.
        unsigned n = rng() % 4;
        for (unsigned i = 0; i <= n; i++)
        {
            u16 a0 = rng(), a1 = rng(), a2 = rng();
            a0 &= 0xFF00 | 0xFF; a0 &= ~(3u << 8); a0 |= (rng() % 2) << 8;
            a1 &= 0xFFFF;
            a2 &= 0x3FFF;
            sprite(i, a0, a1, a2);
        }
        c.dispcnt = rng() & 0x80A01070;
        c.objEnabled = (rng() & 7) != 0;
        c.enabled = (rng() & 7) != 0;
        break;
    }
    }
    return c;
}
}

int main(int argc, char** argv)
{
    unsigned directed = 20, randomCases = 80;
    if (argc > 1) directed = std::stoul(argv[1]);
    if (argc > 2) randomCases = std::stoul(argv[2]);
    const bool engineB = argc > 3 && std::strcmp(argv[3], "B") == 0;

    NDSArgs args;
    args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args));
    nds->Reset();
    auto& gpu = nds->GPU;
    auto& e = engineB ? gpu.GPU2D_B : gpu.GPU2D_A;
    auto& parent = static_cast<SoftRenderer&>(nds->GetRenderer());
    SoftRenderer2D r(e, parent);
    r.SpriteCache = nullptr;
    r.SpriteSetup = nullptr;
    u8* oamBase = gpu.OAM + (engineB ? 0x400 : 0);
    u8* objBase = engineB ? gpu.VRAMFlat_BOBJ : gpu.VRAMFlat_AOBJ;
    const u32 objBytes = engineB ? 0x20000 : 0x40000;

    fwrite("SPR2", 1, 4, stdout);
    u32 total = directed + randomCases;
    fwrite(&total, 4, 1, stdout);

    for (u32 n = 0; n < total; n++)
    {
        Case c = makeCase(n < directed ? n : 20 + (n % 16), n + 1);
        std::memcpy(oamBase, c.oam.data(), c.oam.size());
        std::memcpy(objBase, c.obj.data(), objBytes);
        e.Enabled = c.enabled;
        e.OBJEnable = c.objEnabled;
        e.DispCnt = c.dispcnt;
        e.OBJMosaicLine = c.mosaicLine;
        e.OBJMosaicSize[0] = c.mosaic;
        e.Num = engineB ? 1 : 0;

        r.DrawSprites(c.line);
        std::array<u32, 256> pre{};
        std::memcpy(pre.data(), r.OBJLine, sizeof(pre));
        r.ApplySpriteMosaicX();

        fwrite(&c.enabled, 1, 1, stdout);
        fwrite(&c.objEnabled, 1, 1, stdout);
        fwrite(&c.mosaic, 1, 1, stdout);
        fwrite(&c.dispcnt, 4, 1, stdout);
        fwrite(&c.mosaicLine, 4, 1, stdout);
        fwrite(&c.line, 4, 1, stdout);
        u32 ob = c.oam.size();
        fwrite(&ob, 4, 1, stdout);
        fwrite(c.oam.data(), 1, ob, stdout);
        u32 vb = objBytes;
        fwrite(&vb, 4, 1, stdout);
        fwrite(c.obj.data(), 1, vb, stdout);
        fwrite(pre.data(), 4, 256, stdout);
        fwrite(r.OBJWindow, 1, 256, stdout);
        fwrite(r.OBJLine, 4, 256, stdout);
    }
    return 0;
}
