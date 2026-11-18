// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Truffle
//
// Textured and translucent scene oracle. Reads one frame of polygons with full
// attributes (vertex colour, texture coordinates, polygon attribute, TexParam,
// TexPalette) from stdin, uploads a VRAM image the way a game does, renders the
// frame with the production SoftRenderer3D::RenderFrame and writes the top
// colour layer to stdout. ORACLE_DEPTH_OUT and ORACLE_ATTR_OUT name files for
// the top depth and attribute layers.
//
// Input lines:
//   CFG dispcnt alpharef clearattr1 clearattr2 wbuffer
//   TOON t0 .. t31
//   POLY attr texparam texpal facing  x y z w r g b s t  (three vertices)
// r, g and b are FinalColor values (0..511); z and w are FinalZ and FinalW.
//
// ORACLE_VRAM names the image: 512 KiB of texture slots 0-3, then 128 KiB of
// texture-palette slots 0-7. Banks A-D are written through LCDC and mapped as
// texture slots 0-3; E maps palette slots 0-3, F slot 4, G slot 5. Slots 6 and
// 7 are unmapped and must be zero in the image.
//
// ORACLE_TEXCACHE=1 selects the fork's decoded texture cache; the default is
// the direct SoftRenderer3D::TextureLookup path.
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

#include "NDS.h"
#include "GPU.h"
#include "GPU3D.h"
#include "GPU3D_Texcache.h"
#include "NDS4MiSTer_FastDivide.h"
#include "Platform.h"
// Oracle-only: expose the renderer's private buffers and texture-path switch.
#define private public
#include "GPU3D_Soft.h"
#undef private
#include "GPU_Soft.h"

using namespace melonDS;

