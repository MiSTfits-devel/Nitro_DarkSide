// SPDX-License-Identifier: GPL-3.0-or-later
// Secondary native firmware layout: DeSmuME firmware.cpp CFIRMWARE::unpack;
// KEY1 word ordering: melonDS NDSCart.cpp. No key material or firmware data.
#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace nds_flash_boot {
using Bytes = std::vector<uint8_t>;
inline void need(bool ok, const char* reason) { if (!ok) throw std::runtime_error(reason); }
inline uint16_t u16(const uint8_t* p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
inline uint32_t u32(const uint8_t* p) { return uint32_t(u16(p)) | uint32_t(u16(p+2)) << 16; }
using Pair = std::array<uint32_t,2>;
class Key1 {
  std::array<uint32_t,0x412> words;
public:
  Pair crypt(Pair p, bool reverse) const {
    uint32_t x=p[1], y=p[0];
    for (unsigned i=0;i<16;++i) {
      uint32_t z=x ^ words[reverse ? 17-i : i];
      x=(((words[0x12+(z>>24)] + words[0x112+((z>>16)&255)]) ^
           words[0x212+((z>>8)&255)]) + words[0x312+(z&255)]) ^ y;
      y=z;
    }
    return {x ^ words[reverse ? 1:16], y ^ words[reverse ? 0:17]};
  }
  Key1(const Bytes& bios7,uint32_t id) {
    need(bios7.size()==16384,"Missing ARM7 firmware boot key table");
    for (size_t i=0;i<words.size();++i) words[i]=u32(bios7.data()+0x30+4*i);
    uint32_t code[3]={id,id>>1,id<<1};
    for (unsigned level=0;level<2;++level) {
      for (int j=1;j>=0;--j) {
        const auto p=crypt({code[j],code[j+1]},false); code[j]=p[0];code[j+1]=p[1];
      }
      for(unsigned i=0;i<18;++i) words[i]^=__builtin_bswap32(code[i%3]);
      Pair p{};
      for(size_t i=0;i<words.size();i+=2) {p=crypt(p,false); words[i]=p[1]; words[i+1]=p[0];}
    }
  }
};

// Validate the exact BIOS LZ token stream without retaining guest code. Limit
// both compressed input and decompressed WRAM extent, including a backref's
// source. Firmware uses flags followed by literals or a 12-bit back distance.
struct Stream { uint32_t src, dest, room; };
inline void decode(const Bytes& b, Stream s, uint32_t limit, const Key1* key, uint16_t& crc) {
  uint32_t pos=s.src, produced=0;
  Pair block{}; std::array<uint8_t,4096> window;
  auto byte=[&]() -> uint8_t {
    need(pos<limit,"Truncated native firmware boot stream");
    if (!key) return b[pos++];
    auto i=(pos-s.src)&7;
    if (!i) {need(limit-pos>=8,"Truncated encrypted native firmware block"); block=key->crypt({u32(&b[pos]),u32(&b[pos+4])},true);}
    ++pos; return uint8_t(block[i/4]>>(8*(i%4)));
  };
  const uint8_t type=byte(); uint32_t n=byte(); n|=uint32_t(byte())<<8; n|=uint32_t(byte())<<16;
  need(type==0x10 && n && n<=s.room && !(n&3),"Invalid native firmware boot length/type");
  auto emit=[&](uint8_t v) {
    window[produced++&4095]=v; crc^=v;
    for(unsigned j=0;j<8;++j) crc=uint16_t((crc>>1)^((crc&1)?0xa001:0));
  };
  while(produced<n) {
    unsigned flags=byte();
    for(unsigned mask=128;mask && produced<n;mask>>=1) {
      if(!(flags&mask)) {emit(byte());continue;}
      unsigned first=byte(), second=byte(); unsigned distance=1+((first&15)<<8)+second;
      need(distance<=produced,"Invalid native firmware LZ back-reference");
      unsigned count=std::min<unsigned>((first>>4)+3,n-produced);
      while(count--) emit(window[(produced-distance)&4095]);
    }
  }
}
inline std::array<Stream,2> streams(const uint8_t* h) {
  const uint32_t shifts=u16(h+0x14);
  std::array<Stream,2> result;
  for(unsigned i=0;i<2;++i){
    auto src=uint32_t(u16(h+12+i*4))<<(2+((shifts>>(i*6))&7));
    auto displacement=uint32_t(u16(h+14+i*4))<<(2+((shifts>>(i*6+3))&7));
    uint32_t dest=(i?0x03810000u:0x02800000u)-displacement;
    uint32_t floor=i?0x037f8000u:0x02000000u, end=i?0x03810000u:0x02400000u;
    need(!(dest&3) && dest>=floor && dest<end,"Native boot target outside DS RAM");
    result[i]={src,dest,end-dest};
  }
  return result;
}
inline void verify(const Bytes& b,const Bytes& bios7) {
  need(b.size()==0x40000 && (u16(b.data()+20)>>12)==0 && b[0x17c]!=0xff,
       "Unrecognized alternate native firmware layout");
  const uint32_t alt=b[0x17c]>1?0x3f680:0x3fc80;
  const auto *h=b.data(), *a=h+alt;
  const auto user=uint32_t(u16(h+32))*8;
  need(user>=alt+0x28 && user<=b.size()-512 && !(user&255),"Invalid alternate user area");
  need(std::equal(h+8,h+12,a+8) && u16(a+6)==u16(h+6),"Invalid secondary firmware header");
  for (unsigned field:{0u,2u,4u,22u})
    need(u16(h+field)==u16(a+field),"Secondary firmware table disagrees with primary");
  const uint32_t wifiEnd=0x2c+u16(h+0x2c);
  const auto first=streams(h), second=streams(a);
  std::array<uint32_t,7> starts={first[0].src,first[1].src,second[0].src,second[1].src,
      uint32_t(u16(h))*8,uint32_t(u16(h+2))*8,uint32_t(u16(h+22))*8};
  for(unsigned i=4;i<7;++i) need(starts[i]>=0x200 && starts[i]<alt,"Bad secondary firmware data region");
  std::sort(starts.begin(),starts.end());
  need(std::adjacent_find(starts.begin(),starts.end())==starts.end(),"Overlapping native firmware starts");
  const Key1 key(bios7,u32(h+8));
  for(unsigned stage=0;stage<2;++stage){
    const auto& pair=stage?second:first;
    // Encrypted bootstraps START in the unused header tail, but their stream
    // can cross 0x200. No stream may consume the next named section.
    uint32_t low=stage?0x200:wifiEnd, high=stage?alt:0x200;
    uint16_t crc=0xffff;
    for(unsigned i=0;i<2;++i){
      auto s=pair[i]; need(s.src>=low && s.src<high && !(s.src&3),"Native firmware boot stream outside its region");
      auto next=std::upper_bound(starts.begin(),starts.end(),s.src);
      uint32_t limit=next==starts.end()?alt:*next;
      decode(b,s,limit,stage?nullptr:&key,crc);
    }
    // FlashMe's secondary header copies the primary boot checksum. It is
    // NOT an independent digest of the replacement unencrypted boot programs.
    if(!stage) need(crc==u16(h+6),"Native encrypted bootstrap CRC mismatch");
  }
}
} // namespace nds_flash_boot
