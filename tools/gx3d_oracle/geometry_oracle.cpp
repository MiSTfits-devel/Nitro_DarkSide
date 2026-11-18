// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Truffle
//
// Geometry-engine oracle for the Clash model (Nds.Gpu3D.Geometry). Runs the
// production GPU3D command execution on directed and seeded random input
// streams and writes, after every input, the complete geometry state and the
// vertex SubmitVertex produced. No melonDS source is modified; private
// members are exposed to this translation unit only.
//
//   geometry_oracle directed
//   geometry_oracle random SEED STREAMS LENGTH
//
// An input is one whole GX command (opcode plus its CmdNumParams words, each
// pushed through GPU3D::CmdFIFOWrite and executed by GPU3D::ExecuteCommand,
// the same path a GXFIFO or command-port write takes), a DISP_1DOT_DEPTH
// write (GPU3D::Write32/Write16 at 0x04000610) or a GXSTAT acknowledge
// (bit 15 through Write16/Write32 at 0x04000600 or bit 7 through Write8 at
// 0x04000601). Each stream starts from a freshly constructed NDS with
// GPU3D::Reset and SetEnabled(true, true) (MMIO writes to the geometry range
// are ignored while geometry is disabled).
//
// Output: little-endian u32 words.
//   'STRM' id                                     stream start
//   'REC1' kind op n p[n]  STATE  nv [VERTEX]  polygonmode flushreq flushattr
//   'ENDS'                                        stream end
//   'ENDF' records                                file end
// kind: 0 command, 1 DISP_1DOT_DEPTH (p[0] is the value written, p[1] the
// write width form), 2 GXSTAT acknowledge (p[0] the write form, p[1] junk).
// STATE is dumpState below (the checker builds the same list from the
// model). VERTEX is the TempVertexBuffer entry SubmitVertex stored: the
// entry index before the call, except that a quad strip moves its fourth
// vertex to entry 2 (SubmitPolygon never writes TempVertexBuffer); then the
// polygon state SubmitPolygon reads. flushreq/flushattr expose SWAP_BUFFERS;
// the oracle clears FlushRequest after each record (it only gates Run()).
// Result reads at 0x04000640-0x0400067F go through UpdateClipMatrix, which
// caches; the oracle restores ClipMatrix/ClipMatrixDirty around them so the
// dump records the cache exactly as command execution left it.
#include <algorithm>
#include <array>
#include <atomic>
#include <bitset>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <thread>
#include <tuple>
#include <unordered_map>
#include <utility>
#include <variant>
#include <vector>

// Oracle-only: reach GPU3D::CmdFIFOWrite and its entry type.
#define private public
#include "NDS.h"
#include "GPU.h"
#include "GPU3D.h"
#undef private
#include "Platform.h"

using namespace melonDS;

namespace
{

// GPU3D.cpp's CmdNumParams has internal linkage; this is a verbatim copy.
// Every group is checked to leave ExecParamCount at 0, so a wrong count
// cannot pass silently.
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

constexpr u32 TagStream = 0x5354524D;
constexpr u32 TagRecord = 0x52454331;
constexpr u32 TagStreamEnd = 0x454E4453;
constexpr u32 TagFileEnd = 0x454E4446;

std::vector<u32> outBuf;
u64 records = 0;

void put(u32 v)
{
    outBuf.push_back(v);
    if (outBuf.size() >= (1u << 20))
    {
        std::fwrite(outBuf.data(), sizeof(u32), outBuf.size(), stdout);
        outBuf.clear();
    }
}

void flushOut()
{
    std::fwrite(outBuf.data(), sizeof(u32), outBuf.size(), stdout);
    outBuf.clear();
    std::fflush(stdout);
}

struct In
{
    u32 kind;
    u32 op;
    std::vector<u32> p;
};

// --- random numbers -------------------------------------------------------

u64 rngState = 1;

u32 rnd()
{
    u64 x = rngState;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    rngState = x;
    return static_cast<u32>(x >> 16);
}

void seed(u64 s)
{
    rngState = 0x9E3779B97F4A7C15ULL ^ (s * 0xD1B54A32D192ED03ULL);
    if (rngState == 0) rngState = 1;
    for (int i = 0; i < 8; ++i) rnd();
}

u32 below(u32 n) { return rnd() % n; }
s32 range(s32 lo, s32 hi) { return lo + static_cast<s32>(below(static_cast<u32>(hi - lo + 1))); }
bool chance(u32 percent) { return below(100) < percent; }

u32 half2(s32 lo, s32 hi) { return (static_cast<u32>(lo) & 0xFFFF) | (static_cast<u32>(hi) << 16); }

// --- the run --------------------------------------------------------------

class Runner
{
public:
    void start(u32 id)
    {
        nds = std::make_unique<NDS>();
        g = &nds->GPU.GPU3D;
        g->Reset();
        g->SetEnabled(true, true);
        put(TagStream);
        put(id);
    }

    void end() { put(TagStreamEnd); nds.reset(); g = nullptr; }

