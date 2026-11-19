// SPDX-License-Identifier: GPL-3.0-or-later
// Public marker test by default. Optional owner media is read once, never
// printed; each destructive negative test below operates on an in-memory copy.
#include "test_firmware_fixture.h"
#include <filesystem>
#include <fstream>
#include <iostream>
using namespace nds_flash_boot;
static Bytes marker(const Bytes& bios) {
  using namespace firmware_fixture;
  Bytes b=syntheticFirmware();
  constexpr unsigned alt=0x3f680;
  b[0x17c]=2;
  put16(b,0x14,6<<3); put16(b,14,0x4100); put16(b,18,0x200);
  put16(b,12,0x180/4); put16(b,16,0x198/4);
  std::copy_n(b.begin(),0x28,b.begin()+alt);
  put16(b,alt+12,0x4000/4); put16(b,alt+16,0x4400/4);
  Key1 key(bios,u32(b.data()+8));
  uint16_t crc=0xffff;
  for (unsigned stage=0;stage<2;++stage) {
    const auto pair=streams(b.data()+(stage?alt:0));
    for (unsigned i=0;i<2;++i) {
      auto pos=pair[i].src;
      std::array<uint8_t,16> plain{0x10,4,0,0,0,0x46,0x49,0x4f,uint8_t(0x40+2*stage+i)};
      if (stage) {std::copy(plain.begin(),plain.end(),b.begin()+pos);continue;}
      crc=nds_firmware::crc16(plain.data()+5,4,crc);
      for (unsigned j=0;j<16;j+=8) {
        const auto encrypted=key.crypt({u32(plain.data()+j),u32(plain.data()+j+4)},false);
        for(unsigned k=0;k<8;++k) b[pos+j+k]=uint8_t(encrypted[k/4]>>(8*(k%4)));
      }
    }
  }
  put16(b,6,crc); put16(b,alt+6,crc);
  return b;
}
int main(int argc,char**argv) {
  if(argc>2){std::cerr<<"usage: test_flash_boot [PRIVATE_NATIVE_DIRECTORY]\n"; return 2;}
  try {
    Bytes b,bios;
    if(argc==2) {
      auto originals=nds_firmware::Media::readOriginals(argv[1]);
      b=std::move(originals.firmware); bios=std::move(originals.bios7);
    } else {
      bios=firmware_fixture::syntheticBios(16384,0x42,0x1280f0d5);
      b=marker(bios);
    }
    nds_firmware::inspectProfile(b,&bios);
    auto reject=[&](const auto& mutate){ auto bad=b; mutate(bad);
      try{nds_firmware::inspectProfile(bad,&bios);}catch(const std::runtime_error&){return;}
      throw std::runtime_error("Invalid alternate layout accepted"); };
    unsigned alt=b[0x17c]>1?0x3f680:0x3fc80;
    reject([](Bytes&v){v.pop_back();});
    reject([](Bytes&v){v[0x17c]=0xff;});
    reject([](Bytes&v){v[6]^=1; v[v[0x17c]>1?0x3f686:0x3fc86]^=1;});
    reject([](Bytes&v){v[streams(v.data())[0].src]^=1;});
    reject([&](Bytes&v){v[alt+12]=v[alt+13]=0xff;});
    reject([&](Bytes&v){auto off=streams(v.data()+alt)[0].src;v[off+3]=0xff;});
    reject([&](Bytes&v){auto off=streams(v.data()+alt)[1].src;v[off+4]=0x80;});
    reject([](Bytes&v){v[0x2a]^=1;});
    reject([](Bytes&v){const auto user=u16(v.data()+32)*8;v[user+0x72]^=1;v[user+0x172]^=1;});
    std::cout<<"PASS "<<(argc==2?"private":"source-generated")<<" alternate profile: primary decrypted boot CRC, bounded secondary CPU streams, nine rejection cases; no original writes\n";
  }catch(const std::exception&e){std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
}
