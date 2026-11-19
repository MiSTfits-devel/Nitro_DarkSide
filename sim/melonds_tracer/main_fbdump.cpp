// Headless melonDS framebuffer dump for the M5 frame diff (tb_top_frame).
// Boots a minimal .nds the same way the RTL HLE loader does (parse the
// header offset/entry/load/size fields, copy both sections, preset both
// CPU PCs — no firmware boot, no cart emulation) and runs whole frames,
// dumping the engine-A (top) screen after each one.
//
//   melonds_fbdump [--direct] [--input FILE] <image.nds> <dump.txt> <frames> [dump_b.txt]
//
//   melonds_fbdump --hs-gpu LIB [--hs-ndsf FILE|-] [--hs-txn-log FILE] --direct <image.nds> <dump.txt> <frames>
//   (closed-loop Haskell GPU backend; see NDS::RunFrameHs in third_party/melonDS/src/NDSHsGpu.cpp)
// --input polls a 16-byte little-endian control file before every frame:
// "NDSI", u32 key mask (melonDS SetKeyMask order, active low, 12 bits),
// u32 touch (bit 31 pressed, x bits 0-7, y bits 8-15), u32 sequence.
// Changes are applied with SetKeyMask/TouchScreen/ReleaseScreen and logged
// to stderr. After each frame the sequence that frame ran with is written
// back at byte 16, so the writer (tools/hs_gpu_view/NdsView.swift) can hold
// short taps until the emulated CPU has seen them.
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
#include <vector>
#include <fcntl.h>
#include <unistd.h>

#include "NDS.h"
#include "NDSCart.h"
#ifdef NDS4MISTER_VENDORED_FORK
#include "NDS4MiSTer_2DTrace.h"
#endif
#include "ARM.h"
#include "GPU.h"
#include "SPI_Firmware.h"

#ifndef NDS4MISTER_VENDORED_FORK
// tracer.patch globals in ARM.cpp. The vendored NDS4MiSTer fork has the
// NSD2 2D trace instead; its instruction-trace and IRQ-census hooks live in
// the patched upstream tree, so those debug knobs compile only there.
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
#endif

#include <string>
#include <unistd.h>
#include "HsGpu.h"
using namespace melonDS;

static void getFramebuffers(GPU& gpu, u32*& top, u32*& bottom)
{
#ifdef NDS4MISTER_VENDORED_FORK
    void* t = nullptr;
    void* b = nullptr;
    gpu.GetFramebuffers(&t, &b);
    top = static_cast<u32*>(t);
    bottom = static_cast<u32*>(b);
#else
    int fb = gpu.FrontBuffer;
    top = gpu.Framebuffer[fb][0].get();
    bottom = gpu.Framebuffer[fb][1].get();
#endif
}

// --trace2d: write the vendored fork's packed NSD2 stream verbatim. The runner
// never decodes records: new versioned record types must pass through unchanged.
namespace
{
struct Trace2DFileState
{
    FILE* file = nullptr;
    unsigned long long bytes = 0;
    bool failed = false;
};

void trace2dSink(const void* data, size_t size, void* userdata)
{
    auto* state = static_cast<Trace2DFileState*>(userdata);
    if (!state || !state->file) return;
    if (fwrite(data, 1, size, state->file) != size)
    {
        state->failed = true;
        return;
    }
    state->bytes += size;
}

// --input: see the file header. Short or foreign reads leave input unchanged.
struct LiveInput
{
    int fd = -1;
    u32 keys = 0xFFF;
    u32 touch = 0;
    u32 seq = 0;
    u32 acked = 0;
};

void pollLiveInput(LiveInput& in, NDS& nds, int frame)
{
    if (in.fd < 0) return;
    if (in.seq != in.acked && pwrite(in.fd, &in.seq, 4, 16) == 4) in.acked = in.seq;
    unsigned char b[16];
    if (pread(in.fd, b, sizeof b, 0) != (ssize_t)sizeof b) return;
    auto le = [&](int o) { return (u32)b[o] | (u32)b[o+1] << 8 | (u32)b[o+2] << 16 | (u32)b[o+3] << 24; };
    if (memcmp(b, "NDSI", 4) != 0) return;
    u32 keys = le(4) & 0xFFF, touch = le(8), seq = le(12);
    if (keys != in.keys)
        nds.SetKeyMask(keys);
    if (touch != in.touch)
    {
        if (touch & 0x80000000u)
            nds.TouchScreen(touch & 0xFF, ((touch >> 8) & 0xFF) > 191 ? 191 : (touch >> 8) & 0xFF);
        else
            nds.ReleaseScreen();
    }
    if (keys != in.keys || touch != in.touch)
        fprintf(stderr, "input frame=%d seq=%u keys=%03X touch=%s x=%u y=%u\n", frame, seq, keys,
                (touch & 0x80000000u) ? "down" : "up", touch & 0xFF, (touch >> 8) & 0xFF);
    in.keys = keys; in.touch = touch; in.seq = seq;
}
}

