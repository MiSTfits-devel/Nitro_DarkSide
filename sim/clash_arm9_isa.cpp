// SPDX-License-Identifier: GPL-3.0-or-later
// CPU-only Verilator host for the generated Clash ARM9 slice: same contract
// as clash/test/Arm9IsaCheck.hs (ordered mailbox stores, then quiet, an
// exact fault, or one exact held GPU offer). The GPU link is never ready.
#include "Vnds_arm9_slice.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

static void require(bool ok, const char *message) {
    if (!ok) { std::fprintf(stderr, "Clash RTL ISA: %s\n", message); std::exit(1); }
}
static void clock(Vnds_arm9_slice &top) {
    top.CLK = 1; top.eval(); top.CLK = 0; top.eval();
}
// First token of each line; '#' starts a comment.
static std::vector<uint32_t> readWords(const char *path) {
    std::ifstream file(path);
    require(bool(file), "cannot open input");
    std::vector<uint32_t> out;
    std::string line;
    while (std::getline(file, line)) {
        line = line.substr(0, line.find('#'));
        const size_t start = line.find_first_not_of(" \t\r");
        if (start == std::string::npos) continue;
        out.push_back(uint32_t(std::stoul(line.substr(start), nullptr, 16)));
    }
    return out;
}
static uint32_t hex(const char *s) { return uint32_t(std::strtoul(s, nullptr, 16)); }

int main(int argc, char **argv) {
    const char *usage = "usage: isa ROM.hex EXPECTED [--scratch N] [--fault CODE ADDR | --offer R|W WIDTH ADDR DATA]";
    require(argc >= 3, usage);
    // Mailbox slot k is RAM word k; word indices >= scratch are free scratch.
    size_t scratch = 64;
    int arg = 3;
    if (argc > arg + 1 && std::strcmp(argv[arg], "--scratch") == 0) {
        scratch = hex(argv[arg + 1]);
        arg += 2;
    }
    enum { Quiet, Fault, Offer } want = Quiet;
    uint32_t wantCode = 0, wantAddr = 0, wantWidth = 0, wantData = 0;
    bool wantWrite = false;
    if (argc == arg + 3 && std::strcmp(argv[arg], "--fault") == 0) {
        want = Fault; wantCode = hex(argv[arg + 1]); wantAddr = hex(argv[arg + 2]);
    } else if (argc == arg + 5 && std::strcmp(argv[arg], "--offer") == 0) {
        want = Offer; wantWrite = std::strcmp(argv[arg + 1], "W") == 0;
        require(wantWrite || std::strcmp(argv[arg + 1], "R") == 0, "offer kind must be R or W");
        wantWidth = hex(argv[arg + 2]); wantAddr = hex(argv[arg + 3]); wantData = hex(argv[arg + 4]);
    } else {
        require(argc == arg, usage);
    }
    const std::vector<uint32_t> rom = readWords(argv[1]);
    const std::vector<uint32_t> expected = readWords(argv[2]);
    require(!rom.empty() && !expected.empty() && expected.size() <= scratch, "invalid input");
    Verilated::commandArgs(argc, argv);
    Vnds_arm9_slice top;
    top.CLK = 0; top.RST = 1; top.EN = 1; top.BOOT_WORD = 0;
    top.GPU_REQ_READY = 0; top.GPU_REPLY_VALID = 0;
    top.GPU_REPLY_DATA = 0; top.GPU_REPLY_FAULT = 0; top.IRQ = 0;
    top.eval(); clock(top); clock(top); top.RST = 0; top.eval();
    size_t stores = 0;
    unsigned retired = 0;
    int doneAt = -1;
    for (int tick = 0; tick < 40000; ++tick) {
        const uint32_t addr = top.BOOT_ADDR & ~3u;
        const size_t index = (addr - 0xffff0000u) / 4;
        top.BOOT_WORD = addr >= 0xffff0000u && index < rom.size() ? rom[index] : 0xe7f000f0u;
        top.eval();
        if (top.STORE_VALID) {
            require(stores < expected.size(), "store after the mailbox");
            const size_t word = (top.STORE_ADDR - 0x02000000u) / 4;
            if (word >= scratch && word < 64) {
                std::printf("scratch[%zu]=%08x\n", word, top.STORE_DATA);
            } else {
                require(top.STORE_ADDR == 0x02000000u + 4 * stores, "store out of slot order");
                std::printf("ARM9 RAM[%zu]=%08x\n", stores * 4, top.STORE_DATA);
                if (top.STORE_DATA != expected[stores]) {
                    std::fprintf(stderr, "slot %zu: got %08x, expected %08x\n", stores, top.STORE_DATA, expected[stores]);
                    return 1;
                }
                ++stores;
            }
        }
        if (top.RETIRE_VALID) ++retired;
        if (stores == expected.size() && doneAt < 0) doneAt = tick;
        if (top.GPU_REQ_VALID) {
            const uint32_t lanes = ((1u << top.GPU_REQ_WIDTH) - 1) << (top.GPU_REQ_ADDR & 3);
            std::printf("GPU offer %s%u %08x %08x\n", top.GPU_REQ_WRITE ? "W" : "R",
                        unsigned(top.GPU_REQ_WIDTH), top.GPU_REQ_ADDR, top.GPU_REQ_DATA);
            require(want == Offer && stores == expected.size() && bool(top.GPU_REQ_WRITE) == wantWrite &&
                    top.GPU_REQ_WIDTH == wantWidth && top.GPU_REQ_ADDR == wantAddr &&
                    top.GPU_REQ_DATA == wantData && top.GPU_REQ_LANES == lanes, "unexpected GPU offer");
            std::puts("PASS: generated slice held the expected GPU offer");
            return 0;
        }
        if (top.FAULT) {
            std::printf("fault %u at %08x\n", unsigned(top.FAULT), top.FAULT_ADDR);
            require(want == Fault && stores == expected.size() && top.FAULT == wantCode &&
                    top.FAULT_ADDR == wantAddr, "unexpected fault");
            std::puts("PASS: generated slice faulted as expected");
            return 0;
        }
        if (doneAt >= 0 && tick - doneAt >= 500) {
            require(want == Quiet, "expected fault/offer did not occur");
            std::printf("PASS: generated slice %zu mailbox stores, %u retired, no GPU access\n", stores, retired);
            return 0;
        }
        clock(top);
    }
    require(false, "timeout");
}