namespace
{

constexpr u32 TextureBytes = 512 * 1024;
constexpr u32 PaletteBytes = 128 * 1024;
constexpr u32 MappedPaletteBytes = 96 * 1024;

struct Poly
{
    u32 attr, texparam, texpal;
    bool facing;
    s32 x[3], y[3], z[3], w[3], r[3], g[3], b[3], s[3], t[3];
};

struct Config
{
    u32 dispcnt = 0, alpharef = 0, clear1 = 0, clear2 = 0x7FFF;
    bool wbuffer = false;
    u16 toon[32] {};
};

bool readFrame(Config& cfg, std::vector<Poly>& polys)
{
    char kind[8];
    while (std::scanf("%7s", kind) == 1)
    {
        if (std::strcmp(kind, "CFG") == 0)
        {
            int wb = 0;
            if (std::scanf("%u %u %u %u %d", &cfg.dispcnt, &cfg.alpharef,
                    &cfg.clear1, &cfg.clear2, &wb) != 5)
                return false;
            cfg.wbuffer = wb != 0;
        }
        else if (std::strcmp(kind, "TOON") == 0)
        {
            for (int i = 0; i < 32; ++i)
            {
                unsigned v;
                if (std::scanf("%u", &v) != 1) return false;
                cfg.toon[i] = static_cast<u16>(v & 0x7FFF);
            }
        }
        else if (std::strcmp(kind, "POLY") == 0)
        {
            Poly p {};
            int face = 1;
            if (std::scanf("%u %u %u %d", &p.attr, &p.texparam, &p.texpal, &face) != 4)
                return false;
            p.facing = face != 0;
            for (int v = 0; v < 3; ++v)
                if (std::scanf("%d %d %d %d %d %d %d %d %d",
                        &p.x[v], &p.y[v], &p.z[v], &p.w[v],
                        &p.r[v], &p.g[v], &p.b[v], &p.s[v], &p.t[v]) != 9)
                    return false;
            polys.push_back(p);
        }
        else
            return false;
    }
    return true;
}

bool loadVram(GPU& gpu, std::vector<u8>& image)
{
    const char* path = std::getenv("ORACLE_VRAM");
    image.assign(TextureBytes + PaletteBytes, 0);
    if (path)
    {
        std::FILE* f = std::fopen(path, "rb");
        if (!f) return false;
        const size_t got = std::fread(image.data(), 1, image.size(), f);
        std::fclose(f);
        if (got != image.size()) return false;
    }
    for (u32 i = MappedPaletteBytes; i < PaletteBytes; ++i)
        if (image[TextureBytes + i] != 0) return false;

    // Upload through LCDC, as a game does, then hand the banks to the 3D engine.
    gpu.MapVRAM_AB(0, 0x80);
    gpu.MapVRAM_AB(1, 0x80);
    gpu.MapVRAM_CD(2, 0x80);
    gpu.MapVRAM_CD(3, 0x80);
    gpu.MapVRAM_E(4, 0x80);
    gpu.MapVRAM_FG(5, 0x80);
    gpu.MapVRAM_FG(6, 0x80);
    auto word = [&](u32 at) {
        return static_cast<u32>(image[at]) | (static_cast<u32>(image[at + 1]) << 8)
            | (static_cast<u32>(image[at + 2]) << 16) | (static_cast<u32>(image[at + 3]) << 24);
    };
    for (u32 i = 0; i < TextureBytes; i += 4)
        gpu.WriteVRAM_LCDC<u32>(0x06800000 + i, word(i));
    for (u32 i = 0; i < 0x10000; i += 4)
        gpu.WriteVRAM_LCDC<u32>(0x06880000 + i, word(TextureBytes + i));
    for (u32 i = 0; i < 0x4000; i += 4)
        gpu.WriteVRAM_LCDC<u32>(0x06890000 + i, word(TextureBytes + 0x10000 + i));
    for (u32 i = 0; i < 0x4000; i += 4)
        gpu.WriteVRAM_LCDC<u32>(0x06894000 + i, word(TextureBytes + 0x14000 + i));
    gpu.MapVRAM_AB(0, 0x83 | (0 << 3));
    gpu.MapVRAM_AB(1, 0x83 | (1 << 3));
    gpu.MapVRAM_CD(2, 0x83 | (2 << 3));
    gpu.MapVRAM_CD(3, 0x83 | (3 << 3));
    gpu.MapVRAM_E(4, 0x83);
    gpu.MapVRAM_FG(5, 0x83 | (2 << 3));
    gpu.MapVRAM_FG(6, 0x83 | (3 << 3));
    return true;
}

bool writeLayer(const char* env, const u32* buffer)
{
    const char* path = std::getenv(env);
    if (!path) return true;
    std::FILE* f = std::fopen(path, "wb");
    if (!f) return false;
    for (int y = 0; y < 192; ++y)
        std::fwrite(&buffer[SoftRenderer3D::FirstPixelOffset
                        + y * SoftRenderer3D::ScanlineWidth],
            sizeof(u32), 256, f);
    std::fclose(f);
    return true;
}

} // namespace

