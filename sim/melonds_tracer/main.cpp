// Headless melonDS harness for the M3 differential trace (docs/TRACE_DIFF.md).
// Boots a raw ARM9 binary in main RAM with the same initial state as the RTL
// island (regs zero, CPSR 0xD3, CP15 at reset, TCMs off) and traces every
// retired instruction via the ARM9TraceFile hook patched into ARM.cpp.
//
//   melonds_tracer <arm9.bin> <trace.log> <maxinstr> [entry-hex, default 02000000]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>

#include "NDS.h"
#include "ARM.h"
#include "GPU.h"

// tracer.patch globals in ARM.cpp
namespace melonDS
{
extern FILE* ARM9TraceFile;
extern u64 ARM9TraceCount;
extern u64 ARM9TraceMax;
}

using namespace melonDS;

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        fprintf(stderr, "usage: %s <arm9.bin> <trace.log> <maxinstr> [entry-hex]\n", argv[0]);
        return 2;
    }
    const char* binpath = argv[1];
    const char* tracepath = argv[2];
    u64 maxinstr = strtoull(argv[3], nullptr, 0);
    u32 entry = (argc > 4) ? (u32)strtoul(argv[4], nullptr, 16) : 0x02000000;

    // default NDSArgs: FreeBIOS, generated firmware, software renderer
    // (heap-allocated: the 1.1 NDS object is far too large for the stack)
    auto nds_holder = std::make_unique<NDS>();
    NDS& nds = *nds_holder;
    nds.Reset();

    FILE* f = fopen(binpath, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", binpath); return 1; }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len <= 0 || (u32)len > nds.MainRAMMask + 1 - (entry & nds.MainRAMMask))
    {
        fprintf(stderr, "bad binary size %ld\n", len);
        return 1;
    }
    if (fread(&nds.MainRAM[entry & nds.MainRAMMask], 1, len, f) != (size_t)len)
    {
        fprintf(stderr, "short read on %s\n", binpath);
        return 1;
    }
    fclose(f);

    // Reset left the CPU in the RTL-matching reset state (regs zero,
    // CPSR 0xD3, CP15 reset); just point it at the payload.
    nds.ARM9.JumpTo(entry);

    ARM9TraceFile = fopen(tracepath, "w");
    if (!ARM9TraceFile) { fprintf(stderr, "cannot open %s\n", tracepath); return 1; }
    ARM9TraceCount = 0;
    ARM9TraceMax = maxinstr;

    // Drive the ARM9 alone: no scheduler, no ARM7, no IRQ sources. The
    // workload must be pure CPU+memory (anything MMIO-dependent would
    // diverge from the RTL island anyway).
    int stuck = 0;
    while (ARM9TraceCount < maxinstr)
    {
        u64 before = ARM9TraceCount;
        nds.ARM9Target = nds.ARM9Timestamp + 0x40000;
        nds.ARM9.Execute<CPUExecuteMode::Interpreter>();
        if (nds.ARM9.Halted)
        {
            fprintf(stderr, "ARM9 halted after %llu instructions\n",
                    (unsigned long long)ARM9TraceCount);
            break;
        }
        if (ARM9TraceCount == before)
        {
            if (++stuck > 16) { fprintf(stderr, "no progress, aborting\n"); break; }
        }
        else stuck = 0;
    }

    fclose(ARM9TraceFile);
    ARM9TraceFile = nullptr;
    printf("traced %llu instructions\n", (unsigned long long)ARM9TraceCount);
    return ARM9TraceCount == maxinstr ? 0 : 3;
}
