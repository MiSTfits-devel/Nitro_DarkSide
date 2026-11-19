// SPDX-License-Identifier: GPL-3.0-or-later
//
// Replays a cycle trace of the compact geometry engine's Clash simulation
// (geomatrix-check dump) on the freshly generated Verilog top
// nds_gpu3d_geomtx under Verilator and compares every output, every cycle:
// entry ready, event valid and (when valid) the whole 330-bit event, status
// (all bits), swap wait, read ready, read data valid and, when valid, the
// read data.
//
// Verilator, not iverilog: Clash emits combinational logic as
// `always @(*)` blocks, which Icarus does not run at time zero, so registers
// whose initial value never changes leave those blocks x and the x is
// latched into the state during the power-on sweep. That is a simulator
// scheduling artefact, not netlist behaviour; Verilator evaluates all logic
// at initialisation.
//
// One trace line: input flags (reset, command valid, event ready, stall,
// acknowledge, read valid, VBlank), command, parameter, ZeroDotWLimit, read
// address, expected-output flags (ready, event valid, swap wait, read ready,
// read data valid), status, read data, event (83 hex digits), cycle number.
#include "Vnds_gpu3d_geomtx.h"
#include "verilated.h"
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {
constexpr int kEventWords = 11;   // 330 bits

// 83 hex digits, most significant first, into little-endian 32-bit words.
bool parseEvent(const char *hex, uint32_t (&w)[kEventWords]) {
    const int n = static_cast<int>(std::strlen(hex));
    if (n != 83) return false;
    std::memset(w, 0, sizeof w);
    for (int i = 0; i < n; ++i) {
        const char c = hex[n - 1 - i];
        const int v = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
        if (v < 0) return false;
        w[i / 8] |= static_cast<uint32_t>(v) << (4 * (i % 8));
    }
    return true;
}
}

int main(int argc, char **argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: %s TRACE|-\n", argv[0]); return 2; }
    FILE *f = std::strcmp(argv[1], "-") == 0 ? stdin : std::fopen(argv[1], "r");
    if (!f) { std::fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    Verilated::commandArgs(argc, argv);
    Vnds_gpu3d_geomtx top;
    top.CLK = 0; top.RST = 1; top.EN = 1;
    top.CMD_VALID = 0; top.CMD_CMD = 0; top.CMD_PARAM = 0; top.EV_READY = 0; top.STALL = 0;
    top.VBLANK = 0; top.ACK = 0; top.ZERO_DOT_W = 0; top.RD_VALID = 0; top.RD_ADDR = 0;
    top.eval();
    unsigned iflags, cc, eflags, cyc;
    uint32_t cp, zdw, ra, st, rd;
    char evhex[128];
    long checks = 0, reads = 0, events = 0, swaps = 0, errs = 0;
    while (std::fscanf(f, "%x %x %" SCNx32 " %" SCNx32 " %" SCNx32 " %x %" SCNx32 " %" SCNx32 " %127s %u",
                       &iflags, &cc, &cp, &zdw, &ra, &eflags, &st, &rd, evhex, &cyc) == 10) {
        uint32_t ev[kEventWords];
        if (!parseEvent(evhex, ev)) { std::fprintf(stderr, "bad event field at cycle %u\n", cyc); return 2; }
        top.RST = iflags & 1;
        top.CMD_VALID = (iflags >> 1) & 1;
        top.EV_READY = (iflags >> 2) & 1;
        top.STALL = (iflags >> 3) & 1;
        top.ACK = (iflags >> 4) & 1;
        top.RD_VALID = (iflags >> 5) & 1;
        top.VBLANK = (iflags >> 6) & 1;
        top.CMD_CMD = cc; top.CMD_PARAM = cp; top.ZERO_DOT_W = zdw; top.RD_ADDR = ra;
        top.eval();
        ++checks;
        const bool eReady = eflags & 1, eEv = (eflags >> 1) & 1, eSwap = (eflags >> 2) & 1,
                   eRdReady = (eflags >> 3) & 1, eRdValid = (eflags >> 4) & 1;
        if (eRdValid) ++reads;
        if (eEv) ++events;
        if (eSwap) ++swaps;
        bool evOk = true;
        if (eEv)
            for (int i = 0; i < kEventWords; ++i)
                if (top.EVENT[i] != ev[i]) evOk = false;
        if (top.CMD_READY != eReady || top.EV_VALID != eEv || !evOk || top.SWAP_WAIT != eSwap
            || top.RD_READY != eRdReady || top.RD_DATA_VALID != eRdValid || top.STATUS != st
            || (eRdValid && top.RD_DATA != rd)) {
            if (++errs <= 10)
                std::printf("cycle %u: ready %u/%u event %u/%u%s swap %u/%u rdready %u/%u rdvalid %u/%u status %08x/%08x data %08x/%08x\n",
                            cyc, top.CMD_READY, eReady, top.EV_VALID, eEv, evOk ? "" : " (payload differs)",
                            top.SWAP_WAIT, eSwap, top.RD_READY, eRdReady, top.RD_DATA_VALID, eRdValid,
                            top.STATUS, st, top.RD_DATA, rd);
        }
        // Clash's simulation of an asynchronously reset register holds the
        // reset value through the edge that ends a reset cycle (the pure
        // runner models the same), so the reset stays asserted across it.
        top.CLK = 1; top.eval();
        top.CLK = 0; top.eval();
    }
    // The trace ends with "# end N": a truncated trace (the writer died) is a
    // failure, not a short pass.
    long declared = -1;
    if (std::fscanf(f, " # end %ld", &declared) != 1 || declared != checks) {
        std::printf("geomtx cosim: trace ended without its trailer or with the wrong count (%ld lines, trailer %ld)\n",
                    checks, declared);
        return 1;
    }
    std::printf("geomtx cosim: %ld cycles compared, %ld events, %ld swap-wait cycles, %ld result reads, %ld mismatches\n",
                checks, events, swaps, reads, errs);
    return errs == 0 && checks > 0 && events > 0 ? 0 : 1;
}
