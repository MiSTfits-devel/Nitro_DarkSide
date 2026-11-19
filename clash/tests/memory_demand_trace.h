// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
namespace memory_trace {
inline uint32_t mix(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; return x ^ (x >> 16);
}
inline uint16_t initial(unsigned ha){uint16_t x=ha^0xc33c^((ha>>16)<<8);return uint16_t((x<<8)|(x>>8)) ^ uint16_t(ha>>16) ^ 0x1234;}
inline uint64_t hash(uint64_t state,uint64_t q){return (state^q)*1099511628211ull;}
// Deliberately cold BG lines; display addresses do not depend on controller
// timing, CPU grants, or the number of cycles spent waiting for a response.
inline uint32_t video(unsigned y,unsigned slot){return mix(y*1024+slot+61)&0x1fff8;}
// Saturated, independent CPU-main stream. Disjoint from the display VRAM:
// this isolates scheduling, not read-after-write bypass at cross-channel races.
struct Bus { uint32_t offset, data; bool seven, write; };
inline Bus cpu(unsigned y,unsigned slot){auto k=mix(y*4096+slot+117);return {k&0x3ffffcu,mix(k),bool(k&1),bool(k&2)};}
}
