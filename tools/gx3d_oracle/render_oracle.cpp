// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Truffle
//
// Full renderer oracle: SoftRenderer3D::RenderFrame on complete polygon
// records and Render* registers, for the Nds.Gpu3D.Render gate.
//
// Reads one or more frames from stdin, builds real melonDS Vertex/Polygon
// objects from them, sets the Render* registers, and renders each frame with
// the production RenderFrame on the direct TextureLookup path. Frames render
// back to back on one renderer, so the lower layer, the stencil buffer and
// PrevIsShadowMask carry from one frame to the next exactly as in production.
// Before the first frame the renderer is in its Reset() state with a zeroed
// stencil buffer.
//
// Input, whitespace separated:
//   FRAME
//   REGS dispcnt alpharef clearattr1 clearattr2 fogcolor fogoffset fogshift xpos
//   FOG  d0 .. d33          (RenderFogDensityTable)
//   EDGE e0 .. e7           (RenderEdgeTable)
//   TOON t0 .. t31          (RenderToonTable)
//   POLY n attr texparam texpal degenerate facing translucent shadowmask shadow
//        type wbuffer vtop vbottom ytop ybottom xtop xbottom sortkey
//        then n (3..10) vertices: x y r g b s t z w
// x/y are FinalPosition, r/g/b FinalColor, s/t TexCoords, z/w FinalZ/FinalW.
// fogoffset is RenderFogOffset (FOG_OFFSET * 0x200).
//
// Output (stdout), per frame, little-endian u32 words: the 192 GetLine lines
// of 256 pixels, then the top colour, depth and attribute layers and the
// lower colour, depth and attribute layers, each 192 rows of 256.
//
// ORACLE_VRAM names the image: 512 KiB of texture slots 0-3, then 128 KiB of
// texture-palette slots 0-7 (slots 6 and 7 must be zero). It is uploaded
// through LCDC as scene_oracle.cpp does.
//
// Reference-path settings (the fork's optimisations are not the reference):
// texture cache off (direct TextureLookup), sparse clear off (the full
// ClearBuffers), no render thread, rectangle span specialisations off (the
// GPU3D default), RenderFrameIdentical false so every frame renders.
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

#include "NDS.h"
#include "GPU.h"
#include "GPU3D.h"
#include "GPU3D_Texcache.h"
#include "NDS4MiSTer_FastDivide.h"
#include "Platform.h"
// Oracle-only: expose the renderer's private buffers and path switches.
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

struct Vert
{
    s32 x, y, r, g, b, s, t, z, w;
};

struct Poly
{
    u32 n, attr, texparam, texpal;
    int degenerate, facing, translucent, shadowmask, shadow, type, wbuffer;
    u32 vtop, vbottom;
    s32 ytop, ybottom, xtop, xbottom;
    u32 sortkey;
    std::vector<Vert> verts;
};

struct Frame
{
    u32 dispcnt = 0, alpharef = 0, clear1 = 0, clear2 = 0;
    u32 fogcolor = 0, fogoffset = 0, fogshift = 0, xpos = 0;
    u8 fog[34] {};
    u16 edge[8] {};
    u16 toon[32] {};
    std::vector<Poly> polys;
};

bool readU32s(u32* out, int n)
{
    for (int i = 0; i < n; ++i)
        if (std::scanf("%u", &out[i]) != 1) return false;
    return true;
}

