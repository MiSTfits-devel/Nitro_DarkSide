// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Truffle
//
// Polygon-pipeline oracle for Nds.Gpu3D.Polygon.
//
//   nds_gx3d_polygon_oracle directed            the directed cases
//   nds_gx3d_polygon_oracle random SEED FRAMES  seeded random frames
//
// Drives the production GPU3D through its real command path: every command
// is pushed into CmdPIPE and run by GPU3D::ExecuteCommand, so BEGIN_VTXS,
// VTX_16 (SubmitVertex's assembly, SubmitPolygon, clipping, polygon/vertex
// RAM), SWAP_BUFFERS and GPU3D::VBlank are the vendored code, untouched.
//
// The one shortcut is the clip matrix: instead of building it from
// projection and position matrices, the oracle writes GPU3D::ClipMatrix
// directly and leaves ClipMatrixDirty false, so UpdateClipMatrix keeps it. A
// "clip-space vertex" (X, Y, Z, W) is a VTX_16 of (0, 0, 0) under a matrix
// whose translation row is (X, Y, Z, W): Position = (0x1000 * M[12+i]) >> 12
// = M[12+i] exactly. Other vertices use general random matrices.
//
// Output, one record per line (the model gate reads it, see
// clash/test/PolygonCheck.hs):
//
//   B p                    BEGIN_VTXS p                         (GeBegin)
//   V x y z w r g b s t attr tp tpal vp0..vp5 zdw  np nv pp vsc vsf
//                          one SubmitVertex (GeVertex): the ClipVertex and
//                          PolyState it ran with, then NumPolygons,
//                          NumVertices, PolygonPipeline, VertexSlotCounter
//                          and VertexSlotsFree after the command
//   E                      END_VTXS                             (GeEnd)
//   S p                    SWAP_BUFFERS p                       (GeSwap)
//   A                      DISP3DCNT write acknowledging bit 13 (RAM overflow)
//   D                      a dump of the current bank follows:
//   C np nv ovf bank flushreq flushattr
//   P gidx n ref*n z*n w*n  wbuf attr tp tpal degen facing transl smask shadow
//                          type vtop vbot ytop ybot xtop xbot sortkey
//   X gidx x y z w r g b s t clipped fx fy fr fg fb
//   VB swapped n           GPU3D::VBlank; n sorted render polygons follow:
//   L gidx n (fx fy fr fg fb s t)*n z*n w*n  wbuf attr ... sortkey
//
// gidx is the index into PolygonRAM[4096] / VertexRAM[12288] (both banks).
// The ClipVertex of each V line is computed here with SubmitVertex's own
// transform helper and arithmetic, and checked against TempVertexBuffer
// after the command; a mismatch aborts the oracle.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <set>
#include <type_traits>
#include <utility>
#include <vector>

#include "NDS.h"
#include "GPU.h"
#include "GPU3D.h"
#include "NDS4MiSTer_GXVertexTransform.h"
#include "Platform.h"

using namespace melonDS;

namespace
{

struct Rng
{
    u64 s;
    // The state is a hash of the seed: splitmix streams of nearby raw seeds
    // would be the same stream shifted by a few draws.
    explicit Rng(u64 seed) : s(0)
    {
        s = seed;
        s = next() ^ 0x5DEECE66Dull;
        s = next();
    }
    u64 next()
    {
        u64 z = (s += 0x9E3779B97F4A7C15ull);
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }
    u32 word() { return static_cast<u32>(next() >> 32); }
    // uniform in [lo, hi]
    s64 range(s64 lo, s64 hi)
    {
        return lo + static_cast<s64>(next() % static_cast<u64>(hi - lo + 1));
    }
    bool chance(int percent) { return range(0, 99) < percent; }
    double unit() { return static_cast<double>(next() >> 11) / 9007199254740992.0; }
    double sym() { return unit() * 2.0 - 1.0; }
};

class Driver
{
public:
    Driver(GPU3D& gpu, std::FILE* f) : g(gpu), out(f) {}

    GPU3D& g;
    std::FILE* out;
    u64 vertices = 0;

    using Entry = std::remove_cv_t<std::remove_reference_t<
        decltype(std::declval<GPU3D&>().CmdPIPE.Peek())>>;

    void exec(u8 cmd, u32 param)
    {
        Entry e;
        e._contents = 0;
        e.Command = cmd;
        e.Param = param;
        g.CmdPIPE.Write(e);
        g.ExecuteCommand();
        if (!g.CmdPIPE.IsEmpty() || g.ExecParamCount > 1)
        {
            std::fprintf(stderr, "polygon-oracle: command pipe out of step\n");
            std::exit(2);
        }
    }

    void attr(u32 v) { exec(0x29, v); }
    void texParam(u32 v) { exec(0x2A, v); }
    void texPal(u32 v) { exec(0x2B, v); }
    void viewport(u32 x0, u32 y0, u32 x1, u32 y1)
    {
        exec(0x60, (x0 & 0xFF) | ((y0 & 0xFF) << 8) | ((x1 & 0xFF) << 16) | ((y1 & 0xFF) << 24));
    }
    void zeroDot(u32 v) { g.Write32(0x04000610, v); }
    void color(u32 rgb15) { exec(0x20, rgb15); }
    void color(u32 r, u32 gg, u32 b) { color((r & 31) | ((gg & 31) << 5) | ((b & 31) << 10)); }
    void texCoord(s32 s, s32 t)
    {
        exec(0x22, (static_cast<u32>(s) & 0xFFFF) | (static_cast<u32>(t) << 16));
    }
    void begin(u32 p)
    {
        exec(0x40, p);
        std::fprintf(out, "B %u\n", p);
    }
    void end()
    {
        exec(0x41, 0);
        std::fprintf(out, "E\n");
    }
    void swap(u32 p)
    {
        exec(0x50, p);
        std::fprintf(out, "S %u\n", p);
    }
    void ack()
    {
        g.Write32(0x04000060, 1u << 13);
        std::fprintf(out, "A\n");
    }

