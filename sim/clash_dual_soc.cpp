// SPDX-License-Identifier: GPL-3.0-or-later
// Verilator host for freshly generated nds_dual_soc (Nds.WholeCore.DualSoc):
// same contract and options as clash/test/DualSocCheck.hs.
//
//   dual BOOT9.hex BOOT7.hex CARD.hex EXPECT9 EXPECT7
//        [--seed N] [--latency MIN MAX] [--stall PCT] [--card-stall PCT]
//
// Boot ROMs served from BOOT_ADDR; card image behind its port with random
// delays (direct-boot strap, chip ID 0x1FC2); 4 KiB main RAM behind the
// memory port, accepted with probability 1 - stall/100, applied in
// acceptance order, answered in order MIN..MAX cycles later. Checks: no
// fault, no external link request, per-CPU mailboxes in slot order, no
// store into the other CPU's mailbox, the memory request held while not
// accepted and inside the RAM window, and bounded wait (at most one grant
// to the other core while a core waits).
#include "Vnds_dual_soc.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

static void check(bool ok, const char *message) {
    if (!ok) { std::fprintf(stderr, "dual RTL: %s\n", message); std::exit(1); }
}
static std::vector<uint32_t> words(const char *path) {
    std::ifstream f(path);
    check(bool(f), "cannot open input");
    std::vector<uint32_t> out;
    std::string line;
    while (std::getline(f, line)) {
        line = line.substr(0, line.find('#'));
        std::istringstream in(line);
        uint32_t w;
        if (in >> std::hex >> w) out.push_back(w);
    }
    return out;
}
static uint64_t rngState;
static uint64_t next64() {
    uint64_t z = (rngState += 0x9e3779b97f4a7c15ull);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return z ^ (z >> 31);
}
static int below(int n) { return int(next64() % uint64_t(n < 1 ? 1 : n)); }
static void clock(Vnds_dual_soc &top) { top.CLK = 1; top.eval(); top.CLK = 0; top.eval(); }