    void run(const In& in)
    {
        put(TagRecord);
        put(in.kind);
        put(in.op);
        put(static_cast<u32>(in.p.size()));
        for (u32 v : in.p) put(v);

        const u32 idxBefore = g->VertexNumInPoly;
        const u32 numBefore = g->VertexNum;

        if (in.kind == 0)
        {
            u32 n = NumParams[in.op & 0xFF];
            if (n == 0) n = 1;
            for (u32 i = 0; i < n; ++i)
            {
                GPU3D::CmdFIFOEntry e {};
                e.Command = static_cast<u8>(in.op);
                e.Param = i < in.p.size() ? in.p[i] : 0;
                g->CmdFIFOWrite(e);
                g->ExecuteCommand();
            }
            if (g->ExecParamCount != 0 || !g->CmdPIPE.IsEmpty() || !g->CmdFIFO.IsEmpty())
            {
                std::fprintf(stderr, "geometry-oracle: command %02X left parameters pending\n", in.op);
                std::exit(1);
            }
        }
        else if (in.kind == 1)
        {
            if (in.p[1] == 0) g->Write32(0x04000610, in.p[0]);
            else g->Write16(0x04000610, static_cast<u16>(in.p[0]));
        }
        else
        {
            switch (in.p[0])
            {
            case 0: g->Write16(0x04000600, static_cast<u16>(0x8000 | (in.p[1] & 0x7FFF))); break;
            case 1: g->Write32(0x04000600, 0x8000 | (in.p[1] & 0x3FFF7FFF)); break;
            default: g->Write8(0x04000601, static_cast<u8>(0x80 | (in.p[1] & 0x7F))); break;
            }
        }

        dumpState();

        const bool vertex = g->VertexNum == numBefore + 1;
        put(vertex ? 1 : 0);
        if (vertex)
        {
            const u32 idx = (g->PolygonMode == 3 && idxBefore == 3) ? 2 : idxBefore;
            const Vertex& v = g->TempVertexBuffer[idx];
            for (int i = 0; i < 4; ++i) put(static_cast<u32>(v.Position[i]));
            for (int i = 0; i < 3; ++i) put(static_cast<u32>(v.Color[i]));
            put(static_cast<u32>(static_cast<s32>(v.TexCoords[0])));
            put(static_cast<u32>(static_cast<s32>(v.TexCoords[1])));
            put(g->CurPolygonAttr);
            put(g->TexParam);
            put(g->TexPalette);
            for (int i = 0; i < 6; ++i) put(g->Viewport[i]);
            put(g->ZeroDotWLimit);
        }
        put(g->PolygonMode);
        put(g->FlushRequest);
        put(g->FlushAttributes);
        g->FlushRequest = 0;
        ++records;
    }

private:
    static void putMat(const s32* m) { for (int i = 0; i < 16; ++i) put(static_cast<u32>(m[i])); }
    static void putS(s32 v) { put(static_cast<u32>(v)); }

    u64 stackHash() const
    {
        u64 h = 0xCBF29CE484222325ULL;
        auto mix = [&h](const s32* m) {
            for (int i = 0; i < 16; ++i)
            {
                h ^= static_cast<u32>(m[i]);
                h *= 0x100000001B3ULL;
            }
        };
        mix(g->ProjMatrixStack);
        mix(g->TexMatrixStack);
        for (int i = 0; i < 32; ++i) mix(g->PosMatrixStack[i]);
        for (int i = 0; i < 32; ++i) mix(g->VecMatrixStack[i]);
        return h;
    }

    void dumpState()
    {
        put(g->MatrixMode);
        putMat(g->ProjMatrix);
        putMat(g->PosMatrix);
        putMat(g->VecMatrix);
        putMat(g->TexMatrix);
        putMat(g->ClipMatrix);
        put(g->ClipMatrixDirty ? 1 : 0);
        putS(g->ProjMatrixStackPointer);
        putS(g->PosMatrixStackPointer);
        putS(g->TexMatrixStackPointer);
        const u64 h = stackHash();
        put(static_cast<u32>(h));
        put(static_cast<u32>(h >> 32));
        put(g->GXStat & 0x8002);
        // Production GXSTAT read; bits 0 and 14 are timing and not modelled.
        put(g->Read32(0x04000600) & 0x0000BF02);
        for (int i = 0; i < 3; ++i) putS(g->CurVertex[i]);
        for (int i = 0; i < 3; ++i) put(g->VertexColor[i]);
        for (int i = 0; i < 2; ++i) putS(g->TexCoords[i]);
        for (int i = 0; i < 2; ++i) putS(g->RawTexCoords[i]);
        for (int i = 0; i < 3; ++i) putS(g->Normal[i]);
        for (int l = 0; l < 4; ++l)
        {
            for (int i = 0; i < 3; ++i) putS(g->LightDirection[l][i]);
            putS(g->SpecRecip[l]);
            for (int i = 0; i < 3; ++i) put(g->LightColor[l][i]);
        }
        for (int i = 0; i < 3; ++i) put(g->MatDiffuse[i]);
        for (int i = 0; i < 3; ++i) put(g->MatAmbient[i]);
        for (int i = 0; i < 3; ++i) put(g->MatSpecular[i]);
        for (int i = 0; i < 3; ++i) put(g->MatEmission[i]);
        put(g->UseShininessTable ? 1 : 0);
        for (int i = 0; i < 128; i += 4)
            put(static_cast<u32>(g->ShininessTable[i]) | (static_cast<u32>(g->ShininessTable[i + 1]) << 8)
                | (static_cast<u32>(g->ShininessTable[i + 2]) << 16)
                | (static_cast<u32>(g->ShininessTable[i + 3]) << 24));
        put(g->PolygonAttr);
        put(g->CurPolygonAttr);
        put(g->TexParam);
        put(g->TexPalette);
        for (int i = 0; i < 6; ++i) put(g->Viewport[i]);
        put(g->ZeroDotWLimit);
        for (int i = 0; i < 4; ++i) putS(g->PosTestResult[i]);
        for (int i = 0; i < 3; ++i) putS(g->VecTestResult[i]);

        s32 clipSave[16];
        std::memcpy(clipSave, g->ClipMatrix, sizeof clipSave);
        const bool dirtySave = g->ClipMatrixDirty;
        for (u32 a = 0x04000620; a <= 0x040006A0; a += 4) put(g->Read32(a));
        for (u32 a : {0x04000621u, 0x04000642u, 0x04000643u, 0x0400067Du, 0x04000682u})
            put(g->Read32(a));
        for (u32 a = 0x04000620; a <= 0x040006A2; a += 2) put(g->Read16(a));
        std::memcpy(g->ClipMatrix, clipSave, sizeof clipSave);
        g->ClipMatrixDirty = dirtySave;
    }