    void matrix(const s32* m)
    {
        std::memcpy(g.ClipMatrix, m, sizeof(g.ClipMatrix));
        g.ClipMatrixDirty = false;
    }

    // A VTX_16 under the current clip matrix.
    void vtx(s16 x, s16 y, s16 z)
    {
        // SubmitVertex's transform, colour and texture coordinates.
        s32 vertex[4] = {x, y, z, 0x1000};
        s32 pos[4];
        NDS4MiSTerGXTransformVertex4(vertex, g.ClipMatrix, pos);
        s32 col[3];
        for (int i = 0; i < 3; ++i) col[i] = (g.VertexColor[i] << 12) + 0xFFF;
        s16 tc[2];
        if ((g.TexParam >> 30) == 3)
        {
            tc[0] = (((s64)vertex[0]*g.TexMatrix[0] + (s64)vertex[1]*g.TexMatrix[4] + (s64)vertex[2]*g.TexMatrix[8]) >> 24) + g.RawTexCoords[0];
            tc[1] = (((s64)vertex[0]*g.TexMatrix[1] + (s64)vertex[1]*g.TexMatrix[5] + (s64)vertex[2]*g.TexMatrix[9]) >> 24) + g.RawTexCoords[1];
        }
        else
        {
            tc[0] = g.TexCoords[0];
            tc[1] = g.TexCoords[1];
        }
        const u32 attr = g.CurPolygonAttr, tp = g.TexParam, tpal = g.TexPalette;
        const u32 zdw = g.ZeroDotWLimit;
        u32 vp[6];
        std::memcpy(vp, g.Viewport, sizeof(vp));

        exec(0x23, (static_cast<u32>(x) & 0xFFFF) | (static_cast<u32>(y) << 16));
        exec(0x23, static_cast<u32>(z) & 0xFFFF);

        bool found = false;
        for (const Vertex& t : g.TempVertexBuffer)
            if (std::memcmp(t.Position, pos, sizeof(pos)) == 0 &&
                std::memcmp(t.Color, col, sizeof(col)) == 0 &&
                t.TexCoords[0] == tc[0] && t.TexCoords[1] == tc[1] && !t.Clipped)
                found = true;
        if (!found)
        {
            std::fprintf(stderr, "polygon-oracle: ClipVertex replica differs from SubmitVertex\n");
            std::exit(2);
        }

        std::fprintf(out, "V %d %d %d %d %d %d %d %d %d %u %u %u %u %u %u %u %u %u %u %u %u %d %d %u\n",
            pos[0], pos[1], pos[2], pos[3], col[0], col[1], col[2], tc[0], tc[1],
            attr, tp, tpal, vp[0], vp[1], vp[2], vp[3], vp[4], vp[5], zdw,
            g.NumPolygons, g.NumVertices, g.PolygonPipeline, g.VertexSlotCounter,
            g.VertexSlotsFree);
        ++vertices;
    }

    // A vertex at clip-space (X, Y, Z, W) exactly.
    void clip(s32 X, s32 Y, s32 Z, s32 W)
    {
        s32 m[16] = {};
        m[12] = X; m[13] = Y; m[14] = Z; m[15] = W;
        matrix(m);
        vtx(0, 0, 0);
    }

    u32 vref(const Vertex* v) const { return static_cast<u32>(v - &g.VertexRAM[0]); }
    u32 pref(const Polygon* p) const { return static_cast<u32>(p - &g.PolygonRAM[0]); }

    void polyTail(const Polygon* p)
    {
        for (u32 i = 0; i < p->NumVertices; ++i) std::fprintf(out, " %d", p->FinalZ[i]);
        for (u32 i = 0; i < p->NumVertices; ++i) std::fprintf(out, " %d", p->FinalW[i]);
        std::fprintf(out, " %d %u %u %u %d %d %d %d %d %d %u %u %d %d %d %d %u\n",
            p->WBuffer ? 1 : 0, p->Attr, p->TexParam, p->TexPalette,
            p->Degenerate ? 1 : 0, p->FacingView ? 1 : 0, p->Translucent ? 1 : 0,
            p->IsShadowMask ? 1 : 0, p->IsShadow ? 1 : 0, p->Type,
            p->VTop, p->VBottom, p->YTop, p->YBottom, p->XTop, p->XBottom, p->SortKey);
    }

    void vertexLine(u32 gidx)
    {
        const Vertex& v = g.VertexRAM[gidx];
        std::fprintf(out, "X %u %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n", gidx,
            v.Position[0], v.Position[1], v.Position[2], v.Position[3],
            v.Color[0], v.Color[1], v.Color[2], v.TexCoords[0], v.TexCoords[1],
            v.Clipped ? 1 : 0, v.FinalPosition[0], v.FinalPosition[1],
            v.FinalColor[0], v.FinalColor[1], v.FinalColor[2]);
    }

