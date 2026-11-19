// SPDX-License-Identifier: GPL-3.0-or-later
// Compile the production Clash netlist and unchanged board adapter; observe
// actual chip commands as well as the request/completion handshake.
module memory_fabric_gate(input CLK, RST, CV, ARM7, WR, input [31:0] ADDR,
    input [3:0] BE, input [31:0] WD, input CT, DV, input [3:0] SPACE,
    input [19:0] OFF, input DT, output CR, CA, output [31:0] CQ,
    output [63:0] CLINE, output DR, DA, output [63:0] DQOUT,
    output SREQ, SWRITE, output [25:0] SADDR, output [3:0] SBE, output DONE,
    output [31:0] ERRORS, READS, WRITES, REFRESHES, output ACT, REF);
    wire [31:0] SDATA;
    wire [63:0] Q;
    nds_memory_gate dut (.*);
    wire [15:0] dq;
    wire [12:0] a;
    wire [1:0] ba;
    wire ck,cke,cs,we,ras,cas,dqmh,dqml;
    // This gate exercises power reset only; soft holds have a separate pin gate.
    nds_clash_sdram sd(.clk(CLK), .init(RST), .rst(RST), .client_reset(), .sd_req(SREQ), .sd_write(SWRITE),
        .sd_half_addr(SADDR), .sd_lanes(SBE), .sd_data(SDATA), .sd_done(DONE), .sd_read_data(Q),
        .SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_BA(ba), .SDRAM_CLK(ck), .SDRAM_CKE(cke),
        .SDRAM_nCS(cs), .SDRAM_nWE(we), .SDRAM_nRAS(ras), .SDRAM_nCAS(cas),
        .SDRAM_DQMH(dqmh), .SDRAM_DQML(dqml));
    sdram_model chip (.clk_pin(ck), .cke(cke), .nCS(cs), .nRAS(ras), .nCAS(cas), .nWE(we),
        .BA(ba), .A({dqmh, dqml, a[10:0]}), .DQ(dq));
    assign ACT = {cs,ras,cas,we} == 4'b0011;
    assign REF = {cs,ras,cas,we} == 4'b0001;
    assign {ERRORS, READS, WRITES, REFRESHES} = {chip.errors,chip.reads,chip.writes,chip.refreshes};
endmodule
