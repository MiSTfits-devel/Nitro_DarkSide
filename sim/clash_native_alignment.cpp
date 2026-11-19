// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vnds_dual_soc_firmware.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
static void check(bool ok,const char *s){if(!ok){std::fprintf(stderr,"alignment: %s\n",s);std::exit(1);}}
struct Beat { bool wr; unsigned off,n; uint32_t value; };
static constexpr Beat expected[]={{true,0,4,0xace05178},{false,0,4,0},{true,2,2,0xd9a3},{true,3,1,0x34},{false,0,4,0},{false,0,4,0},{false,2,2,0},{false,2,2,0}};
int main(int argc,char**argv){
    check(argc==3,"public BIOS9.bin PASS_PC"); std::array<uint8_t,4096> rom{};std::ifstream f(argv[1],std::ios::binary|std::ios::ate);
    auto len=f.tellg();check(len>0 && len<=4096,"invalid public ROM size");f.seekg(0);check(bool(f.read(reinterpret_cast<char*>(rom.data()),len)),"short ROM");
    const uint32_t pass=std::strtoul(argv[2],nullptr,0),base=0x04000204;
    Vnds_dual_soc_firmware t;t.CLK=0;t.RST=1;t.EN=1;t.BOOT9_WORD=t.BOOT7_WORD=0xeafffffe;
    t.CARD_INSERTED=t.CARD_DIRECT_BOOT=t.CARD_CHIP_ID=t.CARD_ROM_MASK=t.CARD_ROM_READY=t.CARD_ROM_REPLY_VALID=t.CARD_ROM_DATA=0;
    t.SYS7_READY=t.SYS7_REPLY_VALID=t.SYS7_REPLY_DATA=t.SYS7_REPLY_FAULT=t.SYS7_IRQ_SET=t.EXT_IRQ_SET=0;
    t.MEM_REQ_READY=t.MEM_RESP_VALID=t.MEM_RESP_DATA=t.MEM_RESP_LINE=t.SNOOP_ADDR=t.SNOOP_WRITE=t.GPU_REPLY_FAULT=0;
    std::array<uint8_t,4> data{};unsigned count=0,due=0,retired=0;uint32_t reply=0,last=0;
    for(unsigned c=0;c<10000;c++){
        t.RST=c<5;t.EN=t.RST || c%13!=3;t.GPU_REQ_READY=!due && t.EN && c%5!=2;
        t.GPU_REPLY_VALID=due && c>=due;t.GPU_REPLY_DATA=reply;t.eval();
        if(!t.RST){
            if(t.CPU9_FAULT)std::fprintf(stderr,"fault %u at %08x, last %08x\n",t.CPU9_FAULT,t.CPU9_FAULT_ADDR,last);
            check(!t.CPU9_FAULT && !t.CPU7_FAULT && !t.MEM_REQ_VALID && !t.IO7_GPU_REQ_VALID,"fault or unexpected external access");
            if(t.CPU9_RETIRE_VALID){last=t.CPU9_RETIRE_PC;retired++;if(last==pass){
                check(count==sizeof expected/sizeof *expected && !due && data==std::array<uint8_t,4>{0x78,0x51,0xa3,0x34},"partial ledger or bad stored data");
                std::printf("PASS: native ARM946 BIOS and stalled MMIO single transfers, SBZ bit1, odd-halfword sign/width, 4 word rotations, ARM/Thumb, unrotated stores, unrounded writeback: %u retired, %u checked beats\n",retired,count);return 0;}}
            if(t.GPU_REPLY_VALID && t.IO9_GPU_REPLY_READY && t.EN)due=0;
            if(t.GPU_REQ_READY && t.IO9_GPU_REQ_VALID){
                check(count<sizeof expected/sizeof *expected,"unexpected extra bus access");auto b=expected[count++];
                check(t.CPU9_REQ_ADDR==base+b.off && t.CPU9_REQ_WIDTH==b.n && t.CPU9_REQ_LANES==(((1u<<b.n)-1)<<b.off) && bool(t.CPU9_REQ_WRITE)==b.wr,"wrong aligned address, width or lane");
                reply=0;if(b.wr)check(t.CPU9_REQ_DATA==b.value,"store data rotated or corrupted");
                for(unsigned j=0;j<b.n;j++)if(b.wr)data[b.off+j]=b.value>>(8*j);else reply|=uint32_t(data[b.off+j])<<(8*j);
                due=c+11;
            }
        }
        auto p=&rom[t.CPU9_BOOT_ADDR&0xffc];uint32_t w=uint32_t(p[0])|uint32_t(p[1])<<8|uint32_t(p[2])<<16|uint32_t(p[3])<<24;
        t.CLK=1;t.eval();t.BOOT9_WORD=w;t.CLK=0;t.eval();
    }
    std::fprintf(stderr,"timeout count=%u last PC=%08x\n",count,last);return 1;
}
