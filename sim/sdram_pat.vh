// SPDX-License-Identifier: GPL-2.0-or-later
//
// Shared expected-data function for the SDRAM bench. Included by both
// sim/sdram_model.sv and sim/tb_sdram_ch.sv so the model and the checker cannot
// drift apart.
//
// Unwritten memory reads back as a function of the FULL halfword address
// {bank,row,col} = addr[24:1], and every one of those 24 bits feeds the result.
// That is deliberate: the alternative (a zero-filled array) would let a
// mis-mapped bank, row, column or burst-wrap bit read back plausible data, which
// is exactly the class of bug this bench exists to catch.
function [15:0] sdpat(input [23:0] ha);
   reg [15:0] x;
   begin
      x     = ha[15:0] ^ 16'hC33C;
      x     = x ^ {ha[23:16], 8'h00};
      x     = {x[7:0], x[15:8]} ^ {8'h00, ha[23:16]};
      sdpat = x ^ 16'h1234;
   end
endfunction
