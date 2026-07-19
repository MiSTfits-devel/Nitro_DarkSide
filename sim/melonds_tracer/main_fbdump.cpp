// Headless melonDS framebuffer dump for the M5 frame diff (tb_top_frame).
// Boots a minimal .nds the same way the RTL HLE loader does (parse the
// header offset/entry/load/size fields, copy both sections, preset both
// CPU PCs — no firmware boot, no cart emulation) and runs whole frames,
// dumping the engine-A (top) screen after each one.
//
//   melonds_fbdump [--direct] <image.nds> <dump.txt> <frames> [dump_b.txt]
//
// --direct uses melonDS's own cart + SetupDirectBoot path (full boot
// environment: header copy, chip IDs, user settings, CP15 preset) for
// stock libnds/calico ROMs; the default stays the HLE-loader-equivalent
// section copy matching the RTL nds_loader.
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
#include <memory>

#include "NDS.h"
#include "NDSCart.h"
#include "ARM.h"
#include "GPU.h"

// tracer.patch globals in ARM.cpp
namespace melonDS
{
extern FILE* ARM9TraceFile;
extern u64 ARM9TraceCount;
extern u64 ARM9TraceMax;
extern FILE* ARM7TraceFile;
extern u64 ARM7TraceCount;
extern u64 ARM7TraceMax;
}

using namespace melonDS;

int main(int argc, char** argv)
{
    int argbase = 1;
    bool direct = false;
    if (argc > 1 && strcmp(argv[1], "--direct") == 0) { direct = true; argbase = 2; }
    if (argc < argbase + 3)
    {
        fprintf(stderr, "usage: %s [--direct] <image.nds> <dump.txt> <frames> [dump_b.txt]\n", argv[0]);
        return 2;
    }
    const char* ndspath  = argv[argbase];
    const char* dumppath = argv[argbase + 1];
    int frames = atoi(argv[argbase + 2]);
    const char* dumppathb = (argc > argbase + 3) ? argv[argbase + 3] : nullptr;

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

    // default NDSArgs: FreeBIOS, generated firmware, software renderer
    // (heap-allocated: the 1.1 NDS object is far too large for the stack)
    auto nds_holder = std::make_unique<NDS>();
    NDS& nds = *nds_holder;
    nds.Reset();

    if (direct)
    {
        auto cart = NDSCart::ParseROM(img, (u32)len);
        if (!cart)
        {
            fprintf(stderr, "ParseROM failed\n");
            return 1;
        }
        nds.SetNDSCart(std::move(cart));
        nds.Reset();
        nds.SetupDirectBoot("rom.nds");
        nds.Start();
    }
    else
    {
    // HLE load, nds_loader semantics: sections go to main RAM (or ARM7 WRAM)
    auto copysec = [&](u32 off, u32 load, u32 size, int cpu) -> bool
    {
        if (off + size > (u32)len) { fprintf(stderr, "section outside image\n"); return false; }
        for (u32 i = 0; i < size; i += 4)
        {
            u32 w;
            memcpy(&w, &img[off + i], 4);
            if (cpu == 7) nds.ARM7Write32(load + i, w);   // ARM7-WRAM loads
            else          nds.ARM9Write32(load + i, w);
        }
        return true;
    };
    if (!copysec(a9off, a9load, a9size, 9)) return 1;
    if (!copysec(a7off, a7load, a7size, 7)) return 1;

    nds.ARM9.JumpTo(a9entry);
    nds.ARM7.JumpTo(a7entry);
    nds.Start();
    }

    // TRACE9=<path> [TRACE9MAX=<n>] dumps the ARM9 instruction trace
    // (tracer.patch hook) - the debug view for stock-ROM boot issues.
    // TRACE7/TRACE7MAX: same for the ARM7.
    // TRACE9STARTFRAME=<n> defers the trace to frame n (divergence hunting
    // without a multi-GB from-boot trace); same for TRACE7STARTFRAME.
    const char* trace9path = getenv("TRACE9");
    const char* trace7path = getenv("TRACE7");
    int trace9start = 0, trace7start = 0;
    if (const char* ts = getenv("TRACE9STARTFRAME")) trace9start = atoi(ts);
    if (const char* ts = getenv("TRACE7STARTFRAME")) trace7start = atoi(ts);
    if (trace9path)
    {
        const char* tm = getenv("TRACE9MAX");
        ARM9TraceMax = tm ? strtoull(tm, nullptr, 0) : 20000000ull;
        if (trace9start == 0) ARM9TraceFile = fopen(trace9path, "w");
    }
    if (trace7path)
    {
        const char* tm = getenv("TRACE7MAX");
        ARM7TraceMax = tm ? strtoull(tm, nullptr, 0) : 20000000ull;
        if (trace7start == 0) ARM7TraceFile = fopen(trace7path, "w");
    }

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
        if (trace9path && n == trace9start && !ARM9TraceFile)
            ARM9TraceFile = fopen(trace9path, "w");
        if (trace7path && n == trace7start && !ARM7TraceFile)
            ARM7TraceFile = fopen(trace7path, "w");
        nds.RunFrame();
        int fb = nds.GPU.FrontBuffer;
        u32* top = nds.GPU.Framebuffer[fb][0].get();
        fprintf(d, "frame %d\n", n);
        for (int i = 0; i < 256 * 192; i++)
            fprintf(d, "%08x\n", top[i]);
        if (db)
        {
            u32* bot = nds.GPU.Framebuffer[fb][1].get();
            fprintf(db, "frame %d\n", n);
            for (int i = 0; i < 256 * 192; i++)
                fprintf(db, "%08x\n", bot[i]);
        }
    }
    fclose(d);
    if (db) fclose(db);
    if (ARM9TraceFile) { fclose(ARM9TraceFile); ARM9TraceFile = nullptr; }
    if (ARM7TraceFile) { fclose(ARM7TraceFile); ARM7TraceFile = nullptr; }

    // scene-debug peeks (harmless noise for real runs)
    printf("DISPCNT=%08X POWCNT=%08X mail=%08X/%08X vb=%u\n",
           nds.ARM9Read32(0x04000000), nds.ARM9Read32(0x04000304),
           nds.ARM9Read32(0x02FFFF00), nds.ARM9Read32(0x02FFFF04),
           nds.ARM9Read32(0x02FFFF08));
    printf("pal[0..3]=%08X %08X vram6000000=%08X map6002000=%08X oam=%08X\n",
           nds.ARM9Read32(0x05000000), nds.ARM9Read32(0x05000004),
           nds.ARM9Read32(0x06000020), nds.ARM9Read32(0x06002000),
           nds.ARM9Read32(0x07000000));
    // sub-engine / console probes
    {
        int nzc = 0;
        for (u32 i = 0; i < 128*1024; i += 4)
            if (*(u32*)&nds.GPU.VRAM_C[i]) nzc++;
        printf("VRAMCNT=");
        for (int b = 0; b < 9; b++) printf("%02X", nds.GPU.VRAMCNT[b]);
        printf(" subDISPCNT=%08X subBG0CNT=%04X vramC_nz=%d\n",
               nds.ARM9Read32(0x04001000), nds.ARM9Read16(0x04001008), nzc);
        printf("subpal[0..3]=%08X %08X vram6200000=%08X %08X\n",
               nds.ARM9Read32(0x05000400), nds.ARM9Read32(0x05000404),
               nds.ARM9Read32(0x06200000), nds.ARM9Read32(0x06200004));
    }
    printf("dumped %d frames to %s\n", frames, dumppath);
    return 0;
}
