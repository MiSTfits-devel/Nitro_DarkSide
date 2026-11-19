// SPDX-License-Identifier: GPL-3.0-or-later
// Monitor the real dual-CPU IPC device and retirement stream; no fake FIFO.
#ifdef FETCH_BUFFER
#include "Vnds_dual_soc_buffered.h"
using DUT = Vnds_dual_soc_buffered;
#else
#include "Vnds_dual_soc_wide.h"
using DUT = Vnds_dual_soc_wide;
#endif
#include "verilated.h"
#include <array>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <vector>
#include <sys/resource.h>

static void check(bool ok, const char *why) {
    if (!ok) { std::fprintf(stderr, "retirement boundary: %s\n", why); std::exit(1); }
}
static uint64_t peakRss() {
    struct rusage r{};
    check(getrusage(RUSAGE_SELF, &r)==0, "cannot read process memory usage");
#ifdef __APPLE__
    return uint64_t(r.ru_maxrss);
#else
    return uint64_t(r.ru_maxrss)*1024;
#endif
}
static std::vector<uint8_t> load(const char *name) {
    std::ifstream f(name, std::ios::binary | std::ios::ate);
    check(bool(f) && f.tellg() > 0, "cannot open fixture");
    std::vector<uint8_t> b(static_cast<size_t>(f.tellg()));
    f.seekg(0); f.read(reinterpret_cast<char *>(b.data()), b.size());
    check(bool(f), "cannot read fixture"); return b;
}
static uint32_t word(const uint8_t *p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
static uint32_t romword(const std::vector<uint8_t>& rom, uint32_t addr, uint32_t base) {
    uint32_t i = (addr-base) & ~3u;
    return i < rom.size() && rom.size()-i >= 4 ? word(&rom[i]) : 0xe7f000f0;
}
static void clock(DUT &t) { t.CLK=1; t.eval(); t.CLK=0; t.eval(); }
int main(int argc, char **argv) {
    check(argc == 14, "usage: bench BOOT9 BOOT7 GUEST9 GUEST7 preirq pred branch wrong recv1 recv2 recv3 done slow");
    Verilated::commandArgs(argc, argv);
    auto b9=load(argv[1]), b7=load(argv[2]), g9=load(argv[3]), g7=load(argv[4]);
    std::array<uint32_t,8> pc{};
    for (unsigned i=0; i<pc.size(); ++i) pc[i]=uint32_t(std::strtoul(argv[5+i], nullptr, 0));
    const auto pre=pc[0], pred=pc[1], branch=pc[2], wrong=pc[3], recv1=pc[4], recv2=pc[5], recv3=pc[6];
    const bool slow=std::strtoul(argv[13], nullptr, 0)!=0;
    check(b9.size()<=4096 && b7.size()<=4096 && g9.size()<=4096 && g7.size()<=4096, "fixture too large");
    std::vector<uint8_t> ram(0x400000);
    std::copy(g9.begin(),g9.end(),ram.begin()+0x1000);
    std::copy(g7.begin(),g7.end(),ram.begin()+0x2000);
    DUT t;
    t.CLK=0; t.RST=1; t.EN=1; t.BOOT9_WORD=t.BOOT7_WORD=0;
    t.GPU_REQ_READY=t.GPU_REPLY_VALID=t.GPU_REPLY_DATA=t.GPU_REPLY_FAULT=t.EXT_IRQ_SET=0;
    t.CARD_INSERTED=t.CARD_DIRECT_BOOT=t.CARD_CHIP_ID=t.CARD_ROM_MASK=0;
    t.CARD_ROM_READY=t.CARD_ROM_REPLY_VALID=t.CARD_ROM_DATA=0;
    t.MEM_REQ_READY=t.MEM_RESP_VALID=t.MEM_RESP_DATA=0;
#ifdef FETCH_BUFFER
    t.MEM_RESP_LINE=0; t.SNOOP_WRITE=0; t.SNOOP_ADDR=0;
#endif
    t.eval(); clock(t); clock(t); t.RST=0;
    unsigned due=0, accepted=0, vectors=0, acks=0, targetRetires=0, predRetires=0;
    unsigned badFetch=0, badFetchBeforeBranch=0, heldCycles=0;
    bool branchRetired=false, raisedPre=false, raisedPost=false, sawPre=false, sawPost=false;
    bool held=false; uint32_t heldAddr=0, heldData=0, heldLanes=0; bool heldOwner=false, heldWrite=false;
    uint32_t answer=0; uint64_t line=0;
    for (unsigned cycle=0; cycle<1000000; ++cycle) {
        if ((cycle & 127u)==0) check(peakRss() <= 3ull*1024*1024*1024, "checker exceeded 3 GiB peak RSS");
        t.EXT_IRQ_SET=0;
        t.MEM_REQ_READY = due<=cycle && (!slow || cycle%7>=3);
        t.MEM_RESP_VALID = cycle && due==cycle;
        t.MEM_RESP_DATA=answer;
#ifdef FETCH_BUFFER
        t.MEM_RESP_LINE=line;
#endif
        t.eval();
        t.BOOT9_WORD=romword(b9,t.CPU9_BOOT_ADDR,0xffff0000);
        t.BOOT7_WORD=romword(b7,t.CPU7_BOOT_ADDR,0);
        t.eval();
        check(!t.CPU9_FAULT && !t.CPU7_FAULT, "CPU fault");
        // IO7 exposes its router-to-IPC link; unlike IO9 it is not filtered.
        check(!t.IO9_GPU_REQ_VALID && !t.CARD_ROM_REQ_VALID, "unexpected external device access");
        if (held) check(t.MEM_REQ_VALID && t.MEM_REQ_ADDR==heldAddr && bool(t.MEM_ARM7)==heldOwner &&
                        bool(t.MEM_REQ_WRITE)==heldWrite && t.MEM_REQ_DATA==heldData &&
                        t.MEM_REQ_LANES==heldLanes, "stalled RAM request changed");
        held=t.MEM_REQ_VALID && !t.MEM_REQ_READY;
        if (held) { heldAddr=t.MEM_REQ_ADDR; heldOwner=t.MEM_ARM7; heldWrite=t.MEM_REQ_WRITE;
                    heldData=t.MEM_REQ_DATA; heldLanes=t.MEM_REQ_LANES; ++heldCycles; }
        if (t.CPU9_RETIRE_VALID) {
            uint32_t p=t.CPU9_RETIRE_PC;
            check(p!=wrong, "wrong-path FIFO read retired");
            if (p==pred) { ++predRetires; std::printf("condition-failed FIFO instruction pc=%08x cycle=%u\n",p,cycle); }
            if (p==branch) { branchRetired=true; std::printf("taken branch pc=%08x cycle=%u\n",p,cycle); }
            if (p==pre) { check(!raisedPre, "pre-IRQ marker retired twice"); raisedPre=true; t.EXT_IRQ_SET=1; }
            if (p==recv1 || p==recv2 || p==recv3) {
                check(p==(targetRetires==0?recv1:targetRetires==1?recv2:recv3), "receive retire order");
                if (p==recv1) check(vectors==1 && acks==1, "IRQ did not precede first receive");
                if (p==recv2) { check(raisedPost && vectors==1, "post-receive IRQ arrived before retirement"); sawPost=true; }
                ++targetRetires;
                std::printf("retire receive%u pc=%08x cycle=%u\n", targetRetires, p, cycle);
            }
            if (p==0xffff0018u) {
                ++vectors;
                check((vectors==1 && raisedPre && targetRetires==0) ||
                      (vectors==2 && raisedPost && sawPost && targetRetires==2), "IRQ vector order");
                std::printf("IRQ vector%u cycle=%u\n", vectors, cycle);
            }
        }
        if (t.IO9_IF_ACK) { check(t.IO9_IF_ACK==1, "unexpected IF ack"); ++acks; std::printf("IF ack%u cycle=%u\n",acks,cycle); }
        if (t.CPU9_REQ_VALID && t.IO9_CPU_REQ_READY && t.CPU9_REQ_ADDR==0x04100000) {
            check(!t.CPU9_REQ_WRITE && accepted<3, "duplicate/invalid receive transaction");
            ++accepted;
            if (accepted==1) { check(vectors==1 && acks==1, "FIFO popped before first IRQ return"); sawPre=true; }
            if (accepted==2) { check(sawPre && !raisedPost && targetRetires==1, "second receive acceptance order"); raisedPost=true; t.EXT_IRQ_SET=1; }
            std::printf("FIFO accept%u cycle=%u\n",accepted,cycle);
        }
        if (t.CPU9_STORE_VALID && t.CPU9_STORE_ADDR==0x0200033c) {
            check(t.CPU9_STORE_DATA==0x600d9009, "completion marker");
            auto get=[&](unsigned off) { return word(&ram[0x300+off]); };
            check(accepted==3 && targetRetires==3 && predRetires==1 && branchRetired, "missing or duplicate retirement/receive");
            check(vectors==2 && acks==2 && raisedPre && raisedPost, "missing IRQs/acknowledgements");
            check(get(0)==2 && get(4)==recv1+4 && get(8)==recv2+8, "IRQ LR/restart PC mismatch");
            check(get(0x28)==0x77 && get(0x2c)==0x12345678 && get(0x30)==0x9abcdef0 &&
                  get(0x34)==0x0badc0de && get(0x38)==2, "FIFO sentinels/IRQ count mismatch");
            check(badFetchBeforeBranch, "wrong-path RAM instruction line was not fetched before branch retirement");
            check(!slow || heldCycles, "RAM backpressure never exercised");
            const auto peak=peakRss();
            check(peak <= 3ull*1024*1024*1024, "checker exceeded 3 GiB peak RSS");
            std::printf("checker peak RSS=%llu bytes (3 GiB ceiling)\n", static_cast<unsigned long long>(peak));
            std::printf("PASS: cycles=%u FIFO=3 IRQ=2 LR=%08x,%08x pred=%08x skipped=%08x wrong-line-fetch=%u before-branch-retire=%u stalled=%u\n",
                        cycle,get(4),get(8),pred,wrong,badFetch,badFetchBeforeBranch,heldCycles);
            return 0;
        }
        if (t.MEM_REQ_VALID && t.MEM_REQ_READY) {
            uint32_t addr=t.MEM_REQ_ADDR, ix=addr&0x3fffff;
            check((addr>>24)==2 && !(ix&3) && ix+4<=ram.size(), "unexpected RAM address");
            if (!t.MEM_ARM7 && t.MEM_FETCH && !t.MEM_REQ_WRITE && (addr&~7u)==(wrong&~7u)) {
                ++badFetch; if (!branchRetired) ++badFetchBeforeBranch;
            }
            answer=word(&ram[ix]);
            const uint32_t lineIx=ix&~7u;
            line=uint64_t(word(&ram[lineIx])) | uint64_t(word(&ram[lineIx+4]))<<32;
            if (t.MEM_REQ_WRITE) for (unsigned k=0;k<4;++k) if (t.MEM_REQ_LANES&(1u<<k)) ram[ix+k]=uint8_t(t.MEM_REQ_DATA>>(8*k));
            due=cycle+(slow?9:1);
        }
        clock(t);
    }
    check(false, "timeout");
}
