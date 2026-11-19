// SPDX-License-Identifier: GPL-3.0-or-later
// CPU socket only. No cartridge header, staged RAM, fake firmware or MMIO
// acknowledgements on private reset. Stop a CPU at its first missing owner.
#include "Vnds_dual_soc_firmware.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>

using DUT = Vnds_dual_soc_firmware;
static void check(bool ok, const char *why) {
    if (!ok) { std::fprintf(stderr,"native reset: %s\n",why); std::exit(1); }
}
template<size_t N> struct Rom {
    std::array<uint8_t,N> data;
    explicit Rom(const char *path) {
        std::ifstream in(path,std::ios::binary);
        check(bool(in.read(reinterpret_cast<char*>(data.data()),N)) && in.peek()==EOF,"BIOS must be exactly its aperture size");
    }
    uint32_t at(uint32_t address) const {
        const auto *p = &data[address & (N-4)];
        return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24;
    }
};
struct Side {
    uint32_t base, size, passPc, previous=~0u, last=0;
    unsigned retired=0, ioReads=0, replyAt=0;
    bool stop=false, edge=false;
    bool inRom(uint32_t a) const { return a-base<size; }
};
static void run(DUT &t,const Rom<4096>& r9,const Rom<16384>& r7,bool diagnostic,uint32_t pass9,uint32_t pass7) {
    Side cpu[2]={{0xffff0000,4096,pass9},{0,16384,pass7}};
    std::ifstream reference[2]; unsigned matched[2]={};
    if(!diagnostic) for(unsigned i=0;i<2;++i) {
        if(const char *path=std::getenv(i?"NATIVE_PC7":"NATIVE_PC9")) {
            reference[i].open(path); check(bool(reference[i]),"cannot open no-cart PC reference");
        }
    }
    t.RST=1; t.EN=1; t.CLK=0;
    t.BOOT9_WORD=t.BOOT7_WORD=0xe7f000f0;
    t.CARD_INSERTED=t.CARD_DIRECT_BOOT=t.CARD_CHIP_ID=t.CARD_ROM_MASK=0;
    t.CARD_ROM_READY=t.CARD_ROM_REPLY_VALID=t.CARD_ROM_DATA=0;
    t.MEM_REQ_READY=t.MEM_RESP_VALID=t.MEM_RESP_DATA=t.MEM_RESP_LINE=0;
    t.SNOOP_WRITE=t.SNOOP_ADDR=0;
    t.EXT_IRQ_SET=t.GPU_REPLY_FAULT=t.SYS7_IRQ_SET=t.SYS7_REPLY_FAULT=0;
    for(unsigned c=0;c<100000;++c) {
        t.RST=c<5;
        // Exercise clock enables without changing the ROMs' physical clock.
        t.EN=!diagnostic || c<5 || c%11!=0;
        t.GPU_REQ_READY=diagnostic && t.EN && !cpu[0].replyAt;
        t.SYS7_READY=diagnostic && t.EN && !cpu[1].replyAt;
        t.GPU_REPLY_VALID=cpu[0].replyAt && c>=cpu[0].replyAt;
        t.SYS7_REPLY_VALID=cpu[1].replyAt && c>=cpu[1].replyAt;
        t.GPU_REPLY_DATA=0x900; t.SYS7_REPLY_DATA=0x700;
        t.eval();
        for(unsigned i=0;i<2;++i) {
            auto &s=cpu[i]; const unsigned side=i?7:9;
            const uint32_t a=i?t.CPU7_BOOT_ADDR:t.CPU9_BOOT_ADDR;
            const bool step=i?t.ARB_STEP7:t.ARB_STEP9, retired=i?t.CPU7_RETIRE_VALID:t.CPU9_RETIRE_VALID;
            const bool req=i?t.IO7_GPU_REQ_VALID:t.IO9_GPU_REQ_VALID;
            const uint32_t pc=i?t.CPU7_RETIRE_PC:t.CPU9_RETIRE_PC, op=i?t.CPU7_RETIRE_OPCODE:t.CPU9_RETIRE_OPCODE;
            const uint32_t fault=i?t.CPU7_FAULT:t.CPU9_FAULT, faultAt=i?t.CPU7_FAULT_ADDR:t.CPU9_FAULT_ADDR;
            if(t.RST) check((!c || a==s.base) && !retired && !req && !t.MEM_REQ_VALID,"reset address/side effect");
            if(!t.RST && t.EN && step && s.inRom(a)) check(((s.previous^a)&(s.size-4))==0,"CPU consumed a different word index from its registered BIOS word");
            s.previous=a&~3u;
            if(s.stop) continue;
            if(retired) {
                if(!s.retired) check(pc==s.base,"first retired instruction not the reset vector");
                if(s.inRom(pc)) {
                    const uint32_t w=i?r7.at(pc):r9.at(pc);
                    check(w==op || ((w>>((pc&2)*8))&0xffff)==op,"retirement differs from uploaded BIOS contents");
                }
                if(reference[i].is_open() && matched[i]<128) {
                    uint32_t want; check(bool(reference[i]>>std::hex>>want),"short no-cart reference");
                    if(want!=pc) std::fprintf(stderr,"ARM%u native divergence at record %u: expected PC %08x, retired PC %08x\n",side,matched[i]+1,want,pc);
                    check(want==pc,"no-cart reference PC mismatch"); ++matched[i];
                }
                ++s.retired; s.last=pc; s.edge|=pc==s.base+s.size-4;
                if(diagnostic && pc==s.passPc) {
                    check(s.edge && s.ioReads==1,"success reached without end-of-ROM branch or device read");
                    s.stop=true;
                }
            }
            if(fault) {
                std::printf("native ARM%u fault %u at %08x, last retired %08x, %u retires, clock %u\n",side,fault,faultAt,s.last,s.retired,c);
                check(!diagnostic,"public diagnostic faulted"); s.stop=true;
            } else if(req) {
                const uint32_t addr=i?t.CPU7_REQ_ADDR:t.CPU9_REQ_ADDR;
                if(diagnostic) {
                    check(addr==0x04000204 && !(i?t.CPU7_REQ_WRITE:t.CPU9_REQ_WRITE) && (i?t.CPU7_REQ_WIDTH:t.CPU9_REQ_WIDTH)==2,"wrong external diagnostic IO access");
                    if(i?t.SYS7_READY:t.GPU_REQ_READY) { ++s.ioReads; s.replyAt=c+7; }
                } else {
                    std::printf("native ARM%u requires external IO %s at %08x; last retired %08x, %u retires, clock %u\n",side,(i?t.CPU7_REQ_WRITE:t.CPU9_REQ_WRITE)?"write":"read",addr,s.last,s.retired,c);
                    s.stop=true;
                }
            } else if(t.MEM_REQ_VALID && t.MEM_ARM7==i) {
                check(!diagnostic,"private BIOS transaction escaped to main memory");
                std::printf("native ARM%u requires external memory %s at %08x; last retired %08x, %u retires, clock %u\n",side,t.MEM_REQ_WRITE?"write":"read",t.MEM_REQ_ADDR,s.last,s.retired,c);
                s.stop=true;
            }
            if((i?t.SYS7_REPLY_VALID:t.GPU_REPLY_VALID) && (i?t.IO7_GPU_REPLY_READY:t.IO9_GPU_REPLY_READY)) s.replyAt=0;
        }
        const uint32_t q9=r9.at(t.CPU9_BOOT_ADDR), q7=r7.at(t.CPU7_BOOT_ADDR);
        t.CLK=1; t.eval(); t.BOOT9_WORD=q9; t.BOOT7_WORD=q7; t.CLK=0; t.eval();
        if(cpu[0].stop && cpu[1].stop) break;
    }
    for(unsigned i=0;i<2;++i) {
        check(cpu[i].retired!=0,"no BIOS instruction retired");
        if(reference[i].is_open()) std::printf("native no-cart ARM%u reference PC prefix: %u records\n",i?7:9,matched[i]);
        if(!cpu[i].stop) std::printf("native ARM%u reached 100000-clock CPU-socket bound: %u retires, last PC %08x\n",i?7:9,cpu[i].retired,cpu[i].last);
        check(!diagnostic || cpu[i].stop,"public diagnostic timed out");
    }
}
int main(int argc,char **argv) {
    check(argc==3 || argc==5,"usage: runner BIOS9.bin BIOS7.bin [PUBLIC_PASS9 PUBLIC_PASS7]");
    const Rom<4096> r9(argv[1]); const Rom<16384> r7(argv[2]); DUT t;
    const bool diag=argc==5;
    const uint32_t p9=diag?std::strtoul(argv[3],nullptr,0):0, p7=diag?std::strtoul(argv[4],nullptr,0):0;
    run(t,r9,r7,diag,p9,p7);
    if(diag) { run(t,r9,r7,true,p9,p7); std::puts("PASS: native reset twice, SVC/ARM/D3, c1 reset, registered fetch/literal at both ROM limits, write-once ARM7 BIOSPROT, two delayed peripheral reads"); }
    return 0;
}
