// SPDX-License-Identifier: GPL-3.0-or-later
// Verilator host for freshly generated nds_arm9_soc running an IRQ fixture.
// Same contract, options and external sources as clash/test/Arm9IrqCheck.hs:
//   * timer clock on odd cycles;
//   * --link-read: the only allowed link request, a word read of
//     0x06000000, is held 8 cycles and answered 4 cycles after acceptance
//     with 13579bdf; IF bit 0 is raised in the cycle it is first offered;
//   * --store-irq ADDR MASK: IF |= MASK when the CPU first reports a store
//     to ADDR;
//   * --irq-before PC MASK: IF |= MASK so that the IRQ line is first high in
//     the first cycle in which the instruction at PC (first execution) is
//     the oldest uncommitted one. A probe run without this source finds the
//     cycle P in which the retire just before PC is reported (retire is
//     reported the cycle after commit, in order, so PC is uncommitted at P);
//     IF is a register, so the real run raises it in cycle P-1, then
//     requires that retire again at P and the IRQ vector (0xffff0018) as
//     the very next retire.
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
#include <memory>
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

struct Opts {
    bool linkRead = false, storeIrq = false, beforeIrq = false, wantFault = false;
    uint32_t storeAddr = 0, storeMask = 0, beforePc = 0, beforeMask = 0, wantCode = 0, wantAddr = 0;
};
// --irq-before placement from the probe run.
struct Trigger {
    long at = -1, predAt = -1;
    uint32_t predPc = 0;
};
static const uint32_t irqVector = 0xffff0018u;

