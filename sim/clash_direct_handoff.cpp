// SPDX-License-Identifier: GPL-3.0-or-later
// Two independent starts on the pushed DualSoc top: reproduce the synthetic
// loader's rejection, then stage a *post-firmware* image outside the CPU and
// enter its binaries. This is not a KEY1 implementation or a new B7 mode.
#ifdef FETCH_BUFFER
#include "Vnds_dual_soc_buffered.h"
using DUT = Vnds_dual_soc_buffered;
#else
#include "Vnds_dual_soc_wide.h"
using DUT = Vnds_dual_soc_wide;
#endif
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <vector>

using Bytes = std::vector<uint8_t>;
constexpr uint32_t base = 0x02000000, ramSize = 0x400000, marker = 0xe7ffdeff;
using Rom = std::array<uint8_t,4096>;
using Header = std::array<uint8_t, 512>;
static void require(bool ok, const char *why) {
    if (!ok) { std::fprintf(stderr, "direct handoff: %s\n", why); std::exit(1); }
}
static uint32_t word(const uint8_t *p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
static void readAt(std::ifstream &file, uint32_t offset, uint8_t *buffer, size_t count) {
    file.seekg(offset);
    require(bool(file.read(reinterpret_cast<char*>(buffer), count)), "short image read");
}
static Rom boot(const char *path, const Header *header) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    const auto n = f.tellg();
    require(n > 0 && n <= 4096, "missing or oversized boot ROM");
    Rom rom{};
    readAt(f, 0, rom.data(), size_t(n));
    if (header) std::copy(header->begin(), header->end(), rom.begin() + 0xe00);
    return rom;
}
struct Section { uint32_t off, entry, addr, size; };
static Section section(const Header &h, unsigned at, uint64_t imageSize) {
    const uint8_t *p = h.data() + at;
    Section s{word(p), word(p+4), word(p+8), word(p+12)};
    require(s.size && ((s.off | s.size | s.addr | s.entry) & 3) == 0, "unaligned or empty section");
    require(uint64_t(s.off) + s.size <= imageSize, "section outside image");
    require(s.addr >= base && uint64_t(s.addr) + s.size <= base + ramSize, "not a 4 MiB main RAM section");
    require(s.entry >= s.addr && s.entry - s.addr < s.size, "entry outside section");
    return s;
}
// NDS::SetupDirectBoot and sim/tb_top_frame.vhd::preload_main: this is a
// trusted post-firmware input, not ciphertext. Do not silently substitute a
// page from 0x8000 or invent decrypted bytes if a retail dump is encrypted.
static Bytes stage(std::ifstream &image, const Header &h, Section a, Section b) {
    require(a.off >= 0x4000 && a.off < 0x8000 && a.size >= 0x800, "expected secure-area ARM9 section");
    require(b.off >= 0x8000, "expected normal ARM7 section");
    require(a.addr + a.size <= b.addr || b.addr + b.size <= a.addr, "overlapping RAM sections");
    Bytes ram(ramSize);
    std::copy_n(h.begin(), 0x170, ram.begin() + (0x027ffe00 & (ramSize-1)));
    for (auto s : {a,b}) readAt(image, s.off, &ram[s.addr-base], s.size);
    const uint8_t *prefix = &ram[a.addr-base];
    require(word(prefix) == marker && word(prefix+4) == marker, "expected post-firmware ARM9 markers; encrypted input not supported");
    return ram;
}
static uint32_t fetch(const Rom &rom, uint32_t pc, uint32_t start) {
    // BOOT_ADDR also serves literal loads: the CPU selects the byte lane.
    const uint32_t aligned = (pc-start) & ~3u;
    return aligned < rom.size() ? word(&rom[aligned]) : 0xe7f000f0;
}
static void clock(DUT &t) { t.CLK=1; t.eval(); t.CLK=0; t.eval(); }

