// Headless melonDS run of the two-CPU fixture (sim/tests/hs_dual_*.S) as a
// second oracle for Nds.WholeCore.DualSoc (sim/run_clash_dual_soc.sh).
//
//   melonds_dual BOOT9.bin BOOT7.bin ARM9.bin ENTRY9 ARM7.bin ENTRY7 MAXFRAMES
//
// The fixture's boot ROMs are installed as the ARM9 and ARM7 BIOS images,
// so IRQs dispatch through them exactly as on DualSoc. The card loader is
// not run here (melonDS models the real cartridge protocol, not the
// direct-boot strap the loader relies on): the state it hands over is set
// up directly, as the loader leaves it — the ARM9 binary at 0x02000400, the
// ARM7 binary at 0x02000900, both CPUs' IPCSYNC outputs at 1 — and each CPU
// starts at its entry in SVC mode with IRQs masked (the reset CPSR). The
// whole system then runs frame by frame with melonDS's scheduler (ARM9 at
// twice the ARM7 clock) until both guests have written their done markers,
// and both mailboxes are printed: "9 <slot> <word>" and "7 <slot> <word>".
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

#include "NDS.h"

using namespace melonDS;

static std::vector<u8> readFile(const char* path)
{
    std::vector<u8> out;
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    int c;
    while ((c = fgetc(f)) != EOF) out.push_back((u8)c);
    fclose(f);
    return out;
}

int main(int argc, char** argv)
{
    if (argc != 8)
    {
        fprintf(stderr, "usage: %s BOOT9.bin BOOT7.bin ARM9.bin ENTRY9 ARM7.bin ENTRY7 MAXFRAMES\n", argv[0]);
        return 2;
    }
    std::vector<u8> boot9 = readFile(argv[1]), boot7 = readFile(argv[2]);
    std::vector<u8> bin9 = readFile(argv[3]), bin7 = readFile(argv[5]);
    u32 entry9 = 0x02000400 + (u32)strtoul(argv[4], nullptr, 0);
    u32 entry7 = 0x02000900 + (u32)strtoul(argv[6], nullptr, 0);
    int maxFrames = atoi(argv[7]);

    auto ndsHolder = std::make_unique<NDS>();
    NDS& nds = *ndsHolder;
    ARM9BIOSImage b9 {};
    ARM7BIOSImage b7 {};
    if (boot9.size() > b9.size() || boot7.size() > b7.size()) { fprintf(stderr, "boot ROM too large\n"); return 1; }
    memcpy(b9.data(), boot9.data(), boot9.size());
    memcpy(b7.data(), boot7.data(), boot7.size());
    nds.SetARM9BIOS(b9);
    nds.SetARM7BIOS(b7);
    nds.Reset();

    for (u32 i = 0; i < bin9.size(); i += 4)
    {
        u32 w = 0;
        memcpy(&w, &bin9[i], std::min<size_t>(4, bin9.size() - i));
        nds.ARM9Write32(0x02000400 + i, w);
    }
    for (u32 i = 0; i < bin7.size(); i += 4)
    {
        u32 w = 0;
        memcpy(&w, &bin7[i], std::min<size_t>(4, bin7.size() - i));
        nds.ARM9Write32(0x02000900 + i, w);
    }
    nds.ARM9Write32(0x02000F00, entry7);       // the loader's handoff word
    nds.ARM9IOWrite16(0x04000180, 0x0100);     // ARM9 IPCSYNC output 1
    nds.ARM7IOWrite16(0x04000180, 0x0100);     // ARM7 IPCSYNC output 1
    nds.ARM9.JumpTo(entry9);
    nds.ARM7.JumpTo(entry7);
    nds.Start();

    // Both guests end by storing their done marker as their last mailbox
    // word (ARM9 0x600D9, ARM7 0x700D7).
    auto marked = [&](u32 base, u32 marker)
    {
        for (u32 k = 0; k < 64; ++k)
            if (nds.ARM9Read32(base + 4 * k) == marker) return true;
        return false;
    };
    int frame = 0;
    for (; frame < maxFrames; ++frame)
    {
        if (marked(0x02000000, 0x600D9) && marked(0x02000100, 0x700D7))
            break;
        nds.RunFrame();
    }
    printf("frames %d\n", frame);
    for (u32 k = 0; k < 64; ++k)
        printf("9 %u %08x\n", k, nds.ARM9Read32(0x02000000 + 4 * k));
    for (u32 k = 0; k < 64; ++k)
        printf("7 %u %08x\n", k, nds.ARM9Read32(0x02000100 + 4 * k));
    return frame < maxFrames ? 0 : 3;
}