int main(int argc, char** argv)
{
    bool direct = false;
    bool fwboot = false;
    const char* trace2dpath = nullptr;
    bool trace2dphase = false;
    bool trace2dprovenance = false;
    bool trace2draw3d = false;
    const char* hsLib = nullptr;
    const char* hsNdsf = nullptr;
    const char* hsTxnLog = nullptr;
    bool hsProfile = false;
    bool noTextDump = false;
    const char* clockLogPath = nullptr;
    const char* ramDump = nullptr;
    bool schedInterleave = false;
    FILE* clockLog = nullptr;
    std::vector<const char*> positional;
    LiveInput liveInput;
    for (int i = 1; i < argc; i++)
    {
        if (strcmp(argv[i], "--direct") == 0) direct = true;
        else if (strcmp(argv[i], "--fw") == 0) fwboot = true;
        else if (strcmp(argv[i], "--trace2d-phase") == 0) trace2dphase = true;
        else if (strcmp(argv[i], "--trace2d-provenance") == 0) trace2dprovenance = true;
        else if (strcmp(argv[i], "--trace2d-raw3d") == 0) trace2draw3d = true;
        else if (strcmp(argv[i], "--trace2d") == 0)
        {
            if (i + 1 >= argc)
            {
                fprintf(stderr, "--trace2d needs a file\n");
                return 2;
            }
            trace2dpath = argv[++i];
        }
        else if (strncmp(argv[i], "--trace2d=", 10) == 0) trace2dpath = argv[i] + 10;
        else if (strcmp(argv[i], "--hs-gpu") == 0 && i + 1 < argc) hsLib = argv[++i];
        else if (strcmp(argv[i], "--hs-ndsf") == 0 && i + 1 < argc) hsNdsf = argv[++i];
        else if (strcmp(argv[i], "--hs-txn-log") == 0 && i + 1 < argc) hsTxnLog = argv[++i];
        else if (strcmp(argv[i], "--hs-profile") == 0) hsProfile = true;
        else if (strcmp(argv[i], "--no-text-dump") == 0) noTextDump = true;
        else if (strcmp(argv[i], "--clock-log") == 0 && i + 1 < argc) clockLogPath = argv[++i];
        else if (strcmp(argv[i], "--ram-dump") == 0 && i + 1 < argc) ramDump = argv[++i];
        else if (strcmp(argv[i], "--sched=interleave") == 0) schedInterleave = true;
        else if (strcmp(argv[i], "--input") == 0 && i + 1 < argc)
        {
            liveInput.fd = open(argv[++i], O_RDWR);
            if (liveInput.fd < 0)
            {
                fprintf(stderr, "cannot open --input %s\n", argv[i]);
                return 2;
            }
        }
        else positional.push_back(argv[i]);
    }
    if ((trace2dphase || trace2dprovenance || trace2draw3d) && !trace2dpath)
    {
        fprintf(stderr, "--trace2d-phase/--trace2d-provenance/--trace2d-raw3d need --trace2d <file>\n");
        return 2;
    }
    if ((hsNdsf || hsTxnLog) && !hsLib)
    {
        fprintf(stderr, "--hs-ndsf/--hs-txn-log need --hs-gpu <lib>\n");
        return 2;
    }
    if (hsLib && (trace2dpath || getenv("VIDLOG") || getenv("SNAPSHOT_PREFIX") || fwboot))
    {
        fprintf(stderr, "--hs-gpu does not support --trace2d, --fw, VIDLOG or SNAPSHOT_PREFIX "
                        "(they read or replay stock GPU state)\n");
        return 2;
    }
    // --hs-ndsf '-': the binary record stream owns the original stdout. Move stdout to
    // stderr BEFORE anything else (ROM metadata, dlopen/RTS init, all later printf) can
    // write to it. No fflush here: nothing has been written yet.
    FILE* ndsfEarly = nullptr;
    if (hsNdsf && strcmp(hsNdsf, "-") == 0)
    {
        const int out = dup(1);
        if (out < 0 || dup2(2, 1) < 0) { fprintf(stderr, "cannot redirect stdout\n"); return 1; }
        ndsfEarly = fdopen(out, "wb");
        if (!ndsfEarly) { fprintf(stderr, "cannot open --hs-ndsf stdout stream\n"); return 1; }
    }
    if (positional.size() < 3)
    {
        fprintf(stderr, "usage: %s [--direct|--fw] [--input <file>] [--trace2d <file> [--trace2d-phase]]"
                        " <image.nds> <dump.txt> <frames> [dump_b.txt]\n", argv[0]);
        fprintf(stderr, "  --trace2d defaults to v9; --trace2d-phase selects v10; "
                        "--trace2d-provenance selects v11 (capture Begin/Delta/End + lifecycle); "
                        "--trace2d-raw3d selects v12 (ordered raw 3D power/XPos/abort/render-start/"
                        "VBlank/frame-end, render-start memory and texture maps).\n");
        fprintf(stderr, "  --hs-gpu <lib.dylib> runs the closed-loop Haskell GPU (HsGpuAbi.h): every GPU register,\n"
                        "    memory, timing, IRQ and DMA request is answered by the device; stock GPU code never runs.\n"
                        "    --hs-ndsf <file|-> writes one NDSF record per frame from the device pixels ('-' = stdout,\n"
                        "    logs move to stderr); --hs-txn-log <file> logs every device call with the actual access\n"
                        "    clock. Not combinable with --trace2d/--fw/VIDLOG/SNAPSHOT_PREFIX. Exit 4 = device failure.\n");
        fprintf(stderr, "  --hs-ndsf ends the stream with an NDSE record (status 0 normal end, 1 error + message).\n"
                        "  --hs-profile prints per-op device call counts at exit: exact ADVANCE timings; 1/256-sampled bus timings (--hs-gpu).\n"
                        "  --clock-log <file> writes per dump frame: emulated ARM9/ARM7 system cycles, device frame,\n"
                        "    real RunFrame/cumulative wall ms and input-file sequence/ack wall time.\n"
                        "  --no-text-dump skips the text frame dump entirely: <dump.txt>/[dump_b.txt] are still\n"
                        "    positionals for the legacy interface but are ignored (no file created, no hex formatting).\n"
                        "  --sched=interleave runs the STOCK GPU under the hs min-clock CPU coordinator (control for\n"
                        "    --hs-gpu; not combinable with it).\n");
        return 2;
    }
    const char* ndspath  = positional[0];
    const char* dumppath = positional[1];
    int frames = atoi(positional[2]);
    const char* dumppathb = (positional.size() > 3) ? positional[3] : nullptr;

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
    const auto wallOrigin = std::chrono::steady_clock::now();
    double ackWallMs = -1.0;
    if (clockLogPath)
    {
        clockLog = fopen(clockLogPath, "w");
        if (!clockLog) { fprintf(stderr, "cannot open --clock-log %s\n", clockLogPath); return 1; }
    }
    std::unique_ptr<HsGpuClient> hsClient;
    FILE* ndsfOut = nullptr;
    // Terminal record, same 20-byte layout as TraceView: "NDSE", u32 status (0 end of
    // stream, 1 error), u32 message bytes, u64 0, then the UTF-8 message. Always last.
    auto endNdsf = [&](u32 status, const char* message) -> bool
    {
        const size_t len = strlen(message);
        const u32 head[5] = { 0x4553444E /* "NDSE" little-endian */, status, (u32)len, 0, 0 };
        bool ok = fwrite(head, 4, 5, ndsfOut) == 5 && fwrite(message, 1, len, ndsfOut) == len
                  && fflush(ndsfOut) == 0;
        if (fclose(ndsfOut) != 0) ok = false;
        ndsfOut = nullptr;
        if (!ok) fprintf(stderr, "cannot write --hs-ndsf terminal record\n");
        return ok;
    };
    FILE* txnLog = nullptr;
    if (hsLib)
    {
        std::string hsError;
        hsClient = HsGpuClient::Open(hsLib, hsError);
        if (!hsClient)
        {
            fprintf(stderr, "--hs-gpu: %s\n", hsError.c_str());
            return 1;
        }
        if (hsProfile) hsClient->EnableProfile();
        if (hsNdsf)
        {
            if (!ndsfEarly)
                ndsfOut = fopen(hsNdsf, "wb");
            else
                ndsfOut = ndsfEarly;
            if (!ndsfOut) { fprintf(stderr, "cannot open --hs-ndsf %s\n", hsNdsf); return 1; }
        }
        if (hsTxnLog)
        {
            txnLog = fopen(hsTxnLog, "w");
            if (!txnLog) { fprintf(stderr, "cannot open --hs-txn-log %s\n", hsTxnLog); return 1; }
        }
    }
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
    if (hsClient)
    {
        std::string hsError;
        if (!nds.AttachHsGpu(hsClient.get(), hsError))
        {
            fprintf(stderr, "--hs-gpu: %s\n", hsError.c_str());
            return 1;
        }
        nds.SetHsGpuTransactionLog(txnLog);
    }
    if (schedInterleave)
    {
        if (hsClient) { fprintf(stderr, "--sched=interleave is the stock-GPU control; not with --hs-gpu\n"); return 2; }
        nds.InterleavedSchedule = true;
    }
    nds.Reset();

    // Attach the trace immediately before the first execution. The extension
    // mode must be selected before MakeTrace2DFileHeader and SetTrace2DSink:
    // it changes the header version and which records the fork emits.
#ifdef NDS4MISTER_VENDORED_FORK
    Trace2DFileState trace2d;
    melonDS::NDS4MiSTer::Trace2DFileHeader trace2dHeader {};
    bool trace2dAttached = false;
    auto attachTrace = [&]() -> bool
    {
        if (!trace2dpath) return true;
        trace2d.file = fopen(trace2dpath, "wb");
        if (!trace2d.file)
        {
            fprintf(stderr, "cannot open --trace2d %s\n", trace2dpath);
            return false;
        }
        if (trace2draw3d && !melonDS::NDS4MiSTer::SetTrace2DRaw3DInputs(true))
        {
            fprintf(stderr, "--trace2d-raw3d: sink already attached\n");
            return false;
        }
        if (trace2dprovenance && !melonDS::NDS4MiSTer::SetTrace2DCaptureProvenance(true))
        {
            fprintf(stderr, "--trace2d-provenance: sink already attached\n");
            return false;
        }
        if (!trace2dprovenance && !trace2draw3d && trace2dphase
            && !melonDS::NDS4MiSTer::SetTrace2DExtensions(true))
        {
            fprintf(stderr, "--trace2d-phase: sink already attached\n");
            return false;
        }
        trace2dHeader = melonDS::NDS4MiSTer::MakeTrace2DFileHeader();
        if (fwrite(&trace2dHeader, 1, sizeof(trace2dHeader), trace2d.file)
            != sizeof(trace2dHeader))
        {
            fprintf(stderr, "cannot write --trace2d header\n");
            return false;
        }
        melonDS::NDS4MiSTer::SetTrace2DSink(trace2dSink, &trace2d);
        if (trace2draw3d)
            melonDS::NDS4MiSTer::EmitTrace3DInitialState(nds.GPU);
        trace2dAttached = true;
        printf("trace2d: %s version %u header %u bytes\n", trace2dpath,
               trace2dHeader.Version, trace2dHeader.HeaderSize);
        return true;
    };
#else
    auto attachTrace = [&]() -> bool
    {
        if (!trace2dpath) return true;
        fprintf(stderr, "--trace2d needs a build against the vendored NDS4MiSTer fork\n");
        return false;
    };
#endif

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
        if (!attachTrace()) return 1;
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
        if (!attachTrace()) return 1;
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
    if (!attachTrace()) return 1;
    nds.Start();
    }

    // TRACE9=<path> [TRACE9MAX=<n>] dumps the ARM9 instruction trace
    // (tracer.patch hook) - the debug view for stock-ROM boot issues.
    // TRACE7/TRACE7MAX: same for the ARM7.
    // TRACE9STARTFRAME=<n> defers the trace to frame n (divergence hunting
    // without a multi-GB from-boot trace); same for TRACE7STARTFRAME.
