// Standalone display-capture oracle: production SoftRenderer::DoCapture.
#define private public
#include <array>
#include <cstdio>
#include <cstring>
#include <memory>
#include <random>
#include <vector>
#include "NDS.h"
#include "GPU_Soft.h"
#undef private

using namespace melonDS;

namespace
{
constexpr u32 BankWords = 65536;
constexpr u32 BankBytes = BankWords * 2;

u16 bankWord(u32 seed, u32 bank, u32 i)
{
    return u16((seed * 37u + bank * 911u + i * 1103u + (i >> 7)) & 0xFFFF);
}

struct Case
{
    u32 captureCnt, line, lcdc, dispcnt, seed;
};
}

int main(int argc, char** argv)
{
    unsigned directed = 20, randomCases = 40;
    if (argc > 1) directed = std::stoul(argv[1]);
    if (argc > 2) randomCases = std::stoul(argv[2]);
    NDSArgs args; args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args));
    nds->Reset();
    auto& gpu = nds->GPU;
    auto& r = static_cast<SoftRenderer&>(nds->GetRenderer());
    std::vector<u32> src2d(256), src3d(256);
    std::vector<u16> fifo(256);
    std::array<u16, BankWords> before{};

    fwrite("CAP1", 1, 4, stdout);
    u32 total = directed + randomCases;
    fwrite(&total, 4, 1, stdout);

    for (u32 n = 0; n < total; n++)
    {
        Case c{};
        c.seed = n + 1;
        std::mt19937 rng(c.seed * 2654435761u + 7u);
        if (n < directed)
        {
            unsigned mode = n;
            c.captureCnt = 0x80000000u | (rng() & 0x1F1F);
            c.line = 0;
            c.lcdc = 0xF;
            c.dispcnt = 0;
            if (mode >= 2) { c.captureCnt = (c.captureCnt & 0xE0FFFFFFu) | (1u << 25); }
            if (mode >= 4) { c.captureCnt = (c.captureCnt & 0xE0FFFFFFu) | (2u << 25); }
            if (mode >= 6) { c.captureCnt |= (1u << 24); }
            if (mode >= 8) { c.captureCnt = (c.captureCnt & ~(3u << 20)) | (1u << 20); c.line = 3; }
            if (mode >= 10) { c.captureCnt = (c.captureCnt & ~(3u << 20)) | (2u << 20); c.line = 70; }
            if (mode >= 12) { c.captureCnt = (c.captureCnt & ~(3u << 20)); c.line = 40; }
            if (mode >= 14) { c.captureCnt = (c.captureCnt & ~(3u << 29)) | (1u << 29); }
            if (mode >= 16) { c.captureCnt = (c.captureCnt & ~(3u << 29)) | (2u << 29); }
            if (mode >= 18) { c.captureCnt = (c.captureCnt & ~0x3F0000u) | (1u << 18) | (2u << 16); }
            if (mode == 19) { c.lcdc = 0x1; c.captureCnt = (c.captureCnt & ~0x30000u) | (1u << 16); }
        }
        else
        {
            c.captureCnt = rng() & 0xEF3F1F1Fu;
            c.line = rng() % 192;
            c.lcdc = rng() & 0xF;
            c.dispcnt = rng() & 0x000F0000u;
            if (rng() & 1) c.dispcnt |= 2u << 16;
        }
        for (u32 b = 0; b < 4; b++)
            for (u32 i = 0; i < BankWords; i++)
                reinterpret_cast<u16*>(gpu.VRAM[b])[i] = bankWord(c.seed, b, i);
        for (u32 i = 0; i < 256; i++)
        {
            src2d[i] = rng(); src3d[i] = rng(); fifo[i] = rng();
        }
        u32 dstbank = (c.captureCnt >> 16) & 3;
        std::memcpy(before.data(), gpu.VRAM[dstbank], BankBytes);
        std::memcpy(r.Output2D[0], src2d.data(), 256 * 4);
        r.Output3D = src3d.data();
        std::memcpy(gpu.DispFIFOBuffer, fifo.data(), 256 * 2);
        gpu.CaptureCnt = c.captureCnt;
        gpu.VRAMMap_LCDC = c.lcdc;
        gpu.GPU2D_A.DispCnt = c.dispcnt;
        r.DoCapture(c.line);
        const u16* after = reinterpret_cast<const u16*>(gpu.VRAM[dstbank]);

        std::vector<std::pair<u32, u16>> changes;
        for (u32 i = 0; i < BankWords; i++)
            if (after[i] != before[i]) changes.push_back({i, after[i]});

        fwrite(&c.captureCnt, 4, 1, stdout);
        fwrite(&c.line, 4, 1, stdout);
        fwrite(&c.lcdc, 4, 1, stdout);
        fwrite(&c.dispcnt, 4, 1, stdout);
        fwrite(&c.seed, 4, 1, stdout);
        fwrite(src2d.data(), 4, 256, stdout);
        fwrite(src3d.data(), 4, 256, stdout);
        fwrite(fifo.data(), 2, 256, stdout);
        // Capture block lifecycle from GPU::CheckCaptureStart/End.
        std::memset(gpu.VRAMCaptureBlockFlags, 0, sizeof(gpu.VRAMCaptureBlockFlags));
        gpu.CaptureCnt = c.captureCnt;
        gpu.VRAMMap_LCDC = c.lcdc;
        gpu.CheckCaptureStart();
        u16 flagsStart[16];
        std::memcpy(flagsStart, gpu.VRAMCaptureBlockFlags, sizeof(flagsStart));
        gpu.CheckCaptureEnd();
        u16 flagsEnd[16];
        std::memcpy(flagsEnd, gpu.VRAMCaptureBlockFlags, sizeof(flagsEnd));

        u32 nch = changes.size();
        fwrite(&nch, 4, 1, stdout);
        for (auto& p : changes) { fwrite(&p.first, 4, 1, stdout); fwrite(&p.second, 2, 1, stdout); }
        fwrite(flagsStart, 2, 16, stdout);
        fwrite(flagsEnd, 2, 16, stdout);
    }
    return 0;
}
