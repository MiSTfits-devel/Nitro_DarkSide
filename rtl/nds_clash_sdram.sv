// SPDX-License-Identifier: GPL-3.0-or-later
// Same 67.028 MHz master clock as Nds.Memory.Fabric. Not a CDC bridge.
// Exactly one request pulse outstanding. Reads start on an 8-byte boundary;
// ready64 includes the fourth halfword; for writes it is the second WRITE.
module nds_clash_sdram (
    input clk, init, rst, sd_req, sd_write,
    input [25:0] sd_half_addr,
    input [3:0] sd_lanes,
    input [31:0] sd_data,
    output client_reset, sd_done, output [63:0] sd_read_data,
    inout [15:0] SDRAM_DQ, output [12:0] SDRAM_A, output [1:0] SDRAM_BA,
    output SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS,
           SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK
);
    // init: physical power/clock reset, no retention guarantee. rst: guest
    // session hold, synchronous to clk. Never stop refresh for a guest hold.
    // Once offered, even a write still waiting for init/refresh must drain.
    // Hold the producer in reset until the old completion has been consumed.
    reg pending = 0, discard = 0;
    wire physical_done;
    assign client_reset = init || rst || discard;
    wire issue = sd_req && !client_reset;
    assign sd_done = physical_done && !client_reset;
    always @(posedge clk) begin
        if (init) begin
            pending <= 0;
            discard <= 0;
        end else begin
            if (issue || physical_done) pending <= issue;
            if (physical_done) discard <= 0;
            else if (rst && pending) discard <= 1;
        end
    end
    // 8192 refreshes / 64 ms => 523 clocks at this frequency. Trigger at
    // 490, leaving >30 clocks even for the longest already-issued access.
    // The forwarded rising edge follows the controller falling edge through
    // the clock output pin. Capture the preceding beat at that falling edge;
    // the following rising edge drives a single relay per DQ bit. The four
    // burst destinations are now a full clock away; ready64 shifts with data.
    sdram #(.REFRESH_CYCLES(490), .DQ_CAPTURE_NEGEDGE(1'b1), .DQ_PIPE(1)) memory (
        .clk(clk), .init(init), .refresh_req(1'b0),
        .ch2_addr(sd_half_addr), .ch2_din(sd_data), .ch2_be(sd_lanes),
        .ch2_rnw(!sd_write), .ch2_req(issue), .ch2_cancel(init),
        .ch2_dout(sd_read_data[31:0]), .ch2_dout_hi(sd_read_data[63:32]),
        .ch2_ready64(physical_done), .ch2_ready(), .ch2_ready16(),
        .ch1_addr(26'b0), .ch1_req(1'b0), .ch1_rnw(1'b1), .ch1_din(16'b0),
        .ch1_dout(), .ch1_accept(), .ch1_ready(),
        .ch3_addr(24'b0), .ch3_req(1'b0), .ch3_rnw(1'b1), .ch3_din(16'b0),
        .ch3_dout(), .ch3_ready(),
        .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_DQML, .SDRAM_DQMH,
        .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE, .SDRAM_CLK
    );
endmodule