#ifndef NDS4MISTER_VENDORED_FORK
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
#else
    if (getenv("TRACE9") || getenv("TRACE7"))
        fprintf(stderr, "TRACE9/TRACE7 need the upstream patched melonDS tree; ignored\n");
#endif

    FILE* d = nullptr;
    FILE* db = nullptr;
    if (!noTextDump)
    {
        d = fopen(dumppath, "w");
        if (!d) { fprintf(stderr, "cannot open %s\n", dumppath); return 1; }
        if (dumppathb)
        {
            db = fopen(dumppathb, "w");
            if (!db) { fprintf(stderr, "cannot open %s\n", dumppathb); return 1; }
        }
    }

    const char* snapshotPrefix = getenv("SNAPSHOT_PREFIX");
    std::unique_ptr<u32[]> snapBG, snapOBJ, snapPAL, snapOAM;
    u32 snapRegs[22] = {};
#ifndef NDS4MISTER_VENDORED_FORK
    int irq7census = 0;
    if (const char* ic = getenv("IRQ7CENSUS")) irq7census = atoi(ic);
#endif

    for (int n = 0; n < frames; n++)
    {
#ifndef NDS4MISTER_VENDORED_FORK
        if (irq7census > 0 && (n % irq7census) == 0) printIrq7Census(n);
        if (trace9path && n == trace9start && !ARM9TraceFile)
            ARM9TraceFile = fopen(trace9path, "w");
        if (trace7path && n == trace7start && !ARM7TraceFile)
            ARM7TraceFile = fopen(trace7path, "w");
#endif
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
        const u32 ackedBefore = liveInput.acked;
        pollLiveInput(liveInput, nds, n);
        if (liveInput.acked != ackedBefore)
            ackWallMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - wallOrigin).count();
        const auto runStart = std::chrono::steady_clock::now();
        nds.RunFrame();
        const auto runEnd = std::chrono::steady_clock::now();
        u32* top = nullptr;
        u32* bot = nullptr;
        if (hsClient)
        {
            if (nds.HsGpuFailed())
            {
                fprintf(stderr, "hs-gpu failed at dump frame %d: %s\n", n, nds.HsGpuError().c_str());
                if (ndsfOut) endNdsf(1, nds.HsGpuError().c_str());
                return 4;
            }
            u32 hsFrame = 0;
            const u32* px = nds.HsGpuFrame(hsFrame);
            if (!px || !nds.HsState.FrameDone)
            {
                // The machine stopped without the device completing a frame: report it,
                // never repeat the previous frame.
                char why[160];
                snprintf(why, sizeof(why), "machine stopped without a device frame completing at dump frame %d", n);
                fprintf(stderr, "hs-gpu: %s\n", why);
                if (ndsfOut) endNdsf(1, why);
                return 4;
            }
            top = const_cast<u32*>(px);
            bot = top + 256 * 192;
            if (ndsfOut)
            {
                // Same record layout as TraceView: NDSF, frame, matched, compared, 0, then
                // 256x384 BGRA (top, bottom). The device frame is the only pixel source.
                const u32 head[5] = { 0x4653444E /* "NDSF" little-endian */, hsFrame, 0, 0, 0 };
                if (fwrite(head, 4, 5, ndsfOut) != 5 ||
                    fwrite(px, 4, 256 * 384, ndsfOut) != 256 * 384 || fflush(ndsfOut) != 0)
                {
                    fprintf(stderr, "cannot write --hs-ndsf record\n");
                    return 4;
                }
            }
        }
        else
            getFramebuffers(nds.GPU, top, bot);
        // --no-text-dump: no text frame dump is produced at all (the dump path
        // positionals are ignored), so the 98k-line hex formatting is skipped.
        if (!noTextDump)
        {
            fprintf(d, "frame %d\n", n);
        }
        if (clockLog)
        {
            const unsigned long long a9 = nds.ARM9Timestamp >> nds.ARM9ClockShift;
            u32 devFrame = 0;
            if (hsClient) nds.HsGpuFrame(devFrame);
            const double frameMs = std::chrono::duration<double, std::milli>(runEnd - runStart).count();
            const double nowMs = std::chrono::duration<double, std::milli>(runEnd - wallOrigin).count();
            fprintf(clockLog, "dump=%d arm9_sys=%llu arm7_sys=%llu hw_frames=%.3f device_frame=%u runframe_numframes=%u frame_wall_ms=%.2f wall_ms=%.2f input_seq=%u input_acked=%u ack_wall_ms=%.2f\n",
                    n, a9, (unsigned long long)nds.ARM7Timestamp, (double)a9 / 560190.0, devFrame, nds.NumFrames,
                    frameMs, nowMs, liveInput.seq, liveInput.acked, ackWallMs);
            fflush(clockLog);
        }
        if (!noTextDump)
            for (int i = 0; i < 256 * 192; i++)
                fprintf(d, "%08x\n", top[i]);
        if (db)
        {
            fprintf(db, "frame %d\n", n);
            for (int i = 0; i < 256 * 192; i++)
                fprintf(db, "%08x\n", bot[i]);
        }
    }
    if (d) fclose(d);
    if (db) fclose(db);
