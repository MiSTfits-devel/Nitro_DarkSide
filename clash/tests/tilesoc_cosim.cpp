// SPDX-License-Identifier: GPL-3.0-or-later
//
// Replays the both-screen tile SoC's pure-model cycle stream (tilesoc-check
// dump, piped in on stdin; nothing is written to disk) on the freshly
// generated Verilog top nds_tile_soc under Verilator and compares every
// output, every cycle, as the lines arrive: boot-ROM address, the 28-bit
// video bus (pixel enable, DE, HS, VS, RGB), the GPU link transaction probe,
// the IF set bits, the GPU and CPU fault words, the local-RAM store probe and
// the retire strobe. The Verilog's boot ROM is the same 4 KiB image the
// checker and emu.sv serve: BOOT_WORD answers BOOT_ADDR in the same cycle.
//
// Verilator, not iverilog: Clash emits combinational logic as `always @(*)`
// blocks, which Icarus does not run at time zero (see geomtx_cosim.cpp).
//
// One trace line: BOOT_ADDR, VIDEO, transaction flags (bit 0 valid, 1 write,
// 2 fault), transaction address, width, value, IF set bits, GPU fault, CPU
// fault, flags (bit 0 store valid, 1 retire), store address, store data,
// cycle number. Cycle 0 is the reset cycle.
#include "Vnds_tile_soc.h"
#include "verilated.h"
#include <cinttypes>
#include <cstdio>
#include <vector>

int main(int argc, char **argv) {
    if (argc != 3) { std::fprintf(stderr, "usage: %s ROM.hex TRACE|-\n", argv[0]); return 2; }
    std::vector<uint32_t> rom(1024, 0);
    {
        FILE *r = std::fopen(argv[1], "r");
        if (!r) { std::fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
        unsigned n = 0, w;
        while (n < 1024 && std::fscanf(r, "%x", &w) == 1) rom[n++] = w;
        std::fclose(r);
    }
    FILE *f = argv[2][0] == '-' && argv[2][1] == 0 ? stdin : std::fopen(argv[2], "r");
    if (!f) { std::fprintf(stderr, "cannot open %s\n", argv[2]); return 2; }
    Verilated::commandArgs(argc, argv);
    Vnds_tile_soc top;
    auto bootWord = [&](uint32_t a) -> uint32_t {
        return (a & 0xfffff000u) == 0xffff0000u ? rom[(a >> 2) & 1023] : 0;
    };
    top.CLK = 0; top.RST = 1; top.EN = 1; top.BOOT_WORD = 0;
    top.eval();
    uint32_t ba, video, ta, tv, sa, sd;
    unsigned tf, tw, irq, gf, cf, sf;
    unsigned long cyc;
    long checks = 0, pixels = 0, txns = 0, irqs = 0, retired = 0, errs = 0;
    while (std::fscanf(f, "%" SCNx32 " %" SCNx32 " %x %" SCNx32 " %x %" SCNx32 " %x %x %x %x %" SCNx32 " %" SCNx32 " %lu",
                       &ba, &video, &tf, &ta, &tw, &tv, &irq, &gf, &cf, &sf, &sa, &sd, &cyc) == 13) {
        top.RST = cyc == 0;
        top.eval();
        top.BOOT_WORD = bootWord(top.BOOT_ADDR);
        top.eval();
        if (top.BOOT_WORD != bootWord(top.BOOT_ADDR)) {
            std::printf("cycle %lu: BOOT_ADDR depends combinationally on BOOT_WORD\n", cyc);
            return 1;
        }
        ++checks;
        const bool eTxn = tf & 1, eStore = sf & 1;
        if (((video >> 27) & 1) && ((video >> 26) & 1)) ++pixels;
        if (eTxn) ++txns;
        if (irq & 1) ++irqs;
        if ((sf >> 1) & 1) ++retired;
        const bool txnOk = top.TXN_VALID == eTxn
            && (!eTxn || (top.TXN_WRITE == ((tf >> 1) & 1) && top.TXN_FAULT == ((tf >> 2) & 1)
                          && top.TXN_ADDR == ta && top.TXN_WIDTH == tw && top.TXN_VALUE == tv));
        const bool storeOk = top.STORE_VALID == eStore && (!eStore || (top.STORE_ADDR == sa && top.STORE_DATA == sd));
        if (top.BOOT_ADDR != ba || top.VIDEO != video || !txnOk || top.IRQ_SET != irq
            || top.GPU_FAULT != gf || top.CPU_FAULT != cf || !storeOk || top.RETIRE_VALID != ((sf >> 1) & 1)) {
            if (++errs <= 10)
                std::printf("cycle %lu: boot %08x/%08x video %07x/%07x txn %u%u%u/%x %08x/%08x w %u/%u v %08x/%08x "
                            "irq %u/%u gpu-fault %04x/%04x cpu-fault %u/%u store %u/%u %08x/%08x %08x/%08x retire %u/%u\n",
                            cyc, top.BOOT_ADDR, ba, top.VIDEO, video, top.TXN_VALID, top.TXN_WRITE, top.TXN_FAULT, tf,
                            top.TXN_ADDR, ta, top.TXN_WIDTH, tw, top.TXN_VALUE, tv, top.IRQ_SET, irq, top.GPU_FAULT, gf,
                            top.CPU_FAULT, cf, top.STORE_VALID, eStore, top.STORE_ADDR, sa, top.STORE_DATA, sd,
                            top.RETIRE_VALID, (sf >> 1) & 1);
        }
        // the reset stays asserted across the edge that ends the reset
        // cycle, as Clash's simulation and the pure model do
        top.CLK = 1; top.eval();
        top.CLK = 0; top.eval();
    }
    std::printf("tilesoc cosim: %ld cycles compared, %ld picture pixels, %ld GPU link transactions, %ld VBlank IF sets, %ld instructions retired, %ld mismatches\n",
                checks, pixels, txns, irqs, retired, errs);
    return errs == 0 && checks > 0 && pixels > 0 ? 0 : 1;
}
