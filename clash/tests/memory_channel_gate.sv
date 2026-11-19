// SPDX-License-Identifier: GPL-3.0-or-later
// Isolated capacity experiment, not a second production interface. Both
// channels of the same platform controller drive the same pin-clocked model.
module memory_channel_gate(input CLK,RST,VREQ,CREQ,CWRITE,
    input [25:0] VADDR,CADDR, input [31:0] CDATA,
    output VACCEPT, VDONE, CDONE, output [63:0] VDATA,CQ,
    output [31:0] ERRORS, READS, WRITES, REFRESHES);
    wire [15:0] dq; wire [12:0] a; wire [1:0] ba;
    wire ck,cke,cs,we,ras,cas,dqmh,dqml;
    sdram #(.REFRESH_CYCLES(490)) sd (.clk(CLK),.init(RST),.refresh_req(1'b0),
        .ch1_addr(VADDR),.ch1_req(VREQ),.ch1_rnw(1'b1),.ch1_din(16'b0),
        .ch1_dout(VDATA),.ch1_ready(VDONE),.ch1_accept(VACCEPT),
        .ch2_addr(CADDR),.ch2_din(CDATA),.ch2_be(4'b1111),.ch2_req(CREQ),.ch2_cancel(RST),
        .ch2_rnw(!CWRITE),.ch2_dout(CQ[31:0]),.ch2_dout_hi(CQ[63:32]),.ch2_ready64(CDONE),.ch2_ready(),.ch2_ready16(),
        .ch3_addr(24'b0),.ch3_req(1'b0),.ch3_rnw(1'b1),.ch3_din(16'b0),.ch3_dout(),.ch3_ready(),
        .SDRAM_DQ(dq),.SDRAM_A(a),.SDRAM_BA(ba),.SDRAM_CLK(ck),.SDRAM_CKE(cke),
        .SDRAM_nCS(cs),.SDRAM_nWE(we),.SDRAM_nRAS(ras),.SDRAM_nCAS(cas),.SDRAM_DQMH(dqmh),.SDRAM_DQML(dqml));
    sdram_model chip(.clk_pin(ck),.cke(cke),.nCS(cs),.nRAS(ras),.nCAS(cas),.nWE(we),.BA(ba),.A({dqmh,dqml,a[10:0]}),.DQ(dq));
    assign {ERRORS,READS,WRITES,REFRESHES}={chip.errors,chip.reads,chip.writes,chip.refreshes};
endmodule
