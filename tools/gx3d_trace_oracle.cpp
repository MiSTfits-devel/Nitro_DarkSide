// Independent production GPU3D replay oracle.
//
// Feeds the ordered v12 raw inputs (types5/7 registers+commands, types20-25
// control/timing, type2 memory deltas) into melonDS's own GPU3D and software
// renderer, then compares the resulting lines with the recorded type3 lines.
// Recorded type3 pixels are used only as expected output, never as input.
#define private public
#define protected public
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <vector>
#include "NDS.h"
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#undef protected
#undef private

using namespace melonDS;

namespace
{
u16 rd16(const u8* b) { return u16(b[0] | (b[1] << 8)); }
u32 rd32(const u8* b) { return u32(b[0]) | (u32(b[1]) << 8) | (u32(b[2]) << 16) | (u32(b[3]) << 24); }
u64 rd64(const u8* b) { return u64(rd32(b)) | (u64(rd32(b + 4)) << 32); }

const u32 RegionSizes[13] = {2048, 2048, 131072, 131072, 131072, 131072,
                             65536, 16384, 16384, 32768, 16384, 262144, 131072};
}

int main(int argc, char** argv)
{
    if (argc < 2) { fprintf(stderr, "usage: gx3d_trace_oracle trace.nsd2\n"); return 2; }
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    u8 hdr[16];
    if (fread(hdr, 1, 16, f) != 16) return 2;
    if (rd32(hdr) != 0x3244534eu) { fprintf(stderr, "bad magic\n"); return 2; }
    u16 version = rd16(hdr + 4);
    if (version < 12) { fprintf(stderr, "need v12 trace (got %u)\n", version); return 2; }

    NDSArgs args; args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args));
    nds->Reset();
    auto& gpu = nds->GPU;
    auto& rend = gpu.GetRenderer();

    std::map<u32, std::array<std::vector<u32>, 192>> lines;
    u32 compared = 0, mismatched = 0, skipped = 0;
    bool printed = false;

    // GPU3D::Run is cycle-gated: it executes queued commands only once the
    // recorded ARM9 time has advanced past their pipeline delay. Every v12
    // type5/7/20-25 record carries the exact timestamp, so advance to it
    // before applying the event instead of forcing unbounded execution.
    auto advance = [&](u64 ts) {
        nds->ARM9Timestamp = ts;
        if (gpu.GPU3D.GeometryEnabled)
            gpu.GPU3D.Run();
    };
    auto settle = [&]() {
        if (gpu.GPU3D.GeometryEnabled && !gpu.GPU3D.FlushRequest)
            gpu.GPU3D.Run();
    };

    for (;;)
    {
        u8 rh[4];
        if (fread(rh, 1, 4, f) != 4) break;
        u16 type = rd16(rh), size = rd16(rh + 2);
        if (size < 4) return 2;
        std::vector<u8> body(size - 4);
        if (fread(body.data(), 1, body.size(), f) != body.size()) return 2;
        const u8* b = body.data();
        switch (type)
        {
        case 2:
        {
            u8 region = b[6];
            u32 off = rd32(b + 8);
            const u8* data = b + 12;
            size_t n = body.size() - 12;
            if (region == 0 && off + n <= sizeof(gpu.Palette))
                memcpy(gpu.Palette + off, data, n);
            else if (region == 1 && off + n <= sizeof(gpu.OAM))
                memcpy(gpu.OAM + off, data, n);
            else if (region >= 2 && region <= 10 && region < 13)
            {
                u32 bank = region - 2;
                if (off + n <= RegionSizes[region])
                    memcpy(gpu.VRAM[bank] + off, data, n);
            }
            break;
        }
        case 5: // superseded by type26 raw bus writes in this replay
            break;
        case 26:
        {
            advance(rd64(b + 4));
            u32 addr = rd32(b + 12), val = rd32(b + 16);
            u8 width = b[20];
            if (width == 1) gpu.GPU3D.Write8(addr, u8(val));
            else if (width == 2) gpu.GPU3D.Write16(addr, u16(val));
            else gpu.GPU3D.Write32(addr, val);
            break;
        }
        case 7: // superseded by type26
            break;
        case 20:
            advance(rd64(b + 4));
            gpu.GPU3D.SetEnabled(b[12] != 0, b[13] != 0);
            break;
        case 21:
            advance(rd64(b + 4));
            gpu.GPU3D.SetRenderXPos(rd16(b + 12), 0xFFFF);
            break;
        case 22:
            advance(rd64(b + 4));
            gpu.GPU3D.AbortFrame = b[12] != 0;
            break;
        case 23:
        {
            u32 frame = rd32(b);
            advance(rd64(b + 8));
            bool geom = b[18] != 0, rendering = b[19] != 0;
            bool initial = (b[20] & 1) != 0;
            gpu.GPU3D.SetEnabled(geom, rendering);
            gpu.GPU3D.SetRenderXPos(rd16(b + 16), 0xFFFF);
            for (u32 i = 0; i < 4; i++) gpu.VRAMMap_Texture[i] = rd32(b + 34 + 4 * i);
            for (u32 i = 0; i < 8; i++) gpu.VRAMMap_TexPal[i] = rd32(b + 50 + 4 * i);
            if (!initial)
            {
                rend.Start3DRendering();
                std::array<std::vector<u32>, 192>& out = lines[frame + 1];
                for (u32 y = 0; y < 192; y++)
                {
                    const u32* px = rend.Get3DScanline(y);
                    out[y].assign(px, px + 256);
                }
            }
            break;
        }
        case 24:
            advance(rd64(b + 8));
            gpu.GPU3D.AbortFrame = false;
            break;
        case 25:
            advance(rd64(b + 8));
            gpu.GPU3D.VBlank();
            break;
        case 3:
        {
            u32 frame = rd32(b);
            u32 line = rd16(b + 4);
            auto it = lines.find(frame);
            if (it == lines.end() || line >= 192) { ++skipped; break; }
            const std::vector<u32>& want = it->second[line];
            const u8* got = b + 8;
            bool bad = false;
            int first = -1;
            for (u32 x = 0; x < 256; x++)
                if (rd32(got + 4 * x) != want[x]) { bad = true; first = int(x); break; }
            ++compared;
            if (bad)
            {
                ++mismatched;
                if (!printed)
                {
                    printed = true;
                    printf("first re-render mismatch frame %u line %u x %d got %08x want %08x\n",
                           frame, line, first, rd32(got + 4 * first), want[first]);
                }
            }
            break;
        }
        default:
            break;
        }
    }
    fclose(f);
    printf("gx3d-trace-oracle: %u recorded lines compared, %u mismatched, %u skipped\n",
           compared, mismatched, skipped);
    return mismatched ? 1 : 0;
}