int main(int argc, char **argv) {
    const char *usage = "usage: dual BOOT9 BOOT7 CARD EXPECT9 EXPECT7 [--seed N] [--latency MIN MAX] [--stall PCT] [--card-stall PCT]";
    check(argc >= 6, usage);
    int latMin = 1, latMax = 1, stall = 0, cardStall = 0;
    rngState = 1;
    for (int a = 6; a < argc; ++a) {
        if (!std::strcmp(argv[a], "--seed") && a + 1 < argc) rngState = std::strtoull(argv[++a], nullptr, 10);
        else if (!std::strcmp(argv[a], "--latency") && a + 2 < argc) { latMin = std::atoi(argv[++a]); latMax = std::atoi(argv[++a]); }
        else if (!std::strcmp(argv[a], "--stall") && a + 1 < argc) stall = std::atoi(argv[++a]);
        else if (!std::strcmp(argv[a], "--card-stall") && a + 1 < argc) cardStall = std::atoi(argv[++a]);
        else check(false, usage);
    }
    const auto boot9 = words(argv[1]), boot7 = words(argv[2]), image = words(argv[3]);
    const auto exp9 = words(argv[4]), exp7 = words(argv[5]);
    Verilated::commandArgs(argc, argv);
    Vnds_dual_soc top;
    top.CLK = 0; top.RST = 1; top.EN = 1;
    top.BOOT9_WORD = top.BOOT7_WORD = 0;
    top.GPU_REQ_READY = top.GPU_REPLY_VALID = top.GPU_REPLY_FAULT = 0; top.GPU_REPLY_DATA = 0;
    top.EXT_IRQ_SET = 0;
    top.CARD_INSERTED = 1; top.CARD_DIRECT_BOOT = 1; top.CARD_CHIP_ID = 0x1fc2; top.CARD_ROM_MASK = 0xffff;
    top.CARD_ROM_READY = top.CARD_ROM_REPLY_VALID = 0; top.CARD_ROM_DATA = 0;
    top.MEM_REQ_READY = 0; top.MEM_RESP_VALID = 0; top.MEM_RESP_DATA = 0;
    top.eval(); clock(top); clock(top); top.RST = 0; top.eval();

    std::vector<uint32_t> ram(1024, 0);
    std::deque<std::pair<long, uint32_t>> resps;
    long lastDue = 0;
    bool held = false;
    uint32_t hValid = 0, hWrite = 0, hAddr = 0, hLanes = 0, hData = 0;
    bool cardBusy = false;
    long cardDue = 0;
    uint32_t cardAddr = 0;
    size_t s9 = 0, s7 = 0;
    long doneAt = -1;
    int wait9 = -1, wait7 = -1, maxWait = 0;
    long steps9 = 0, steps7 = 0, acceptedN = 0, staleMerges = 0;
    for (long t = 0; t < 3000000; ++t) {
        const bool memReady = below(100) >= stall;
        const bool cardReady = below(100) >= cardStall && !cardBusy;
        const int lat = latMin + below(latMax - latMin + 1);
        const int cardLat = below(4);
        const bool respNow = !resps.empty() && resps.front().first <= t;
        const bool cardReply = cardBusy && cardDue <= t;
        top.MEM_REQ_READY = memReady;
        top.MEM_RESP_VALID = respNow;
        top.MEM_RESP_DATA = respNow ? resps.front().second : 0;
        top.CARD_ROM_READY = cardReady;
        top.CARD_ROM_REPLY_VALID = cardReply;
        top.CARD_ROM_DATA = cardReply ? image[(cardAddr >> 2) % image.size()] : 0;
        top.eval();
        const uint32_t a9 = top.CPU9_BOOT_ADDR, a7 = top.CPU7_BOOT_ADDR;
        top.BOOT9_WORD = (a9 >= 0xffff0000u && a9 - 0xffff0000u < 0x1000) ? boot9[(a9 - 0xffff0000u) >> 2] : 0xe7f000f0u;
        top.BOOT7_WORD = (a7 < 0x1000) ? boot7[a7 >> 2] : 0xe7f000f0u;
        top.eval();
        char msg[160];
        if (top.CPU9_FAULT) { std::snprintf(msg, sizeof msg, "ARM9 fault %u at %08x", unsigned(top.CPU9_FAULT), unsigned(top.CPU9_FAULT_ADDR)); check(false, msg); }
        if (top.CPU7_FAULT) { std::snprintf(msg, sizeof msg, "ARM7 fault %u at %08x", unsigned(top.CPU7_FAULT), unsigned(top.CPU7_FAULT_ADDR)); check(false, msg); }
        check(!top.IO9_GPU_REQ_VALID, "unexpected external link request");
        if (held)
            check(top.MEM_REQ_VALID == hValid && top.MEM_REQ_WRITE == hWrite && top.MEM_REQ_ADDR == hAddr &&
                  top.MEM_REQ_LANES == hLanes && top.MEM_REQ_DATA == hData, "memory request changed while not accepted");
        if (top.MEM_REQ_VALID)
            check((top.MEM_REQ_ADDR & 0xfffff003u) == 0x02000000u, "memory request outside the RAM window");
        const bool acc = top.MEM_REQ_VALID && memReady;
        if (respNow) resps.pop_front();
        if (acc) {
            const uint32_t ix = (top.MEM_REQ_ADDR & 0xfffu) >> 2;
            const uint32_t old = ram[ix];
            if (top.MEM_REQ_WRITE) {
                uint32_t mask = 0;
                for (int k = 0; k < 4; ++k) if (top.MEM_REQ_LANES & (1u << k)) mask |= 0xffu << (8 * k);
                ram[ix] = (old & ~mask) | (top.MEM_REQ_DATA & mask);
                // Bytes outside the lanes that differ from memory: the other
                // CPU wrote this word between this core's read and its write.
                staleMerges += (top.MEM_REQ_DATA & ~mask) != (old & ~mask);
            }
            const long due = std::max(lastDue + 1, t + lat);
            resps.emplace_back(due, top.MEM_REQ_WRITE ? 0 : old);
            lastDue = due;
            ++acceptedN;
        }
        held = top.MEM_REQ_VALID && !memReady;
        hValid = top.MEM_REQ_VALID; hWrite = top.MEM_REQ_WRITE; hAddr = top.MEM_REQ_ADDR;
        hLanes = top.MEM_REQ_LANES; hData = top.MEM_REQ_DATA;
        // Bounded wait. ARB_GRANT is a Maybe Bool: bit 1 = Just, bit 0 = ARM7.
        const bool g = (top.ARB_GRANT >> 1) & 1, g7 = g && (top.ARB_GRANT & 1), g9 = g && !(top.ARB_GRANT & 1);
        auto track = [](int &w, bool want, bool mine, bool other) {
            if (mine) w = -1;
            else if (w >= 0) w += other;
            else if (want) w = other ? 1 : 0;
        };
        track(wait9, top.ARB_WANT9, g9, g7);
        track(wait7, top.ARB_WANT7, g7, g9);
        maxWait = std::max(maxWait, std::max(wait9, wait7));
        check(wait9 <= 1 && wait7 <= 1, "arbiter starvation: more than one grant to the other core while one waited");
        steps9 += top.ARB_STEP9; steps7 += top.ARB_STEP7;
        // Card image port.
        if (cardReply) cardBusy = false;
        if (top.CARD_ROM_REQ_VALID && cardReady) { cardBusy = true; cardDue = t + 1 + cardLat; cardAddr = top.CARD_ROM_ADDR; }
        // Mailboxes.
        auto box = [&](const char *name, bool valid, uint32_t a, uint32_t v, uint32_t base, const std::vector<uint32_t> &e, size_t &n) {
            if (!valid || a < base || a >= base + 0x100) return;
            check(n < e.size(), "store after a mailbox");
            check((a - base) / 4 == n, "mailbox store out of slot order");
            std::printf("%s RAM[%u]=%08x\n", name, unsigned(a - base), unsigned(v));
            if (v != e[n]) { std::fprintf(stderr, "%s slot %zu: got %08x, expected %08x\n", name, n, unsigned(v), unsigned(e[n])); std::exit(1); }
            ++n;
        };
        box("ARM9", top.CPU9_STORE_VALID, top.CPU9_STORE_ADDR, top.CPU9_STORE_DATA, 0x02000000u, exp9, s9);
        box("ARM7", top.CPU7_STORE_VALID, top.CPU7_STORE_ADDR, top.CPU7_STORE_DATA, 0x02000100u, exp7, s7);
        check(!(top.CPU9_STORE_VALID && top.CPU9_STORE_ADDR >= 0x02000100u && top.CPU9_STORE_ADDR < 0x02000200u), "ARM9 stored into the ARM7 mailbox");
        check(!(top.CPU7_STORE_VALID && top.CPU7_STORE_ADDR >= 0x02000000u && top.CPU7_STORE_ADDR < 0x02000100u), "ARM7 stored into the ARM9 mailbox");
        if (s9 == exp9.size() && s7 == exp7.size() && doneAt < 0) doneAt = t;
        if (doneAt >= 0 && t - doneAt >= 4000) {
            check(staleMerges > 0, "no write ever carried stale bytes outside its lanes: the byte-lane interleaving was not exercised");
            std::printf("PASS: generated nds_dual_soc: ARM9 %zu and ARM7 %zu mailbox words; %ld cycles, %ld ARM9 and %ld ARM7 steps, %ld memory requests (%ld byte writes kept the other CPU's newer bytes); at most %d grant(s) to the other core while one waited\n",
                        s9, s7, t, steps9, steps7, acceptedN, staleMerges, maxWait);
            return 0;
        }
        clock(top);
    }
    check(false, "timeout");
    return 1;
}