    std::unique_ptr<NDS> nds;
    GPU3D* g = nullptr;
};

// --- stream building ------------------------------------------------------

struct Stream
{
    std::vector<In> ins;

    Stream& cmd(u32 op, std::vector<u32> p = {})
    {
        u32 n = NumParams[op & 0xFF];
        if (n == 0) n = 1;
        p.resize(n, 0);
        ins.push_back({0, op, p});
        return *this;
    }
    Stream& zeroDot(u32 v, u32 form) { ins.push_back({1, 0, {form ? (v & 0xFFFF) : v, form}}); return *this; }
    Stream& ack(u32 form, u32 junk = 0) { ins.push_back({2, 0, {form, junk}}); return *this; }

    Stream& mode(u32 m) { return cmd(0x10, {m}); }
    Stream& load(std::array<s32, 16> m)
    {
        std::vector<u32> p(m.begin(), m.end());
        return cmd(0x16, p);
    }
    Stream& vtx(s32 x, s32 y, s32 z) { return cmd(0x23, {half2(x, y), static_cast<u32>(z) & 0xFFFF}); }
    Stream& trans(s32 x, s32 y, s32 z) { return cmd(0x1C, {static_cast<u32>(x), static_cast<u32>(y), static_cast<u32>(z)}); }
    Stream& scale(s32 x, s32 y, s32 z) { return cmd(0x1B, {static_cast<u32>(x), static_cast<u32>(y), static_cast<u32>(z)}); }
    Stream& begin(u32 m) { return cmd(0x40, {m}); }
    Stream& attr(u32 a) { return cmd(0x29, {a}); }
    Stream& box(s32 x, s32 y, s32 z, s32 w, s32 h, s32 d) { return cmd(0x70, {half2(x, y), half2(z, w), half2(h, d)}); }
};

u32 vec10(s32 x, s32 y, s32 z)
{
    return (static_cast<u32>(x) & 0x3FF) | ((static_cast<u32>(y) & 0x3FF) << 10) | ((static_cast<u32>(z) & 0x3FF) << 20);
}

std::array<s32, 16> identityM()
{
    return {0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000};
}

// A gluPerspective-style projection for row vectors (w = -z).
std::array<s32, 16> perspectiveM(s32 a, s32 b, s32 c, s32 d)
{
    return {a, 0, 0, 0, 0, b, 0, 0, 0, 0, c, -0x1000, 0, 0, d, 0};
}

std::array<s32, 16> randomM(s32 lim)
{
    std::array<s32, 16> m {};
    for (auto& v : m) v = range(-lim, lim);
    return m;
}

std::vector<u32> randomWords(u32 n)
{
    std::vector<u32> p(n);
    for (auto& v : p) v = rnd();
    return p;
}

// Every opcode, each command branch, the stack edges, all texture-coordinate
// modes, lighting with and without the shininess table, DIF_AMB bit 15, the
// zero specular denominator, box tests inside/outside/straddling/far plane.
std::vector<std::pair<const char*, Stream>> directed()
{
    std::vector<std::pair<const char*, Stream>> out;
    seed(0xD1EC7ED);

    {   // projection and texture stacks: one slot, overflow/underflow, acknowledge
        Stream s;
        for (u32 m : {0u, 3u})
        {
            s.mode(m).load(randomM(0x3000)).cmd(0x11).cmd(0x15).cmd(0x11);
            s.ack(0, 0x1234).cmd(0x12).cmd(0x12).ack(1, 0x3FFF7FFF).cmd(0x12);
            s.load(randomM(0x2000)).cmd(0x13, {31}).cmd(0x15).cmd(0x14, {0}).cmd(0x11).cmd(0x11);
            s.ack(2, 0x7F).cmd(0x12, {0x3F});
        }
        out.push_back({"stack-proj-tex", s});
    }
    {   // position/vector stack: fill past 31, wrap the 6-bit pointer, pop offsets
        Stream s;
        s.mode(2);
        for (int i = 0; i < 34; ++i) s.trans(i * 0x100, -i * 0x80, i).cmd(0x11, {rnd()});
        s.ack(0);
        for (u32 off : {1u, 0x3Fu, 0x20u, 0x1Fu, 0u, 2u, 0x21u, 30u, 0x3Eu})
            s.cmd(0x12, {off | (rnd() & ~0x3Fu)});
        s.ack(1);
        s.mode(1).cmd(0x15).trans(0x1000, 0, 0).cmd(0x11).mode(2).cmd(0x15).cmd(0x12, {1});
        for (u32 a = 0; a < 32; ++a) s.scale(0x1000 + a, 0x1000 - a, 0x2000).cmd(0x13, {a | (rnd() & ~0x1Fu)});
        s.ack(2);
        for (u32 a : {0u, 31u, 5u, 30u, 31u}) s.cmd(0x14, {a | (rnd() & ~0x1Fu)});
        s.mode(1);
        for (u32 a : {3u, 31u}) s.cmd(0x13, {a}).cmd(0x14, {a});
        out.push_back({"stack-pos-vec", s});
    }
    {   // matrix unit: every operation in every mode, realistic and full range
        Stream s;
        for (u32 m = 0; m < 4; ++m)
        {
            for (int pass = 0; pass < 2; ++pass)
            {
                const s32 lim = pass ? 0x7FFFFFFF : 0x2000;
                auto words = [&](u32 n) {
                    std::vector<u32> p(n);
                    for (auto& v : p) v = pass ? rnd() : static_cast<u32>(range(-lim, lim));
                    return p;
                };
                s.mode(m | (rnd() & ~3u)).cmd(0x15).vtx(0x100, 0x200, -0x300);
                s.cmd(0x16, words(16)).vtx(0x10, 0x20, 0x30);
                s.cmd(0x17, words(12)).vtx(-0x10, 0x20, -0x30);
                s.cmd(0x18, words(16)).cmd(0x19, words(12)).cmd(0x1A, words(9));
                s.vtx(0x123, -0x456, 0x789);
                s.cmd(0x1B, words(3)).cmd(0x1C, words(3)).vtx(-0x7FFF, 0x7FFF, -0x8000);
                s.cmd(0x71, {rnd(), rnd()}).cmd(0x72, {rnd()});
            }
        }
        out.push_back({"matrix-ops", s});
    }
    {   // clip matrix cache: stale until a vertex, a test or a read needs it
        Stream s;
        s.mode(0).load(perspectiveM(0x14C9, 0x1BB6, -0x1042, -0x2084));
        s.mode(1).cmd(0x15).trans(0, 0, -0x4000).vtx(0, 0, 0);
        s.trans(0x800, 0, 0).cmd(0x20, {0x7FFF}).vtx(0x1000, 0x1000, 0);
        s.mode(3).trans(1, 2, 3).mode(2).scale(0x2000, 0x800, 0x1000);
        s.cmd(0x71, {half2(0x100, -0x100), 0x40}).cmd(0x15).cmd(0x70, {0, 0, 0});
        s.mode(0).cmd(0x15).cmd(0x13).cmd(0x14).vtx(1, 2, 3);
        // Every matrix command in every mode between two vertices, starting
        // from a clean cache and with stack slots that differ from the
        // current matrices, so each dirty (or not-dirty) rule is visible.
        for (u32 m = 0; m < 4; ++m)
        {
            s.mode(m).load(randomM(0x1800)).cmd(0x11).cmd(0x13, {1});
            s.mode(m).load(randomM(0x1800)).vtx(0x100, 0x200, 0x300);
            const std::vector<std::pair<u32, u32>> ops = {
                {0x11, 0}, {0x13, 1}, {0x14, 1}, {0x12, 1}, {0x15, 0}, {0x16, 16}, {0x17, 12},
                {0x18, 16}, {0x19, 12}, {0x1A, 9}, {0x1B, 3}, {0x1C, 3}};
            for (auto [op, n] : ops)
            {
                std::vector<u32> p(n ? n : 1, 1);
                if (n > 1) for (auto& v : p) v = static_cast<u32>(range(-0x1800, 0x1800));
                s.cmd(op, p).vtx(0x100, 0x200, 0x300).cmd(0x11).cmd(0x13, {1});
                s.load(randomM(0x1800)).vtx(-0x100, 0x80, 0x40);
            }
        }
        out.push_back({"clip-cache", s});
    }
    {   // texture coordinates: modes 0-3 with TEXCOORD, NORMAL and vertices
        Stream s;
        s.mode(3).load(randomM(0x3000)).mode(2).load(randomM(0x1800));
        for (u32 tm = 0; tm < 4; ++tm)
        {
            s.cmd(0x2A, {(tm << 30) | (rnd() & 0x3FFFFFFF)});
            s.cmd(0x22, {half2(0x100, -0x80)}).vtx(0x100, 0x200, 0x300);
            s.cmd(0x21, {vec10(100, -200, 300)}).vtx(-0x100, 0x200, -0x300);
            s.cmd(0x22, {rnd()}).cmd(0x21, {rnd()}).cmd(0x24, {rnd()});
            s.mode(3).load({0x7FFFFFFF, -0x7FFFFFFF, 0x12345678, 0, 0x40000000, 0x7FFFFFFF, 0, 0,
                            -0x40000000, 0x3FFFFFFF, 0, 0, 0x7FFF0000, -0x10000, 0, 0x1000});
            s.cmd(0x22, {half2(0x7FFF, -0x8000)}).cmd(0x21, {vec10(-512, 511, -512)}).vtx(0x7FFF, -0x8000, 0x7FFF);
            s.mode(3).load(randomM(0x3000)).mode(2);
        }
        out.push_back({"texcoord-modes", s});
    }
    {   // lighting: four lights, diffuse/specular/ambient/emission, shininess
        // table, DIF_AMB bit 15, lights disabled, zero specular denominator
        Stream s;
        s.mode(2).cmd(0x15);
        s.attr(0xF).begin(0);
        s.cmd(0x33, {0x7FFF}).cmd(0x33, {(1u << 30) | 0x03E0}).cmd(0x33, {(2u << 30) | 0x7C00}).cmd(0x33, {(3u << 30) | 0x5294});
        s.cmd(0x32, {vec10(0, 0, -511)}).cmd(0x32, {(1u << 30) | vec10(-300, 200, -100)});
        s.cmd(0x32, {(2u << 30) | vec10(511, -511, 0)}).cmd(0x32, {(3u << 30) | vec10(10, 20, 500)});
        s.cmd(0x30, {0x7FFF | (0x4210u << 16)}).cmd(0x31, {0x7FFF | (0x0421u << 16)});
        for (u32 n : {vec10(0, 0, 511), vec10(0, 0, -511), vec10(300, 300, 300), vec10(-511, 0, 0), vec10(100, -400, 200)})
            s.cmd(0x21, {n}).vtx(0, 0, 0);
        std::vector<u32> table(32);
        for (u32 i = 0; i < 32; ++i) table[i] = (4 * i) * 0x01010101u + 0x03020100u;
        s.cmd(0x34, table).cmd(0x31, {0x8000 | 0x2108 | (0x0842u << 16)});
        for (u32 n : {vec10(0, 0, 511), vec10(200, -100, 450), vec10(0, 0, -511)}) s.cmd(0x21, {n});
        s.cmd(0x34, randomWords(32)).cmd(0x21, {vec10(0, 0, 511)}).cmd(0x21, {rnd()});
        s.cmd(0x30, {0x8000 | 0x1234 | (0x1F1Fu << 16)}).vtx(1, 1, 1).cmd(0x30, {0x0421}).vtx(2, 2, 2);
        s.attr(0x5).cmd(0x21, {vec10(0, 0, 511)}).begin(1).cmd(0x21, {vec10(0, 0, 511)});
        s.attr(0).begin(2).cmd(0x21, {vec10(1, 2, 3)});
        // zero specular denominator: VecMatrix[10] = 0x2000, direction z = 256
        s.attr(0xF).begin(0).load({0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x2000, 0, 0, 0, 0, 0x1000});
        s.cmd(0x32, {vec10(0, 0, 256)}).cmd(0x21, {vec10(0, 0, 400)}).cmd(0x21, {vec10(10, 0, 300)});
        // large vector matrix: 32-bit overflow in the normal and light transforms
        s.load({0x7FFFFFFF, 0x40000000, -0x7FFFFFFF, 0, 0x12345678, 0x7FFFFFFF, 0x55555555, 0,
                INT32_MIN, 0x40000000, 0x7FFFFFFF, 0, 0, 0, 0, 0x1000});
        s.cmd(0x32, {vec10(511, -512, 511)}).cmd(0x32, {(1u << 30) | rnd()}).cmd(0x21, {vec10(-512, 511, -512)});
        // bright material: colour clamps at 31, shine clamps at 0x1FF
        s.load(identityM()).cmd(0x30, {0x7FFF7FFF}).cmd(0x31, {0x7FFF7FFF}).cmd(0x21, {vec10(0, 0, -511)});
        s.cmd(0x32, {vec10(0, 0, 511)}).cmd(0x21, {vec10(0, 0, -511)}).cmd(0x21, {vec10(0, 0, 511)});
        // shine level past 14 bits: SpecRecip = 2^18 (divisor 1); one light,
        // unsaturated material, so the 14-bit sign wrap (shine 0) is visible
        s.attr(0x1).begin(0).cmd(0x30, {0}).cmd(0x31, {0x1084}).cmd(0x33, {0x7FFF});
        s.cmd(0x32, {vec10(300, 0, 511)});
        for (s32 nx : {-300, -100, -200, -511, 50}) s.cmd(0x21, {vec10(nx, 0, 0)});
        out.push_back({"lighting", s});
    }
    {   // box test: inside, outside, straddling, far plane with and without
        // attribute bit 12, behind the camera, empty and wrapped boxes
        Stream s;
        s.mode(0).cmd(0x15).mode(1).cmd(0x15);
        s.box(-0x100, -0x100, -0x100, 0x200, 0x200, 0x200);
        s.box(0x2000, 0, 0, 0x100, 0x100, 0x100);
        s.box(-0x2000, -0x2000, -0x2000, 0x100, 0x100, 0x100);
        s.box(0x800, -0x100, -0x100, 0x1000, 0x200, 0x200);
        s.box(-0x100, -0x100, 0x800, 0x200, 0x200, 0x1000);
        s.attr(1u << 12).begin(0).box(-0x100, -0x100, 0x800, 0x200, 0x200, 0x1000);
        s.box(-0x100, -0x100, 0x1800, 0x200, 0x200, 0x100);
        s.attr(0).begin(0).box(-0x100, -0x100, 0x1800, 0x200, 0x200, 0x100);
        s.box(0, 0, 0, 0, 0, 0).box(0x7FFF, 0x7FFF, 0x7FFF, 1, 1, 1).box(-0x8000, 0, 0, -1, 0x10, 0x10);
        s.box(0x1000, 0x1000, 0x1000, 0, 0, 0).box(0x1001, 0, 0, 0, 0, 0);
        s.mode(0).load(perspectiveM(0x14C9, 0x1BB6, -0x1042, -0x2084)).mode(1).cmd(0x15);
        s.box(-0x100, -0x100, -0x3000, 0x200, 0x200, 0x200);
        s.box(-0x100, -0x100, 0x1000, 0x200, 0x200, 0x200);
        s.box(-0x4000, -0x100, -0x3000, 0x200, 0x200, 0x200);
        s.box(-0x4000, -0x100, -0x3000, 0x8000, 0x200, 0x200);
        s.box(-0x800, -0x800, -0x100, 0x1000, 0x1000, 0x1000);
        s.trans(0, 0, -0x10000).box(-0x100, -0x100, -0x100, 0x200, 0x200, 0x200);
        s.attr(1u << 12).begin(0).box(-0x7000, -0x7000, -0x7000, 0x7FFF, 0x7FFF, 0x7FFF);
        for (int i = 0; i < 40; ++i)
            s.box(range(-0x3000, 0x3000), range(-0x3000, 0x3000), range(-0x3000, 0x3000),
                  range(-0x2000, 0x2000), range(-0x2000, 0x2000), range(-0x2000, 0x2000));
        s.mode(0).load(randomM(0x7FFFFFFF));
        for (int i = 0; i < 20; ++i) s.cmd(0x70, randomWords(3));
        // Edges whose 32-bit plane distances alias (zero legacy denominator):
        // the fork's widened path, on the far plane (z > w, attribute bit 12)
        // and on the near plane (z < -w).
        s.mode(1).cmd(0x15).mode(0);
        s.load({0x1000, 0, 0x20000000, -0x20000000, 0, 0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, -0x40000000, 0x40000000});
        s.box(0, 0, 0, 0x4000, 0, 0).box(0, 0, 0, 0x4000, 0x10, 0x10);
        s.load({0x1000, 0, -0x20000000, -0x20000000, 0, 0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0x40000000, 0x40000000});
        s.box(0, 0, 0, 0x4000, 0, 0).box(0, 0, 0, 0x4000, 0x10, 0x10);
        // Box tests whose result is decided by one clip intersection, found by
        // searching the model: the result flips if the widened (aliasing)
        // edge's interpolation is wrong (first six; the box is the segment
        // from row 3 to row 3 + 2 * row 0), or if an ordinary edge's quotient
        // floors instead of truncating (last six).
        const std::vector<std::pair<std::array<s32, 16>, std::array<u32, 3>>> decisive = {
            {{1616079272, 211905548, -1359584791, 787898857, 0, 0, 0, 0, 0, 0, 0, 0, -2012794334, -296076907, 683084883, -40472201}, {0, 536870912, 0}},
            {{-92785983, 88929819, -1166400889, 981082759, 0, 0, 0, 0, 0, 0, 0, 0, 1461611179, 1696863500, 437310950, -1615507417}, {0, 536870912, 0}},
            {{-1125507806, -338299223, -1342449962, 805033686, 0, 0, 0, 0, 0, 0, 0, 0, 938947492, 841864747, 870519864, -31718718}, {0, 536870912, 0}},
            {{1541351662, -57958101, 1366534574, -780949074, 0, 0, 0, 0, 0, 0, 0, 0, -2024432448, 812265351, -1176760409, -428372874}, {0, 536870912, 0}},
            {{472626024, -1391322609, 1529034062, -618449586, 0, 0, 0, 0, 0, 0, 0, 0, -414089855, 1521868147, -1214904352, 1033001989}, {0, 536870912, 0}},
            {{1717805576, -206371707, 1286092020, -861391628, 0, 0, 0, 0, 0, 0, 0, 0, -1764239420, 1198384344, -2117330069, 100699453}, {0, 536870912, 0}},
            {{2146, -2066, 4026, 0, -3874, 5003, -1991, 0, 3038, -1780, 5329, 0, -4736, 2, 5628, 4096}, {3871535607u, 338225453, 7537053}},
            {{-4010, -1718, 500, 3394, -4045, 195, -260, -1987, -503, 533, 3042, 1191, 5762, -4281, -3856, 4096}, {491520502, 382737315, 36438177}},
            {{2180, 1106, 3763, -1332, -604, -3836, 2231, 812, -2274, 2670, 1108, -3974, -9341, -6747, -8482, 4096}, {4239588286u, 305456791, 251070684}},
            {{-2725, 771, -3703, -613, -1086, -1374, 715, 1861, -3054, -3739, -1379, -328, 1881, 3680, 4128, 4096}, {232973712, 79697803, 290524833}},
            {{3563, -1686, -946, -1686, -1840, 3400, -2302, -2302, -1737, -2229, 2696, -4096, -9849, -1132, -6641, 0}, {3991664729u, 215806333, 319816583}},
            {{-3032, -2612, 2172, 2118, 1717, 1851, -1465, 2390, 4081, -3909, 2508, 3459, -8173, -6052, -7475, 4096}, {133692546, 124321095, 254345244}},
        };
        s.attr(1u << 12).begin(0);
        for (const auto& [m, p] : decisive)
            s.load(m).cmd(0x70, {p[0], p[1], p[2]});
        out.push_back({"box-test", s});
    }
    {   // position and vector tests, and their effect on CurVertex
        Stream s;
        s.mode(0).load(perspectiveM(0x14C9, 0x1BB6, -0x1042, -0x2084)).mode(2).load(randomM(0x1000));
        s.cmd(0x71, {half2(0x100, -0x200), 0x12340300}).cmd(0x28, {vec10(1, -1, 511)});
        s.cmd(0x72, {vec10(511, 511, 511)}).cmd(0x72, {vec10(-512, -512, -512)}).cmd(0x72, {0xFFFFFFFF});
        s.load({0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000});
        for (s32 v : {0x100, 0xFF, 0x1FF, -0x100, -0x101, 511, -512}) s.cmd(0x72, {vec10(v, -v, v)});
        s.load({0x8000, 0x10000, -0x8000, 0, 0x3000, 0x7FFFF, 0x1FFF, 0, 0x4000, -0x4000, 0x12345, 0, 0, 0, 0, 0x1000});
        for (int i = 0; i < 8; ++i) s.cmd(0x72, {rnd()});
        s.cmd(0x71, {0x7FFF7FFF, 0x8000}).cmd(0x71, {rnd(), rnd()});
        out.push_back({"pos-vec-test", s});
    }
    {   // vertex formats and the strip modes (capture across strip swaps)
        Stream s;
        s.mode(0).load(perspectiveM(0x14C9, 0x1BB6, -0x1042, -0x2084)).mode(1).cmd(0x15).trans(0, 0, -0x3000);
        for (u32 pm = 0; pm < 4; ++pm)
        {
            s.begin(pm | (rnd() & ~3u)).cmd(0x20, {rnd()});
            s.vtx(0x100, 0x200, 0x300).cmd(0x24, {rnd()}).cmd(0x25, {half2(-0x100, 0x7FFF)});
            s.cmd(0x26, {half2(0x123, -0x8000)}).cmd(0x27, {half2(0x55, 0x66)});
            s.cmd(0x28, {vec10(511, -512, 1)}).cmd(0x28, {rnd()}).vtx(0x7FFF, 0x7FFF, 0x7FFF);
            s.cmd(0x28, {vec10(1, 1, 1)}).vtx(-0x8000, -0x8000, -0x8000).cmd(0x28, {vec10(-1, -1, -1)});
            for (int i = 0; i < 9; ++i) s.cmd(0x24 + (i % 5), {rnd()});
            s.cmd(0x23, {rnd(), rnd()}).cmd(0x41);
        }
        out.push_back({"vertex-formats", s});
    }
    {   // polygon state: latch, palette mask, viewport, swap, 1-dot depth
        Stream s;
        s.attr(0x1F0F80C0).begin(2).vtx(1, 2, 3).attr(0x3F1F00FF).vtx(4, 5, 6).vtx(7, 8, 9);
        s.cmd(0x2A, {0xFFFFFFFF}).cmd(0x2B, {0xFFFFFFFF}).vtx(0, 0, 0).cmd(0x2B, {0x1234}).cmd(0x2A, {0x12345678});
        for (u32 v : {0x00000000u, 0xFFFFFFFFu, 0xBFFF00FFu, 0x00BF0000u, 0x10C01020u, 0xC0C0FFFFu, 0x80FF7F01u})
            s.cmd(0x60, {v}).vtx(1, 1, 1);
        s.zeroDot(0, 0).vtx(2, 2, 2).zeroDot(0x7FFF, 1).vtx(3, 3, 3).zeroDot(0xFFFFFFFF, 0).vtx(4, 4, 4);
        s.zeroDot(0x12345678, 1).zeroDot(0x8001, 0).vtx(5, 5, 5);
        s.cmd(0x50, {0}).cmd(0x50, {3}).cmd(0x50, {0xFFFFFFFE}).cmd(0x41).cmd(0x41, {0xFFFFFFFF});
        s.begin(1).attr(0).vtx(6, 6, 6);
        out.push_back({"polygon-state", s});
    }
    {   // every opcode once, with random parameters
        Stream s;
        s.mode(0).load(perspectiveM(0x14C9, 0x1BB6, -0x1042, -0x2084)).mode(2);
        for (u32 op = 0; op < 256; ++op)
        {
            u32 n = NumParams[op];
            s.cmd(op, randomWords(n ? n : 1));
        }
        out.push_back({"all-opcodes", s});
    }
    return out;
}

// --- random streams ---------------------------------------------------------

u32 realWord(s32 lim) { return static_cast<u32>(range(-lim, lim)); }

void scene(Stream& s)
{
    const s32 a = range(0x800, 0x3000);
    s.mode(0).load(perspectiveM(a, a * 4 / 3, range(-0x1100, -0x1000), range(-0x4000, -0x100)));
    s.mode(2).cmd(0x15).trans(range(-0x4000, 0x4000), range(-0x4000, 0x4000), range(-0x10000, -0x1000));
    s.mode(chance(50) ? 1 : 2);
}

void randomCommand(Stream& s)
{
    const bool wild = chance(25);
    const u32 pick = below(1000);
    auto mtxWords = [&](u32 n, s32 lim) {
        std::vector<u32> p(n);
        for (auto& v : p) v = wild ? rnd() : realWord(lim);
        return p;
    };
    auto coord = [&]() -> s32 { return wild ? static_cast<s16>(rnd()) : range(-0x1000, 0x1000); };

    if (pick < 30) { scene(s); return; }
    if (pick < 70) { s.mode(rnd() & (wild ? 0xFFFFFFFF : 3)); return; }
    if (pick < 95) { s.cmd(0x11, {rnd()}); return; }
    if (pick < 120)
    {
        const u32 offs[] = {1, 1, 1, 2, 0x3F, 0x3E, 0};
        s.cmd(0x12, {chance(70) ? offs[below(7)] : rnd()});
        return;
    }
    if (pick < 135) { s.cmd(0x13, {wild ? rnd() : below(32)}); return; }
    if (pick < 150) { s.cmd(0x14, {wild ? rnd() : below(32)}); return; }
    if (pick < 165) { s.cmd(0x15); return; }
    if (pick < 185) { s.cmd(0x16, mtxWords(16, 0x2000)); return; }
    if (pick < 205) { s.cmd(0x17, mtxWords(12, 0x2000)); return; }
    if (pick < 225) { s.cmd(0x18, mtxWords(16, 0x1400)); return; }
    if (pick < 245) { s.cmd(0x19, mtxWords(12, 0x1400)); return; }
    if (pick < 265) { s.cmd(0x1A, mtxWords(9, 0x1400)); return; }
    if (pick < 285) { s.cmd(0x1B, mtxWords(3, 0x2000)); return; }
    if (pick < 310) { s.cmd(0x1C, mtxWords(3, 0x8000)); return; }
    if (pick < 345) { s.cmd(0x20, {rnd()}); return; }
    if (pick < 400) { s.cmd(0x21, {rnd()}); return; }
    if (pick < 455) { s.cmd(0x22, {wild ? rnd() : half2(range(-0x2000, 0x2000), range(-0x2000, 0x2000))}); return; }
    if (pick < 500) { s.cmd(0x23, {half2(coord(), coord()), (static_cast<u32>(coord()) & 0xFFFF) | (rnd() & 0xFFFF0000)}); return; }
    if (pick < 530) { s.cmd(0x24, {rnd()}); return; }
    if (pick < 555) { s.cmd(0x25, {half2(coord(), coord())}); return; }
    if (pick < 580) { s.cmd(0x26, {half2(coord(), coord())}); return; }
    if (pick < 605) { s.cmd(0x27, {half2(coord(), coord())}); return; }
    if (pick < 640) { s.cmd(0x28, {wild ? rnd() : vec10(range(-64, 64), range(-64, 64), range(-64, 64))}); return; }
    if (pick < 660)
    {
        u32 a = rnd();
        if (chance(60)) a |= 0xF;
        if (chance(50)) a ^= 1u << 12;
        s.attr(a);
        return;
    }
    if (pick < 690) { s.cmd(0x2A, {rnd()}); return; }
    if (pick < 700) { s.cmd(0x2B, {rnd()}); return; }
    if (pick < 720) { s.cmd(0x30, {rnd()}); return; }
    if (pick < 740) { s.cmd(0x31, {rnd()}); return; }
    if (pick < 770) { s.cmd(0x32, {rnd()}); return; }
    if (pick < 790) { s.cmd(0x33, {rnd()}); return; }
    if (pick < 797) { s.cmd(0x34, randomWords(32)); return; }
    if (pick < 830) { s.begin(rnd()); return; }
    if (pick < 840) { s.cmd(0x41, {rnd()}); return; }
    if (pick < 845) { s.cmd(0x50, {rnd()}); return; }
    if (pick < 855) { s.cmd(0x60, {rnd()}); return; }
    if (pick < 895)
    {
        if (wild) s.cmd(0x70, randomWords(3));
        else s.box(range(-0x1800, 0x1800), range(-0x1800, 0x1800), range(-0x1800, 0x1800),
                   range(-0x800, 0x1800), range(-0x800, 0x1800), range(-0x800, 0x1800));
        return;
    }
    if (pick < 920) { s.cmd(0x71, {half2(coord(), coord()), (static_cast<u32>(coord()) & 0xFFFF) | (rnd() & 0xFFFF0000)}); return; }
    if (pick < 945) { s.cmd(0x72, {rnd()}); return; }
    if (pick < 960)
    {
        static const u32 bad[] = {0x00, 0x01, 0x0F, 0x1D, 0x1F, 0x2C, 0x2F, 0x35, 0x3F, 0x42, 0x4F,
                                  0x51, 0x5F, 0x61, 0x6F, 0x73, 0x7F, 0x80, 0xAA, 0xFF};
        s.cmd(bad[below(sizeof bad / sizeof bad[0])], {rnd()});
        return;
    }
    if (pick < 975) { s.zeroDot(rnd(), below(2)); return; }
    s.ack(below(3), rnd());
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        std::fprintf(stderr, "usage: geometry_oracle directed | random SEED STREAMS LENGTH\n");
        return 2;
    }
    Runner runner;
    const std::string mode = argv[1];
    if (mode == "directed")
    {
        u32 id = 0;
        for (auto& [name, s] : directed())
        {
            std::fprintf(stderr, "geometry-oracle: directed stream %u %s: %zu inputs\n",
                id, name, s.ins.size());
            runner.start(id++);
            for (const In& in : s.ins) runner.run(in);
            runner.end();
        }
    }
    else if (mode == "random" && argc == 5)
    {
        const u64 base = std::strtoull(argv[2], nullptr, 0);
        const u32 streams = static_cast<u32>(std::strtoul(argv[3], nullptr, 0));
        const u32 length = static_cast<u32>(std::strtoul(argv[4], nullptr, 0));
        for (u32 i = 0; i < streams; ++i)
        {
            seed(base * 0x10001 + i);
            Stream s;
            scene(s);
            while (s.ins.size() < length) randomCommand(s);
            runner.start(i);
            for (const In& in : s.ins) runner.run(in);
            runner.end();
        }
    }
    else
    {
        std::fprintf(stderr, "usage: geometry_oracle directed | random SEED STREAMS LENGTH\n");
        return 2;
    }
    put(TagFileEnd);
    put(static_cast<u32>(records));
    flushOut();
    return 0;
}
