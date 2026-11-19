// SPDX-License-Identifier: GPL-3.0-or-later
// Public synthetic transfers only. The oracle runs actual stock melonDS CPU
// bus and GPU mapping code. The DUT includes the board SDRAM controller and
// the pin-clocked chip model, NOT a zero-wait host RAM on the Clash port.
#include "Vmemory_fabric_gate.h"
#include "NDS.h"
#include "memory_demand_trace.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <random>
#include <sys/resource.h>

namespace {
using namespace melonDS;
constexpr uint32_t reg0 = 0x04000240, lcd = 0x06800000, mainBase = 0x02000000;
struct Cpu { bool seven, wr; uint32_t addr, data; unsigned width; };
struct Vid { unsigned space, off; };
struct Expected { uint64_t q, line; uint32_t where; bool checkLine; };
uint32_t pattern(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; return x ^ (x >> 16);
}
struct Bench {
    Vmemory_fabric_gate d;
    std::unique_ptr<NDS> nds;
    std::deque<Expected> cq, dq;
    std::mt19937 rng{0x76595};
    uint64_t cycles=0, cpuCount=0, displayCount=0, sdReads=0, sdWrites=0, lastRefresh=0, refreshGap=0;
    unsigned refreshCount=0;
    bool outstanding=false, cpuHeld=false, displayHeld=false;
    struct Split { unsigned fabric=0, refreshWait=0, otherWait=0, service=0, cpu=0; };
    Split* split=nullptr;
    bool activated=false, cpuOwner=false;
    uint64_t refreshUntil=0, cpuBirth=0, maxCpuLatency=0;
    bool recordHash=false; uint64_t gpuHash=0,cpuHash=0;
    Bench() {
        NDSArgs a; a.JIT = std::nullopt; nds = std::make_unique<NDS>(std::move(a)); nds->Reset();
        nds->ARM9Write8(reg0+7,0); // WRAMCNT belongs to a different device
        d.RST=1; d.CT=d.DT=1; d.CV=d.DV=d.CLK=0;
        clock(); clock(); d.RST=0;
        // Do not hide startup from the master; first SDRAM write can wait for init.
    }
    [[noreturn]] void fail(const char *why, uint64_t got=0, uint64_t want=0, uint32_t where=0) const {
        std::fprintf(stderr,"cycle %llu %s addr=%08x got=%016llx expected=%016llx cpu=%llu video=%llu\n",
            (unsigned long long)cycles,why,where,(unsigned long long)got,(unsigned long long)want,
            (unsigned long long)cpuCount,(unsigned long long)displayCount); std::exit(1);
    }
    void clock() {
        d.CLK=1; d.eval(); d.CLK=0; d.eval(); ++cycles;
        if ((cycles & 0x3fff)==0) {
            struct rusage u{};
            if(getrusage(RUSAGE_SELF,&u)) fail("getrusage");
            // Darwin does not enforce RLIMIT_AS. Guard RSS below 3 GiB,
            // leaving 256 MiB headroom (max 2 sparse inserts per edge).
#if defined(__APPLE__)
            constexpr uint64_t unit=1;
#else
            constexpr uint64_t unit=1024;
#endif
            if(uint64_t(u.ru_maxrss)*unit >= (uint64_t(2816)<<20)) fail("checker RSS ceiling");
        }
        if (d.ERRORS) fail("SDRAM protocol",d.ERRORS);
        if (d.REFRESHES != refreshCount) {
            if (cycles>13000 && lastRefresh) refreshGap=std::max(refreshGap,cycles-lastRefresh);
            lastRefresh=cycles; refreshCount=d.REFRESHES;
        } else if(cycles>13000 && cycles-lastRefresh>523) fail("SDRAM refresh deadline");
    }
    uint32_t read32(bool seven, uint32_t a) {
        if (seven && a==reg0) return nds->ARM7Read8(a); // excludes WRAMSTAT byte
        return seven ? nds->ARM7Read32(a) : nds->ARM9Read32(a);
    }
    Expected cpuRef(Cpu c) {
        auto a=c.addr,v=c.data; auto aligned=a&~3u;
        if (c.wr) {
            if(c.seven) {
                if(c.width==4) nds->ARM7Write32(a,v); else if(c.width==2) nds->ARM7Write16(a,v); else nds->ARM7Write8(a,v);
            } else {
                if(c.width==4) nds->ARM9Write32(a,v); else if(c.width==2) nds->ARM9Write16(a,v); else nds->ARM9Write8(a,v);
            }
            return {0,0,a,false};
        }
        uint64_t line=0; bool checkLine=(a>>24)==2;
        if(checkLine) line=read32(c.seven,a&~7u) | (uint64_t(read32(c.seven,(a&~7u)+4))<<32);
        return {read32(c.seven,aligned),line,a,checkLine};
    }
    uint64_t videoRef(Vid r) {
        auto& g=nds->GPU; unsigned a=r.off&~7u;
        switch(r.space) {
        case 0:return g.ReadVRAM_ABG<u64>(a);
        case 1:return g.ReadVRAM_BBG<u64>(a);
        case 2:return g.ReadVRAM_AOBJ<u64>(a);
        case 3:return g.ReadVRAM_BOBJ<u64>(a);
        case 4:return g.ReadVRAM_LCDC<u64>(lcd+a);
        case 5:return g.ReadVRAM_Texture<u64>(a);
        case 6:return g.ReadVRAM_TexPal<u64>(a);
        case 7: case 8: case 9: case 10:{
            // Ask the stock mapper and its physical-bank pointer helper,
            // like the renderer's fast path. Its private *slow* AOBJExtPal
            // helper tests bits 4/5 in error (F/G are bits 5/6).
            unsigned slot=(a>>13)&3;
            unsigned mask=r.space==7?g.VRAMMap_ABGExtPal[slot]:r.space==8?g.VRAMMap_BBGExtPal[slot]:
                          r.space==9?g.VRAMMap_AOBJExtPal:g.VRAMMap_BOBJExtPal;
            a &= r.space<9?0x7fff:0x1fff;
            uint64_t q=0;
            for(unsigned bit=4;bit<9;bit++) if(auto* p=g.GetUniqueBankPtr(mask & (1u<<bit),a)) {
                uint64_t w; std::memcpy(&w,p,8); q|=w;
            }
            return q;
        }
        case 11:return 0; // No video master has the ARM7 CPU aperture.
        default:fail("test space");
        }
    }
    void check(std::deque<Expected>& queue, uint64_t q, bool taken) {
        if(queue.empty()) fail("unsolicited reply");
        const auto& e=queue.front();
        if(e.q!=q) fail("reply",q,e.q,e.where);
        if(e.checkLine && d.CLINE!=e.line) fail("instruction burst",d.CLINE,e.line,e.where);
        if(recordHash && e.checkLine && taken)cpuHash=memory_trace::hash(cpuHash,d.CLINE);
        if(taken) queue.pop_front();
    }
    // Each offer stays stable until accepted; oracle order = accept order.
    // Replies are also checked on every non-taken edge, not just at consume.
    std::pair<bool,bool> edge(const Cpu* c,const Vid* v,bool ct=true,bool dt=true) {
        d.CV=c!=nullptr; d.DV=v!=nullptr; d.CT=ct; d.DT=dt;
        if(c){d.ARM7=c->seven; d.WR=c->wr; d.ADDR=c->addr&~3u;
            unsigned sh=c->addr&3; d.BE=((1u<<c->width)-1)<<sh; d.WD=c->data<<(sh*8);}
        if(v){d.SPACE=v->space; d.OFF=v->off;}
        d.eval();
        if(d.REF)refreshUntil=cycles+8; // REF(chip0), REF(chip1), recovery, next ACT
        if(d.ACT)activated=true;
        if(split) {
            // Exclusive buckets over the exact active line, with CPU owner
            // time as an orthogonal count. Pre-ACT includes grant pipeline
            // and previous burst tail; refresh recovery is shown separately.
            if(outstanding && activated) ++split->service;
            else if((outstanding || d.SREQ) && cycles<refreshUntil) ++split->refreshWait;
            else if(outstanding || d.SREQ) ++split->otherWait;
            else ++split->fabric;
            if(cpuOwner) ++split->cpu;
            if(d.CA && ct)maxCpuLatency=std::max(maxCpuLatency,cycles-cpuBirth);
        }
        if((cpuHeld && !d.CA) || (displayHeld && !d.DA)) fail("dropped backpressured reply");
        cpuHeld=d.CA && !ct; displayHeld=d.DA && !dt;
        if(d.CA) check(cq,d.CQ,ct);
        if(d.DA) check(dq,d.DQOUT,dt);
        if(recordHash && d.DA && dt)gpuHash=memory_trace::hash(gpuHash,d.DQOUT);
        bool cf=c && d.CR, df=v && d.DR;
        if(cf && df) fail("double grant");
        if(cf){cq.push_back(cpuRef(*c)); ++cpuCount;cpuBirth=cycles;}
        if(df){dq.push_back({videoRef(*v),0,(v->space<<24)|v->off,false}); ++displayCount;}
        if(cf || df)cpuOwner=cf;
        else if((cpuOwner && d.CA) || (!cpuOwner && d.DA))cpuOwner=false;
        if(d.DONE){if(!outstanding) fail("stray controller completion"); outstanding=false;}
        if(d.SREQ){if(outstanding) fail("overwrote controller slot"); outstanding=true;activated=false;
            if(d.SADDR & (d.SWRITE?1:3)) fail("unaligned controller request",d.SADDR);
            if(d.SADDR>=0x40000 && (d.SADDR<0x400000 || d.SADDR>=0x600000)) fail("outside physical allocation",d.SADDR);
            if(d.SWRITE)++sdWrites; else ++sdReads;}
        clock(); return {cf,df};
    }
    void drain(){auto end=cycles+13000;while(!cq.empty()||!dq.empty()){edge(nullptr,nullptr);if(cycles>end)fail("lost response");}}
    void cpu(Cpu c){auto end=cycles+13000;while(!edge(&c,nullptr).first) if(cycles>end)fail("CPU starvation");}
    void video(Vid v){auto end=cycles+13000;while(!edge(nullptr,&v).second) if(cycles>end)fail("display starvation");}
    void cnt(int b,unsigned val){cpu({false,true,reg0+unsigned(b)+(b>=7),val,1});}
    void init(){
        for(int b=0;b<9;b++)cnt(b,0x80);
        for(uint32_t a=0;a<0xa4000;a+=4) cpu({false,true,lcd+a,pattern(a+0x33099),4});
        // Write and then read *every* physical main RAM word through different
        // mirror addresses and CPU owners. Include the whole adjacent burst.
        for(uint32_t a=0;a<0x400000;a+=4)cpu({bool(a&4),true,mainBase+a,pattern(a+51),4});
        for(uint32_t a=0;a<0x400000;a+=4)cpu({!bool(a&4),false,mainBase+0xc00000+a,0,4});
        for(uint32_t a=0;a<0xa4000;a+=8)video({4,a});
        for(uint32_t a=0;a<0x100;a++) {
            cpu({bool(a&1),true,mainBase+0x400000+a,pattern(a),1});
            cpu({false,false,mainBase+a,0,1});
        }
        drain();
    }
    void mappings(){
        // Stock decoder, not a duplicate table: sweep every physical bank,
        // encoded MST and offset. Probe both ends of every 16KiB page, and
        // 8KiB palette slots, in every consumer space and mirrored CPU window.
        for(int b=0;b<9;b++)cnt(b,0);
        for(int b=0;b<9;b++){
            for(unsigned cntval=0;cntval<32;cntval++){
                cnt(b,0xe0|cntval); // reserved bits must read masked
                cpu({false,false,(reg0+unsigned(b)+(b>=7))&~3u,0,4});
                cpu({true,false,reg0,0,1});
                for(unsigned page=0;page<128;page++)for(unsigned lane:{0u,0x1ff8u}){
                    unsigned a=(page<<13)+lane;
                    for(unsigned sp=0;sp<11;sp++)video({sp,a});
                    for(unsigned r=0;r<8;r++)cpu({false,false,0x06000000+(r<<21)+a+4,0,4});
                    cpu({true,false,0x06c00000+a+4,0,4});
                }
            }
            cnt(b,0);
        }
        drain();
    }
    void overlaps(){
        // Different patterns in all banks, OR on reads, writes fan out;
        // inspect individually after remap to establish physical persistence.
        for(int b=0;b<7;b++)cnt(b,0x81);
        // Both ports want the very same overlapped A..G line. Select each
        // grant order in turn. Hold the display answer while the other
        // port commits a write and changes the mapping under it.
        for(bool cpuFirst:{false,true}){
            Vid v{0,0};Cpu wr{false,true,0x06080000,pattern(0x3199+cpuFirst),4};
            if(cpuFirst)video(v);else cpu({false,false,reg0,0,4});
            drain();
            auto [cf,df]=edge(&wr,&v,true,false);
            if(cf!=cpuFirst || df==cpuFirst)fail("simultaneous grant fairness");
            auto end=cycles+200;
            while(!cf || !df){
                auto r=edge(cf?nullptr:&wr,df?nullptr:&v,true,false);cf|=r.first;df|=r.second;
                if(cycles>end)fail("stalled simultaneous offer");
            }
            Cpu remap{false,true,reg0,0x80,1};
            while(!edge(&remap,nullptr,true,false).first)if(cycles>end)fail("held display blocked remap");
            for(int k=0;k<6;k++)edge(nullptr,nullptr,true,false);
            drain();cnt(0,0x81);video(v);drain();
        }
        for(unsigned i=0;i<128;i++){
            unsigned a=i*128; cpu({false,false,0x06000000+a,0,4});video({0,a});
            cpu({false,true,0x06000000+a+2,pattern(i),2});
            cpu({false,true,0x06000000+a+1,pattern(~i),1}); // ignored on ARM9
            cpu({false,false,0x06080000+a,0,4});
        }
        for(int b=0;b<9;b++)cnt(b,0x80);
        for(unsigned a=0;a<0xa4000;a+=128)video({4,a});
        cnt(2,0x8a);cnt(3,0x9a); // both ARM7 slot 1, high OFS bit is ignored
        video({11,0x20000});
        for(unsigned j=0;j<64;j++){
            cpu({true,true,0x06fe0000+j,pattern(j),1});
            cpu({true,false,0x06020000+j,0,1});
            cpu({false,false,0x06840000+j,0,1}); // ownership rules
        }
        for(int b:{2,3}){cnt(b,0x80);for(unsigned j=0;j<64;j+=4)cpu({false,false,lcd+unsigned(b)*0x20000+j,0,4});}
        // Register writes wider than a byte, including the WRAMCNT hole.
        cpu({false,true,reg0,0x84848381,4});cpu({false,false,reg0,0,4});
        cpu({false,true,reg0+4,0x00818584,4});cpu({false,false,reg0+4,0,4});
        cpu({false,true,reg0+8,0x8381,2});cpu({false,false,reg0+8,0,4});
        drain();
    }
    void seedTrace(unsigned cpuPerLine) {
        auto initial32=[](unsigned ha){return uint32_t(memory_trace::initial(ha)) | uint32_t(memory_trace::initial(ha+1))<<16;};
        cnt(0,0x80);
        for(unsigned a=0;a<0x20000;a+=4)cpu({false,true,lcd+a,initial32(a/2),4});
        for(unsigned y=0;y<192;y++)for(unsigned k=0;k<cpuPerLine;k++) {
            auto t=memory_trace::cpu(y,k); unsigned off=t.offset&~7u;
            for(unsigned j:{0u,4u})cpu({false,true,mainBase+off+j,initial32(0x400000+(off+j)/2),4});
        }
        drain();
    }
    void pressure(unsigned largeBanks,unsigned gfxPerLine,bool randomStalls,int pairedCpu=-1) {
        bool paired=pairedCpu>=0;
        if(paired)seedTrace(pairedCpu);
        for(int b=0;b<9;b++)cnt(b,b<int(largeBanks)?0x81:0);
        drain(); const auto begin=cycles; const auto reads=d.READS, writes=d.WRITES;
        unsigned misses=0; uint64_t maxLine=0,stalls=0;
        unsigned maxCpuWait=0; auto cpuStart=cpuCount; Split worst{};maxCpuLatency=0;
        recordHash=paired;gpuHash=cpuHash=0;
        for(unsigned y=0;y<192;y++){
            uint64_t start=cycles, end=start+4260; unsigned got=0;
            unsigned cpuSlot=0, accepted=0, cpuWait=0; Split line{}; split=&line;
            auto bus=[&](){ // bus-master-shaped traffic, not a DMA engine
                if(paired){auto t=memory_trace::cpu(y,cpuSlot++);return Cpu{t.seven,t.write,mainBase+t.offset,t.data,4};}
                auto k=rng(); bool seven=k&1; bool w=k&2;
                unsigned addr=(k&8)?mainBase+(k&0x3ffffc):0x06000000+(k&0x1fffc);
                return Cpu{seven,w,addr,pattern(k),4};};
            Cpu c=bus(); Vid v{0,paired?memory_trace::video(y,0):unsigned(rng()&0x1fff8)};
            while(got<gfxPerLine || !dq.empty()){
                const bool hold=randomStalls && (rng()%7==0);
                bool loaded=!paired || accepted<unsigned(pairedCpu);
                auto [cf,df]=edge(loaded?&c:nullptr,got<gfxPerLine?&v:nullptr,!hold,!hold);
                if(loaded && !cf){++stalls;maxCpuWait=std::max(maxCpuWait,++cpuWait);}
                if(cf){++accepted;c=bus();cpuWait=0;}
                if(df){++got;v.off=paired?memory_trace::video(y,got):rng()&0x1fff8;}
                if(cycles-start>200000)fail("contended starvation");
            }
            split=nullptr;auto elapsed=cycles-start;if(elapsed>maxLine){maxLine=elapsed;worst=line;}if(cycles>end)++misses;
            // Finish the last CPU offer, even if the graphics line just
            // ended on an edge where the CPU port wasn't ready.
            if(!paired)cpu(c);
            else while(accepted<unsigned(pairedCpu)){cpu(c);c=bus();++accepted;}
            drain();while(cycles<end)edge(nullptr,nullptr);
        }
        std::printf("bus pressure: %u overlapping SDRAM banks, %u 8B demands/line; max %llu/4260 master clocks, misses %u/192, CPU denied %llu, pin READ/WRITE %u/%u, total clocks %llu\n",largeBanks,gfxPerLine,(unsigned long long)maxLine,misses,(unsigned long long)stalls,d.READS-reads,d.WRITES-writes,(unsigned long long)(cycles-begin));
        if(worst.fabric+worst.refreshWait+worst.otherWait+worst.service!=maxLine)fail("line accounting");
        if(largeBanks==1 && gfxPerLine==140 && misses)fail("140-demand line budget regression");
        std::printf("  %s %d: worst line clocks logic/dispatch=%u, pre-ACT refresh=%u other/turnaround=%u, ACT->done=%u (of all clocks CPU-owned=%u); CPU completed=%llu max denied=%u accept->consume=%llu\n",paired?"fixed CPU/line":"seeded saturated",pairedCpu,worst.fabric,worst.refreshWait,worst.otherWait,worst.service,worst.cpu,(unsigned long long)(cpuCount-cpuStart),maxCpuWait,(unsigned long long)maxCpuLatency);
        if(paired)std::printf("paired-hash %d %016llx %016llx\n",pairedCpu,(unsigned long long)gpuHash,(unsigned long long)cpuHash);
        recordHash=false;
    }
};
}
int main(){
    Bench b; b.init(); b.mappings(); b.overlaps();
    b.pressure(1,140,true); b.pressure(1,420,true); b.pressure(4,420,true);
    for(int cpu:{0,64,420})b.pressure(1,420,false,cpu);
    b.drain();
    if(b.outstanding||b.sdReads!=b.d.READS||2*b.sdWrites!=b.d.WRITES) b.fail("physical transaction balance");
    std::printf("PASS stock melonDS memory oracle + Clash netlist + SDRAM pin model: %llu CPU, %llu display, %llu clock edges; %llu SDRAM bursts, %llu word stores, max refresh gap %llu clocks\n",(unsigned long long)b.cpuCount,(unsigned long long)b.displayCount,(unsigned long long)b.cycles,(unsigned long long)b.sdReads,(unsigned long long)b.sdWrites,(unsigned long long)b.refreshGap);
}
