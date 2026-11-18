// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Truffle
//
// GX front-end oracle. Drives the production GPU3D register block and
// command FIFO through the ARM9 I/O entry points (NDS::ARM9IORead*/
// ARM9IOWrite*, so the 0x04000060 routing and the POWCNT1 write path are
// melonDS's own), takes FIFO entries the way GPU3D::ExecuteCommand does, and
// prints the state after every scripted op for Nds.Gpu3D.GxFront's gate.
//
// Script (stdin), one op per line, numbers in hex:
//   C name                  new case: GPU3D::Reset, IF cleared, stubs cleared
//   W size addr value       ARM9IOWrite8/16/32
//   R size addr             ARM9IORead8/16/32
//   P                       take the head entry (see below)
//   V                       GPU3D::VBlank
//   X xpos mask             GPU3D::SetRenderXPos
//   E geom rend             POWCNT1 write (ARM9IOWrite16 0x04000304)
//   G tb br ps pj sb se bz  geometry stub: test busy, box result, position
//                           stack level, projection stack level, stack busy,
//                           stack error, busy
//   F under over            DISP3DCNT |= bit 12 / bit 13 (as SubmitPolygon)
//   Q polys verts           NumPolygons / NumVertices (RAM_COUNT)
//   Z addr value            result register word (geoReadResult layout)
//
// Output per op: optional "R value" (reads), "P cmd param" / "P empty"
// (pops), an "S ..." state line, then "T ..." (live tables) after table
// writes and C, and "RR ..." (latched render registers) after V, E, X, C.
//
// What is production code and what is not:
// * every register, FIFO and PIPE effect is GPU3D's own code;
// * P calls the private GPU3D::CmdFIFORead (exactly what ExecuteCommand
//   calls), then performs ExecuteCommand's counter bookkeeping for the entry
//   (a verbatim copy of the NumPushPopCommands/NumTestCommands/
//   ExecParamCount lines, since running the command itself is the geometry
//   block's business);
// * after every op the oracle "settles" the bits GPU3D::Run would clear once
//   the geometry engine has caught up: bit 14 / bit 0 when their counters
//   are zero (copy of Run's two lines), bit 27 when the PIPE is empty
//   (FinishWork with idle pipelines). The geometry stub's busy flags hold
//   the bits instead, as a busy geometry engine does;
// * CycleCount is kept huge so the Run() inside GXSTAT reads never executes
//   a command;
// * NDS::CheckDMAs is overridden to count GXFIFO-mode (7) checks, and the
//   result registers and RAM_COUNT are poked through private access.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

// Oracle-only: expose GPU3D's FIFOs, counters and CmdFIFORead.
#define private public
#include "GPU3D.h"
#undef private
#include "NDS.h"
#include "GPU.h"
#include "Platform.h"

using namespace melonDS;

