// SPDX-License-Identifier: GPL-3.0-or-later
// Verilator host for freshly generated nds_arm9_soc running the game-card
// fixture. Same contract as clash/test/Arm9CardCheck.hs: the image store
// refuses requests on every fifth cycle, answers the k-th accepted request
// 1 + (k mod 4) cycles later, and checks a refused request is held and stays
// inside the image; the timer clock ticks on odd cycles; the GPU link must
// stay silent. Mailbox slot k is RAM word k, words 0x30.. (to the 4 KiB
// RAM end) are scratch, no store after the mailbox; then quiet, or (--fault
// CODE ADDR [--after N]) exactly that fault after N mailbox words. --rom-log
// writes the accepted image addresses. Every instruction retired from RAM
// must be the word the guest last stored there; --no-ram-exec forbids such
// retirements, --trace FILE ("pc opcode" lines) fixes their sequence (the
// last entry then repeats), --load START SIZE requires that whole range to
// be stored before the first one.
#include "Vnds_arm9_soc.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <map>

static void check(bool ok, const char *message) {
    if (!ok) { std::fprintf(stderr, "ARM9 card RTL: %s\n", message); std::exit(1); }
}
static std::vector<uint32_t> words(const char *path) {
    std::ifstream f(path);
    check(bool(f), "cannot open input");
    std::vector<uint32_t> out;
    std::string line;
    while (std::getline(f, line)) {
        line = line.substr(0, line.find('#'));
        std::istringstream in(line);
        uint32_t word;
        if (in >> std::hex >> word) out.push_back(word);
    }
    check(!out.empty(), "empty input");
    return out;
}
static void clock(Vnds_arm9_soc &top) {
    top.CLK = 1; top.eval(); top.CLK = 0; top.eval();
}