    void dump()
    {
        std::fprintf(out, "D\nC %u %u %u %u %u %u\n", g.NumPolygons, g.NumVertices,
            (g.DispCnt >> 13) & 1, g.CurRAMBank, g.FlushRequest, g.FlushAttributes);
        const u32 vbase = vref(g.CurVertexRAM);
        std::set<u32> extra;
        for (u32 i = 0; i < g.NumPolygons; ++i)
        {
            const Polygon* p = &g.CurPolygonRAM[i];
            std::fprintf(out, "P %u %u", pref(p), p->NumVertices);
            for (u32 k = 0; k < p->NumVertices; ++k)
            {
                const u32 r = vref(p->Vertices[k]);
                std::fprintf(out, " %u", r);
                if (r < vbase || r >= vbase + g.NumVertices) extra.insert(r);
            }
            polyTail(p);
        }
        for (u32 i = 0; i < g.NumVertices; ++i) vertexLine(vbase + i);
        for (u32 r : extra) vertexLine(r);
    }

    void vblank()
    {
        dump();
        const bool swapping = g.FlushRequest != 0;
        g.VBlank();
        if (!swapping)
        {
            std::fprintf(out, "VB 0 0\n");
            return;
        }
        std::fprintf(out, "VB 1 %u\n", g.RenderNumPolygons);
        for (u32 i = 0; i < g.RenderNumPolygons; ++i)
        {
            const Polygon* p = g.RenderPolygonRAM[i];
            std::fprintf(out, "L %u %u", pref(p), p->NumVertices);
            for (u32 k = 0; k < p->NumVertices; ++k)
            {
                const Vertex* v = p->Vertices[k];
                std::fprintf(out, " %d %d %d %d %d %d %d", v->FinalPosition[0],
                    v->FinalPosition[1], v->FinalColor[0], v->FinalColor[1],
                    v->FinalColor[2], v->TexCoords[0], v->TexCoords[1]);
            }
            polyTail(p);
        }
    }
};

// ---------------------------------------------------------------- directed

constexpr s32 U = 0x1000;           // a typical W
constexpr u32 ShowBoth = 0x001F00C0; // alpha 31, both faces drawn

void tri(Driver& d, const s32 (&a)[4], const s32 (&b)[4], const s32 (&c)[4])
{
    d.clip(a[0], a[1], a[2], a[3]);
    d.clip(b[0], b[1], b[2], b[3]);
    d.clip(c[0], c[1], c[2], c[3]);
}

void quad(Driver& d, const s32 (&a)[4], const s32 (&b)[4], const s32 (&c)[4], const s32 (&e)[4])
{
    tri(d, a, b, c);
    d.clip(e[0], e[1], e[2], e[3]);
}

void frame(Driver& d, u32 swapParam = 0)
{
    d.swap(swapParam);
    d.vblank();
}

void directed(Driver& d)
{
    d.viewport(0, 0, 255, 191);
    d.attr(ShowBoth);
    d.color(31, 16, 0);

    // A vertex before any BEGIN_VTXS: mode 0 from reset.
    d.clip(-U / 2, -U / 2, 0, U);
    d.clip(U / 2, -U / 2, 0, U);
    d.clip(0, U / 2, 0, U);

    // 1. Every polygon mode, all inside.
    d.begin(0);
    tri(d, {-U/2, -U/2, 0, U}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});
    tri(d, {-U/4, -U/4, U/2, U}, {U/4, -U/3, -U/2, U}, {0, U/5, 0, U});
    d.end();
    d.begin(1);
    quad(d, {-U/2, -U/2, 0, U}, {U/2, -U/2, 0, U}, {U/2, U/2, 0, U}, {-U/2, U/2, 0, U});
    quad(d, {-U/3, -U/2, 100, U}, {U/2, -U/3, 0, U*2}, {U/3, U/2, 0, U}, {-U/2, U/3, -100, U});
    d.end();
    d.begin(2);
    for (int i = 0; i < 7; ++i)
        d.clip(-U/2 + i * U/8, (i & 1) ? U/3 : -U/3, i * 64, U + i * 16);
    d.end();
    d.begin(3);
    for (int i = 0; i < 8; ++i)
        d.clip(-U/2 + (i >> 1) * U/4, (i & 1) ? U/3 : -U/3, -i * 64, U);
    d.end();
    d.dump();
    frame(d);

    // 2. Each plane: one, two and three vertices outside, triangles and quads.
    d.attr(ShowBoth | (1u << 12));
    d.begin(0);
    for (int comp = 0; comp < 3; ++comp)
        for (int sign = -1; sign <= 1; sign += 2)
            for (int nout = 1; nout <= 3; ++nout)
            {
                s32 v[3][4] = {{-U/2, -U/2, 0, U}, {U/2, -U/2, 0, U}, {0, U/2, 0, U}};
                for (int k = 0; k < nout; ++k) v[k][comp] = sign * (U + U/2 + k * 100);
                tri(d, {v[0][0], v[0][1], v[0][2], v[0][3]},
                       {v[1][0], v[1][1], v[1][2], v[1][3]},
                       {v[2][0], v[2][1], v[2][2], v[2][3]});
            }
    d.begin(1);
    for (int comp = 0; comp < 3; ++comp)
        for (int sign = -1; sign <= 1; sign += 2)
        {
            s32 v[4][4] = {{-U/2, -U/2, 0, U}, {U/2, -U/2, 0, U}, {U/2, U/2, 0, U}, {-U/2, U/2, 0, U}};
            v[1][comp] = sign * 3 * U;
            quad(d, {v[0][0], v[0][1], v[0][2], v[0][3]}, {v[1][0], v[1][1], v[1][2], v[1][3]},
                    {v[2][0], v[2][1], v[2][2], v[2][3]}, {v[3][0], v[3][1], v[3][2], v[3][3]});
        }
    // on-plane vertices (comp == +-W exactly are inside)
    quad(d, {-U, -U, -U, U}, {U, -U, U, U}, {U, U, 0, U}, {-U, U, 0, U});
    d.dump();
    frame(d);

