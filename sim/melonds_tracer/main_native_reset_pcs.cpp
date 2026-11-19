// SPDX-License-Identifier: GPL-3.0-or-later
// Stock, tracer.patch-instrumented melonDS. Run one no-cart frame from real
// reset. Only the first 128 architectural PCs are exported; register/opcode
// trace records stay in two bounded memory streams, never in a disk file.
#include "NDS.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <stdexcept>
namespace melonDS {
extern FILE *ARM9TraceFile, *ARM7TraceFile;
extern u64 ARM9TraceMax, ARM7TraceMax;
}
using namespace melonDS;
template<size_t N> static std::array<u8,N> load(const char* path) {
    std::array<u8,N> bytes; std::ifstream f(path,std::ios::binary);
    if(!f.read(reinterpret_cast<char*>(bytes.data()),bytes.size()) || f.peek()!=EOF) throw std::runtime_error("native media size/read error");
    return bytes;
}
static bool writePcs(const char *trace,const char *path) {
    std::ofstream out(path); bool thumb=false;
    for(unsigned i=0;i<128;++i) {
        unsigned pipeline,psr;
        if(std::sscanf(trace,"%x %*x %x",&pipeline,&psr)!=2) return false;
        out<<std::hex<<uint32_t(pipeline-(thumb?4:8))<<'\n'; thumb=psr&32;
        while(*trace && *trace!='\n') ++trace;
        if(!*trace) return false;
        ++trace;
    }
    return bool(out);
}
int main(int argc,char **argv) {
    if(argc!=6) return 2;
    auto n=std::make_unique<NDS>();
    n->SetARM9BIOS(load<ARM9BIOSSize>(argv[1])); n->SetARM7BIOS(load<ARM7BIOSSize>(argv[2]));
    auto fw=load<262144>(argv[3]); n->SetFirmware(Firmware(fw.data(),fw.size()));
    n->Reset();
    if(n->CartInserted() || !n->IsLoadedARM9BIOSKnownNative() || !n->IsLoadedARM7BIOSKnownNative()) return 3;
    char *s9=nullptr,*s7=nullptr; size_t n9=0,n7=0;
    ARM9TraceFile=open_memstream(&s9,&n9); ARM7TraceFile=open_memstream(&s7,&n7);
    if(!ARM9TraceFile || !ARM7TraceFile) return 4;
    ARM9TraceMax=ARM7TraceMax=128;
    n->Start(); n->RunFrame();
    std::fclose(ARM9TraceFile); std::fclose(ARM7TraceFile); ARM9TraceFile=ARM7TraceFile=nullptr;
    const bool ok=writePcs(s9,argv[4]) && writePcs(s7,argv[5]);
    std::free(s9); std::free(s7); return ok?0:5;
}
