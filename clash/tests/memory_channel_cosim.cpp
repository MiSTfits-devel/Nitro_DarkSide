// SPDX-License-Identifier: GPL-3.0-or-later
// Upper-bound experiment, not board wiring: known independent physical A
// renderer reads through ch1, main RAM traffic through ch2. At most one
// queued ch1 grant plus one returning burst. Limit ch1 lookahead while a
// CPU transaction waits; a ch2 completion replenishes the display credit.
#include "Vmemory_channel_gate.h"
#include "memory_demand_trace.h"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <unordered_map>

namespace {
struct Experiment {
    Vmemory_channel_gate d;
    std::unordered_map<unsigned,uint16_t> mem;
    unsigned cycle=0,refresh=0,lastRef=0,maxGap=0;
    [[noreturn]] void fail(const char* why) const {std::fprintf(stderr,"channel experiment cycle %u: %s\n",cycle,why);std::exit(1);}
    uint16_t word(unsigned ha) const {
        if(auto f=mem.find(ha);f!=mem.end())return f->second;
        return memory_trace::initial(ha);
    }
    uint64_t line(unsigned ha)const{uint64_t q=0;for(unsigned j=0;j<4;j++)q|=uint64_t(word(ha+j))<<(16*j);return q;}
    void clock(){d.CLK=1;d.eval();d.CLK=0;d.eval();++cycle;
        if(d.ERRORS)fail("pin model protocol");
        if(d.REFRESHES!=refresh){if(cycle>13000)maxGap=std::max(maxGap,cycle-lastRef);lastRef=cycle;refresh=d.REFRESHES;}
        if(cycle>13000 && cycle-lastRef>523) fail("refresh timeout");
    }
    Experiment(){d.RST=1;d.CREQ=d.VREQ=d.CLK=0;clock();clock();d.RST=0;for(int j=0;j<12500;j++)clock();}
    void run(unsigned cpuPerLine,unsigned quota){
        const unsigned startReads=d.READS,startWrites=d.WRITES;
        unsigned gfxMiss=0,bothMiss=0,worstGfx=0,worstBoth=0,maxCpu=0,cpuReads=0,cpuWrites=0,cpuComplete=0,maxBacklog=0;
        uint64_t gpuHash=0,cpuHash=0;
        for(unsigned y=0;y<192;y++){
            unsigned begin=cycle,vi=0,vr=0,ci=0,cr=0,cStart=0,credit=quota;
            unsigned peakCpuAtGfx=0;
            bool cpuBusy=false,awaitGrant=false;
            std::array<uint64_t,2> expect{};
            uint64_t cpuExpected=0;
            while(vr<420 || cr<cpuPerLine){
                d.VREQ=d.CREQ=0;
                if(d.VACCEPT){if(!awaitGrant)fail("unrequested ch1 grant");awaitGrant=false;}
                if(d.VDONE){if(vr==vi || d.VDATA!=expect[vr&1])fail("ch1 burst mismatch/order");
                    gpuHash=memory_trace::hash(gpuHash,d.VDATA);
                    if(++vr==420){worstGfx=std::max(worstGfx,cycle-begin);gfxMiss+=cycle-begin>4260;peakCpuAtGfx=cpuPerLine-cr;}}
                if(d.CDONE){if(!cpuBusy)fail("duplicate ch2 completion");
                    if(!d.CWRITE && d.CQ!=cpuExpected)fail("ch2 burst mismatch/order");
                    if(!d.CWRITE)cpuHash=memory_trace::hash(cpuHash,d.CQ);
                    ++cr;++cpuComplete;cpuBusy=false;credit=quota;maxCpu=std::max(maxCpu,cycle-cStart);}
                if(!cpuBusy && ci<cpuPerLine){
                    auto t=memory_trace::cpu(y,ci++);auto a=0x400000u+((t.offset&(t.write?~3u:~7u))>>1);
                    d.CADDR=a;d.CDATA=t.data;d.CWRITE=t.write;d.CREQ=1;cpuBusy=true;cStart=cycle;
                    if(t.write){mem[a]=t.data;mem[a+1]=t.data>>16;++cpuWrites;}
                    else{cpuExpected=line(a);++cpuReads;}
                }
                if(vi<420 && vi-vr<2 && !awaitGrant && (!cpuBusy || credit>0)){
                    auto a=memory_trace::video(y,vi)>>1;
                    d.VADDR=a;d.VREQ=1;awaitGrant=true;expect[vi&1]=line(a);++vi;if(cpuBusy)--credit;
                }
                d.eval();clock();if(cycle-begin>50000)fail("starved CPU or display");
            }
            if(awaitGrant || cpuBusy)fail("orphan transaction");
            worstBoth=std::max(worstBoth,cycle-begin);bothMiss+=cycle-begin>4260;
            maxBacklog=std::max(maxBacklog,peakCpuAtGfx);
            d.VREQ=d.CREQ=0;while(cycle-begin<4260)clock();
        }
        if(d.READS-startReads!=420*192+cpuReads || d.WRITES-startWrites!=2*cpuWrites)fail("pin command counts");
        std::printf("ch1/ch2 isolated fixed trace CPU=%u/line, display-credit=%u: graphics max=%u/4260 misses=%u/192; both max=%u misses=%u/192; CPU complete=%u max request->done=%u, backlog at graphics completion<=%u; pin READ/WRITE=%u/%u max refresh gap=%u\n",cpuPerLine,quota,worstGfx,gfxMiss,worstBoth,bothMiss,cpuComplete,maxCpu,maxBacklog,d.READS-startReads,d.WRITES-startWrites,maxGap);
        std::printf("paired-hash %u %016llx %016llx\n",cpuPerLine,(unsigned long long)gpuHash,(unsigned long long)cpuHash);
    }
};
}
int main(){Experiment().run(0,4);Experiment().run(64,4);Experiment().run(420,4);Experiment().run(420,8);}
