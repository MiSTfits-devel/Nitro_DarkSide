// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Truffle
//
// Whole-chip oracle for Nds.Gpu3D.Chip: a real melonDS NDS whose 3D engine
// is driven only the way the console drives it -- ARM9 I/O accesses
// (NDS::ARM9IOWrite*/ARM9IORead*, so DISP3DCNT routing, POWCNT1, BG0HOFS,
// VCOUNT and IF go through melonDS's own bus code), GPU3D::Run with the
// ARM9 clock advanced, GPU3D::VBlank at scanline 192, the renderer's
// Start3DRendering at scanline 215, GetLine for the 2D engine and
// GPU::FinishFrame at the end of the frame. No GPU3D state is written
// directly; the renderer is the production SoftRenderer3D on the reference
// path (render_oracle.cpp's settings).
//
// Script (stdin), one op per line, numbers hex except the access width:
//   W size addr value   ARM9IOWrite8/16/32
//   R size addr         ARM9IORead8/16/32               -> 1 word
//   P value             POWCNT1 (ARM9IOWrite16 0x04000304)
//   X size addr value   BG0HOFS (ARM9IOWrite8/16 0x04000010-11)
//   A size addr value   VCOUNT (ARM9IOWrite8/16 0x04000006-07)
//   I value             IF acknowledge (ARM9IOWrite32 0x04000214)
//   V                   scanline 192: GPU3D::VBlank
//   S                   scanline 215: Start3DRendering (RenderFrame)
//   F                   end of frame: GPU::FinishFrame
//   L                   GetLine(0..191)                 -> 49152 words
//   T                   time passes (no access; the engine catches up)
// An op prefixed with '+' (e.g. "+W 32 4000400 ...") is part of a burst:
// the geometry engine does not run after it.
//
// Timing (the interleavings the gate compares): after every op that is not
// a burst op the geometry engine catches up completely -- the ARM9 clock
// advances by 2^30 cycles and GPU3D::Run executes until the PIPE is empty, a
// SWAP_BUFFERS waits for VBlank, or geometry is disabled. A burst is what
// melonDS does for an STM or a DMA block to GXFIFO: several accesses with no
// Run in between (Run is called by the scheduler, not by the bus), so all of
// their entries queue before any executes. Any op that is not a GXSTAT read
// may be a burst op; a GXSTAT read calls Run itself and would execute
// commands at zero elapsed time, a cycle-budget effect the gate does not
// model -- the oracle aborts if any read executes a command. The FIFO thus
// fills behind a pending swap, with geometry off, or in a burst. A write
// that overflows it stalls the ARM9 (NDS::GXFIFOStall); the bus stays held
// until the engine has drained the stall queue, exactly as the ARM9 waits
// in melonDS. The script must not issue an ARM9 op (W R P X A I) while the
// bus is held.
//
// Output (stdout), little-endian u32 words: after every op a status word
// (bit 0: ARM9 held by the GX stall, bit 1: IF bit 21, bits 8-31: entries
// ExecuteCommand took during the op) and the number of GXFIFO DMA checks
// (CmdFIFORead's CheckFIFODMA finding fewer than 128 entries, which starts
// the ARM9 DMA channels in GXFIFO mode), then the op's words (R, L).
//
// ORACLE_VRAM names the VRAM image (512 KiB of texture slots 0-3, then
// 128 KiB of palette slots 0-7, slots 6 and 7 zero), uploaded through LCDC
// and mapped as texture/palette slots like render_oracle.cpp.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "NDS.h"
#include "GPU.h"
#include "GPU3D.h"
#include "GPU3D_Texcache.h"
#include "NDS4MiSTer_FastDivide.h"
#include "Platform.h"
// Oracle-only: expose the renderer's path switches and buffers.
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

[[noreturn]] void die(const std::string& msg)
{
    std::fprintf(stderr, "chip-oracle: %s\n", msg.c_str());
    std::exit(1);
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

void put(u32 w)
{
    std::fwrite(&w, sizeof w, 1, stdout);
}

void write(NDS& nds, unsigned size, u32 addr, u32 val)
{
    if (size == 8) nds.ARM9IOWrite8(addr, static_cast<u8>(val));
    else if (size == 16) nds.ARM9IOWrite16(addr, static_cast<u16>(val));
    else if (size == 32) nds.ARM9IOWrite32(addr, val);
    else die("bad access width");
}

} // namespace