    // 3. Corners: two and three planes at once, a polygon larger than the view.
    d.begin(0);
    tri(d, {-3*U, -3*U, 0, U}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});
    tri(d, {3*U, 3*U, 3*U, U}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});
    tri(d, {-3*U, 3*U, -3*U, U}, {3*U, -3*U, 0, U}, {0, U/2, 0, U});
    d.begin(1);
    quad(d, {-4*U, -4*U, 0, U}, {4*U, -4*U, 0, U}, {4*U, 4*U, 0, U}, {-4*U, 4*U, 0, U});
    quad(d, {-4*U, -4*U, -4*U, U}, {4*U, -4*U, 4*U, U}, {4*U, 4*U, 4*U, U}, {-4*U, 4*U, -4*U, U});
    // twisted (bow-tie) quads; the last three clip to more than ten vertices
    // and drop the excess (MaxClipVertices)
    quad(d, {-5*U, 0, 0, U}, {5*U, U/2, 5*U, U}, {-5*U, -U/2, -5*U, U}, {5*U, 0, 0, U});
    quad(d, {0, -5*U, 5*U, U}, {U/3, 5*U, -5*U, U}, {-5*U, -U/3, 5*U, U}, {5*U, U/4, -5*U, U});
    quad(d, {-6*U, 6*U, 6*U, U}, {6*U, -6*U, -6*U, U}, {6*U, 6*U, -6*U, U}, {-6*U, -6*U, 6*U, U});
    quad(d, {-U/2, -3*U/2, 3*U/2, U}, {-3*U/2, 3*U, -3*U/2, U}, {U/2, U/2, 3*U/2, U}, {3*U/2, U/2, -3*U, U});
    quad(d, {-U/2, -U/2, 3*U, U}, {-3*U, 3*U/2, -3*U/2, U}, {-3*U, -3*U, 3*U, U}, {3*U, U/2, -3*U, U});
    quad(d, {-3*U/2, 3*U/2, -U/2, U}, {3*U, -U/2, -U/2, U}, {-3*U/2, 3*U/2, U/2, U}, {0, -3*U, 3*U/2, U});
    d.dump();
    frame(d);

    // 4. Near and far: far rejected without attribute bit 12, clipped with it.
    for (u32 far = 0; far < 2; ++far)
    {
        d.attr(ShowBoth | (far << 12));
        d.begin(0);
        tri(d, {-U/2, -U/2, 2*U, U}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});
        tri(d, {-U/2, -U/2, -2*U, U}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});
        tri(d, {-U/2, -U/2, 2*U, U}, {U/2, -U/2, -2*U, U}, {0, U/2, 0, U});
        tri(d, {-U/2, -U/2, 2*U, U}, {U/2, -U/2, 2*U, U}, {0, U/2, 2*U, U});
        d.begin(2);
        tri(d, {-U/2, -U/2, 0, U}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});
        d.clip(U/2, U/2, 3*U, U);   // far: rejected, or clipped
        d.clip(U, U/2, 0, U);
        d.end();
    }
    d.dump();
    frame(d);

    // 5. Strips and clipping: shared vertices that were clipped, and the
    //    two-vertex polygon left when the far plane rejects a reusing strip
    //    polygon (clipstart == 2).
    d.attr(ShowBoth);
    d.begin(2);
    d.clip(-U/2, -U/2, 0, U);
    d.clip(-U/2, U/2, 0, U);
    d.clip(0, -U/2, 0, U);
    d.clip(0, U/2, 2*U, U);     // far, bit 12 clear: Z pass returns 0, Y pass 2
    d.clip(U/2, -U/2, 0, U);
    d.clip(U/2, U/2, 0, U);
    d.clip(3*U, -U/2, 0, U);    // right plane
    d.clip(3*U, U/2, 0, U);
    d.clip(U, U/3, 0, U);
    d.end();
    d.begin(2);                 // triangle with two vertices out: 3 vertices, 2 clipped
    d.clip(0, 0, 0, U);
    d.clip(3*U, -U/4, 0, U);
    d.clip(3*U, U/4, 0, U);
    d.clip(U/2, U/2, 0, U);
    d.clip(-U/2, U/2, 0, U);
    d.end();
    d.begin(3);
    for (int i = 0; i < 10; ++i)
        d.clip(-U + (i >> 1) * U/2 + ((i == 5) ? 3*U : 0), (i & 1) ? U/2 : -U/2, 0, U);
    d.end();
    d.attr(ShowBoth | (1u << 12));
    d.begin(3);
    d.clip(-U/2, -U/2, 0, U);
    d.clip(-U/2, U/2, 0, U);
    d.clip(0, -U/2, 0, U);
    d.clip(0, U/2, 0, U);
    d.clip(U/2, -U/2, 5*U, U);  // far, kept: clipped into the next quad
    d.clip(U/2, U/2, 0, U);
    d.clip(U, -U/2, 0, U);
    d.clip(U, U/2, 0, U);
    d.end();
    // culled polygon in the middle of a strip breaks reuse
    d.attr(0x001F0080);
    d.begin(2);
    for (int i = 0; i < 6; ++i)
        d.clip(-U/2 + i * U/6, (i & 1) ? U/2 : -U/2, 0, U);
    d.clip(U/2, U/2, 0, U);     // repeats: dot 0
    d.end();
    // END_VTXS in the middle does nothing; the strip continues
    d.attr(ShowBoth);
    d.begin(2);
    tri(d, {-U/2, -U/2, 0, U}, {-U/2, U/2, 0, U}, {0, -U/2, 0, U});
    d.end();
    d.clip(0, U/2, 0, U);
    d.clip(U/2, -U/2, 0, U);
    // an incomplete list, then a new one
    d.begin(0);
    d.clip(0, 0, 0, U);
    d.clip(U/2, 0, 0, U);
    d.begin(1);
    quad(d, {-U/2, -U/2, 0, U}, {U/2, -U/2, 0, U}, {U/2, U/2, 0, U}, {-U/2, U/2, 0, U});
    d.dump();
    frame(d);

    // 6. The 1-dot rule.
    d.attr(ShowBoth);
    d.begin(0);
    tri(d, {100, 100, 0, 0x200000}, {101, 100, 5, 0x200000}, {100, 101, -5, 0x200000});
    d.zeroDot(0x10);            // limit 0x21FF
    tri(d, {100, 100, 0, 0x200000}, {101, 100, 5, 0x200000}, {100, 101, -5, 0x200000});
    tri(d, {100, 100, 0, 0x2000}, {101, 100, 5, 0x200000}, {100, 101, -5, 0x200000});
    tri(d, {100, 100, 0, 0x21FF}, {100, 100, 5, 0x2200}, {100, 100, -5, 0x2200});
    tri(d, {100, 100, 0, 0x2200}, {100, 100, 5, 0x2200}, {100, 100, -5, 0x2200});
    tri(d, {0x10000, 100, 0, 0x200000}, {101, 100, 5, 0x200000}, {100, 101, -5, 0x200000});
    d.attr(ShowBoth | (1u << 13));
    d.begin(0);
    tri(d, {100, 100, 0, 0x200000}, {101, 100, 5, 0x200000}, {100, 101, -5, 0x200000});
    d.zeroDot(0x7FFF);
    d.dump();
    frame(d);

    // 7. Culling: every attribute combination, both windings and dot == 0.
    for (u32 cull = 0; cull < 4; ++cull)
    {
        d.attr(0x001F0000 | (cull << 6));
        d.begin(0);
        tri(d, {-U/2, -U/2, 0, U}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});
        tri(d, {-U/2, -U/2, 0, U}, {0, U/2, 0, U}, {U/2, -U/2, 0, U});
        tri(d, {-U/2, -U/2, 0, U}, {0, 0, 0, U}, {U/2, U/2, 0, U});
        d.begin(1);
        quad(d, {-U/2, -U/2, 0, U}, {U/2, -U/2, 0, U}, {U/2, U/2, 0, U}, {-U/2, U/2, 0, U});
        quad(d, {-U/2, -U/2, 0, U}, {-U/2, U/2, 0, U}, {U/2, U/2, 0, U}, {U/2, -U/2, 0, U});
    }
    d.dump();
    frame(d, 2);                // next frame is W-buffered

    // 8. W- vs Z-buffer, W normalisation widths, special W.
    d.attr(ShowBoth | (1u << 12));
    for (int wb = 0; wb < 2; ++wb)
    {
        d.begin(0);
        const s32 ws[] = {1, 0xF, 0x10, 0xFF, 0x1000, 0xFFFF, 0x10000, 0x12345, 0xFFFFFF,
                          0x1000000, 0x1000010, 0x7FFFFFFF};
        for (s32 w : ws)
            tri(d, {-w/2, -w/2, w/3, w}, {w/2, -w/2, -w/3, w}, {0, w/2, 0, w});
        tri(d, {-U/2, -U/2, 0, 0x10}, {U/2, -U/2, 0x7FFF, 0x12345}, {0, U/2, -0x7FFF, 0xFFFFFF});
        tri(d, {0, 0, 0, 0}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});          // W = 0
        tri(d, {0, 0, 0, -U}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});         // W < 0
        tri(d, {0, 0, 0, INT32_MIN}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});  // W = -2^31
        tri(d, {0, 0, 0x1000000, 0x1000010}, {U/2, -U/2, 0, U}, {0, U/2, 0, U}); // |Z| > masked W
        tri(d, {0, 0, -0x1000000, 0x1000010}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});
        // lines: two or three equal clip positions
        tri(d, {-U/2, -U/2, 0, U}, {-U/2, -U/2, 0, U}, {U/2, U/2, 0, U});
        tri(d, {-U/2, -U/2, 0, U}, {U/2, U/2, 0, U}, {U/2, U/2, 0, U});
        tri(d, {U/3, U/3, 0, U}, {-U/2, -U/2, 0, U}, {U/3, U/3, 0, U});
        tri(d, {U/3, U/3, 0, U}, {U/3, U/3, 0, U}, {U/3, U/3, 0, U});
        d.dump();
        frame(d, wb ? 0 : 2);
    }
    frame(d);

    // 9. Translucency, shadows and sorting.
    const u32 alphas[] = {0, 1, 15, 30, 31};
    const u32 fmts[] = {0, 1, 2, 3, 6, 7};
    for (u32 manual = 0; manual < 2; ++manual)
    {
        for (u32 a : alphas)
            for (u32 f : fmts)
            {
                d.attr(0x000000C0 | (a << 16) | (((a * 7 + f) & 0x3F) << 24));
                d.texParam(f << 26);
                d.begin(0);
                const s32 y0 = -U + static_cast<s32>((a * 13 + f * 29) % 32) * U / 20;
                tri(d, {-U/2, y0, 0, U}, {U/2, y0, 0, U}, {0, y0 + U/3, 0, U});
                tri(d, {-U/2, y0, 0, U}, {U/2, y0, 0, U}, {0, y0 + U/3, 0, U}); // equal keys
            }
        d.texParam(0);
        for (u32 id = 0; id < 3; ++id)
            for (u32 mode = 0; mode < 4; ++mode)
            {
                d.attr(0x000F00C0 | (mode << 4) | (id << 24));
                d.begin(0);
                tri(d, {-U/2, -U/2, 0, U}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});
            }
        d.dump();
        frame(d, manual);
    }

    // 10. Viewports, texture parameters and texture-coordinate modes.
    d.attr(ShowBoth | (1u << 12));
    const u32 vps[][4] = {{0, 0, 255, 191}, {10, 20, 100, 150}, {200, 100, 50, 10},
                          {0, 0, 0, 0}, {255, 191, 255, 191}, {128, 0, 127, 255}};
    for (const auto& vp : vps)
    {
        d.viewport(vp[0], vp[1], vp[2], vp[3]);
        d.begin(1);
        quad(d, {-U, -U, 0, U}, {U, -U, 0, U}, {U, U, 0, U}, {-U, U, 0, U});
        quad(d, {-3*U, -U/2, 0, 0x20000}, {U/2, -3*U, 0, 0x20000}, {U, U, 0, 0x30000}, {-U, U, 0, 0x30000});
    }
    d.viewport(0, 0, 255, 191);
    for (u32 tg = 0; tg < 4; ++tg)
    {
        d.texParam(tg << 30 | 0x12345);
        d.texPal(0x1ABC);
        d.texCoord(-100 + tg * 50, 300 - tg * 7);
        d.begin(0);
        const s32 m[16] = {0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000};
        d.matrix(m);
        d.color(1, 2, 3);
        d.vtx(-0x800, -0x800, 0x100);
        d.color(31, 0, 31);
        d.texCoord(0x7FFF, -0x8000);
        d.vtx(0x2800, -0x800, -0x100);
        d.vtx(0, 0x2000, 0x7FFF);
    }
    d.texParam(0);
    d.dump();
    frame(d);

    // 11. 64-bit clip factors: plane distances that alias in 32 bits.
    d.attr(ShowBoth | (1u << 12));
    d.begin(0);
    tri(d, {0, 0, INT32_MAX, -1}, {0, 0, -1, INT32_MAX}, {0, 0x100, 0, U});
    tri(d, {0, 0, INT32_MIN + 1, -1}, {0, 0, 1, INT32_MAX}, {0x100, 0, 0, U});
    tri(d, {INT32_MAX, 0, 0, -1}, {-1, 0, 0, INT32_MAX}, {0, 0x100, 0, U});
    tri(d, {0, INT32_MIN + 1, 0, -1}, {0, 1, 0, INT32_MAX}, {0x100, 0, 0, U});
    tri(d, {0, 0, INT32_MAX, -1}, {0, 0, -1, INT32_MAX}, {0, 0, -2, INT32_MAX - 1});
    d.dump();
    frame(d);

    // 12. RAM limits: 2047 triangles (6141 vertices), a quad that does not
    //     fit (6145), a triangle that exactly fills both RAMs, one more.
    d.attr(ShowBoth);
    d.begin(0);
    for (int i = 0; i < 2047; ++i)
    {
        const s32 x = -U + (i % 64) * (U / 32), y = -U + (i / 64) * (U / 20);
        tri(d, {x, y, 0, U}, {x + 40, y, 0, U}, {x, y + 40, 0, U});
    }
    d.begin(1);
    quad(d, {-U/2, -U/2, 0, U}, {U/2, -U/2, 0, U}, {U/2, U/2, 0, U}, {-U/2, U/2, 0, U});
    d.begin(0);
    tri(d, {-U/2, -U/2, 0, U}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});
    tri(d, {-U/2, -U/2, 0, U}, {U/2, -U/2, 0, U}, {0, U/2, 0, U});
    d.dump();
    d.ack();
    frame(d);
    // vertex RAM first: clipped quads of eight vertices
    d.attr(ShowBoth | (1u << 12));
    d.begin(1);
    for (int i = 0; i < 800; ++i)
        quad(d, {-2*U, 0, 0, U}, {0, -2*U, 0, U}, {2*U, 0, 0, U}, {0, 2*U, 0, U});
    d.dump();
    frame(d);

    // 13. A strip continued across a swap without BEGIN_VTXS shares vertices
    //     with the other bank's polygon (and, after a second swap, with
    //     slots the new bank rewrites).
    d.attr(ShowBoth);
    d.begin(2);
    tri(d, {-U/2, -U/2, 0, U}, {-U/2, U/2, 0, U}, {-U/4, -U/2, 0, U});
    d.clip(-U/4, U/2, 0, U);
    frame(d);
    d.clip(0, -U/2, 0, U);
    d.clip(0, U/2, 0, U);
    d.clip(3*U, -U/2, 0, U);     // clipped: copies instead of shared pointers
    frame(d);
    d.clip(U/4, U/2, 0, U);
    d.clip(U/2, -U/2, 0, U);
    d.begin(3);
    quad(d, {-U/2, -U/2, 0, U}, {-U/2, U/2, 0, U}, {-U/4, -U/2, 0, U}, {-U/4, U/2, 0, U});
    frame(d);
    d.clip(0, -U/2, 0, U);
    d.clip(0, U/2, 0, U);
    frame(d);
    frame(d);
    d.clip(U/4, -U/2, 0, U);
    d.clip(U/4, U/2, 0, U);
    d.dump();
    d.vblank();                  // no swap pending
    frame(d);
}