int main(int argc, char **argv) {
    const char *usage = "usage: card ROM.hex EXPECTED CARD.hex raw|direct [--no-cart] [--rom-log FILE] "
                        "[--fault CODE ADDR [--after N]] [--trace FILE] [--load START SIZE] [--no-ram-exec]";
    check(argc >= 5, usage);
    const bool direct = std::strcmp(argv[4], "direct") == 0;
    check(direct || std::strcmp(argv[4], "raw") == 0, usage);
    bool noCart = false, wantFault = false;
    uint32_t wantCode = 0, wantAddr = 0;
    long after = -1;
    FILE *romLog = nullptr;
    bool noRamExec = false, haveLoad = false;
    uint32_t loadStart = 0, loadSize = 0;
    std::vector<std::pair<uint32_t, uint32_t>> trace;
    for (int k = 5; k < argc; ++k) {
        if (std::strcmp(argv[k], "--no-cart") == 0) noCart = true;
        else if (std::strcmp(argv[k], "--rom-log") == 0 && k + 1 < argc) {
            romLog = std::fopen(argv[++k], "w");
            check(romLog != nullptr, "cannot open ROM log");
        } else if (std::strcmp(argv[k], "--fault") == 0 && k + 2 < argc) {
            wantFault = true;
            wantCode = std::strtoul(argv[++k], nullptr, 16);
            wantAddr = std::strtoul(argv[++k], nullptr, 16);
        } else if (std::strcmp(argv[k], "--after") == 0 && k + 1 < argc) {
            after = std::strtol(argv[++k], nullptr, 10);
        } else if (std::strcmp(argv[k], "--no-ram-exec") == 0) {
            noRamExec = true;
        } else if (std::strcmp(argv[k], "--load") == 0 && k + 2 < argc) {
            haveLoad = true;
            loadStart = std::strtoul(argv[++k], nullptr, 16);
            loadSize = std::strtoul(argv[++k], nullptr, 16);
        } else if (std::strcmp(argv[k], "--trace") == 0 && k + 1 < argc) {
            std::ifstream f(argv[++k]);
            check(bool(f), "cannot open trace");
            uint32_t pc, op;
            while (f >> std::hex >> pc >> op) trace.emplace_back(pc, op);
            check(!trace.empty(), "empty trace");
        } else check(false, usage);
    }
    const auto rom = words(argv[1]), expected = words(argv[2]), image = words(argv[3]);
    const uint32_t imageMask = uint32_t(4 * image.size() - 1);
    const size_t stopAt = after >= 0 ? size_t(after) : expected.size();
    const size_t scratch = 0x30;
    Verilated::commandArgs(argc, argv);
    Vnds_arm9_soc top;
    top.CLK = 0; top.RST = 1; top.EN = 1; top.BOOT_WORD = 0;
    top.GPU_REQ_READY = top.GPU_REPLY_VALID = top.GPU_REPLY_FAULT = 0;
    top.GPU_REPLY_DATA = top.TIMER_TICK = top.EXT_IRQ_SET = top.EXT_IRQ_CLEAR = 0;
    top.CARD_INSERTED = !noCart; top.CARD_DIRECT_BOOT = direct;
    top.CARD_CHIP_ID = 0x00001fc2; top.CARD_ROM_MASK = imageMask;
    top.CARD_ROM_READY = top.CARD_ROM_REPLY_VALID = 0; top.CARD_ROM_DATA = 0;
    top.eval(); clock(top); clock(top); top.RST = 0; top.eval();
    size_t stores = 0;
    long doneAt = -1, replyAt = -1;
    bool held = false, inFlight = false;
    uint32_t heldAddr = 0, replyData = 0;
    unsigned served = 0;
    std::map<uint32_t, uint32_t> shadow;   // RAM words as the guest stored them
    size_t ramRetired = 0;
    for (long tick = 0; tick < 2000000; ++tick) {
        top.TIMER_TICK = tick & 1;
        const bool ready = tick % 5 != 2 && !inFlight;
        const bool reply = inFlight && tick >= replyAt;
        top.CARD_ROM_READY = ready;
        top.CARD_ROM_REPLY_VALID = reply;
        top.CARD_ROM_DATA = reply ? replyData : 0;
        top.eval();
        const uint32_t addr = top.CPU_BOOT_ADDR;
        const uint32_t idx = (addr - 0xffff0000u) / 4;
        top.BOOT_WORD = addr >= 0xffff0000u && idx < rom.size() ? rom[idx] : 0xe7f000f0u;
        top.eval();
        check(!top.IO_GPU_REQ_VALID, "unexpected GPU request");
        const bool want = top.CARD_ROM_REQ_VALID;
        const uint32_t reqAddr = top.CARD_ROM_ADDR;
        if (held) check(want && reqAddr == heldAddr, "refused image request changed or dropped");
        if (want) check((reqAddr & 3) == 0 && reqAddr <= imageMask && !inFlight,
                        "image request outside the image, unaligned or overlapping");
        const uint32_t rpc = top.CPU_RETIRE_PC, rop = top.CPU_RETIRE_OPCODE;
        if (top.CPU_RETIRE_VALID && (rpc & 0xfffff000u) == 0x02000000u) {
            check(!noRamExec, "instruction retired from RAM");
            const auto it = shadow.find(rpc);
            if (it == shadow.end() || it->second != rop) {
                std::fprintf(stderr, "RAM instruction %08x at %08x is not the word the guest stored\n", rop, rpc);
                return 1;
            }
            if (ramRetired == 0 && haveLoad)
                for (uint32_t a = loadStart; a < loadStart + loadSize; a += 4)
                    check(shadow.count(a) == 1, "executed from RAM before the load was stored");
            if (!trace.empty()) {
                const auto &t = ramRetired < trace.size() ? trace[ramRetired] : trace.back();
                if (t.first != rpc || t.second != rop) {
                    std::fprintf(stderr, "RAM retirement %zu: %08x %08x, expected %08x %08x\n",
                                 ramRetired, rpc, rop, t.first, t.second);
                    return 1;
                }
            }
            ++ramRetired;
        }
        if (top.CPU_STORE_VALID) {
            check(stores < stopAt, "store after the mailbox");
            const size_t word = (top.CPU_STORE_ADDR - 0x02000000u) / 4;
            shadow[top.CPU_STORE_ADDR] = top.CPU_STORE_DATA;
            if (!(word >= scratch && word < 1024)) {
                check(top.CPU_STORE_ADDR == 0x02000000u + 4 * stores, "store out of slot order");
                std::printf("ARM9 RAM[%zu]=%08x\n", 4 * stores, unsigned(top.CPU_STORE_DATA));
                if (top.CPU_STORE_DATA != expected[stores]) {
                    std::fprintf(stderr, "slot %zu: got %08x, expected %08x\n", stores,
                                 unsigned(top.CPU_STORE_DATA), unsigned(expected[stores]));
                    return 1;
                }
                if (++stores == stopAt) doneAt = tick;
            }
        }
        const bool accepted = want && ready;
        if (accepted && romLog) std::fprintf(romLog, "%08x\n", reqAddr);
        held = want && !ready;
        heldAddr = reqAddr;
        if (accepted) {
            inFlight = true;
            replyAt = tick + 1 + served % 4;
            replyData = image[reqAddr >> 2];
            ++served;
        } else if (reply) {
            inFlight = false;
        }
        if (top.CPU_FAULT) {
            std::printf("fault %u at %08x\n", unsigned(top.CPU_FAULT), unsigned(top.CPU_FAULT_ADDR));
            check(wantFault && top.CPU_FAULT == wantCode && top.CPU_FAULT_ADDR == wantAddr && stores == stopAt,
                  "unexpected fault");
            std::puts("PASS: generated Arm9Soc faulted as expected");
            if (romLog) std::fclose(romLog);
            return 0;
        }
        if (doneAt >= 0 && tick - doneAt >= 500) {
            check(!wantFault, "expected fault did not occur");
            check(!top.CARD_BUSY, "card still busy");
            check(ramRetired >= trace.size(), "fewer RAM retirements than the trace");
            std::printf("PASS: generated Arm9Soc %zu mailbox stores, %u image words served, "
                        "%zu instructions retired from RAM\n", stores, served, ramRetired);
            if (romLog) std::fclose(romLog);
            return 0;
        }
        clock(top);
    }
    check(false, "timeout");
}
