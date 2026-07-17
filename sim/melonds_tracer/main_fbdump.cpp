// Headless melonDS framebuffer dump for the M5 frame diff (tb_top_frame).
// Boots a minimal .nds the same way the RTL HLE loader does (parse the
// header offset/entry/load/size fields, copy both sections, preset both
// CPU PCs — no firmware boot, no cart emulation) and runs whole frames,
// dumping the engine-A (top) screen after each one.
//
//   melonds_fbdump <image.nds> <dump.txt> <frames> [dump_b.txt]
//
// The optional 4th argument also dumps the bottom screen (engine B with
// POWCNT LCD-swap set) in the same format.
// Dump format: "frame <n>" then 49152 lines of 8-hex-digit ARGB words
// (melonDS native: 8-bit channels expanded from the internal 18-bit
// pipeline). sim/tests/compare_fb.py converts the RTL RGB555 dump with
// the same <<1 / <<2|>>4 expansion and diffs pixel-exact.
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "NDS.h"
#include "ARM.h"
#include "GPU.h"

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        fprintf(stderr, "usage: %s <image.nds> <dump.txt> <frames>\n", argv[0]);
        return 2;
    }
    const char* ndspath  = argv[1];
    const char* dumppath = argv[2];
    int frames = atoi(argv[3]);
    const char* dumppathb = (argc > 4) ? argv[4] : nullptr;

    FILE* f = fopen(ndspath, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", ndspath); return 1; }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0x200) { fprintf(stderr, "image too small\n"); return 1; }
    u8* img = new u8[len];
    if (fread(img, 1, len, f) != (size_t)len) { fprintf(stderr, "short read\n"); return 1; }
    fclose(f);

    u32 hdr[8];
    memcpy(hdr, &img[0x20], 32);
    u32 a9off = hdr[0], a9entry = hdr[1], a9load = hdr[2], a9size = hdr[3];
    u32 a7off = hdr[4], a7entry = hdr[5], a7load = hdr[6], a7size = hdr[7];
    printf("arm9: off=%08X entry=%08X load=%08X size=%u\n", a9off, a9entry, a9load, a9size);
    printf("arm7: off=%08X entry=%08X load=%08X size=%u\n", a7off, a7entry, a7load, a7size);

    if (!NDS::Init())
    {
        fprintf(stderr, "NDS::Init failed\n");
        return 1;
    }
    NDS::SetConsoleType(0);
    GPU::InitRenderer(0);                 // software renderer, single-threaded
    GPU::RenderSettings rs{};
    GPU::SetRenderSettings(0, rs);
    NDS::Reset();

    // HLE load, nds_loader semantics: sections go to main RAM (or ARM7 WRAM)
    auto copysec = [&](u32 off, u32 load, u32 size, int cpu) -> bool
    {
        if (off + size > (u32)len) { fprintf(stderr, "section outside image\n"); return false; }
        for (u32 i = 0; i < size; i += 4)
        {
            u32 w;
            memcpy(&w, &img[off + i], 4);
            if (cpu == 7) NDS::ARM7Write32(load + i, w);   // ARM7-WRAM loads
            else          NDS::ARM9Write32(load + i, w);
        }
        return true;
    };
    if (!copysec(a9off, a9load, a9size, 9)) return 1;
    if (!copysec(a7off, a7load, a7size, 7)) return 1;

    NDS::ARM9->JumpTo(a9entry);
    NDS::ARM7->JumpTo(a7entry);
    NDS::Start();

    FILE* d = fopen(dumppath, "w");
    if (!d) { fprintf(stderr, "cannot open %s\n", dumppath); return 1; }
    FILE* db = nullptr;
    if (dumppathb)
    {
        db = fopen(dumppathb, "w");
        if (!db) { fprintf(stderr, "cannot open %s\n", dumppathb); return 1; }
    }

    for (int n = 0; n < frames; n++)
    {
        NDS::RunFrame();
        int fb = GPU::FrontBuffer;
        u32* top = GPU::Framebuffer[fb][0];
        fprintf(d, "frame %d\n", n);
        for (int i = 0; i < 256 * 192; i++)
            fprintf(d, "%08x\n", top[i]);
        if (db)
        {
            u32* bot = GPU::Framebuffer[fb][1];
            fprintf(db, "frame %d\n", n);
            for (int i = 0; i < 256 * 192; i++)
                fprintf(db, "%08x\n", bot[i]);
        }
    }
    fclose(d);
    if (db) fclose(db);

    // scene-debug peeks (harmless noise for real runs)
    printf("DISPCNT=%08X POWCNT=%08X mail=%08X/%08X vb=%u\n",
           NDS::ARM9Read32(0x04000000), NDS::ARM9Read32(0x04000304),
           NDS::ARM9Read32(0x02FFFF00), NDS::ARM9Read32(0x02FFFF04),
           NDS::ARM9Read32(0x02FFFF08));
    printf("pal[0..3]=%08X %08X vram6000000=%08X map6002000=%08X oam=%08X\n",
           NDS::ARM9Read32(0x05000000), NDS::ARM9Read32(0x05000004),
           NDS::ARM9Read32(0x06000020), NDS::ARM9Read32(0x06002000),
           NDS::ARM9Read32(0x07000000));
    printf("dumped %d frames to %s\n", frames, dumppath);
    return 0;
}