// ------------------------------------------------------------------ random

s32 wrap32(s64 v) { return static_cast<s32>(static_cast<u32>(static_cast<u64>(v))); }

s32 randomW(Rng& r)
{
    const int k = static_cast<int>(r.range(0, 99));
    if (k < 3) return 0;
    if (k < 8) return -static_cast<s32>(r.range(1, 0x20000));
    if (k < 14) return static_cast<s32>(r.range(1, 0xFF));
    if (k < 55) return static_cast<s32>(r.range(0x400, 0x8000));
    if (k < 80) return static_cast<s32>(r.range(0x8000, 0xFFFFFF));
    if (k < 93) return static_cast<s32>(r.range(0x1000000, 0x7FFFFFFF));
    return static_cast<s32>(r.word());
}

u32 randomAttr(Rng& r)
{
    u32 a = r.word() & 0x3F1FFFFF;
    if (r.chance(60)) a |= 0xC0;                  // mostly both faces
    if (r.chance(50)) a &= ~(0x1Fu << 16), a |= (r.chance(70) ? 31u : 0u) << 16;
    if (r.chance(15)) a |= 0x30;                  // shadow / shadow mask
    if (r.chance(10)) a &= ~(0x3Fu << 24);        // polygon ID 0
    if (r.chance(50)) a |= 1u << 12;              // keep far-plane crossers
    return a;
}

