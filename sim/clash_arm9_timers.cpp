// SPDX-License-Identifier: GPL-3.0-or-later
// Real generated ARM9+timer/interrupt SoC running an assembled ARM witness.
#include "Vnds_arm9_soc.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static void check(bool ok, const char *message) {
    if (!ok) { std::fprintf(stderr, "ARM9 timer RTL: %s\n", message); std::exit(1); }
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
    check(argc == 3, "usage: witness ROM.hex EXPECTED");
    auto rom = words(argv[1]), expected = words(argv[2]);
    Verilated::commandArgs(argc, argv);
    Vnds_arm9_soc top;
    top.CLK = 0; top.RST = 1; top.EN = 1; top.BOOT_WORD = 0;
    top.GPU_REQ_READY = top.GPU_REPLY_VALID = top.GPU_REPLY_FAULT = 0;
    top.GPU_REPLY_DATA = top.TIMER_TICK = top.EXT_IRQ_SET = top.EXT_IRQ_CLEAR = 0;
    top.eval(); clock(top); clock(top); top.RST = 0; top.eval();
    size_t stores = 0;
    std::vector<uint32_t> acks;
    bool sawIrq = false;
    int done = -1;
    for (int tick = 0; tick < 20000; ++tick) {
        top.TIMER_TICK = tick & 1;
        top.eval();
        uint32_t addr = top.CPU_BOOT_ADDR;
        uint32_t idx = (addr - 0xffff0000u) / 4;
        top.BOOT_WORD = addr >= 0xffff0000u && !(addr & 3) && idx < rom.size()
            ? rom[idx] : 0xe7f000f0u;
        top.eval();
        check(top.CPU_BOOT_ADDR == addr, "boot address depends on boot data");
        check(!top.CPU_FAULT, "CPU fault");
        check(!top.IO_GPU_REQ_VALID, "local transaction escaped to GPU");
        check(bool(top.IO_IRQ) == (top.IO_IME && (top.IO_IE & top.IO_IF)), "incorrect IRQ level");
        sawIrq |= top.IO_IRQ;
        if (top.IO_IF_ACK) acks.push_back(top.IO_IF_ACK);
        if (top.CPU_STORE_VALID) {
            check(stores < expected.size(), "extra mailbox store");
            if (top.CPU_STORE_ADDR != 0x02000000u + 4 * stores || top.CPU_STORE_DATA != expected[stores]) {
                std::fprintf(stderr, "mailbox %zu: %08x=%08x expected %08x\n", stores,
                             unsigned(top.CPU_STORE_ADDR), unsigned(top.CPU_STORE_DATA), unsigned(expected[stores]));
                return 1;
            }
            std::printf("ARM9 RAM[%zu]=%08x\n", 4 * stores, unsigned(top.CPU_STORE_DATA));
            if (++stores == expected.size()) done = tick;
        }
        if (done >= 0 && tick - done >= 50) {
            check(sawIrq && !top.IO_IRQ && !top.IO_IF, "IRQ did not assert and clear");
            check(acks == std::vector<uint32_t>({8, 16}), "unexpected IF acknowledgements");
            // External GPU-source masks latch and clear even with IME disabled.
            top.EXT_IRQ_SET = 8; top.eval(); clock(top);
            top.EXT_IRQ_SET = 0; top.eval();
            check(top.IO_IF == 8 && !top.IO_IRQ, "external IRQ set/IME gate failed");
            top.EXT_IRQ_CLEAR = 8; top.eval(); clock(top);
            top.EXT_IRQ_CLEAR = 0; top.eval();
            check(top.IO_IF == 0 && !top.IO_IRQ, "external IRQ clear failed");
            std::puts("PASS: generated ARM9 timer/IF witness");
            return 0;
        }
        clock(top);
    }
    check(false, "timeout");
}