namespace
{

// GPU3D.cpp's CmdNumParams (internal linkage there), copied verbatim.
const u8 CmdNumParams[256] =
{
    // 0x00
    0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    // 0x10
    1, 0, 1, 1, 1, 0, 16, 12, 16, 12, 9, 3, 3,
    0, 0, 0,
    // 0x20
    1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0,
    // 0x30
    1, 1, 1, 1, 32,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    // 0x40
    1, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    // 0x50
    1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    // 0x60
    1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    // 0x70
    3, 2, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    // 0x80+
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

class OracleNDS : public NDS
{
public:
    unsigned GXDMAChecks = 0;
    void CheckDMAs(u32 cpu, u32 mode) override
    {
        if (cpu == 0 && mode == 0x07) ++GXDMAChecks;
        NDS::CheckDMAs(cpu, mode);
    }
};

struct GeoStub
{
    bool testBusy = false, stackBusy = false, busy = false;
};

constexpr s32 NeverRun = 0x40000000;

void reset(OracleNDS& nds, GeoStub& geo)
{
    GPU3D& g = nds.GPU.GPU3D;
    g.Reset();
    g.CycleCount = NeverRun;
    nds.IF[0] = 0;
    nds.GXDMAChecks = 0;
    geo = GeoStub {};
}

// GPU3D::Run's clears once the geometry engine has caught up; a busy stub
// holds the bit.
void settle(GPU3D& g, const GeoStub& geo)
{
    if (g.NumPushPopCommands == 0) g.GXStat &= ~(1u << 14);
    if (g.NumTestCommands == 0)    g.GXStat &= ~(1u << 0);
    if (g.CmdPIPE.IsEmpty())       g.GXStat &= ~(1u << 27);
    if (geo.stackBusy) g.GXStat |= (1u << 14);
    if (geo.testBusy)  g.GXStat |= (1u << 0);
    if (geo.busy)      g.GXStat |= (1u << 27);
    g.CycleCount = NeverRun;
}

// CmdFIFORead plus ExecuteCommand's counter bookkeeping for the entry.
GPU3D::CmdFIFOEntry take(GPU3D& g)
{
    GPU3D::CmdFIFOEntry entry = g.CmdFIFORead();
    u32 paramsRequiredCount = CmdNumParams[entry.Command];
    if (paramsRequiredCount <= 1)
    {
        if (entry.Command == 0x11 || entry.Command == 0x12) g.NumPushPopCommands--;
        else if (entry.Command == 0x72) g.NumTestCommands--;
    }
    else
    {
        g.ExecParams[g.ExecParamCount] = entry.Param;
        g.ExecParamCount++;
        if (g.ExecParamCount != 1 && g.ExecParamCount >= paramsRequiredCount)
        {
            g.ExecParamCount = 0;
            if (entry.Command == 0x71) g.NumTestCommands -= 2;
            else if (entry.Command == 0x70) g.NumTestCommands -= 3;
        }
    }
    return entry;
}

void entry(std::ostringstream& o, const GPU3D::CmdFIFOEntry& e)
{
    char buf[32];
    std::snprintf(buf, sizeof buf, " %x:%x", e.Command, e.Param);
    o << buf;
}

void printState(OracleNDS& nds, unsigned dma)
{
    GPU3D& g = nds.GPU.GPU3D;
    std::ostringstream o;
    o << std::hex;
    u32 gx = nds.ARM9IORead32(0x04000600);
    o << "S f=" << g.CmdFIFO.Level();
    if (!g.CmdFIFO.IsEmpty())
    {
        entry(o, g.CmdFIFO.Peek(0));
        entry(o, g.CmdFIFO.Peek(g.CmdFIFO.Level() - 1));
    }
    o << " p=" << g.CmdPIPE.Level();
    for (u32 i = 0; i < g.CmdPIPE.Level(); ++i) entry(o, g.CmdPIPE.Peek(i));
    o << " q=" << g.CmdStallQueue.Level();
    for (u32 i = 0; i < g.CmdStallQueue.Level(); ++i) entry(o, g.CmdStallQueue.Peek(i));
    o << " gx=" << gx
      << " irq=" << ((nds.IF[0] >> IRQ_GXFIFO) & 1)
      << " dma=" << dma
      << " pp=" << g.NumPushPopCommands
      << " tst=" << g.NumTestCommands
      << " epc=" << g.ExecParamCount
      << " pk=" << g.NumCommands << "," << g.CurCommand << "," << g.ParamCount << "," << g.TotalParams
      << " dc=" << g.DispCnt
      << " ar=" << unsigned(g.AlphaRefVal) << "," << unsigned(g.AlphaRef)
      << " ca=" << g.ClearAttr1 << "," << g.ClearAttr2
      << " fc=" << g.FogColor << " fo=" << g.FogOffset
      << " zd=" << g.ZeroDotWLimit
      << " en=" << int(g.GeometryEnabled) << int(g.RenderingEnabled)
      << " xp=" << g.RenderXPos
      << " se=" << ((g.GXStat >> 15) & 1) << "," << g.ProjMatrixStackPointer;
    std::cout << o.str() << '\n';
}

void hexList(std::ostringstream& o, const char* tag, const u8* p, int n)
{
    o << ' ' << tag << '=';
    for (int i = 0; i < n; ++i) { if (i) o << ','; o << unsigned(p[i]); }
}

void hexList(std::ostringstream& o, const char* tag, const u16* p, int n)
{
    o << ' ' << tag << '=';
    for (int i = 0; i < n; ++i) { if (i) o << ','; o << unsigned(p[i]); }
}

void printTables(GPU3D& g)
{
    std::ostringstream o;
    o << std::hex << "T";
    hexList(o, "fd", g.FogDensityTable, 32);
    hexList(o, "ed", g.EdgeTable, 8);
    hexList(o, "tn", g.ToonTable, 32);
    std::cout << o.str() << '\n';
}

void printRender(GPU3D& g)
{
    std::ostringstream o;
    o << std::hex << "RR dc=" << g.RenderDispCnt << " ar=" << unsigned(g.RenderAlphaRef)
      << " ca=" << g.RenderClearAttr1 << "," << g.RenderClearAttr2
      << " fc=" << g.RenderFogColor << " fo=" << g.RenderFogOffset
      << " fs=" << g.RenderFogShift;
    hexList(o, "fd", g.RenderFogDensityTable, 34);
    hexList(o, "ed", g.RenderEdgeTable, 8);
    hexList(o, "tn", g.RenderToonTable, 32);
    o << " xp=" << g.RenderXPos;
    std::cout << o.str() << '\n';
}

void setResult(GPU3D& g, u32 addr, u32 val)
{
    static const int vecIndex[9] = {0, 1, 2, 4, 5, 6, 8, 9, 10};
    if (addr >= 0x04000620 && addr <= 0x0400062C)
        g.PosTestResult[(addr - 0x04000620) >> 2] = static_cast<s32>(val);
    else if (addr == 0x04000630)
    {
        g.VecTestResult[0] = static_cast<s16>(val & 0xFFFF);
        g.VecTestResult[1] = static_cast<s16>(val >> 16);
    }
    else if (addr == 0x04000634)
        g.VecTestResult[2] = static_cast<s16>(val & 0xFFFF);
    else if (addr >= 0x04000640 && addr <= 0x0400067C)
    {
        g.ClipMatrixDirty = false;
        g.ClipMatrix[(addr - 0x04000640) >> 2] = static_cast<s32>(val);
    }
    else if (addr >= 0x04000680 && addr <= 0x040006A0)
        g.VecMatrix[vecIndex[(addr - 0x04000680) >> 2]] = static_cast<s32>(val);
}

bool tableAddr(u32 a) { return a >= 0x04000330 && a < 0x040003C0; }

} // namespace

int main()
{
    auto holder = std::make_unique<OracleNDS>();
    OracleNDS& nds = *holder;
    GPU3D& g = nds.GPU.GPU3D;
    GeoStub geo;
    reset(nds, geo);

    std::string line;
    while (std::getline(std::cin, line))
    {
        if (line.empty()) continue;
        std::istringstream in(line);
        in >> std::hex;
        char op = 0;
        in >> op;
        nds.GXDMAChecks = 0;
        bool tables = false, render = false;
        switch (op)
        {
        case 'C':
            reset(nds, geo);
            tables = render = true;
            break;
        case 'W':
        {
            unsigned size = 0; u32 addr = 0, val = 0;
            in >> std::dec >> size >> std::hex >> addr >> val;
            if (size == 8) nds.ARM9IOWrite8(addr, static_cast<u8>(val));
            else if (size == 16) nds.ARM9IOWrite16(addr, static_cast<u16>(val));
            else nds.ARM9IOWrite32(addr, val);
            tables = tableAddr(addr);
            break;
        }
        case 'R':
        {
            unsigned size = 0; u32 addr = 0, val = 0;
            in >> std::dec >> size >> std::hex >> addr;
            if (size == 8) val = nds.ARM9IORead8(addr);
            else if (size == 16) val = nds.ARM9IORead16(addr);
            else val = nds.ARM9IORead32(addr);
            std::printf("R %x\n", val);
            break;
        }
        case 'P':
            if (g.CmdPIPE.IsEmpty()) std::printf("P empty\n");
            else
            {
                GPU3D::CmdFIFOEntry e = take(g);
                std::printf("P %x %x\n", e.Command, e.Param);
            }
            break;
        case 'V':
            g.VBlank();
            render = true;
            break;
        case 'X':
        {
            u32 xpos = 0, mask = 0;
            in >> xpos >> mask;
            g.SetRenderXPos(static_cast<u16>(xpos), static_cast<u16>(mask));
            render = true;
            break;
        }
        case 'E':
        {
            unsigned geom = 0, rend = 0;
            in >> geom >> rend;
            nds.ARM9IOWrite16(0x04000304, static_cast<u16>(0x0203 | (geom ? 8 : 0) | (rend ? 4 : 0)));
            render = true;
            break;
        }
        case 'G':
        {
            unsigned tb, br, ps, pj, sb, se, bz;
            in >> tb >> br >> ps >> pj >> sb >> se >> bz;
            geo.testBusy = tb; geo.stackBusy = sb; geo.busy = bz;
            g.GXStat = (g.GXStat & ~((1u << 1) | (1u << 15))) | (br ? (1u << 1) : 0) | (se ? (1u << 15) : 0);
            g.PosMatrixStackPointer = static_cast<s32>(ps);
            g.ProjMatrixStackPointer = static_cast<s32>(pj);
            break;
        }
        case 'F':
        {
            unsigned under = 0, over = 0;
            in >> under >> over;
            if (under) g.DispCnt |= (1u << 12);
            if (over) g.DispCnt |= (1u << 13);
            break;
        }
        case 'Q':
        {
            u32 polys = 0, verts = 0;
            in >> polys >> verts;
            g.NumPolygons = polys;
            g.NumVertices = verts;
            break;
        }
        case 'Z':
        {
            u32 addr = 0, val = 0;
            in >> addr >> val;
            setResult(g, addr, val);
            break;
        }
        default:
            std::fprintf(stderr, "gxfront-oracle: bad op: %s\n", line.c_str());
            return 1;
        }
        unsigned dma = nds.GXDMAChecks;
        settle(g, geo);
        printState(nds, dma);
        if (tables) printTables(g);
        if (render) printRender(g);
    }
    return 0;
}