#ifdef NDS4MISTER_VENDORED_FORK
    if (trace2dAttached)
    {
        melonDS::NDS4MiSTer::SetTrace2DSink(nullptr, nullptr);
        if (fclose(trace2d.file) != 0) trace2d.failed = true;
        printf("trace2d: wrote %llu record bytes, version %u (%s)\n",
               trace2d.bytes, trace2dHeader.Version,
               trace2d.failed ? "FAILED" : "ok");
        if (trace2d.failed) return 1;
    }
#endif
#ifndef NDS4MISTER_VENDORED_FORK
    if (ARM9TraceFile) { fclose(ARM9TraceFile); ARM9TraceFile = nullptr; }
    if (ARM7TraceFile) { fclose(ARM7TraceFile); ARM7TraceFile = nullptr; }
#endif

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
    // --ram-dump ADDR:WORDS prints non-GPU memory words (main RAM / WRAM only: a GPU
    // address would be a debug bus access and is fatal in --hs-gpu mode).
    if (ramDump)
    {
        char* colon = nullptr;
        const u32 base = (u32)strtoul(ramDump, &colon, 0);
        const u32 count = (colon && *colon == ':') ? (u32)strtoul(colon + 1, nullptr, 0) : 1;
        for (u32 i = 0; i < count; i++)
            printf("ram[%08X]=%08X\n", base + i * 4, nds.ARM9Read32(base + i * 4));
    }

    if (hsClient)
    {
        if (nds.HsGpuFailed())
        {
            fprintf(stderr, "hs-gpu failed after the last frame: %s\n", nds.HsGpuError().c_str());
            if (ndsfOut) endNdsf(1, nds.HsGpuError().c_str());
            return 4;
        }
        if (ndsfOut && !endNdsf(0, "end of stream: requested frame count reached")) return 4;
        if (txnLog) fclose(txnLog);
        printf("hs-gpu: %llu device calls\n", (unsigned long long)hsClient->CallCount());
        if (hsProfile)
        {
            static const char* names[] = { "ADVANCE", "IO_READ", "IO_WRITE", "MEM_READ", "MEM_WRITE", "RESET", "IF_ACK", "FRAME", "FRAME_START", "IO_CONTINUE" };
            double totalMs = 0;
            for (unsigned op = 0; op < sizeof(names) / sizeof(names[0]); op++)
            {
                const auto& p = hsClient->ProfileOf(op);
                if (!p.calls) continue;
                const double avgUs = p.sampled ? (double)p.sampledNs / p.sampled / 1000.0 : 0.0;
                const double estMs = avgUs * p.calls / 1000.0;
                totalMs += estMs;
                printf("hs-profile %-11s calls=%llu sampled=%llu avg=%.3fus est-total=%.1fms\n", names[op],
                       (unsigned long long)p.calls, (unsigned long long)p.sampled, avgUs, estMs);
            }
            printf("hs-profile estimated time inside device calls: %.1f ms\n", totalMs);
        }
        printf("dumped %d frames to %s\n", frames, dumppath);
        return nds.HsGpuFailed() ? 4 : 0;
    }

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
        u32* top = nullptr;
        u32* bot = nullptr;
        getFramebuffers(nds.GPU, top, bot);
        for (u32 i = 0; i < 256*192; i++)
        {
            u32 p = top[i];
            u32 r = (p >> 16) & 0xFF, g = (p >> 8) & 0xFF, b = (p >> 0) & 0xFF;
            fprintf(f, "%08X\n", (r >> 2) | ((g >> 2) << 6) | ((b >> 2) << 12));
        }
        fclose(f);
        printf("snapshot dumped with prefix %s\n", prefix);
    }
#ifndef NDS4MISTER_VENDORED_FORK
    if (irq7census > 0) printIrq7Census(frames);
#endif
    printf("dumped %d frames to %s\n", frames, dumppath);
    return 0;
}
