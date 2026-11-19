// SPDX-License-Identifier: GPL-3.0-or-later
// Verilator host for the freshly generated CPU + VRAM display prototype.
// Supplies the boot ROM, logs every GPU-link transaction and mailbox store
// in GfxSliceCheck's format, and, after the program halts, captures one
// complete 640x480 frame from the VGA output.
#include "Vnds_gfx_soc.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

namespace {
constexpr uint32_t haltOpcode = 0xeafffffe;
constexpr long cycleLimit = 20000000;

void require(bool ok, const char *message) {
    if (!ok) { std::fprintf(stderr, "FAIL: generated SoC: %s\n", message); std::exit(1); }
}

struct Host {
    Vnds_gfx_soc top;
    std::vector<uint32_t> rom;
    long cycles = 0;

    void settle() {
        const uint32_t addr = top.BOOT_ADDR;
        top.BOOT_WORD = (addr & 0xfffff000u) == 0xffff0000u && ((addr & 0xfffu) >> 2) < rom.size()
            ? rom[(addr & 0xfffu) >> 2] : 0;
        top.eval();
    }
    void edge() {
        top.CLK = 1; top.eval();
        top.CLK = 0; top.eval();
        settle();
        ++cycles;
    }
};
}

int main(int argc, char **argv) {
    require(argc == 3 || (argc == 4 && std::string(argv[3]) == "--expect-fault"),
            "usage: Vnds_gfx_soc ROM.hex OUTDIR [--expect-fault]");
    const bool expectFault = argc == 4;
    const std::string out = argv[2];
    Verilated::commandArgs(argc, argv);
    Host h;
    {
        std::ifstream image(argv[1]);
        require(bool(image), "cannot open ROM");
        uint32_t value;
        while (image >> std::hex >> value) h.rom.push_back(value);
        require(image.eof() && !h.rom.empty() && h.rom.size() <= 1024, "invalid ROM");
    }
    FILE *log = std::fopen((out + "/rtl.log").c_str(), "w");
    require(log, "cannot write rtl.log");

    h.top.CLK = 0; h.top.RST = 1; h.top.BOOT_WORD = 0;
    h.top.eval(); h.edge(); h.edge();
    h.top.RST = 0; h.settle();

    bool held = false, heldWrite = false;
    unsigned heldWidth = 0;
    uint32_t heldAddr = 0, heldData = 0;
    unsigned ops = 0, faultCode = 0;
    for (;;) {
        require(h.cycles < cycleLimit, "program did not halt");
        auto &t = h.top;
        if (t.REPLY_FIRE) {
            require(held, "reply without request");
            std::fprintf(log, "%c%u %08x %08x%s\n", heldWrite ? 'W' : 'R', heldWidth, heldAddr,
                         heldWrite ? heldData : t.REPLY_DATA, t.REPLY_FAULT ? " FAULT" : "");
            held = false;
            ++ops;
        }
        if (t.REQ_FIRE) {
            require(!held, "overlapping GPU requests");
            held = true; heldWrite = t.REQ_WRITE; heldWidth = t.REQ_WIDTH;
            heldAddr = t.REQ_ADDR; heldData = t.REQ_DATA;
        }
        if (t.STORE_VALID) std::fprintf(log, "S %08x %08x\n", t.STORE_ADDR, t.STORE_DATA);
        if (t.CPU_FAULT) {
            faultCode = t.CPU_FAULT;
            std::fprintf(log, "CPU FAULT %u %08x\n", faultCode, t.CPU_FAULT_ADDR);
            break;
        }
        if (t.RETIRE_VALID && t.RETIRE_OPCODE == haltOpcode) { std::fprintf(log, "HALT\n"); break; }
        h.edge();
    }
    std::fclose(log);
    std::printf("generated SoC: %u GPU transactions, stopped after %ld cycles\n", ops, h.cycles);
    if (expectFault) {
        require(faultCode != 0, "expected a CPU fault");
        return 0;
    }
    require(faultCode == 0, "unexpected CPU fault");

    // The LCD-enable latch samples POWCNT1 at the first clock of each frame;
    // capture the first frame that starts entirely after the halt.
    auto video = [&] { return h.top.VIDEO; };
    auto vs = [&] { return (video() >> 24) & 1; };
    while (vs()) h.edge();
    while (!vs()) h.edge();
    while (vs()) h.edge();
    // VS ends at line 492; the next frame starts at line 0.
    std::vector<uint32_t> frame;
    frame.reserve(640 * 480);
    long ce = 0;
    bool started = false;
    while (true) {
        const uint32_t v = video();
        const bool pixel = (v >> 27) & 1, de = (v >> 26) & 1;
        if (pixel && de) started = true;
        if (started && vs()) break;
        if (pixel && started) ++ce;
        if (pixel && de) frame.push_back(v & 0xffffff);
        h.edge();
    }
    require(frame.size() == 640u * 480u, "frame does not have 640x480 active pixels");
    require(ce == 800L * 490L, "raster is not 800 CE clocks per line");

    FILE *ds = std::fopen((out + "/rtl-frame.hex").c_str(), "w");
    require(ds, "cannot write rtl-frame.hex");
    for (int y = 0; y < 480; ++y)
        for (int x = 0; x < 640; ++x) {
            const bool inside = x >= 64 && x < 576 && y >= 48 && y < 432;
            const uint32_t c = frame[y * 640 + x];
            if (!inside) { require(c == 0, "non-black border"); continue; }
            const int dx = (x - 64) / 2, dy = (y - 48) / 2;
            require(c == frame[(48 + 2 * dy) * 640 + 64 + 2 * dx], "LCD pixel is not a uniform 2x2 block");
        }
    for (int dy = 0; dy < 192; ++dy)
        for (int dx = 0; dx < 256; ++dx)
            std::fprintf(ds, "%06x\n", frame[(48 + 2 * dy) * 640 + 64 + 2 * dx]);
    std::fclose(ds);
    FILE *ppm = std::fopen((out + "/vga.ppm").c_str(), "wb");
    require(ppm, "cannot write vga.ppm");
    std::fprintf(ppm, "P6\n640 480\n255\n");
    for (uint32_t c : frame) { std::fputc(c >> 16, ppm); std::fputc((c >> 8) & 255, ppm); std::fputc(c & 255, ppm); }
    std::fclose(ppm);
    std::printf("generated SoC: captured 640x480 frame ending at cycle %ld\n", h.cycles);
    return 0;
}
