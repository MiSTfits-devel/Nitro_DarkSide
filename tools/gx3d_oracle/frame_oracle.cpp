// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Truffle
//
// Multi-triangle depth-test oracle. Reads TRI/TRIZ/TRIZW lines, renders them in
// one production melonDS frame, and writes the 256x192 colour buffer to stdout.
// With ORACLE_DEPTH_OUT set, the 256x192 depth buffer is written there too.
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
// Oracle-only: expose the renderer's private depth buffer for comparison.
// Every header GPU3D_Soft.h pulls in is already included above, so the
// redefinition only touches the SoftRenderer3D declaration itself.
#define private public
#include "GPU3D_Soft.h"
#undef private
#include "GPU_Soft.h"

using namespace melonDS;

struct Tri
{
    s32 x[3];
    s32 y[3];
    s32 z[3];
    s32 w[3];
    u32 color;
    bool facing;
};

static bool readTri(Tri& tri)
{
    char kind[8];
    if (std::scanf("%7s", kind) != 1) return false;
    unsigned r, g, b;
    int face = 1;
    tri.w[0] = tri.w[1] = tri.w[2] = 0;
    if (std::strcmp(kind, "TRIZW") == 0)
    {
        if (std::scanf("%d %d %d %d %d %d %d %d %d %d %d %d %u %u %u %d",
                &tri.x[0], &tri.y[0], &tri.z[0], &tri.w[0],
                &tri.x[1], &tri.y[1], &tri.z[1], &tri.w[1],
                &tri.x[2], &tri.y[2], &tri.z[2], &tri.w[2],
                &r, &g, &b, &face) != 16)
            return false;
    }
    else if (std::strcmp(kind, "TRIZ") == 0)
    {
        if (std::scanf("%d %d %d %d %d %d %d %d %d %u %u %u %d",
                &tri.x[0], &tri.y[0], &tri.z[0],
                &tri.x[1], &tri.y[1], &tri.z[1],
                &tri.x[2], &tri.y[2], &tri.z[2],
                &r, &g, &b, &face) != 13)
            return false;
    }
    else if (std::strcmp(kind, "TRI") == 0)
    {
        if (std::scanf("%d %d %d %d %d %d %u %u %u %d",
                &tri.x[0], &tri.y[0], &tri.x[1], &tri.y[1],
                &tri.x[2], &tri.y[2], &r, &g, &b, &face) != 10)
            return false;
        tri.z[0] = 0;
        tri.z[1] = 0;
        tri.z[2] = 0;
    }
    else return false;

    tri.facing = face != 0;
    // Five bits per channel, matching how the vertex colour is unpacked below.
    tri.color = (r & 31) | ((g & 31) << 5) | ((b & 31) << 10);
    return true;
}

int main()
{
    auto ndsHolder = std::make_unique<NDS>();
    NDS& nds = *ndsHolder;
    auto softHolder = std::make_unique<SoftRenderer>(nds);
    SoftRenderer& soft = *softHolder;
    SoftRenderer3D* r3d = soft.Get3DRenderer();
    GPU3D& gpu3d = nds.GPU.GPU3D;

    u32 dispcnt = 0;
    if (const char* env = std::getenv("ORACLE_DISPCNT"))
        dispcnt = static_cast<u32>(std::strtoul(env, nullptr, 0));
    gpu3d.RenderDispCnt = dispcnt;
    gpu3d.RenderAlphaRef = 0;
    gpu3d.RenderClearAttr1 = 0;
    gpu3d.RenderClearAttr2 = 0x7FFF;
    gpu3d.RenderXPos = 0;

    std::vector<Tri> tris;
    Tri tri;
    while (readTri(tri)) tris.push_back(tri);

    std::vector<Polygon> polygons(tris.size());
    std::vector<std::array<Vertex, 3>> vertices(tris.size());
    std::vector<Polygon*> pointers(tris.size());

    for (size_t i = 0; i < tris.size(); ++i)
    {
        const Tri& t = tris[i];
        Polygon& p = polygons[i];
        auto& vs = vertices[i];
        p.NumVertices = 3;
        p.Attr = 31 << 16;
        p.TexParam = 0;
        p.TexPalette = 0;
        p.Degenerate = false;
        p.FacingView = t.facing;
        p.WBuffer = false;
        p.Translucent = false;
        p.IsShadowMask = false;
        p.IsShadow = false;
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
            vert.FinalColor[0] = ((t.color & 31) << 3);
            vert.FinalColor[1] = (((t.color >> 5) & 31) << 3);
            vert.FinalColor[2] = (((t.color >> 10) & 31) << 3);
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

    r3d->RenderFrame(pointers.data(), static_cast<int>(pointers.size()));
    for (u32 y = 0; y < 192; ++y)
        std::fwrite(r3d->GetLine(static_cast<int>(y)),
            sizeof(u32), 256, stdout);
    if (const char* path = std::getenv("ORACLE_DEPTH_OUT"))
    {
        std::FILE* f = std::fopen(path, "wb");
        if (!f) return 1;
        for (int y = 0; y < 192; ++y)
            std::fwrite(&r3d->DepthBuffer[SoftRenderer3D::FirstPixelOffset
                            + y * SoftRenderer3D::ScanlineWidth],
                sizeof(u32), 256, f);
        std::fclose(f);
    }
    return 0;
}