struct Trace {
    // tracer.patch records the pre-execute R15 but the post-execute CPSR.
    // Use the preceding record's T flag to remove the pipeline offset.
    // No register or instruction contents are printed.
    std::ifstream in;
    unsigned matched=0, limit;
    bool thumb=false, skipReferenceBios;
    explicit Trace(const char *path, unsigned n=16, bool skip=false) : limit(n), skipReferenceBios(skip) {
        if (path) { in.open(path); require(bool(in),"missing reference trace"); }
    }
    void compare(uint32_t pc, uint32_t op) {
        if (!in.is_open() || matched==limit) return;
        uint32_t rp,ro,psr,addr;
        do {
            require(bool(in >> std::hex >> rp >> ro >> psr),"reference trace too short");
            in.ignore(1024,'\n');
            addr=rp-(thumb?4:8);
            thumb=(psr&32)!=0;
        } while (skipReferenceBios && addr<0x4000); // functional shim intentionally differs from BIOS
        if (pc!=addr || op!=ro) {
            std::fprintf(stderr,"reference mismatch at record %u, CPU PC %08x, reference PC %08x\n",matched+1,pc,addr);
            require(false,"guest PC/opcode differs from reference");
        }
        ++matched;
    }
};
static void run(bool stock, bool synthetic, const Rom &boot9, const Rom &boot7,
                Bytes ram, uint16_t headerCRC, Section a, Section b, const char *trace9, bool shared=false, bool waitBios=false) {
    DUT t;
#ifdef FETCH_BUFFER
    t.MEM_RESP_LINE=0; t.SNOOP_WRITE=0; t.SNOOP_ADDR=0;
#endif
    t.CLK=0; t.EN=1; t.RST=1; t.BOOT9_WORD=t.BOOT7_WORD=0;
    t.GPU_REQ_READY=t.GPU_REPLY_VALID=t.GPU_REPLY_DATA=t.GPU_REPLY_FAULT=t.EXT_IRQ_SET=0;
    t.CARD_INSERTED=1; t.CARD_DIRECT_BOOT=1; t.CARD_CHIP_ID=0x3fc2; t.CARD_ROM_MASK=0x03ffffff;
    t.CARD_ROM_READY=1; t.CARD_ROM_REPLY_VALID=t.CARD_ROM_DATA=0;
    t.MEM_REQ_READY=1; t.MEM_RESP_VALID=t.MEM_RESP_DATA=0;
    t.eval(); clock(t); clock(t); t.RST=0;
    unsigned slots=0, guest9=0, guest7=0;
    unsigned privateRetires=0;
    unsigned shared9=0, shared7=0;
    std::array<uint32_t,32> recentPc7{};
    uint32_t lastRetired7=0;
    unsigned vectors7=0, decrements7=0, returns7=0;
    bool firstReturn7=false;
    std::array<uint8_t,4> vram{};
    std::array<uint8_t,3> vramCnt{}; // E/F/G companion bytes only; WRAMCNT is real HDL
    bool gpuPending=false;
    uint32_t gpuWord=0;
    bool fetched7=false, held=false;
    uint32_t heldAddr=0; bool heldOwner=false;
    unsigned stalls=0;
    unsigned reads=0, wait9=0, wait7=0, due=0;
    unsigned reqs[2]={}, service[2][2]={}, arbitration[2]={}, remaining[2]={};
    bool pending7=false, pendingFetch=false;
    unsigned irqPhase[2]={};
    const char *retPath=synthetic && !stock ? std::getenv("PUBLIC_RETIRE_PREFIX") : nullptr;
    std::ofstream retired[2];
    if (retPath) for (int k=0;k<2;++k) {
        retired[k].open(std::string(retPath)+(k?".7":".9"),std::ios::binary);
        require(bool(retired[k]),"cannot open public retirement trace");
    }
    uint32_t answer=0;
    uint64_t burst=0, digest9=0, digest7=0;
    const std::string path7=trace9 ? std::string(trace9)+".7" : "";
    constexpr unsigned firstSwi=230817, postWindow=32;
    Trace ref7(trace9 && !stock ? path7.c_str() : nullptr,firstSwi+(waitBios?postWindow:0),waitBios);
    bool done9=false, done7=false, fault9=false, fault7=false;
    Trace reference(stock ? nullptr : trace9,64);
    const unsigned cycleLimit=synthetic || stock ? 160000 : 4000000;
    for (unsigned cycle=0; cycle<cycleLimit; ++cycle) {
        const bool slow=synthetic && !stock;
        t.MEM_REQ_READY = due <= cycle && (!slow || cycle%5 >= 2);
        t.MEM_RESP_VALID = cycle && due == cycle;
        t.MEM_RESP_DATA = answer;
        t.GPU_REQ_READY=!gpuPending;
        t.GPU_REPLY_VALID=gpuPending;
        t.GPU_REPLY_DATA=gpuWord;
#ifdef FETCH_BUFFER
        t.MEM_RESP_LINE = burst;
#endif
        t.eval();
        t.BOOT9_WORD=fetch(boot9,t.CPU9_BOOT_ADDR,0xffff0000);
        t.BOOT7_WORD=fetch(boot7,t.CPU7_BOOT_ADDR,0);
        t.eval();
        require(!t.CARD_ROM_REQ_VALID, "unexpected card read (HLE is not B7)");
        if (gpuPending && t.IO9_GPU_REPLY_READY) gpuPending=false;
        if (t.IO9_GPU_REQ_VALID && t.GPU_REQ_READY) {
            const uint32_t addr=t.CPU9_REQ_ADDR, width=t.CPU9_REQ_WIDTH;
            require(!stock && addr>=0x04000244 && addr<=0x04000248-width &&
                    (width==1 || width==2 || width==4),"unexpected ARM9 peripheral");
            const unsigned first=addr-0x04000244;
            require(t.CPU9_REQ_LANES==(((1u<<width)-1)<<first),"bad control lanes");
            gpuWord=0;
            for (unsigned k=0;k<width && first+k<3;++k) {
                if (t.CPU9_REQ_WRITE) vramCnt[first+k]=uint8_t(t.CPU9_REQ_DATA>>(8*k));
                gpuWord|=uint32_t(vramCnt[first+k])<<(8*k);
            }
            gpuPending=true;
        }
        if (stock) {
            require(!(t.CPU9_FAULT || t.CPU7_FAULT), "CPU fault before stock loader rejection");
            if (t.CPU9_STORE_VALID) {
                require(t.CPU9_STORE_ADDR == base + 4*slots, "unexpected stock loader store");
                require(t.CPU9_STORE_DATA == (slots<2 ? headerCRC : 0xe002), "unexpected rejection or failed header CRC");
                if (++slots == 3) {
                    std::printf("stock: header CRC accepted, mailbox[2]=e002, no card read (%u cycles)\n", cycle);
                    return;
                }
            }
        } else {
            if (t.CPU7_RETIRE_VALID) {
                lastRetired7=t.CPU7_RETIRE_PC;
                if (lastRetired7==8) ++vectors7;
                if (lastRetired7<0xe00 && t.CPU7_RETIRE_OPCODE==0xe2500001) ++decrements7; // public SUBS r0,r0,#1
                if (lastRetired7<0xe00 && t.CPU7_RETIRE_OPCODE==0xe1b0f00e) ++returns7;    // public MOVS pc,lr
            }
            if (synthetic) for (int k=0;k<2;++k) {
                const bool valid=k?t.CPU7_RETIRE_VALID:t.CPU9_RETIRE_VALID;
                const uint32_t pc=k?t.CPU7_RETIRE_PC:t.CPU9_RETIRE_PC, op=k?t.CPU7_RETIRE_OPCODE:t.CPU9_RETIRE_OPCODE;
                if (valid && retPath && !(k?done7:done9)) {
                    retired[k].write(reinterpret_cast<const char*>(&pc),4);
                    retired[k].write(reinterpret_cast<const char*>(&op),4);
                }
                auto &phase=irqPhase[k];
                bool pending=(k?t.IO7_IF:t.IO9_IF)&8;
                if (phase==0 && pending) phase=1;
                if (valid && pc==(k?0x18u:0xffff0018u)) { require(phase==1,"timer IRQ vector out of order"); phase=2; }
                if (phase==2 && !pending) phase=3;
            }
            const bool sharedPc9=(t.CPU9_RETIRE_PC >> 24)==3;
            if (t.CPU9_RETIRE_VALID && (sharedPc9 || (t.CPU9_RETIRE_PC >= base && t.CPU9_RETIRE_PC < base + ramSize))) {
                if (sharedPc9) ++shared9;
                if (!guest9) require(t.CPU9_RETIRE_PC == a.entry, "wrong ARM9 first guest PC");
                reference.compare(t.CPU9_RETIRE_PC, t.CPU9_RETIRE_OPCODE);
                if (!done9) digest9=digest9*33+t.CPU9_RETIRE_PC+t.CPU9_RETIRE_OPCODE;
                ++guest9;
            }
            const bool privatePc=(t.CPU7_RETIRE_PC >> 23)==7;
            const bool sharedPc7=(t.CPU7_RETIRE_PC >> 23)==6;
            if (t.CPU7_RETIRE_VALID && (privatePc || sharedPc7 || (t.CPU7_RETIRE_PC >= base && t.CPU7_RETIRE_PC < base + ramSize))) {
                if (sharedPc7) ++shared7;
                if (privatePc) ++privateRetires;
                if (!guest7) require(t.CPU7_RETIRE_PC == b.entry, "wrong ARM7 first guest PC");
                require(fetched7,"ARM7 retired without exact entry fetch from external RAM");
                if (waitBios && guest7==firstSwi) {
                    require(vectors7==1 && returns7==1 && decrements7==250 && t.CPU7_RETIRE_PC==0x03804296,
                            "first WaitByLoop did not return to the reference Thumb PC after 250 decrements");
                    firstReturn7=true;
                }
                ref7.compare(t.CPU7_RETIRE_PC,t.CPU7_RETIRE_OPCODE);
                if (!done7) digest7=digest7*33+t.CPU7_RETIRE_PC+t.CPU7_RETIRE_OPCODE;
                if (!synthetic) recentPc7[guest7 % recentPc7.size()]=t.CPU7_RETIRE_PC;
                ++guest7;
            }
            if (shared) {
                require(!(t.CPU9_FAULT || t.CPU7_FAULT), "shared-WRAM guest fault");
                if (t.CPU9_STORE_VALID && t.CPU9_STORE_ADDR==base+0xfe8) {
                    require(t.CPU9_STORE_DATA==0x9999cafe, "ARM9 shared-WRAM result"); done9=true;
                }
                if (t.CPU7_STORE_VALID && t.CPU7_STORE_ADDR==base+0xfec) {
                    require(t.CPU7_STORE_DATA==0x7777beef, "ARM7 shared-WRAM result"); done7=true;
                }
                if (done9 && done7) {
                    require(shared9==6 && shared7==8, "missing real execution from shared WRAM");
                    require(vectors7==2 && returns7==2 && decrements7==8,"missing ARM/Thumb WaitByLoop execution");
                    std::printf("SWI 03: ARM/Thumb calls, %u actual decrements, %u exception returns\n",decrements7,returns7);
                    std::printf("shared WRAM: modes 0..3, both mailboxes, %u/%u ARM9/7 shared-code retirements, %u cycles\n",shared9,shared7,cycle);
                    return;
                }
            } else if (synthetic) {
                require(!(t.CPU9_FAULT || t.CPU7_FAULT), "public post-firmware guest fault");
                if (t.CPU9_STORE_VALID && t.CPU9_STORE_ADDR == base+0xff8) {
                    // Sum of two markers and 0x57400000+13*i for i=2..511.
                    const uint32_t sum = 2u*marker + 510u*0x57400000u + 13u*(511u*512u/2u-1u);
                    require(t.CPU9_STORE_DATA == sum, "secure prefix did not survive staging");
                    done9=true;
                }
                if (t.CPU7_STORE_VALID && t.CPU7_STORE_ADDR == base+0xffc) {
                    require(privateRetires==6,"missing ARM/Thumb execution from ARM7 private WRAM");
                    require(t.CPU7_STORE_DATA == b.entry, "bad ARM7 entry LR"); done7=true;
                }
                if (done9 && done7 && guest9 && guest7) {
                    require(irqPhase[0]==3 && irqPhase[1]==3,"missing timer IF/vector/ack sequence");
                    require(stalls,"owner hold was never exercised");
                    std::printf("staged: both high guests ran; both passed distinct-page + mirror checks, ARM7 C/D lane and VRAMSTAT, ARM9 512 secure-prefix words (%u cycles)\n", cycle);
                    std::printf("public reads=%u wait9=%u wait7=%u cycles=%u digest=%016llx:%016llx\n",reads,wait9,wait7,cycle,
                                (unsigned long long)digest9,(unsigned long long)digest7);
                    std::printf("accepted main fetch/data reads=%u/%u; ARM9 disabled service(I/D)/lost-grant/other=%u/%u/%u/%u; ARM7 eligible disabled=%u/%u/%u/%u\n",
                                reqs[1],reqs[0],service[0][1],service[0][0],arbitration[0],remaining[0],
                                service[1][1],service[1][0],arbitration[1],remaining[1]);
                    return;
                }
            } else {
                if (t.CPU9_FAULT && !fault9) {
                    const uint32_t pc=t.CPU9_FAULT_ADDR;
                    require(t.CPU9_FAULT == 1 && pc >= a.addr && pc-a.addr <= a.size-4, "not an unsupported ARM9 guest instruction");
                    const uint32_t insn=word(&ram[pc-base]);
                    std::printf("frontier: ARM9 fault 1 at %08x after %u guest retires (cycle %u)\n",pc,guest9,cycle);
                    require(pc==0x02000ac8 && (insn&0x0fff0fff)==0x0e090f31,
                            "not the expected ITCM region write following MPU setup");
                    reference.compare(pc,insn);
                    fault9=true;
                }
                if (t.CPU7_FAULT && !fault7) {
                    std::printf("frontier: ARM7 fault %u at %08x after %u guest retires (cycle %u); last retired PC %08x, preceding guest PCs",
                                unsigned(t.CPU7_FAULT), t.CPU7_FAULT_ADDR, guest7, cycle, lastRetired7);
                    const unsigned count=std::min(guest7,8u);
                    for (unsigned n=guest7-count;n<guest7;++n) std::printf(" %08x",recentPc7[n % recentPc7.size()]);
                    std::putchar('\n');
                    fault7=true;
                }
                if (fault7 && fault9) {
                    require(!waitBios, "unexpected ARM7 fault with functional WaitByLoop enabled");
                    require(guest9==30,"unexpected ARM9 retirement count before ITCM setup");
                    require(fetched7 && guest7==230817 && lastRetired7==0x03804294 &&
                            t.CPU7_FAULT==1 && t.CPU7_FAULT_ADDR==8,
                            "unexpected ARM7 frontier at unimplemented BIOS SWI vector");
                    std::printf("staged: ARM9 %08x (%u reference records including rejected instruction); ARM7 %08x (%u reference records)\n",a.entry,reference.matched,b.entry,ref7.matched);
                    return;
                }
            }
        }
        if (held) require(t.MEM_REQ_VALID && heldAddr == t.MEM_REQ_ADDR && heldOwner == bool(t.MEM_ARM7),
                          "offered address or owner changed while stalled");
        held=t.MEM_REQ_VALID && !t.MEM_REQ_READY;
        if (held) { heldAddr=t.MEM_REQ_ADDR; heldOwner=t.MEM_ARM7; ++stalls; }
        const bool req=t.MEM_REQ_VALID && t.MEM_REQ_READY;
        if (slow) {
            wait9+=!t.ARB_STEP9;
            wait7+=t.ARB_CE7 && !t.ARB_STEP7;
            for (unsigned who=0;who<2;++who) {
                if (who ? !t.ARB_CE7 || t.ARB_STEP7 : t.ARB_STEP9) continue;
                if (due>cycle && pending7==bool(who)) ++service[who][pendingFetch];
                else if (t.ARB_GRANT==(2u+(1u-who)) && (who?t.ARB_WANT7:t.ARB_WANT9)) ++arbitration[who];
                else ++remaining[who]; // admission/backpressure, uncategorized incl hit response
            }
        }
        uint32_t data=0;
        if (req) {
            const uint32_t addr=t.MEM_REQ_ADDR, ix=addr & (ramSize-1);
            uint8_t *p=nullptr;
            if ((addr >> 24) == 2) {
                require(!(ix&3) && ix <= ram.size()-4,"request outside backing store");
                p=&ram[ix];
                if (!t.MEM_REQ_WRITE) {
                    ++reqs[t.MEM_FETCH];
                    ++reads;
                    const uint8_t *line=&ram[ix&~7u];
                    burst=uint64_t(word(line)) | uint64_t(word(line+4))<<32;
                }
                if (t.MEM_ARM7 && addr == b.entry && !t.MEM_REQ_WRITE) fetched7=true;
            } else if (synthetic && addr==0x06020000 && t.MEM_ARM7) {
                p=vram.data();
                if (t.MEM_REQ_WRITE) require(t.MEM_REQ_LANES == 8 && (t.MEM_REQ_DATA >> 24)==0x93,"bad VRAM byte lane");
            } else if (synthetic && addr==0x04000240 && t.MEM_ARM7 && !t.MEM_REQ_WRITE) {
                data=0x12345603; // only lane 0 is VRAMSTAT
            } else require(false,"unexpected request outside main RAM, ARM7 C/D, VRAMSTAT");
            if (p) {
                data=word(p);
                if (t.MEM_REQ_WRITE) for (unsigned k=0;k<4;++k) if (t.MEM_REQ_LANES & (1u<<k)) p[k]=uint8_t(t.MEM_REQ_DATA>>(8*k));
            }
            due=cycle+(slow ? 6 : 1); answer=data;
            pending7=t.MEM_ARM7; pendingFetch=t.MEM_FETCH;
        }
        clock(t);
    }
    if (waitBios) {
        require(fault9 && !fault7 && firstReturn7 && returns7>=2 && guest7>=firstSwi+postWindow,
                "ARM7 failed to advance through repeated real BIOS calls");
        std::printf("bounded: %u cycles; ARM7 %u guest retires, %u SWI vectors, %u loop decrements, %u returns; last retired PC %08x; no ARM7 fault\n",
                    cycleLimit,guest7,vectors7,decrements7,returns7,lastRetired7);
        std::printf("reference: ARM9 %u; ARM7 %u guest PC/opcodes (BIOS excluded)\n",reference.matched,ref7.matched);
        return;
    }
    std::fprintf(stderr,"direct handoff: %u-cycle bound (ARM9/7 guest retires %u/%u; ARM7 private retires %u)\n",
                 cycleLimit,guest9,guest7,privateRetires);
    if (!synthetic && guest7) {
        const auto n=std::min<size_t>(guest7,recentPc7.size());
        const auto range=std::minmax_element(recentPc7.begin(),recentPc7.begin()+n);
        std::fprintf(stderr,"last %zu ARM7 guest PCs: min=%08x max=%08x last=%08x\n",
                     n,*range.first,*range.second,recentPc7[(guest7-1)%recentPc7.size()]);
    }
    require(false, "cycle bound exhausted");
}
// ROM probes park the unused CPU on B .; no card, firmware or game.
static void resetProbe(DUT &t) {
    t.CLK=0; t.EN=1; t.RST=1;
    t.BOOT9_WORD=t.BOOT7_WORD=0xeafffffe;
    t.MEM_RESP_VALID=t.MEM_RESP_DATA=t.MEM_REQ_READY=t.EXT_IRQ_SET=0;
    t.CARD_INSERTED=t.CARD_DIRECT_BOOT=t.CARD_CHIP_ID=t.CARD_ROM_MASK=0;
    t.CARD_ROM_READY=t.CARD_ROM_REPLY_VALID=t.CARD_ROM_DATA=0;
    t.GPU_REQ_READY=t.GPU_REPLY_VALID=t.GPU_REPLY_DATA=t.GPU_REPLY_FAULT=0;
#ifdef FETCH_BUFFER
    t.MEM_RESP_LINE=0; t.SNOOP_WRITE=t.SNOOP_ADDR=0;
#endif
    t.eval(); clock(t); clock(t); t.RST=0;
}
static int controlFault(bool arm7, const char *file, unsigned code, uint32_t addr, int invalidate=-1) {
    DUT t;
    const Rom rom=boot(file,nullptr);
    resetProbe(t);
    constexpr uint32_t bxLr=0xe12fff1e;
    bool pending=false, probe=false;
    uint32_t resident=0, target=0;
    unsigned demands=0, returns=0;
    for (unsigned n=0;n<300;++n) {
        t.MEM_REQ_READY=invalidate>=0;
        t.MEM_RESP_VALID=pending;
        t.MEM_RESP_DATA=bxLr;
#ifdef FETCH_BUFFER
        t.MEM_RESP_LINE=uint64_t(bxLr)<<32|bxLr;
#endif
        t.eval();
        if (arm7) t.BOOT7_WORD=fetch(rom,t.CPU7_BOOT_ADDR,0);
        else t.BOOT9_WORD=fetch(rom,t.CPU9_BOOT_ADDR,0xffff0000);
        if (invalidate>=0 && t.CPU9_BOOT_ADDR==0xffff0800) {
            require(resident,"no prior fetch line for invalidate probe");
            t.BOOT9_WORD=target=resident; probe=true;
        }
        t.eval();
        pending=t.MEM_REQ_VALID && t.MEM_REQ_READY;
        require(!t.IO9_GPU_REQ_VALID && !t.CARD_ROM_REQ_VALID,"unexpected probe I/O");
        if (t.MEM_REQ_VALID) {
            require(invalidate>=0 && (t.MEM_REQ_ADDR>>24)==2 && !t.MEM_ARM7 &&
                    !t.MEM_REQ_WRITE && t.MEM_FETCH,"unexpected probe demand");
            if (pending) {
                resident=t.MEM_REQ_ADDR&~7u;
                if (probe && t.MEM_REQ_ADDR==target) ++demands;
            }
        }
        if (t.CPU9_RETIRE_VALID && t.CPU9_RETIRE_OPCODE==bxLr &&
            (t.CPU9_RETIRE_PC>>24)==2) ++returns;
        const unsigned fault=arm7?t.CPU7_FAULT:t.CPU9_FAULT;
        if (fault) {
            require(fault == code && (arm7?t.CPU7_FAULT_ADDR:t.CPU9_FAULT_ADDR)==addr,"incorrect CP15 fault");
            if (invalidate>=0) {
                require(probe && returns==2,"did not execute both demand probes");
#ifdef FETCH_BUFFER
                require((demands!=0)==bool(invalidate),"MCR did not selectively evict resident line");
#else
                require(demands!=0,"bypassed fetch did not request target");
#endif
            }
            return 0;
        }
        clock(t);
    }
    require(false,"no CP15 fault"); return 1;
}
// The target delays *visibility* along with the reply; accepting a write
// request is intentionally not counted as completion. A separate IO reply
// is held until the core consumes it. Both MCRs must retire exactly once.
static int checkDrain(const char *file, uint32_t finished) {
    DUT t; resetProbe(t);
    const Rom rom=boot(file,nullptr);
    unsigned rdDue=0, wrDue=0, ioDue=0, ramWrites=0, ioWrites=0, drains=0, dinvs=0;
    uint32_t ram=0x87563412;
    bool ioVisible=false, ramVisible=false;
    for (unsigned n=1;n<500;++n) {
        t.GPU_REQ_READY=!ioDue && n%5!=0;
        t.GPU_REPLY_VALID=ioDue && n>=ioDue;
        t.MEM_REQ_READY=!rdDue && !wrDue && n%7!=0;
        t.MEM_RESP_VALID=rdDue==n || wrDue==n;
        if (wrDue==n) { ram=(ram&~0xff00u)|0x4200; ramVisible=true; }
        t.MEM_RESP_DATA=ram;
        t.eval();
        t.BOOT9_WORD=fetch(rom,t.CPU9_BOOT_ADDR,0xffff0000); t.eval();
        if (rdDue==n) rdDue=0;
        if (wrDue==n) wrDue=0;
        if (t.IO9_GPU_REPLY_READY && t.GPU_REPLY_VALID) {
            ioVisible=true; ioDue=0; ram=(ram&~0xff00u)|0xbe00;
        }
        if (t.MEM_REQ_READY && t.MEM_REQ_VALID) {
            require(!t.MEM_ARM7 && !t.MEM_FETCH && t.MEM_REQ_ADDR==0x02000080,"unexpected drain RAM access");
            if (t.MEM_REQ_WRITE) {
                require(!ramWrites++ && t.MEM_REQ_LANES==2 && ((t.MEM_REQ_DATA>>8)&255)==0x42,"invalid drain store");
                wrDue=n+41;
            } else {
                require(!ramWrites || ramVisible,"load overtook pending RAM store");
                rdDue=n+4;
            }
        }
        if (t.IO9_GPU_REQ_VALID && t.GPU_REQ_READY) {
            require(drains==1 && !ioWrites++ && t.CPU9_REQ_WRITE && t.CPU9_REQ_ADDR==0x04000244 &&
                    t.CPU9_REQ_WIDTH==2 && t.CPU9_REQ_DATA==0x42,"invalid IO store after first drain");
            ioDue=n+29;
        }
        if (t.CPU9_RETIRE_VALID) {
            const uint32_t op=t.CPU9_RETIRE_OPCODE&0x0fff0fff;
            if (op==0x0e070f9a) {
                require(ramVisible && (drains==0 || (drains==1 && ioVisible)),"drain retired before prior write completed");
                ++drains;
            }
            if (op==0x0e070f16) { require(drains==2,"D invalidate overtook drain"); ++dinvs; }
        }
        if (t.CPU9_FAULT) {
            require(t.CPU9_FAULT==1 && t.CPU9_FAULT_ADDR==finished && drains==2 && dinvs==1 &&
                    ramWrites==1 && ioWrites==1,"drain / uncached data witness failed");
            std::puts("Drain: RAM write held 41 clocks, IO reply held 29; two ordered retirements, data reread after independent write.");
            return 0;
        }
        clock(t);
    }
    require(false,"drain did not finish"); return 1;
}
static int checkMpu(const char *file,uint32_t finished) {
    DUT t; resetProbe(t);
    const Rom rom=boot(file,nullptr);
    constexpr uint32_t revoke=0xee050f70, bad=0xe7f000f0;
    unsigned due=0, writes=0, roReads=0, revokes=0, prefetch=0, data=0;
    uint32_t ans=0, last=0;
    uint64_t line=0;
    for (unsigned n=1;n<=1600;++n) {
        t.MEM_REQ_READY=!due && n%5!=0;
        t.MEM_RESP_VALID=due==n;
        t.MEM_RESP_DATA=ans;
#ifdef FETCH_BUFFER
        t.MEM_RESP_LINE=line;
#endif
        t.eval(); t.BOOT9_WORD=fetch(rom,t.CPU9_BOOT_ADDR,0xffff0000); t.eval();
        require(!t.IO9_GPU_REQ_VALID && !t.CARD_ROM_REQ_VALID,"MPU denied IO was presented");
        if (due==n) due=0;
        if (t.CPU9_RETIRE_VALID) {
            last=t.CPU9_RETIRE_PC;
            if (last==0xffff000c) ++prefetch;
            if (last==0xffff0010) ++data;
            if (last==0x02000000) { require(t.CPU9_RETIRE_OPCODE==revoke,"wrong MPU RAM instruction"); ++revokes; }
            else require((last>>24)!=2,"instruction retired from revoked page");
        }
        if (t.MEM_REQ_VALID && t.MEM_REQ_READY) {
            const uint32_t a=t.MEM_REQ_ADDR;
            require(!t.MEM_ARM7,"unexpected ARM7 data request in MPU probe");
            if (t.MEM_FETCH) {
                require(a>=0x02000000 && a<0x02001000 && !revokes,"denied instruction reached memory");
                ans=a==0x02000000 ? revoke : bad;
                line=(uint64_t(bad)<<32) | ((a&~7u)==0x02000000?revoke:bad);
            } else if (a==0x02001000) {
                require(!t.MEM_REQ_WRITE && !roReads,"denied user read or RO store reached memory");
                ++roReads; ans=0x6b;
            } else {
                require(a==0x02000ffc,"unexpected MPU data request");
                if (t.MEM_REQ_WRITE) { require(t.MEM_REQ_LANES==15 && t.MEM_REQ_DATA==0x02001000,"wrong permitted STM beat"); ++writes; }
                ans=0;
            }
            due=n+3;
        }
        if (t.CPU9_FAULT) {
            if (t.CPU9_FAULT_ADDR!=finished)
                std::fprintf(stderr,"MPU terminal fault %u at %08x, preceding retirement %08x; vectors data/prefetch %u/%u\n",
                             unsigned(t.CPU9_FAULT),t.CPU9_FAULT_ADDR,last,data,prefetch);
            require(t.CPU9_FAULT==1 && t.CPU9_FAULT_ADDR==finished && writes==1 && roReads==1 &&
                    revokes==1 && prefetch==2 && data==5,"MPU exception witness failed");
            std::puts("MPU: five precise data aborts, two prefetch aborts; ARM/Thumb/user return, protected IO, overlapping regions and self-revoked execution.");
            return 0;
        }
        clock(t);
    }
    std::fprintf(stderr,"MPU stalled after %08x, vectors data/prefetch=%u/%u\n",last,data,prefetch);
    require(false,"MPU did not finish"); return 1;
}
int main(int argc, char **argv) {
    if (argc==4 && std::string(argv[1])=="mpu9")
        return checkMpu(argv[2],uint32_t(std::strtoul(argv[3],nullptr,0)));
    if (argc==4 && std::string(argv[1])=="drain9")
        return checkDrain(argv[2],uint32_t(std::strtoul(argv[3],nullptr,0)));
    if (argc==5 && std::string(argv[1])=="inv9")
        return controlFault(false,argv[2],1,uint32_t(std::strtoul(argv[3],nullptr,0)),std::atoi(argv[4]));
    if (argc==5 && (std::string(argv[1])=="fault7" || std::string(argv[1])=="fault9"))
        return controlFault(argv[1][5]=='7',argv[2],unsigned(std::strtoul(argv[3],nullptr,0)),uint32_t(std::strtoul(argv[4],nullptr,0)));
    require(argc == 7 || argc == 8, "usage: direct public|shared|kirby|kirby-vector image.nds stock9.bin stock7.bin entry9.bin entry7.bin [arm9.trace]");
    const bool shared=std::string(argv[1])=="shared", waitBios=std::string(argv[1])=="kirby";
    bool synthetic=shared || std::string(argv[1])=="public";
    require(synthetic || waitBios || std::string(argv[1])=="kirby-vector", "unknown probe mode");
    std::ifstream f(argv[2], std::ios::binary | std::ios::ate);
    auto size=f.tellg(); require(size >= 512, "short or missing cartridge");
    Header h; readAt(f,0,h.data(),h.size());
    Section a=section(h,0x20,size), b=section(h,0x30,size);
    for (auto s : {a,b}) std::printf("section: ROM %08x, RAM %08x..%08x, entry %08x\n",s.off,s.addr,s.addr+s.size,s.entry);
    uint16_t crc=uint16_t(h[0x15e] | h[0x15f]<<8);
    if (!shared) run(true,synthetic,boot(argv[3],&h),boot(argv[4],nullptr),Bytes(4096),crc,a,b,nullptr);
    run(false,synthetic,boot(argv[5],&h),boot(argv[6],&h),stage(f,h,a,b),crc,a,b,argc==8 ? argv[7] : nullptr,shared,waitBios);
}