// One run from reset. probe: silent, no --irq-before source; returns true
// with *found set to the retire reported just before the first retire of
// opts.beforePc. Otherwise runs the fixture to its verdict (exit on failure).
static bool run(const Opts &o, const std::vector<uint32_t> &rom, const std::vector<uint32_t> &expected,
                bool probe, const Trigger &trigger, Trigger *found) {
    const size_t scratch = 0x30;
    std::unique_ptr<Vnds_arm9_soc> owner(new Vnds_arm9_soc);
    Vnds_arm9_soc &top = *owner;
    top.CLK = 0; top.RST = 1; top.EN = 1; top.BOOT_WORD = 0;
    top.GPU_REQ_READY = top.GPU_REPLY_VALID = top.GPU_REPLY_FAULT = 0;
    top.GPU_REPLY_DATA = top.TIMER_TICK = top.EXT_IRQ_SET = top.EXT_IRQ_CLEAR = 0;
    top.eval(); clock(top); clock(top); top.RST = 0; top.eval();
    size_t stores = 0;
    long seenAt = -1, acceptedAt = -1, doneAt = -1, lastRetireAt = -1;
    uint32_t lastRetirePc = 0;
    bool replied = false, storeFired = false, beforeFired = false;
    const auto sourcesFired = [&] {
        check(!o.linkRead || replied, "link read source not exercised");
        check(!o.storeIrq || storeFired, "store IRQ source not exercised");
        check(!o.beforeIrq || beforeFired, "--irq-before source not exercised");
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
        const bool firstOffer = o.linkRead && offered && seenAt < 0;
        const long seen = seenAt < 0 ? tick : seenAt;
        const bool ready = o.linkRead && offered && acceptedAt < 0 && tick - seen >= 8;
        const bool replyValid = acceptedAt >= 0 && tick - acceptedAt >= 4 && !replied;
        const bool storeHit = o.storeIrq && !storeFired && top.CPU_STORE_VALID && top.CPU_STORE_ADDR == o.storeAddr;
        const bool beforeHit = !probe && trigger.at == tick;
        top.GPU_REQ_READY = ready;
        top.GPU_REPLY_VALID = replyValid;
        top.EXT_IRQ_SET = (firstOffer ? 1u : 0u) | (storeHit ? o.storeMask : 0u) | (beforeHit ? o.beforeMask : 0u);
        top.eval();
        const bool retired = top.CPU_RETIRE_VALID;
        const uint32_t retiredPc = top.CPU_RETIRE_PC;
        if (probe && retired && retiredPc == o.beforePc) {
            check(lastRetireAt >= 1, "--irq-before: no instruction retired before it");
            found->at = lastRetireAt - 1; found->predAt = lastRetireAt; found->predPc = lastRetirePc;
            return true;
        }
        if (!probe && o.beforeIrq) {
            if (tick == trigger.predAt)
                check(retired && retiredPc == trigger.predPc, "run diverged from the --irq-before probe");
            else if (retired && !beforeFired && lastRetireAt == trigger.predAt) {
                if (retiredPc != irqVector) {
                    std::fprintf(stderr, "ARM9 IRQ RTL: IRQ not taken just before the --irq-before instruction:"
                                 " %08x retired after %08x\n", unsigned(retiredPc), unsigned(trigger.predPc));
                    std::exit(1);
                }
                beforeFired = true;
            }
        }
        if (retired) { lastRetireAt = tick; lastRetirePc = retiredPc; }
        if (offered)
            check(o.linkRead && !top.CPU_REQ_WRITE && top.CPU_REQ_WIDTH == 4 && top.CPU_REQ_ADDR == 0x06000000u &&
                  !replied, "unexpected link request");
        check(bool(top.IO_IRQ) == (top.IO_IME && (top.IO_IE & top.IO_IF)), "IRQ level differs from IME && IE & IF");
        if (top.CPU_STORE_VALID) {
            check(stores < expected.size(), "store after the mailbox");
            const size_t word = (top.CPU_STORE_ADDR - 0x02000000u) / 4;
            if (!(word >= scratch && word < 64)) {
                check(top.CPU_STORE_ADDR == 0x02000000u + 4 * stores, "store out of slot order");
                if (!probe) std::printf("ARM9 RAM[%zu]=%08x\n", 4 * stores, unsigned(top.CPU_STORE_DATA));
                if (top.CPU_STORE_DATA != expected[stores]) {
                    std::fprintf(stderr, "slot %zu: got %08x, expected %08x\n", stores,
                                 unsigned(top.CPU_STORE_DATA), unsigned(expected[stores]));
                    std::exit(1);
                }
                if (++stores == expected.size()) doneAt = tick;
            }
        }
        if (firstOffer) seenAt = tick;
        if (ready) acceptedAt = tick;
        if (replyValid && top.IO_GPU_REPLY_READY) replied = true;
        storeFired |= storeHit;
        if (top.CPU_FAULT) {
            if (probe) return false;
            std::printf("fault %u at %08x\n", unsigned(top.CPU_FAULT), unsigned(top.CPU_FAULT_ADDR));
            check(o.wantFault && top.CPU_FAULT == o.wantCode && top.CPU_FAULT_ADDR == o.wantAddr &&
                  stores == expected.size(), "unexpected fault");
            sourcesFired();
            std::puts("PASS: generated Arm9Soc faulted as expected");
            return true;
        }
        if (doneAt >= 0 && tick - doneAt >= 500) {
            if (probe) return false;
            check(!o.wantFault, "expected fault did not occur");
            sourcesFired();
            std::printf("PASS: generated Arm9Soc %zu mailbox stores, IRQ fixture\n", stores);
            return true;
        }
        clock(top);
    }
    check(false, "timeout");
    return false;
}

int main(int argc, char **argv) {
    const char *usage = "usage: irq ROM.hex EXPECTED [--link-read] [--store-irq ADDR MASK]"
                        " [--irq-before PC MASK] [--fault CODE ADDR]";
    check(argc >= 3, usage);
    Opts o;
    for (int a = 3; a < argc; ++a) {
        const auto hex = [&](int k) { check(a + k < argc, usage); return uint32_t(std::strtoul(argv[a + k], nullptr, 16)); };
        if (std::strcmp(argv[a], "--link-read") == 0) {
            o.linkRead = true;
        } else if (std::strcmp(argv[a], "--store-irq") == 0) {
            o.storeIrq = true; o.storeAddr = hex(1); o.storeMask = hex(2); a += 2;
        } else if (std::strcmp(argv[a], "--irq-before") == 0) {
            o.beforeIrq = true; o.beforePc = hex(1); o.beforeMask = hex(2); a += 2;
        } else if (std::strcmp(argv[a], "--fault") == 0) {
            o.wantFault = true; o.wantCode = hex(1); o.wantAddr = hex(2); a += 2;
        } else {
            check(false, usage);
        }
    }
    const auto rom = words(argv[1]), expected = words(argv[2]);
    Verilated::commandArgs(argc, argv);
    Trigger trigger;
    if (o.beforeIrq)
        check(run(o, rom, expected, true, trigger, &trigger), "--irq-before instruction never retired");
    run(o, rom, expected, false, trigger, nullptr);
    return 0;
}
