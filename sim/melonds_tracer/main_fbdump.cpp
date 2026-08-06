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
#include "SPI_Firmware.h"

// tracer.patch globals in ARM.cpp
namespace melonDS
{
extern FILE* ARM9TraceFile;
extern u64 ARM9TraceCount;
extern u64 ARM9TraceMax;
extern FILE* ARM7TraceFile;
extern u64 ARM7TraceCount;
extern u64 ARM7TraceMax;
// ARM7 IRQ census (see the NDS.cpp hook). IRQ7CENSUS=<n> prints the counts every
// n dump frames; the RTL side prints the same two numbers from irq_in7 and
// cpu7_irq every 10 ms of DS time, so the columns are directly comparable.
extern u64 Arm7IrqSrc[32];
extern u64 Arm7IrqDeliver;

static void printIrq7Census(int frame)
{
    printf("IRQ7 census frame %d deliveries=%llu", frame,
           (unsigned long long)Arm7IrqDeliver);
    for (int i = 0; i < 32; i++)
        if (Arm7IrqSrc[i]) printf("  b%d=%llu", i, (unsigned long long)Arm7IrqSrc[i]);
    printf("\n");
    fflush(stdout);
}
}

using namespace melonDS;

int main(int argc, char** argv)
{
    int argbase = 1;
    bool direct = false;
    bool fwboot = false;
    if (argc > 1 && strcmp(argv[1], "--direct") == 0) { direct = true; argbase = 2; }
    else if (argc > 1 && strcmp(argv[1], "--fw") == 0) { fwboot = true; argbase = 2; }
    if (argc < argbase + 3)
    {
        fprintf(stderr, "usage: %s [--direct|--fw] <image.nds> <dump.txt> <frames> [dump_b.txt]\n", argv[0]);
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

    // Default NDSArgs uses FreeBIOS. BIOS9/BIOS7 optionally replace those
    // images so differential traces can execute the exact ROMs served by RTL.
    // (heap-allocated: the 1.1 NDS object is far too large for the stack)
    auto nds_holder = std::make_unique<NDS>();
    NDS& nds = *nds_holder;
    auto loadBIOS = [](const char* envname, auto image, auto setter) -> bool
    {
        const char* path = getenv(envname);
        if (!path) return true;
        FILE* bf = fopen(path, "rb");
        if (!bf) { fprintf(stderr, "cannot open %s=%s\n", envname, path); return false; }
        bool ok = fread(image.data(), 1, image.size(), bf) == image.size();
        int extra = fgetc(bf);
        fclose(bf);
        if (!ok || extra != EOF) { fprintf(stderr, "%s has wrong size\n", path); return false; }
        setter(image);
        printf("loaded %s from %s\n", envname, path);
        return true;
    };
    if (!loadBIOS("BIOS9", nds.GetARM9BIOS(), [&](const auto& v) { nds.SetARM9BIOS(v); })) return 1;
    if (!loadBIOS("BIOS7", nds.GetARM7BIOS(), [&](const auto& v) { nds.SetARM7BIOS(v); })) return 1;
    nds.Reset();

    // --fw: real firmware boot. No SetupDirectBoot, no section copy - both
    // BIOSes run from their reset vectors and the firmware boots the cart
    // itself, exactly like the RTL's FWBOOT=1. This is the oracle for that
    // path: without it there is no way to tell "the ARM7 BIOS is grinding
    // through a boot stage" from "the ARM7 BIOS took an error branch",
    // because both look like a busy CPU that never reaches the game.
    // FIRMWARE=<path> must be a real dump; melonDS's generated default
    // firmware has no boot code and cannot boot a cart at all.
    if (fwboot)
    {
        const char* fwpath = getenv("FIRMWARE");
        if (!fwpath)
        {
            fprintf(stderr, "--fw needs FIRMWARE=<firmware.bin>\n");
            return 1;
        }
        FILE* ff = fopen(fwpath, "rb");
        if (!ff) { fprintf(stderr, "cannot open FIRMWARE=%s\n", fwpath); return 1; }
        fseek(ff, 0, SEEK_END);
        long fwlen = ftell(ff);
        fseek(ff, 0, SEEK_SET);
        u8* fwbuf = new u8[fwlen];
        if (fread(fwbuf, 1, fwlen, ff) != (size_t)fwlen)
        {
            fprintf(stderr, "short read on %s\n", fwpath);
            return 1;
        }
        fclose(ff);
        Firmware fw(fwbuf, (u32)fwlen);
        if (!fw.Buffer())
        {
            fprintf(stderr, "%s is not a valid firmware image\n", fwpath);
            return 1;
        }
        printf("firmware: %ld bytes, usersettings at 0x%X\n", fwlen, fw.GetUserDataOffset());
        nds.SetFirmware(std::move(fw));
        delete[] fwbuf;

        auto cart = NDSCart::ParseROM(img, (u32)len);
        if (!cart)
        {
            fprintf(stderr, "ParseROM failed\n");
            return 1;
        }
        nds.SetNDSCart(std::move(cart));
        nds.Reset();
        nds.Start();
    }
    else if (direct)
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

    const char* snapshotPrefix = getenv("SNAPSHOT_PREFIX");
    std::unique_ptr<u32[]> snapBG, snapOBJ, snapPAL, snapOAM;
    u32 snapRegs[22] = {};
    int lastfb = 0;
    int irq7census = 0;
    if (const char* ic = getenv("IRQ7CENSUS")) irq7census = atoi(ic);

    for (int n = 0; n < frames; n++)
    {
        if (irq7census > 0 && (n % irq7census) == 0) printIrq7Census(n);
        if (trace9path && n == trace9start && !ARM9TraceFile)
            ARM9TraceFile = fopen(trace9path, "w");
        if (trace7path && n == trace7start && !ARM7TraceFile)
            ARM7TraceFile = fopen(trace7path, "w");
        // dump-frame -> hardware-time map: RunFrame coalesces frames while
        // the LCD is off, so dump indices are NOT 60Hz hardware frames.
        // FRAMEMAP=1 prints the game's own vblank counter per dump frame.
        if (getenv("FRAMEMAP"))
            fprintf(stderr, "FRAMEMAP %d vb=%u\n", n, nds.ARM9Read32(0x02FFFF08));
        // VIDLOG=1: report the video-mode registers whenever they CHANGE, with the
        // dump-frame index and the game's own vblank counter.
        //
        // This exists because the RTL sim cannot answer the question it is asked.
        // Kirby's framebuffer is uniformly white in every reachable RTL window
        // (6 frames / 216 ms) because DISPCNT is 0, i.e. display OFF - which is the
        // hardware behaving correctly, not a rendering bug. The handoff's own rule
        // is to judge only after ~600 frames, which is ~10 s of simulated time and
        // out of reach. melonDS does hundreds of frames in seconds, so the "does
        // Kirby ever turn the display on, and to what mode" question belongs here.
        //
        // Reported on change rather than every frame: a 600-frame run is then a
        // handful of lines, and the first line where DISPCNT goes non-zero is the
        // answer. POWCNT1 (0x304) decides which engine reaches which screen at all,
        // so a display-on DISPCNT with the wrong POWCNT1 still shows nothing.
        if (getenv("VIDLOG"))
        {
            static u32 pa = 0xFFFFFFFF, pb = 0xFFFFFFFF, ppw = 0xFFFFFFFF;
            static u32 pds9 = 0xFFFFFFFF, pds7 = 0xFFFFFFFF;
            u32 da = nds.ARM9Read32(0x04000000);   // engine A DISPCNT
            u32 db = nds.ARM9Read32(0x04001000);   // engine B DISPCNT
            u32 pw = nds.ARM9Read16(0x04000304);   // POWCNT1
            // DISPSTAT is per-CPU. Bit 3 is that CPU's VBlank IRQ enable, and on
            // real hardware the ARM9 sleeps in WFI forever without it. Logged
            // because our core freezes with IE9 VBlank set but IF9 bit 0 never
            // latching, while the ARM7 does receive VBlank.
            u32 ds9 = nds.ARM9Read16(0x04000004);
            u32 ds7 = nds.ARM7Read16(0x04000004);
            // IPCFIFOCNT per CPU: bit 15 = FIFO enable, bit 10 = recv-not-empty
            // IRQ enable. Our RTL shows en9=1/rirq9=1 but en7=0 at 75 ms, and a
            // send with the sender's enable clear is DROPPED - which is exactly
            // why IF9 bit 18 never latches. This says whether the real ARM7 ever
            // enables its FIFO, and when.
            u32 fc9 = nds.ARM9Read16(0x04000184);
            u32 fc7 = nds.ARM7Read16(0x04000184);
            static u32 pfc9 = 0xFFFFFFFF, pfc7 = 0xFFFFFFFF;
            if (fc9 != pfc9 || fc7 != pfc7)
            {
                fprintf(stderr, "IPCCNT frame=%d CNT9=%04X (en=%u rirq=%u) "
                        "CNT7=%04X (en=%u rirq=%u)\n", n,
                        fc9, (fc9>>15)&1, (fc9>>10)&1,
                        fc7, (fc7>>15)&1, (fc7>>10)&1);
                pfc9 = fc9; pfc7 = fc7;
            }
            if (ds9 != pds9 || ds7 != pds7)
            {
                fprintf(stderr, "VBLENA frame=%d DISPSTAT9=%04X (vblIRQ=%u) "
                        "DISPSTAT7=%04X (vblIRQ=%u)\n", n, ds9, (ds9>>3)&1,
                        ds7, (ds7>>3)&1);
                pds9 = ds9; pds7 = ds7;
            }
            // IRQ controllers, both CPUs, reported on change. Directly comparable
            // to `nitrodbg.sh irq` (mailbox op 0x0C) on hardware, which is the only
            // way to read these there - PEEK borrows the ARM9 main-RAM channel and
            // returns garbage for IO space. The question this answers: our hardware
            // sits with IE9=0x00040001 (VBlank + IPC-recv only) while IF9 bit 19
            // (card transfer complete) is latched and unacknowledged. If the oracle
            // never enables bit 19 either, the card driver polls and that latched
            // flag is a red herring; if it does enable it, the ARM9's card-done
            // wakeup is simply missing and the blocked main thread is explained.
            {
                static u32 pi[6] = {0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,
                                    0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF};
                u32 c[6] = { nds.ARM9Read32(0x04000208), nds.ARM9Read32(0x04000210),
                             nds.ARM9Read32(0x04000214), nds.ARM7Read32(0x04000208),
                             nds.ARM7Read32(0x04000210), nds.ARM7Read32(0x04000214) };
                bool ch = false;
                for (int i = 0; i < 6; i++) if (c[i] != pi[i]) ch = true;
                if (ch)
                {
                    fprintf(stderr, "IRQREG frame=%d IME9=%08X IE9=%08X IF9=%08X"
                            "  IME7=%08X IE7=%08X IF7=%08X\n",
                            n, c[0], c[1], c[2], c[3], c[4], c[5]);
                    for (int i = 0; i < 6; i++) pi[i] = c[i];
                }
            }
            if (da != pa || db != pb || pw != ppw)
            {
                fprintf(stderr,
                        "VIDLOG frame=%d vb=%u DISPCNT_A=%08X (mode %u%s) "
                        "DISPCNT_B=%08X POWCNT1=%04X\n",
                        n, nds.ARM9Read32(0x02FFFF08), da, (da >> 16) & 3,
                        ((da >> 16) & 3) ? "" : " = DISPLAY OFF", db, pw);
                pa = da; pb = db; ppw = pw;
            }
        }
        // Capture the inputs immediately before the final rendered frame;
        // games commonly update palettes at VBlank, so an end-of-run state
        // dump is one animation step newer than the displayed front buffer.
        if (snapshotPrefix && n == frames - 1)
        {
            snapBG.reset(new u32[131072]); snapOBJ.reset(new u32[65536]);
            snapPAL.reset(new u32[256]);   snapOAM.reset(new u32[256]);
            for (u32 i = 0; i < 131072; i++) snapBG[i] = nds.ARM9Read32(0x06000000 + i*4);
            for (u32 i = 0; i <  65536; i++) snapOBJ[i] = nds.ARM9Read32(0x06400000 + i*4);
            for (u32 i = 0; i <    256; i++) snapPAL[i] = nds.ARM9Read32(0x05000000 + i*4);
            for (u32 i = 0; i <    256; i++) snapOAM[i] = nds.ARM9Read32(0x07000000 + i*4);
            for (u32 i = 0; i <     22; i++) snapRegs[i] = nds.ARM9Read32(0x04000000 + i*4);
        }
        nds.RunFrame();
        int fb = nds.GPU.FrontBuffer;
        lastfb = fb;
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

    // NDS_MiSTfits: ARM7WRAMDUMP=<file> writes the ARM7's view of
    // 0x037F8000..0x0380FFFF, one hex word per line, so the RTL's shared/private
    // WRAM can be diffed against the oracle word for word. This covers the
    // firmware's decompressed ARM7 boot block (the ARM7 BIOS puts it at
    // 0x03810000 - hdr[0x12]*256 = 0x037FA800) and, at the top, the BIOS IRQ
    // handler's user-handler pointer at 0x0380FFFC.
    //
    // Read through ARM7Read32 on purpose, not off the raw arrays: it is the CPU's
    // own decode, so whatever WRAMCNT is doing to the shared bank is applied
    // exactly as the RTL's nds_membus7 applies it. Reading ARM7WRAM[] directly
    // would answer a different question.
    if (const char* wp = getenv("ARM7WRAMDUMP"))
    {
        FILE* wf = fopen(wp, "w");
        if (wf)
        {
            for (u32 a = 0x037F8000; a < 0x03810000; a += 4)
                fprintf(wf, "%08X\n", nds.ARM7Read32(a));
            fclose(wf);
            printf("ARM7WRAMDUMP wrote 0x037F8000..0x0380FFFF to %s\n", wp);
        }
    }
    printf("ARM7 irq handler ptr [0380FFFC]=%08X  [0380FFF8]=%08X\n",
           nds.ARM7Read32(0x0380FFFC), nds.ARM7Read32(0x0380FFF8));

    // scene-debug peeks (harmless noise for real runs)
    printf("DISPCNT=%08X POWCNT=%08X mail=%08X/%08X vb=%u\n",
           nds.ARM9Read32(0x04000000), nds.ARM9Read32(0x04000304),
           nds.ARM9Read32(0x02FFFF00), nds.ARM9Read32(0x02FFFF04),
           nds.ARM9Read32(0x02FFFF08));
    printf("pal[0..3]=%08X %08X vram6000000=%08X map6002000=%08X oam=%08X\n",
           nds.ARM9Read32(0x05000000), nds.ARM9Read32(0x05000004),
           nds.ARM9Read32(0x06000020), nds.ARM9Read32(0x06002000),
           nds.ARM9Read32(0x07000000));
    printf("BG0CNT..BG3CNT=%04X %04X %04X %04X MASTER_BRIGHT=%04X\n",
           nds.ARM9Read16(0x04000008), nds.ARM9Read16(0x0400000A),
           nds.ARM9Read16(0x0400000C), nds.ARM9Read16(0x0400000E),
           nds.ARM9Read16(0x0400006C));
    printf("BG2PA..PD=%04X %04X %04X %04X BG2X/Y=%08X/%08X\n",
           nds.ARM9Read16(0x04000020), nds.ARM9Read16(0x04000022),
           nds.ARM9Read16(0x04000024), nds.ARM9Read16(0x04000026),
           nds.ARM9Read32(0x04000028), nds.ARM9Read32(0x0400002C));
    printf("BG3PA..PD=%04X %04X %04X %04X BG3X/Y=%08X/%08X\n",
           nds.ARM9Read16(0x04000030), nds.ARM9Read16(0x04000032),
           nds.ARM9Read16(0x04000034), nds.ARM9Read16(0x04000036),
           nds.ARM9Read32(0x04000038), nds.ARM9Read32(0x0400003C));
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
    // SNAPSHOT_PREFIX=<path> emits a directly consumable tb_gpu2d snapshot.
    // The boot card uses main BG3 + standard palette; the other stores are
    // included so the same hook remains useful for later 2D divergences.
    if (const char* prefix = snapshotPrefix)
    {
        auto dumpWords = [&](const char* suffix, const u32* data, u32 words)
        {
            char path[1024];
            snprintf(path, sizeof(path), "%s_%s.hex", prefix, suffix);
            FILE* f = fopen(path, "w");
            if (!f) { fprintf(stderr, "cannot open snapshot %s\n", path); exit(1); }
            for (u32 i = 0; i < words; i++) fprintf(f, "%08X\n", data[i]);
            fclose(f);
        };
        auto dumpZeros = [&](const char* suffix, u32 words)
        {
            char path[1024];
            snprintf(path, sizeof(path), "%s_%s.hex", prefix, suffix);
            FILE* f = fopen(path, "w");
            if (!f) { fprintf(stderr, "cannot open snapshot %s\n", path); exit(1); }
            for (u32 i = 0; i < words; i++) fprintf(f, "00000000\n");
            fclose(f);
        };
        dumpWords("bgvram",  snapBG.get(),  131072);
        dumpWords("objvram", snapOBJ.get(),  65536);
        dumpWords("pal",     snapPAL.get(),    256);
        dumpWords("oam",     snapOAM.get(),    256);
        dumpZeros("bgep", 8192);
        dumpZeros("objep", 2048);

        char framepath[1024];
        snprintf(framepath, sizeof(framepath), "%s_frames.hex", prefix);
        FILE* f = fopen(framepath, "w");
        if (!f) { fprintf(stderr, "cannot open snapshot %s\n", framepath); return 1; }
        fprintf(f, "00000001\n");
        for (u32 i = 0; i < 22; i++) fprintf(f, "%08X\n", snapRegs[i]);
        for (u32 i = 22; i < 32; i++) fprintf(f, "00000000\n");
        u32* top = nds.GPU.Framebuffer[lastfb][0].get();
        for (u32 i = 0; i < 256*192; i++)
        {
            u32 p = top[i];
            u32 r = (p >> 16) & 0xFF, g = (p >> 8) & 0xFF, b = (p >> 0) & 0xFF;
            fprintf(f, "%08X\n", (r >> 2) | ((g >> 2) << 6) | ((b >> 2) << 12));
        }
        fclose(f);
        printf("snapshot dumped with prefix %s\n", prefix);
    }
    if (irq7census > 0) printIrq7Census(frames);
    printf("dumped %d frames to %s\n", frames, dumppath);
    return 0;
}
