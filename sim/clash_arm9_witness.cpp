// SPDX-License-Identifier: GPL-3.0-or-later
// Verilator host for the freshly generated Clash ARM9 slice, using ABI2.
#include "Vnds_arm9_slice.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

extern "C" void arm9_gpu_start(void);
extern "C" int32_t arm9_gpu_transfer(int32_t, int32_t, int32_t, int32_t, int32_t);
extern "C" void arm9_gpu_reset(void);
extern "C" void arm9_gpu_stop(void);

static void require(bool ok, const char *message) {
    if (!ok) { std::fprintf(stderr, "Clash RTL witness: %s\n", message); std::exit(1); }
}
static void clock(Vnds_arm9_slice &top) {
    top.CLK = 1; top.eval(); top.CLK = 0; top.eval();
}
int main(int argc, char **argv) {
    require(argc == 2 || argc == 3, "usage: witness ROM.hex [--unsupported|--reset-offer|--reset-write|--reset-read]");
    const std::string mode = argc == 3 ? argv[2] : "";
    const bool negative = mode == "--unsupported";
    const bool resetOffer = mode == "--reset-offer";
    const bool resetWrite = mode == "--reset-write";
    const bool resetRead = mode == "--reset-read";
    require(mode.empty() || negative || resetOffer || resetWrite || resetRead, "unknown mode");
    std::ifstream image(argv[1]);
    require(bool(image), "cannot open ROM");
    std::vector<uint32_t> rom;
    uint32_t value;
    while (image >> std::hex >> value) rom.push_back(value);
    require(image.eof() && !rom.empty(), "invalid ROM");
    Verilated::commandArgs(argc, argv);
    Vnds_arm9_slice top;
    top.CLK = 0; top.RST = 1; top.EN = 1; top.BOOT_WORD = 0;
    top.GPU_REQ_READY = 0; top.GPU_REPLY_VALID = 0;
    top.GPU_REPLY_DATA = 0; top.GPU_REPLY_FAULT = 0; top.IRQ = 0;
    top.eval(); clock(top); clock(top); top.RST = 0; top.eval();
    arm9_gpu_start();
    bool pending = false, pendingWrite = false, resetDone = false;
    uint32_t reply = 0, requestPc = 0, requestOpcode = 0, lastRetirePc = 0;
    unsigned stores = 0, requests = 0, offerCycles = 0, replyCycles = 0;
    bool held = false, awaitingRetire = false, sawRetire = false;
    uint32_t held_addr = 0, held_data = 0;
    unsigned held_width = 0, held_lanes = 0, held_write = 0;
    for (int tick = 0; tick < 10000; ++tick) {
        // Every request sees a long offer stall and every reply is delayed.
        top.GPU_REQ_READY = !pending && offerCycles >= 5;
        top.GPU_REPLY_VALID = pending && replyCycles >= 7;
        top.GPU_REPLY_DATA = reply;
        top.eval();
        uint32_t addr = top.BOOT_ADDR;
        uint32_t index = (addr - 0xffff0000u) / 4;
        top.BOOT_WORD = addr >= 0xffff0000u && !(addr & 3) && index < rom.size() ? rom[index] : 0xe7f000f0u;
        top.eval();
        require(top.BOOT_ADDR == addr, "boot address depends on boot word");
        if (top.GPU_REQ_VALID || pending) {
            require(!top.RETIRE_VALID && !top.STORE_VALID, "instruction retired before GPU reply");
        }
        if (awaitingRetire) {
            require(top.RETIRE_VALID && top.RETIRE_PC == requestPc &&
                    top.RETIRE_OPCODE == requestOpcode,
                    "GPU instruction did not retire exactly once after its reply");
            awaitingRetire = false;
        }
        if (top.RETIRE_VALID) {
            lastRetirePc = top.RETIRE_PC;
            sawRetire = true;
        }
        if (held)
            require(top.GPU_REQ_VALID && top.GPU_REQ_ADDR == held_addr && top.GPU_REQ_DATA == held_data &&
                    top.GPU_REQ_WIDTH == held_width && top.GPU_REQ_LANES == held_lanes &&
                    top.GPU_REQ_WRITE == held_write, "request changed while backpressured");
        held = top.GPU_REQ_VALID && !top.GPU_REQ_READY;
        if (held) {
            held_addr = top.GPU_REQ_ADDR; held_data = top.GPU_REQ_DATA;
            held_width = top.GPU_REQ_WIDTH; held_lanes = top.GPU_REQ_LANES; held_write = top.GPU_REQ_WRITE;
        }
        if (top.GPU_REQ_VALID && offerCycles == 0) {
            // This assembled witness is straight-line until its terminal
            // branch. BOOT_ADDR may be a speculative fetch, not this PC.
            require(sawRetire, "GPU request before preceding instruction retired");
            requestPc = lastRetirePc + 4;
            require(requestPc >= 0xffff0000u && !(requestPc & 3) &&
                    (requestPc - 0xffff0000u) / 4 < rom.size(), "invalid request PC");
            requestOpcode = rom[(requestPc - 0xffff0000u) / 4];
        }
        // The adapter and CPU are reset together. Never re-present the old
        // reply: this interface has no transaction epoch or stale-reply filter.
        if (!resetDone && ((resetOffer && held && offerCycles == 3) ||
                           ((resetWrite || resetRead) && pending && replyCycles == 3 &&
                            pendingWrite == resetWrite))) {
            top.RST = 1;
            top.GPU_REQ_READY = 0;
            top.GPU_REPLY_VALID = 0;
            top.eval();
            require(!top.GPU_REQ_VALID && !top.GPU_REPLY_READY &&
                    !top.RETIRE_VALID && !top.STORE_VALID, "outputs active during reset");
            clock(top); clock(top);
            arm9_gpu_reset();
            pending = held = awaitingRetire = sawRetire = false;
            offerCycles = replyCycles = stores = requests = 0;
            top.RST = 0;
            top.eval();
            require(top.BOOT_ADDR == 0xffff0000u && !top.GPU_REQ_VALID &&
                    !top.GPU_REPLY_READY && !top.RETIRE_VALID && !top.STORE_VALID,
                    "link or CPU did not reset");
            resetDone = true;
            std::puts("ARM9 RESET COMPLETE");
            continue;
        }
        if (top.FAULT) {
            require(negative && top.FAULT == 3 && top.FAULT_ADDR == 0x04000247u && requests == 2 && stores == 1 && !top.GPU_REQ_VALID,
                    "unexpected CPU fault");
            arm9_gpu_stop();
            std::puts("PASS: generated RTL rejects unsupported WRAMCNT");
            return 0;
        }
        if (top.STORE_VALID) {
            require(stores < 6 && top.STORE_ADDR == 0x02000000u + stores * 4, "unexpected mailbox store");
            std::printf("ARM9 RAM[%u]=%08x\n", stores * 4, unsigned(top.STORE_DATA));
            ++stores;
        }
        bool consume = pending && top.GPU_REPLY_VALID && top.GPU_REPLY_READY;
        bool accept = top.GPU_REQ_VALID && top.GPU_REQ_READY;
        bool stallOffer = top.GPU_REQ_VALID && !top.GPU_REQ_READY;
        uint32_t nextReply = 0;
        if (accept) {
            unsigned width = top.GPU_REQ_WIDTH, a = top.GPU_REQ_ADDR;
            require(!pending && (width == 1 || width == 2 || width == 4) && !(a & (width-1)), "bad GPU width/alignment or overlapping request");
            require(offerCycles >= 5, "request was not backpressured");
            require(top.GPU_REQ_LANES == ((1u << width)-1u) << (a & 3), "bad GPU lanes");
            nextReply = uint32_t(arm9_gpu_transfer(tick/2, int32_t(a), int32_t(width), top.GPU_REQ_WRITE, int32_t(top.GPU_REQ_DATA)));
            ++requests;
            pendingWrite = top.GPU_REQ_WRITE;
        }
        clock(top);
        if (stallOffer) ++offerCycles;
        if (pending && !consume) ++replyCycles;
        if (consume) {
            require(replyCycles >= 7, "reply was not delayed");
            pending = false;
            replyCycles = 0;
            awaitingRetire = true;
        }
        if (accept) { pending = true; reply = nextReply; offerCycles = 0; }
        if (stores == 6) {
            require(!negative && requests == 10 && !pending && !awaitingRetire &&
                    (mode.empty() || resetDone), "incomplete witness");
            arm9_gpu_stop();
            std::puts("PASS: generated Clash RTL completed witness");
            return 0;
        }
    }
    require(false, "timeout");
}