int main()
{
    auto ndsHolder = std::make_unique<NDS>();
    NDS& nds = *ndsHolder;
    auto softHolder = std::make_unique<SoftRenderer>(nds);
    SoftRenderer& soft = *softHolder;
    SoftRenderer3D* r3d = soft.Get3DRenderer();
    GPU3D& gpu3d = nds.GPU.GPU3D;

    const char* cacheEnv = std::getenv("ORACLE_TEXCACHE");
    r3d->UseTextureCache = cacheEnv && std::strcmp(cacheEnv, "1") == 0;

    Config cfg;
    std::vector<Poly> polys;
    if (!readFrame(cfg, polys))
    {
        std::fprintf(stderr, "scene-oracle: malformed input\n");
        return 1;
    }
    std::vector<u8> image;
    if (!loadVram(nds.GPU, image))
    {
        std::fprintf(stderr, "scene-oracle: bad VRAM image\n");
        return 1;
    }

    gpu3d.RenderDispCnt = cfg.dispcnt;
    gpu3d.RenderAlphaRef = static_cast<u8>(cfg.alpharef);
    gpu3d.RenderClearAttr1 = cfg.clear1;
    gpu3d.RenderClearAttr2 = cfg.clear2;
    gpu3d.RenderXPos = 0;
    std::memcpy(gpu3d.RenderToonTable, cfg.toon, sizeof(cfg.toon));

    std::vector<Polygon> polygons(polys.size());
    std::vector<std::array<Vertex, 3>> vertices(polys.size());
    std::vector<Polygon*> pointers(polys.size());
    for (size_t i = 0; i < polys.size(); ++i)
    {
        const Poly& t = polys[i];
        Polygon& p = polygons[i];
        auto& vs = vertices[i];
        p.NumVertices = 3;
        p.Attr = t.attr;
        p.TexParam = t.texparam;
        p.TexPalette = t.texpal;
        p.Degenerate = false;
        p.FacingView = t.facing;
        p.WBuffer = cfg.wbuffer;
        // As GPU3D::SubmitPolygon derives them; Translucent only feeds sorting.
        const u32 texfmt = (t.texparam >> 26) & 0x7;
        const u32 polyalpha = (t.attr >> 16) & 0x1F;
        p.Translucent = (texfmt == 1 || texfmt == 6) || (polyalpha > 0 && polyalpha < 31);
        p.IsShadowMask = (t.attr & 0x3F000030) == 0x00000030;
        p.IsShadow = (t.attr & 0x30) == 0x30 && !p.IsShadowMask;
        p.Type = 0;
        p.SortKey = 0;

        s32 ytop = 192, ybot = 0;
        s32 xtop = 256, xbot = 0;
        u32 vtop = 0, vbot = 0;
        for (u32 v = 0; v < 3; ++v)
        {
            Vertex& vert = vs[v];
            vert.FinalPosition[0] = t.x[v];
            vert.FinalPosition[1] = t.y[v];
            vert.FinalColor[0] = t.r[v];
            vert.FinalColor[1] = t.g[v];
            vert.FinalColor[2] = t.b[v];
            vert.TexCoords[0] = static_cast<s16>(t.s[v]);
            vert.TexCoords[1] = static_cast<s16>(t.t[v]);
            p.Vertices[v] = &vert;
            p.FinalZ[v] = t.z[v];
            p.FinalW[v] = t.w[v];
            if (t.y[v] < ytop) { ytop = t.y[v]; xtop = t.x[v]; vtop = v; }
            if (t.y[v] > ybot || (t.y[v] == ybot && t.x[v] > xbot))
            { ybot = t.y[v]; xbot = t.x[v]; vbot = v; }
        }
        p.YTop = ytop;
        p.YBottom = ybot;
        p.VTop = vtop;
        p.VBottom = vbot;
        p.XTop = xtop;
        p.XBottom = xbot;
        pointers[i] = &p;
    }

    r3d->RenderFrame(pointers.data(), static_cast<u32>(pointers.size()));

    // The direct path reads the flat VRAM views; prove they hold the image.
    if (!r3d->UseTextureCache)
    {
        if (std::memcmp(nds.GPU.VRAMFlat_Texture, image.data(), TextureBytes) != 0 ||
            std::memcmp(nds.GPU.VRAMFlat_TexPal, image.data() + TextureBytes,
                PaletteBytes) != 0)
        {
            std::fprintf(stderr, "scene-oracle: flat VRAM differs from the image\n");
            return 1;
        }
    }

    for (u32 y = 0; y < 192; ++y)
        std::fwrite(r3d->GetLine(static_cast<int>(y)), sizeof(u32), 256, stdout);
    if (!writeLayer("ORACLE_DEPTH_OUT", r3d->DepthBuffer) ||
        !writeLayer("ORACLE_ATTR_OUT", r3d->AttrBuffer))
        return 1;
    return 0;
}
