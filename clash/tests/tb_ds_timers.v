// SPDX-License-Identifier: GPL-3.0-or-later
// Replays TimersCheck --vectors through the Clash-generated nds_ds_timers.
// Line: rst tick valid write word lanes data chkR rdata chkI irq (hex).
// Inputs change after the rising edge; outputs are sampled before the next.
`timescale 1ns/1ps
module tb_ds_timers;
  reg clk = 0, rst = 1, tick = 0, valid = 0, write = 0;
  reg [1:0] word = 0;
  reg [3:0] lanes = 0;
  reg [31:0] data = 0;
  wire [31:0] rdata;
  wire [3:0] irq;
  integer fd, n, line = 0, errors = 0, reads = 0, pulses = 0;
  reg [31:0] f_rst, f_tick, f_valid, f_write, f_word, f_lanes, f_data, f_chkr, f_rdata, f_chki, f_irq;
  reg [8*512-1:0] path;

  nds_ds_timers dut (.CLK(clk), .RST(rst), .EN(1'b1), .TICK(tick), .REQ_VALID(valid),
                     .REQ_WRITE(write), .REQ_WORD(word), .REQ_LANES(lanes), .REQ_DATA(data),
                     .RDATA(rdata), .IRQ(irq));

  initial begin
    if (!$value$plusargs("vectors=%s", path)) begin
      $display("FAIL tb_ds_timers: +vectors=FILE required"); $finish;
    end
    fd = $fopen(path, "r");
    if (fd == 0) begin $display("FAIL tb_ds_timers: cannot open %0s", path); $finish; end
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h\n", f_rst, f_tick, f_valid, f_write,
                  f_word, f_lanes, f_data, f_chkr, f_rdata, f_chki, f_irq);
      if (n == 11) begin
        rst = f_rst[0]; tick = f_tick[0]; valid = f_valid[0]; write = f_write[0];
        word = f_word[1:0]; lanes = f_lanes[3:0]; data = f_data;
        #4;
        if (f_chkr[0]) begin
          reads = reads + 1;
          if (rdata !== f_rdata) begin
            errors = errors + 1;
            if (errors <= 5) $display("FAIL line %0d rdata %08x expected %08x", line, rdata, f_rdata);
          end
        end
        if (f_chki[0]) begin
          if (irq !== f_irq[3:0]) begin
            errors = errors + 1;
            if (errors <= 5) $display("FAIL line %0d irq %x expected %x", line, irq, f_irq[3:0]);
          end
          if (irq != 0) pulses = pulses + 1;
        end
        #1 clk = 1; #5 clk = 0;
        line = line + 1;
      end
    end
    if (errors == 0 && reads > 0 && pulses > 0)
      $display("PASS tb_ds_timers: %0d cycles, %0d reads, %0d irq cycles", line, reads, pulses);
    else
      $display("FAIL tb_ds_timers: %0d mismatches over %0d cycles (%0d reads, %0d irq cycles)", errors, line, reads, pulses);
    $finish;
  end
endmodule
