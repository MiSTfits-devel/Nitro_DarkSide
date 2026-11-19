// SPDX-License-Identifier: GPL-3.0-or-later
// The only inputs are synchronous public BIOS reads and a clock enable. The
// ARM7 program writes and executes WRAM itself. No external bus is serviced.
#include "Vnds_dual_soc_firmware.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>

static void require(bool ok,const char* s){if(!ok){std::fprintf(stderr,"POSTFLG: %s\n",s);std::exit(1);}}
template<unsigned N> struct Bios {
    std::array<uint8_t,N> bytes;
    explicit Bios(const char *path){std::ifstream in(path,std::ios::binary);require(bool(in.read(reinterpret_cast<char*>(bytes.data()),N)) && in.peek()==EOF,"wrong BIOS aperture");}
    uint32_t operator()(uint32_t a) const {auto p=&bytes[a&(N-4)];return uint32_t(p[0])|uint32_t(p[1])<<8|uint32_t(p[2])<<16|uint32_t(p[3])<<24;}
};
struct Side { bool done=false; unsigned n=0, visits=0; uint32_t last=0; };
int main(int argc,char **argv){
    require(argc==6,"BIOS9 BIOS7 PASS9 PASS7 EXPECT_FAULT");
    const Bios<4096> rom9(argv[1]); const Bios<16384> rom7(argv[2]);
    const uint32_t pass[2]={uint32_t(std::strtoul(argv[3],nullptr,0)),uint32_t(std::strtoul(argv[4],nullptr,0))};
    const bool reject=std::atoi(argv[5])!=0;
    Vnds_dual_soc_firmware t; t.CLK=0;t.EN=1;t.RST=1;t.BOOT7_WORD=t.BOOT9_WORD=0xe7f000f0;
    t.SYS7_READY=t.SYS7_REPLY_VALID=t.SYS7_REPLY_DATA=t.SYS7_REPLY_FAULT=t.SYS7_IRQ_SET=0;
    t.GPU_REQ_READY=t.GPU_REPLY_VALID=t.GPU_REPLY_DATA=t.GPU_REPLY_FAULT=t.EXT_IRQ_SET=0;
    t.CARD_INSERTED=t.CARD_DIRECT_BOOT=t.CARD_CHIP_ID=t.CARD_ROM_MASK=t.CARD_ROM_READY=t.CARD_ROM_REPLY_VALID=t.CARD_ROM_DATA=0;
    t.SNOOP_ADDR=t.SNOOP_WRITE=t.MEM_REQ_READY=t.MEM_RESP_VALID=t.MEM_RESP_DATA=t.MEM_RESP_LINE=0;
    for(unsigned epoch=0;epoch<(reject?1u:2u);epoch++){
        Side s[2];unsigned stalls=0,edgeStalls=0,ramMask=0,edgeMask=0,vectorMask=0;
        for(unsigned c=0;c<10000;c++){
            t.RST=c<6;t.EN=t.RST || (((c+epoch*5)%19)>=4 && ((c+epoch)%7)!=3);t.eval();
            if(!t.RST){
                if(!t.EN){stalls++; if(t.CPU7_BOOT_ADDR>=0x3ff4 && t.CPU7_BOOT_ADDR<0x4008)edgeStalls++;}
                require(!t.MEM_REQ_VALID && !t.IO9_GPU_REQ_VALID && !t.IO7_GPU_REQ_VALID,"unserved external request, including unexpected POST or WRAM spill");
                for(unsigned i=0;i<2;i++){
                    if(s[i].done)continue;
                    const uint32_t fault=i?t.CPU7_FAULT:t.CPU9_FAULT;
                    if(fault){
                        uint32_t a=i?t.CPU7_FAULT_ADDR:t.CPU9_FAULT_ADDR;
                        if(!reject || fault!=3 || a!=0x04000300)std::fprintf(stderr,"ARM%u fault=%u at %08x last-retired=%08x\n",i?7:9,fault,a,s[i].last);
                        require(reject && fault==3 && a==0x04000300,"fault not the expected unsupported transfer");s[i].done=true;continue;
                    }
                    if(!(i?t.CPU7_RETIRE_VALID:t.CPU9_RETIRE_VALID))continue;
                    uint32_t pc=i?t.CPU7_RETIRE_PC:t.CPU9_RETIRE_PC;
                    if(!s[i].n)require(pc==(i?0:0xffff0000),"wrong cold reset vector");
                    s[i].last=pc;s[i].n++;
                    if(pc==(i?0:0xffff0000))s[i].visits++;
                    if(pc==(i?8:0xffff0008))vectorMask|=1u<<i;
                    if(i && pc==0x03800100)ramMask|=1;
                    if(i && pc==0x03800108)ramMask|=2;
                    if(i && pc==0x3ff8)edgeMask|=1;
                    if(i && pc==0x3ff4)edgeMask|=2;
                    if(i && pc==0x3ffc)edgeMask|=4;
                    if(!reject && pc==pass[i])s[i].done=true;
                }
            }
            uint32_t q9=rom9(t.CPU9_BOOT_ADDR),q7=rom7(t.CPU7_BOOT_ADDR);
            t.CLK=1;t.eval();t.BOOT9_WORD=q9;t.BOOT7_WORD=q7;t.CLK=0;t.eval();
            if(s[0].done && s[1].done)break;
        }
        if(!(s[0].done && s[1].done))std::fprintf(stderr,"stopped at ARM9=%08x ARM7=%08x\n",s[0].last,s[1].last);
        require(s[0].done && s[1].done,"timeout");
        if(!reject){
            require(s[0].visits==2 && s[1].visits==2 && vectorMask==3 && ramMask==3 && edgeMask==7 && stalls>50 && edgeStalls,"proof paths missing");
            std::printf("PASS: POSTFLG power epoch %u, %u/%u ARM9/7 retires, %u held clocks (%u at ROM edge); warm vectors, IPC independence, ARM/Thumb WRAM rejected, BIOS R15 boundary + sticky flag verified\n",epoch+1,s[0].n,s[1].n,stalls,edgeStalls);
        }else std::puts("PASS: unsupported cross-register/word width trapped on both CPUs");
    }
}
