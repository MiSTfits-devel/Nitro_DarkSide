// SPDX-License-Identifier: GPL-3.0-or-later
// Same 67.028 MHz master clock as Nds.Memory.Fabric. Not a CDC bridge.
// Exactly one request pulse outstanding. Reads start on an 8-byte boundary;
// ready64 includes the fourth halfword; for writes it is the second WRITE.
module nds_clash_sdram (
    input clk, rst, sd_req, sd_write,
    input [25:0] sd_half_addr,
    input [3:0] sd_lanes,
    input [31:0] sd_data,
    output sd_done, output [63:0] sd_read_data,
    inout [15:0] SDRAM_DQ, output [12:0] SDRAM_A, output [1:0] SDRAM_BA,
    output SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS,
           SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK
);
    // 8192 refreshes / 64 ms => 523 clocks at this frequency. Trigger at
    // 490, leaving >30 clocks even for the longest already-issued access.
    sdram #(.REFRESH_CYCLES(490)) memory (
        .clk(clk), .init(rst), .refresh_req(1'b0),
        .ch2_addr(sd_half_addr), .ch2_din(sd_data), .ch2_be(sd_lanes),
        .ch2_rnw(!sd_write), .ch2_req(sd_req && !rst), .ch2_cancel(rst),
        .ch2_dout(sd_read_data[31:0]), .ch2_dout_hi(sd_read_data[63:32]),
        .ch2_ready64(sd_done), .ch2_ready(), .ch2_ready16(),
        .ch1_addr(26'b0), .ch1_req(1'b0), .ch1_rnw(1'b1), .ch1_din(16'b0),
        .ch1_dout(), .ch1_accept(), .ch1_ready(),
        .ch3_addr(24'b0), .ch3_req(1'b0), .ch3_rnw(1'b1), .ch3_din(16'b0),
        .ch3_dout(), .ch3_ready(),
        .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_DQML, .SDRAM_DQMH,
        .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE, .SDRAM_CLK
    );
endmodule