bool readInput(std::vector<Frame>& frames)
{
    char kind[8];
    while (std::scanf("%7s", kind) == 1)
    {
        if (std::strcmp(kind, "FRAME") == 0)
        {
            frames.emplace_back();
            continue;
        }
        if (frames.empty()) return false;
        Frame& f = frames.back();
        if (std::strcmp(kind, "REGS") == 0)
        {
            u32 v[8];
            if (!readU32s(v, 8)) return false;
            f.dispcnt = v[0]; f.alpharef = v[1]; f.clear1 = v[2]; f.clear2 = v[3];
            f.fogcolor = v[4]; f.fogoffset = v[5]; f.fogshift = v[6]; f.xpos = v[7];
        }
        else if (std::strcmp(kind, "FOG") == 0)
        {
            u32 v[34];
            if (!readU32s(v, 34)) return false;
            for (int i = 0; i < 34; ++i) f.fog[i] = static_cast<u8>(v[i]);
        }
        else if (std::strcmp(kind, "EDGE") == 0)
        {
            u32 v[8];
            if (!readU32s(v, 8)) return false;
            for (int i = 0; i < 8; ++i) f.edge[i] = static_cast<u16>(v[i]);
        }
        else if (std::strcmp(kind, "TOON") == 0)
        {
            u32 v[32];
            if (!readU32s(v, 32)) return false;
            for (int i = 0; i < 32; ++i) f.toon[i] = static_cast<u16>(v[i]);
        }
        else if (std::strcmp(kind, "POLY") == 0)
        {
            Poly p {};
            if (std::scanf("%u %u %u %u %d %d %d %d %d %d %d %u %u %d %d %d %d %u",
                    &p.n, &p.attr, &p.texparam, &p.texpal, &p.degenerate, &p.facing,
                    &p.translucent, &p.shadowmask, &p.shadow, &p.type, &p.wbuffer,
                    &p.vtop, &p.vbottom, &p.ytop, &p.ybottom, &p.xtop, &p.xbottom,
                    &p.sortkey) != 18)
                return false;
            if (p.n < 3 || p.n > 10) return false;
            p.verts.resize(p.n);
            for (Vert& v : p.verts)
                if (std::scanf("%d %d %d %d %d %d %d %d %d",
                        &v.x, &v.y, &v.r, &v.g, &v.b, &v.s, &v.t, &v.z, &v.w) != 9)
                    return false;
            f.polys.push_back(std::move(p));
        }
        else
            return false;
    }
    return !frames.empty();
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

void writeLayer(const u32* buffer)
{
    for (int y = 0; y < 192; ++y)
        std::fwrite(&buffer[SoftRenderer3D::FirstPixelOffset + y * SoftRenderer3D::ScanlineWidth],
            sizeof(u32), 256, stdout);
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

    r3d->UseTextureCache = false;
    r3d->SparseClearEnabled = false;
    r3d->SparseClearStateValid = false;

    std::vector<Frame> frames;
    if (!readInput(frames))
    {
        std::fprintf(stderr, "render-oracle: malformed input\n");
        return 1;
    }
    std::vector<u8> image;
    if (!loadVram(nds.GPU, image))
    {
        std::fprintf(stderr, "render-oracle: bad VRAM image\n");
        return 1;
    }

    // The Reset() buffer state, plus a zeroed stencil buffer (which Reset()
    // leaves as it was).
    std::memset(r3d->ColorBuffer, 0, sizeof(r3d->ColorBuffer));
    std::memset(r3d->DepthBuffer, 0, sizeof(r3d->DepthBuffer));
    std::memset(r3d->AttrBuffer, 0, sizeof(r3d->AttrBuffer));
    std::memset(r3d->StencilBuffer, 0, sizeof(r3d->StencilBuffer));
    r3d->PrevIsShadowMask = false;

    for (const Frame& fr : frames)
    {
        gpu3d.RenderDispCnt = fr.dispcnt;
        gpu3d.RenderAlphaRef = static_cast<u8>(fr.alpharef);
        gpu3d.RenderClearAttr1 = fr.clear1;
        gpu3d.RenderClearAttr2 = fr.clear2;
        gpu3d.RenderFogColor = fr.fogcolor;
        gpu3d.RenderFogOffset = fr.fogoffset;
        gpu3d.RenderFogShift = fr.fogshift;
        gpu3d.RenderXPos = static_cast<u16>(fr.xpos);
        std::memcpy(gpu3d.RenderFogDensityTable, fr.fog, sizeof(fr.fog));
        std::memcpy(gpu3d.RenderEdgeTable, fr.edge, sizeof(fr.edge));
        std::memcpy(gpu3d.RenderToonTable, fr.toon, sizeof(fr.toon));
        gpu3d.RenderFrameIdentical = false;
        gpu3d.AbortFrame = false;

        std::vector<Polygon> polygons(fr.polys.size());
        std::vector<std::array<Vertex, 10>> vertices(fr.polys.size());
        std::vector<Polygon*> pointers(fr.polys.size());
        for (size_t i = 0; i < fr.polys.size(); ++i)
        {
            const Poly& q = fr.polys[i];
            Polygon& p = polygons[i];
            p.NumVertices = q.n;
            p.Attr = q.attr;
            p.TexParam = q.texparam;
            p.TexPalette = q.texpal;
            p.Degenerate = q.degenerate != 0;
            p.FacingView = q.facing != 0;
            p.Translucent = q.translucent != 0;
            p.IsShadowMask = q.shadowmask != 0;
            p.IsShadow = q.shadow != 0;
            p.Type = q.type;
            p.WBuffer = q.wbuffer != 0;
            p.VTop = q.vtop;
            p.VBottom = q.vbottom;
            p.YTop = q.ytop;
            p.YBottom = q.ybottom;
            p.XTop = q.xtop;
            p.XBottom = q.xbottom;
            p.SortKey = q.sortkey;
            for (u32 v = 0; v < q.n; ++v)
            {
                Vertex& vert = vertices[i][v];
                const Vert& src = q.verts[v];
                vert.FinalPosition[0] = src.x;
                vert.FinalPosition[1] = src.y;
                vert.FinalColor[0] = src.r;
                vert.FinalColor[1] = src.g;
                vert.FinalColor[2] = src.b;
                vert.TexCoords[0] = static_cast<s16>(src.s);
                vert.TexCoords[1] = static_cast<s16>(src.t);
                p.Vertices[v] = &vert;
                p.FinalZ[v] = src.z;
                p.FinalW[v] = src.w;
            }
            pointers[i] = &p;
        }

        r3d->RenderFrame(pointers.data(), static_cast<u32>(pointers.size()));

        if (std::memcmp(nds.GPU.VRAMFlat_Texture, image.data(), TextureBytes) != 0 ||
            std::memcmp(nds.GPU.VRAMFlat_TexPal, image.data() + TextureBytes, PaletteBytes) != 0)
        {
            std::fprintf(stderr, "render-oracle: flat VRAM differs from the image\n");
            return 1;
        }

        for (int y = 0; y < 192; ++y)
            std::fwrite(r3d->GetLine(y), sizeof(u32), 256, stdout);
        writeLayer(r3d->ColorBuffer);
        writeLayer(r3d->DepthBuffer);
        writeLayer(r3d->AttrBuffer);
        writeLayer(r3d->ColorBuffer + SoftRenderer3D::BufferSize);
        writeLayer(r3d->DepthBuffer + SoftRenderer3D::BufferSize);
        writeLayer(r3d->AttrBuffer + SoftRenderer3D::BufferSize);
    }
    return 0;
}
