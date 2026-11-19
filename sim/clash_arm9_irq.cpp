// SPDX-License-Identifier: GPL-3.0-or-later
// Verilator host for freshly generated nds_arm9_soc running an IRQ fixture.
// Same contract, options and external sources as clash/test/Arm9IrqCheck.hs:
//   * timer clock on odd cycles;
//   * --link-read: the only allowed link request, a word read of
//     0x06000000, is held 8 cycles and answered 4 cycles after acceptance
//     with 13579bdf; IF bit 0 is raised in the cycle it is first offered;
//   * --store-irq ADDR MASK: IF |= MASK when the CPU first reports a store
//     to ADDR;
//   * --retire-irq PC MASK: IF |= MASK when the CPU first retires PC.
// Every enabled source must fire. Mailbox slot k is RAM word k; words
// 0x30..0x3f are scratch; no store after the mailbox; then quiet, or
// (--fault CODE ADDR) exactly that fault.
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

static void check(bool ok, const char *message) {
    if (!ok) { std::fprintf(stderr, "ARM9 IRQ RTL: %s\n", message); std::exit(1); }
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
    const char *usage = "usage: irq ROM.hex EXPECTED [--link-read] [--store-irq ADDR MASK]"
                        " [--retire-irq PC MASK] [--fault CODE ADDR]";
    check(argc >= 3, usage);
    bool linkRead = false, storeIrq = false, retireIrq = false, wantFault = false;
    uint32_t storeAddr = 0, storeMask = 0, retirePc = 0, retireMask = 0, wantCode = 0, wantAddr = 0;
    for (int a = 3; a < argc; ++a) {
        const auto hex = [&](int k) { check(a + k < argc, usage); return uint32_t(std::strtoul(argv[a + k], nullptr, 16)); };
        if (std::strcmp(argv[a], "--link-read") == 0) {
            linkRead = true;
        } else if (std::strcmp(argv[a], "--store-irq") == 0) {
            storeIrq = true; storeAddr = hex(1); storeMask = hex(2); a += 2;
        } else if (std::strcmp(argv[a], "--retire-irq") == 0) {
            retireIrq = true; retirePc = hex(1); retireMask = hex(2); a += 2;
        } else if (std::strcmp(argv[a], "--fault") == 0) {
            wantFault = true; wantCode = hex(1); wantAddr = hex(2); a += 2;
        } else {
            check(false, usage);
        }
    }
    const auto rom = words(argv[1]), expected = words(argv[2]);
    const size_t scratch = 0x30;
    Verilated::commandArgs(argc, argv);
    Vnds_arm9_soc top;
    top.CLK = 0; top.RST = 1; top.EN = 1; top.BOOT_WORD = 0;
    top.GPU_REQ_READY = top.GPU_REPLY_VALID = top.GPU_REPLY_FAULT = 0;
    top.GPU_REPLY_DATA = top.TIMER_TICK = top.EXT_IRQ_SET = top.EXT_IRQ_CLEAR = 0;
    top.eval(); clock(top); clock(top); top.RST = 0; top.eval();
    size_t stores = 0;
    long seenAt = -1, acceptedAt = -1, doneAt = -1;
    bool replied = false, storeFired = false, retireFired = false;
    const auto sourcesFired = [&] {
        check(!linkRead || replied, "link read source not exercised");
        check(!storeIrq || storeFired, "store IRQ source not exercised");
        check(!retireIrq || retireFired, "retire IRQ source not exercised");
    };
    for (long tick = 0; tick < 400000; ++tick) {
        top.TIMER_TICK = tick & 1;
        top.GPU_REQ_READY = top.GPU_REPLY_VALID = 0;
        top.GPU_REPLY_DATA = 0x13579bdf;
        top.EXT_IRQ_SET = 0;
        top.eval();
        const uint32_t addr = top.CPU_BOOT_ADDR;
        const uint32_t idx = (addr - 0xffff0000u) / 4;
        top.BOOT_WORD = addr >= 0xffff0000u && idx < rom.size() ? rom[idx] : 0xe7f000f0u;
        top.eval();
        // The device reacts only to registered state.
        const bool offered = top.IO_GPU_REQ_VALID;
        const bool firstOffer = linkRead && offered && seenAt < 0;
        const long seen = seenAt < 0 ? tick : seenAt;
        const bool ready = linkRead && offered && acceptedAt < 0 && tick - seen >= 8;
        const bool replyValid = acceptedAt >= 0 && tick - acceptedAt >= 4 && !replied;
        const bool storeHit = storeIrq && !storeFired && top.CPU_STORE_VALID && top.CPU_STORE_ADDR == storeAddr;
        const bool retireHit = retireIrq && !retireFired && top.CPU_RETIRE_VALID && top.CPU_RETIRE_PC == retirePc;
        top.GPU_REQ_READY = ready;
        top.GPU_REPLY_VALID = replyValid;
        top.EXT_IRQ_SET = (firstOffer ? 1u : 0u) | (storeHit ? storeMask : 0u) | (retireHit ? retireMask : 0u);
        top.eval();
        if (offered)
            check(linkRead && !top.CPU_REQ_WRITE && top.CPU_REQ_WIDTH == 4 && top.CPU_REQ_ADDR == 0x06000000u &&
                  !replied, "unexpected link request");
        check(bool(top.IO_IRQ) == (top.IO_IME && (top.IO_IE & top.IO_IF)), "IRQ level differs from IME && IE & IF");
        if (top.CPU_STORE_VALID) {
            check(stores < expected.size(), "store after the mailbox");
            const size_t word = (top.CPU_STORE_ADDR - 0x02000000u) / 4;
            if (!(word >= scratch && word < 64)) {
                check(top.CPU_STORE_ADDR == 0x02000000u + 4 * stores, "store out of slot order");
                std::printf("ARM9 RAM[%zu]=%08x\n", 4 * stores, unsigned(top.CPU_STORE_DATA));
                if (top.CPU_STORE_DATA != expected[stores]) {
                    std::fprintf(stderr, "slot %zu: got %08x, expected %08x\n", stores,
                                 unsigned(top.CPU_STORE_DATA), unsigned(expected[stores]));
                    return 1;
                }
                if (++stores == expected.size()) doneAt = tick;
            }
        }
        if (firstOffer) seenAt = tick;
        if (ready) acceptedAt = tick;
        if (replyValid && top.IO_GPU_REPLY_READY) replied = true;
        storeFired |= storeHit;
        retireFired |= retireHit;
        if (top.CPU_FAULT) {
            std::printf("fault %u at %08x\n", unsigned(top.CPU_FAULT), unsigned(top.CPU_FAULT_ADDR));
            check(wantFault && top.CPU_FAULT == wantCode && top.CPU_FAULT_ADDR == wantAddr &&
                  stores == expected.size(), "unexpected fault");
            sourcesFired();
            std::puts("PASS: generated Arm9Soc faulted as expected");
            return 0;
        }
        if (doneAt >= 0 && tick - doneAt >= 500) {
            check(!wantFault, "expected fault did not occur");
            sourcesFired();
            std::printf("PASS: generated Arm9Soc %zu mailbox stores, IRQ fixture\n", stores);
            return 0;
        }
        clock(top);
    }
    check(false, "timeout");
}