int main()
{
    auto holder = std::make_unique<OracleNDS>();
    OracleNDS& nds = *holder;
    GPU& gpu = nds.GPU;
    GPU3D& g = gpu.GPU3D;
    auto& soft = static_cast<SoftRenderer&>(gpu.GetRenderer());
    SoftRenderer3D* r3d = soft.Get3DRenderer();

    // Reference path: direct TextureLookup, the full ClearBuffers.
    r3d->UseTextureCache = false;
    r3d->SparseClearEnabled = false;
    r3d->SparseClearStateValid = false;

    // Power-on: the 3D engine reset, a reset renderer with a zeroed stencil
    // buffer, no interrupt pending, the DS ARM9 clock (NDS::Reset's values).
    g.Reset();
    std::memset(r3d->ColorBuffer, 0, sizeof(r3d->ColorBuffer));
    std::memset(r3d->DepthBuffer, 0, sizeof(r3d->DepthBuffer));
    std::memset(r3d->AttrBuffer, 0, sizeof(r3d->AttrBuffer));
    std::memset(r3d->StencilBuffer, 0, sizeof(r3d->StencilBuffer));
    r3d->PrevIsShadowMask = false;
    nds.IF[0] = 0;
    nds.CPUStop = 0;
    nds.ARM9ClockShift = 1;
    nds.ARM9Timestamp = 0;

    std::vector<u8> image;
    if (!loadVram(gpu, image)) die("bad VRAM image");
    bool vramChecked = false;

    std::string line;
    unsigned lineNo = 0;
    while (std::getline(std::cin, line))
    {
        ++lineNo;
        if (line.empty()) continue;
        std::istringstream in(line);
        in >> std::hex;
        char op = 0;
        in >> op;
        const bool burst = op == '+';
        if (burst) in >> op;
        const bool held = (nds.CPUStop & CPUStop_GXStall) != 0;
        if (held && std::strchr("WRPXAI", op))
            die("line " + std::to_string(lineNo) + ": ARM9 access while the bus is held");
        const u64 executedBefore = NDS4MiSTerGXExecuted;
        nds.GXDMAChecks = 0;
        std::vector<u32> words;
        switch (op)
        {
        case 'W':
        {
            unsigned size = 0; u32 addr = 0, val = 0;
            in >> std::dec >> size >> std::hex >> addr >> val;
            write(nds, size, addr, val);
            break;
        }
        case 'R':
        {
            unsigned size = 0; u32 addr = 0, val = 0;
            in >> std::dec >> size >> std::hex >> addr;
            if (size == 8) val = nds.ARM9IORead8(addr);
            else if (size == 16) val = nds.ARM9IORead16(addr);
            else if (size == 32) val = nds.ARM9IORead32(addr);
            else die("bad access width");
            if (NDS4MiSTerGXExecuted != executedBefore)
                die("line " + std::to_string(lineNo) + ": a read executed GX commands");
            words.push_back(val);
            break;
        }
        case 'P':
        {
            u32 val = 0;
            in >> val;
            nds.ARM9IOWrite16(0x04000304, static_cast<u16>(val));
            break;
        }
        case 'X':
        case 'A':
        {
            unsigned size = 0; u32 addr = 0, val = 0;
            in >> std::dec >> size >> std::hex >> addr >> val;
            const bool ok = op == 'X'
                ? (addr == 0x04000010 || (size == 8 && addr == 0x04000011))
                : (addr == 0x04000006 || (size == 8 && addr == 0x04000007));
            if (!ok || size == 32) die("bad X/A access");
            write(nds, size, addr, val);
            break;
        }
        case 'I':
        {
            u32 val = 0;
            in >> val;
            nds.ARM9IOWrite32(0x04000214, val);
            break;
        }
        case 'V':
            gpu.GetRenderer().Finish3DRendering();
            g.VBlank();
            break;
        case 'S':
            // The hardware renders every frame; RenderFrameIdentical is the
            // emulator's skip of an unchanged frame (not hardware state).
            g.RenderFrameIdentical = false;
            gpu.GetRenderer().Start3DRendering();
            if (!vramChecked)
            {
                if (std::memcmp(gpu.VRAMFlat_Texture, image.data(), TextureBytes) != 0 ||
                    std::memcmp(gpu.VRAMFlat_TexPal, image.data() + TextureBytes, PaletteBytes) != 0)
                    die("flat VRAM differs from the image");
                vramChecked = true;
            }
            break;
        case 'F':
            gpu.FinishFrame(263);
            break;
        case 'T':
            break;
        case 'L':
            for (int y = 0; y < 192; ++y)
            {
                const u32* row = r3d->GetLine(y);
                words.insert(words.end(), row, row + 256);
            }
            break;
        default:
            die("line " + std::to_string(lineNo) + ": bad op: " + line);
        }

        // The geometry engine catches up, unless the burst goes on.
        if (!burst)
        {
            nds.ARM9Timestamp += static_cast<u64>(1) << (30 + nds.ARM9ClockShift);
            g.Run();
        }

        const u64 executed = NDS4MiSTerGXExecuted - executedBefore;
        if (executed >= (1u << 24)) die("too many commands in one op");
        put(((nds.CPUStop & CPUStop_GXStall) ? 1u : 0u)
            | (((nds.IF[0] >> IRQ_GXFIFO) & 1u) << 1)
            | (static_cast<u32>(executed) << 8));
        put(nds.GXDMAChecks);
        for (u32 w : words) put(w);
    }
    return 0;
}