u32 randomTexParam(Rng& r)
{
    u32 t = r.word();
    if (r.chance(40)) t &= ~(3u << 30);
    return t;
}

struct Scene
{
    double cx, cy, cz, spread;
    s32 w;
    int style; // 0 clip-space, 1 matrix, 2 one-dot
    bool calm; // no wild W, on-plane, repeated or aliasing vertices
    s32 m[16];
};

void randomMatrix(Rng& r, s32* m)
{
    for (int i = 0; i < 16; ++i)
    {
        const int k = static_cast<int>(r.range(0, 9));
        if (k < 5) m[i] = static_cast<s32>(r.range(-0x2000, 0x2000));
        else if (k < 8) m[i] = static_cast<s32>(r.range(-0x80000, 0x80000));
        else if (k < 9) m[i] = 0;
        else m[i] = static_cast<s32>(r.word());
    }
    if (r.chance(70))
        m[15] = static_cast<s32>(r.range(0x400, 0x100000)); // a positive W bias
}

void randomVertex(Driver& d, Rng& r, const Scene& sc, s32 (&last)[4], bool& haveLast)
{
    if (!sc.calm && haveLast && r.chance(4))
    {
        d.clip(last[0], last[1], last[2], last[3]); // a repeated position (lines, dot 0)
        return;
    }
    if (r.chance(5)) d.color(r.word() & 0x7FFF);
    if (r.chance(5)) d.texCoord(static_cast<s16>(r.word()), static_cast<s16>(r.word()));
    if (sc.style == 1)
    {
        d.matrix(sc.m);
        const s16 x = static_cast<s16>(r.word()), y = static_cast<s16>(r.word()),
                  z = static_cast<s16>(r.word());
        d.vtx(x, y, z);
        haveLast = false;
        return;
    }
    if (!sc.calm && haveLast && r.chance(2))
    {
        // Aliasing plane distances: W' - p*c' == W - p*c (mod 2^32), the
        // case where melonDS's 32-bit clip denominator is zero.
        const int ci = static_cast<int>(r.range(0, 2));
        const bool pos = r.chance(50);
        const u32 dist = pos ? static_cast<u32>(last[3]) - static_cast<u32>(last[ci])
                             : static_cast<u32>(last[3]) + static_cast<u32>(last[ci]);
        const s32 c = r.chance(50) ? static_cast<s32>(r.word())
                                   : static_cast<s32>(r.range(-0x10000, 0x10000));
        const s32 w = static_cast<s32>(pos ? dist + static_cast<u32>(c) : dist - static_cast<u32>(c));
        s32 v[4];
        for (int k = 0; k < 3; ++k)
            v[k] = r.chance(50) ? wrap32(static_cast<s64>(w * r.sym()))
                                : static_cast<s32>(r.word());
        v[ci] = c;
        v[3] = w;
        d.clip(v[0], v[1], v[2], v[3]);
        std::memcpy(last, v, sizeof(v));
        return;
    }
    s32 w = sc.w;
    if (sc.calm) w = wrap32(static_cast<s64>(w) + r.range(-(w / 8), w / 8));
    else if (r.chance(25)) w = randomW(r);
    else if (r.chance(50)) w = wrap32(static_cast<s64>(w) + r.range(-(std::abs(static_cast<s64>(w)) / 4) - 1, std::abs(static_cast<s64>(w)) / 4 + 1));
    const double aw = static_cast<double>(w);
    auto comp = [&](double c) {
        if (!sc.calm && r.chance(4)) return r.chance(50) ? w : wrap32(-static_cast<s64>(w)); // on a plane
        if (!sc.calm && r.chance(1)) return static_cast<s32>(r.word());
        const double v = aw * (c + sc.spread * r.sym());
        if (v > 9.2e18 || v < -9.2e18) return static_cast<s32>(r.word());
        return wrap32(static_cast<s64>(v));
    };
    s32 x, y, z;
    if (sc.style == 2)
    {
        x = wrap32(static_cast<s64>(aw * sc.cx));
        y = wrap32(static_cast<s64>(aw * sc.cy));
        if (r.chance(10)) x += 1;
        z = comp(sc.cz);
    }
    else
    {
        x = comp(sc.cx);
        y = comp(sc.cy);
        z = comp(sc.cz);
    }
    d.clip(x, y, z, w);
    last[0] = x; last[1] = y; last[2] = z; last[3] = w;
    haveLast = true;
}

