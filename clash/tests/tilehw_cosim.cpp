// SPDX-License-Identifier: GPL-3.0-or-later
//
// Replays the 2D tile engine's pure-model cycle stream (tilehw-check dump,
// piped in on stdin; nothing is written to disk) on the freshly generated
// Verilog top nds_gpu2d_tilehw under Verilator and compares every output,
// every cycle, as the lines arrive: ready, request valid and (when valid)
// the request space and address, pixel valid and (when valid) x, colour and
// layer, and the fault word. Each scene in the stream starts with a reset
// cycle; the Verilog's RAMs are not cleared by reset, so they carry the last
// scene's contents while the pure model's start at zero.
//
// Verilator, not iverilog: Clash emits combinational logic as `always @(*)`
// blocks, which Icarus does not run at time zero (see geomtx_cosim.cpp).
//
// One trace line: input flags (bit 0 reset, 1 start valid, 2 start engine,
// 3 request ready, 4 response valid, 5 palette write, 6 OAM write, 7 OBJ
// extended palette write), start line, start kind (0 both, 1 BG, 2 OBJ,
// 3 clear), DISPCNT, BGCNT (BG0 in the low 16
// bits), HOFS and VOFS (9 bits per BG, BG0 low), BLDCNT, response data,
// palette, OAM and extended-palette write address and data, expected-output
// flags (bit 0 ready, 1 request valid, 2 pixel valid, 3 request is OBJ),
// request address, pixel x, colour and layer, fault, cycle number.
#include "Vnds_gpu2d_tilehw.h"
#include "verilated.h"
#include <cinttypes>
#include <cstdio>

int main(int argc, char **argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: %s TRACE|-\n", argv[0]); return 2; }
    FILE *f = argv[1][0] == '-' && argv[1][1] == 0 ? stdin : std::fopen(argv[1], "r");
    if (!f) { std::fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    Verilated::commandArgs(argc, argv);
    Vnds_gpu2d_tilehw top;
    top.CLK = 0; top.RST = 1; top.EN = 1;
    top.START_VALID = 0; top.START_ENGINE = 0; top.START_LINE = 0; top.START_KIND = 0;
    top.DISPCNT = 0; top.BGCNT = 0; top.HOFS = 0; top.VOFS = 0; top.BLDCNT = 0;
    top.REQ_READY = 0; top.RESP_VALID = 0; top.RESP_DATA = 0;
    top.PAL_WR_VALID = 0; top.PAL_WR_ADDR = 0; top.PAL_WR_DATA = 0;
    top.OAM_WR_VALID = 0; top.OAM_WR_ADDR = 0; top.OAM_WR_DATA = 0;
    top.EXT_WR_VALID = 0; top.EXT_WR_ADDR = 0; top.EXT_WR_DATA = 0;
    top.eval();
    unsigned fl, line, kind, bld, pa, pd, oa, od, xa, xd, of, ra, px, pc, pl, fault;
    uint32_t dc;
    uint64_t bc, hs, vs, rd;
    unsigned long cyc;
    long checks = 0, reqs = 0, objReqs = 0, pixels = 0, objPixels = 0, errs = 0, scenes = 0;
    bool inReset = false;
    while (std::fscanf(f, "%x %x %x %" SCNx32 " %" SCNx64 " %" SCNx64 " %" SCNx64 " %x %" SCNx64
                          " %x %x %x %x %x %x %x %x %x %x %x %x %lu",
                       &fl, &line, &kind, &dc, &bc, &hs, &vs, &bld, &rd, &pa, &pd, &oa, &od, &xa, &xd,
                       &of, &ra, &px, &pc, &pl, &fault, &cyc) == 22) {
        top.RST = fl & 1;
        top.START_VALID = (fl >> 1) & 1;
        top.START_ENGINE = (fl >> 2) & 1;
        top.REQ_READY = (fl >> 3) & 1;
        top.RESP_VALID = (fl >> 4) & 1;
        top.PAL_WR_VALID = (fl >> 5) & 1;
        top.OAM_WR_VALID = (fl >> 6) & 1;
        top.EXT_WR_VALID = (fl >> 7) & 1;
        top.START_LINE = line; top.START_KIND = kind;
        top.DISPCNT = dc; top.BGCNT = bc; top.HOFS = hs; top.VOFS = vs; top.BLDCNT = bld;
        top.RESP_DATA = rd; top.PAL_WR_ADDR = pa; top.PAL_WR_DATA = pd;
        top.OAM_WR_ADDR = oa; top.OAM_WR_DATA = od; top.EXT_WR_ADDR = xa; top.EXT_WR_DATA = xd;
        top.eval();
        ++checks;
        if ((fl & 1) && !inReset) ++scenes;
        inReset = fl & 1;
        const bool eReady = of & 1, eReq = (of >> 1) & 1, ePix = (of >> 2) & 1, eObj = (of >> 3) & 1;
        if (eReq && (fl >> 3) & 1) { ++reqs; if (eObj) ++objReqs; }
        if (ePix) { ++pixels; if (pl == 4) ++objPixels; }
        if (top.READY != eReady || top.REQ_VALID != eReq
            || (eReq && (top.REQ_ADDR != ra || top.REQ_OBJ != eObj))
            || top.PIX_VALID != ePix || (ePix && (top.PIX_X != px || top.PIX_COLOR != pc || top.PIX_LAYER != pl))
            || top.FAULT != fault) {
            if (++errs <= 10)
                std::printf("cycle %lu: ready %u/%u req %u/%u obj %u/%u addr %04x/%04x pix %u/%u x %02x/%02x colour %04x/%04x layer %u/%u fault %04x/%04x\n",
                            cyc, top.READY, eReady, top.REQ_VALID, eReq, top.REQ_OBJ, eObj, top.REQ_ADDR, ra,
                            top.PIX_VALID, ePix, top.PIX_X, px, top.PIX_COLOR, pc, top.PIX_LAYER, pl, top.FAULT, fault);
        }
        // as geomtx_cosim.cpp: the reset stays asserted across the edge that
        // ends a reset cycle, as Clash's simulation and the pure runner model
        top.CLK = 1; top.eval();
        top.CLK = 0; top.eval();
    }
    std::printf("tilehw cosim: %ld scenes, %ld cycles compared, %ld requests (%ld OBJ), %ld pixels (%ld OBJ), %ld mismatches\n",
                scenes, checks, reqs, objReqs, pixels, objPixels, errs);
    return errs == 0 && checks > 0 && pixels > 0 ? 0 : 1;
}
