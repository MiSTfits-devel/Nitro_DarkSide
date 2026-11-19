// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vnds_dual_soc_firmware.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
static void require(bool ok,const char*why){if(!ok){std::fprintf(stderr,"TCM: %s\n",why);std::exit(1);}}
template<size_t N> struct Boot {std::array<uint8_t,N> data{};
 explicit Boot(const char*path){std::ifstream f(path,std::ios::binary|std::ios::ate);auto n=f.tellg();require(n>0 && n<=N,"ROM size");f.seekg(0);require(bool(f.read((char*)data.data(),n)),"ROM read");}
 uint32_t at(uint32_t a)const{auto p=&data[a&(N-4)];return uint32_t(p[0])|uint32_t(p[1])<<8|uint32_t(p[2])<<16|uint32_t(p[3])<<24;}
};
int main(int argc,char**argv){require(argc==5,"9.bin 7.bin pass9 pass7");Boot<4096> r9(argv[1]);Boot<16384> r7(argv[2]);
 uint32_t pass[]={uint32_t(std::strtoul(argv[3],nullptr,0)),uint32_t(std::strtoul(argv[4],nullptr,0))};
 Vnds_dual_soc_firmware t;t.CLK=0;t.EN=1;t.RST=1;t.BOOT9_WORD=t.BOOT7_WORD=0xe7f000f0;
 t.CARD_INSERTED=t.CARD_DIRECT_BOOT=t.CARD_CHIP_ID=t.CARD_ROM_MASK=t.CARD_ROM_READY=t.CARD_ROM_REPLY_VALID=t.CARD_ROM_DATA=0;
 t.SYS7_READY=t.SYS7_REPLY_VALID=t.SYS7_REPLY_DATA=t.SYS7_REPLY_FAULT=t.SYS7_IRQ_SET=t.EXT_IRQ_SET=0;
 t.MEM_REQ_READY=t.MEM_RESP_VALID=t.MEM_RESP_DATA=t.MEM_RESP_LINE=t.SNOOP_ADDR=t.SNOOP_WRITE=t.GPU_REQ_READY=t.GPU_REPLY_VALID=t.GPU_REPLY_DATA=t.GPU_REPLY_FAULT=0;
 for(unsigned epoch=0;epoch<2;epoch++) {unsigned n[2]={},hits=0;bool passed[2]={};uint32_t last[2]={};
 uint32_t ram=0,response=0;unsigned due=0,writes=0,reads=0,stalls=0;
 for(unsigned c=0;c<20000;c++){t.RST=c<6;t.EN=t.RST || !epoch || c%7>1;
  t.MEM_REQ_READY=t.EN && !due && c%5==0;t.MEM_RESP_VALID=t.EN && due && c>=due;
  t.MEM_RESP_DATA=response;t.MEM_RESP_LINE=response;t.eval();
 if(!t.RST){
  if(t.CPU9_FAULT || t.CPU7_FAULT || t.IO7_GPU_REQ_VALID || t.IO9_GPU_REQ_VALID)std::fprintf(stderr,"fault9=%u/%08x fault7=%u/%08x last PCs=%08x/%08x\n",t.CPU9_FAULT,t.CPU9_FAULT_ADDR,t.CPU7_FAULT,t.CPU7_FAULT_ADDR,last[0],last[1]);
  require(!t.CPU9_FAULT && !t.CPU7_FAULT && !t.IO7_GPU_REQ_VALID && !t.IO9_GPU_REQ_VALID,"fault or unexpected MMIO");
  if(t.MEM_RESP_VALID)due=0;
  if(t.MEM_REQ_VALID){
   require(t.MEM_REQ_ADDR==0x02000000 && !t.MEM_ARM7,"private traffic leaked or wrong external address");
   if(!t.MEM_REQ_READY)stalls++;
   else {require(!due,"overlapping RAM requests");response=ram;due=c+9;
    if(t.MEM_REQ_WRITE){unsigned lanes=t.MEM_REQ_LANES;uint32_t data=t.MEM_REQ_DATA;
      require((writes==0 && lanes==15 && data==0xa1b2c3d4) || (writes==1 && lanes==2 && (data&0xff00)==0xe700),"TCM write escaped or bad sentinel write");
      for(unsigned j=0;j<4;j++)if(lanes&(1u<<j)){uint32_t mask=0xffu<<(8*j);ram=(ram&~mask)|(data&mask);}writes++;
    }else reads++;
   }
  }
  for(unsigned i=0;i<2;i++)if(!passed[i] && (i?t.CPU7_RETIRE_VALID:t.CPU9_RETIRE_VALID)) {last[i]=i?t.CPU7_RETIRE_PC:t.CPU9_RETIRE_PC;n[i]++;passed[i]=last[i]==pass[i];if(!i){if(last[i]==0x8200)hits|=1;if(last[i]==0x8208)hits|=2;if(last[i]==0x820a)hits|=4;}}
 }
 auto a=r9.at(t.CPU9_BOOT_ADDR),b=r7.at(t.CPU7_BOOT_ADDR);t.CLK=1;t.eval();t.BOOT9_WORD=a;t.BOOT7_WORD=b;t.CLK=0;t.eval();if(passed[0]&&passed[1])break;
 }
 require(passed[0]&&passed[1]&&hits==7,"missing ARM/Thumb alias retirements or completion");
 require(!due && writes==2 && reads>=4 && stalls && ram==0xa1b2e7d4,"missing external sentinel or stalls");
 std::printf("PASS: TCM reset %u: ARM9 %u / ARM7 %u retired; MPU, load modes, ARM/Thumb ITCM, isolation, remap; underlying main RAM intact after %u reads, %u writes, %u stall clocks\n",epoch+1,n[0],n[1],reads,writes,stalls);}
}