void randomScene(Rng& r, Scene& sc)
{
    const int k = static_cast<int>(r.range(0, 99));
    sc.style = k < 70 ? 0 : (k < 90 ? 1 : 2);
    sc.calm = false;
    sc.cx = r.sym() * 1.4;
    sc.cy = r.sym() * 1.4;
    sc.cz = r.sym() * 1.4;
    const double spreads[] = {0.002, 0.05, 0.2, 0.6, 1.5, 4.0};
    sc.spread = spreads[r.range(0, 5)];
    sc.w = randomW(r);
    if (sc.style == 2)
    {
        sc.w = static_cast<s32>(r.range(0x100, 0xFFFFFF));
        sc.cx *= 0.5;
        sc.cy *= 0.5;
    }
    randomMatrix(r, sc.m);
}

void randomFrame(Driver& d, Rng& r, int frameNo)
{
    if (r.chance(20)) d.zeroDot(r.chance(50) ? static_cast<u32>(r.range(0, 0x80)) : (r.word() & 0x7FFF));
    if (r.chance(20))
        d.viewport(r.word(), r.word(), r.word(), r.word());
    else if (r.chance(30))
        d.viewport(0, 0, 255, 191);

    const bool overflow = r.chance(4);
    const int lists = overflow ? 1 : static_cast<int>(r.range(1, 24));
    for (int l = 0; l < lists; ++l)
    {
        d.attr(randomAttr(r));
        if (r.chance(60)) d.texParam(randomTexParam(r));
        if (r.chance(30)) d.texPal(r.word());
        const u32 mode = static_cast<u32>(r.range(0, 3));
        if (!(frameNo > 0 && l == 0 && r.chance(10))) // sometimes continue across the swap
            d.begin(mode | (r.chance(5) ? (r.word() & ~3u) : 0));
        Scene sc;
        randomScene(r, sc);
        if (overflow)
        {
            // Enough polygons to fill polygon RAM (small, inside) or vertex
            // RAM (large, every one clipped to many vertices).
            sc.style = 0;
            sc.calm = true;
            const bool big = r.chance(50);
            sc.cx = big ? 0.0 : r.sym() * 0.5;
            sc.cy = big ? 0.0 : r.sym() * 0.5;
            sc.cz = 0.0;
            sc.spread = big ? 2.5 : 0.05;
            sc.w = static_cast<s32>(r.range(0x400, 0x8000));
            d.attr(randomAttr(r) | 0x10C0); // both faces, keep far crossers
        }
        const int verts = overflow ? static_cast<int>(r.range(6000, 9000))
                                   : static_cast<int>(r.range(1, 48));
        s32 last[4] = {};
        bool haveLast = false;
        for (int v = 0; v < verts; ++v)
        {
            if (r.chance(2)) d.attr(randomAttr(r));         // latched only by BEGIN_VTXS
            if (r.chance(2)) d.texParam(randomTexParam(r)); // takes effect at once
            if (!overflow && r.chance(3)) randomScene(r, sc);
            randomVertex(d, r, sc, last, haveLast);
        }
        if (r.chance(80)) d.end();
    }
    if (r.chance(3)) d.ack();
    if (r.chance(5))
    {
        d.vblank(); // a VBlank with no swap pending
        return;
    }
    d.swap(r.word() & (r.chance(80) ? 3u : 0xFFFFFFFFu));
    d.vblank();
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        std::fprintf(stderr, "usage: nds_gx3d_polygon_oracle directed | random SEED FRAMES\n");
        return 1;
    }
    static char buffer[1 << 20];
    std::setvbuf(stdout, buffer, _IOFBF, sizeof(buffer));

    auto ndsHolder = std::make_unique<NDS>();
    GPU3D& gpu3d = ndsHolder->GPU.GPU3D;
    gpu3d.Reset();
    gpu3d.SetEnabled(true, true);
    gpu3d.SetHighResolutionCoordinatesEnabled(false);
    Driver d(gpu3d, stdout);

    if (std::strcmp(argv[1], "directed") == 0)
        directed(d);
    else if (std::strcmp(argv[1], "random") == 0 && argc == 4)
    {
        Rng r(std::strtoull(argv[2], nullptr, 0));
        const int frames = std::atoi(argv[3]);
        d.viewport(0, 0, 255, 191);
        for (int f = 0; f < frames; ++f) randomFrame(d, r, f);
    }
    else
    {
        std::fprintf(stderr, "polygon-oracle: bad arguments\n");
        return 1;
    }
    d.dump();
    std::fflush(stdout);
    std::fprintf(stderr, "polygon-oracle: %llu vertices\n",
        static_cast<unsigned long long>(d.vertices));
    return 0;
}
