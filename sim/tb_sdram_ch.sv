// SPDX-License-Identifier: GPL-2.0-or-later
//
// Channel bench for rtl/sdram.sv against sim/sdram_model.sv.
//
// rtl/sdram.sv had no simulation coverage at all in this tree before this file
// (sim/run_fb_pager_tb.sh exercises rtl/ddram.sv, the DDR3 controller, not this
// one), and the nvc frame sims replace it with a VHDL memory model. That is how
// a hardware-only defect in it stays invisible.
//
// The central check is deliberately the SYNCHRONOUS capture:
//
//     always @(posedge clk) if (ch1_ready) cap <= ch1_dout;
//
// because that is exactly what the real consumer does (NDS.sv:984,
// "if (vr_busy & sd_ch1_ready) vrsrv_dout_r <= sd_ch1_dout"). A bench that
// instead writes "@(posedge ch1_ready); check(ch1_dout);" samples a delta after
// the edge and so gets one extra cycle of settling that the hardware consumer
// never gets - it would pass while the core reads a stale word. Both captures
// are taken here and reported separately, so the difference between them is
// visible rather than assumed.
//
//   CLK_PS  9946 = 100.542 MHz (clkMem 3x, the deployable ratio)
//           7460 = 134.056 MHz (clkMem 4x)
//   TRCD_CK  required ACTIVE->READ gap in chip clocks; the controller's gap is
//            fixed at 2, so raising this shows what a faster clock demands.

`timescale 1ps/1ps

`ifndef CLK_PS
`define CLK_PS 9946
`endif
`ifndef TRCD_CK
`define TRCD_CK 2
`endif
`ifndef DQ_PIPE
`define DQ_PIPE 0
`endif
`ifndef CAS_LAT
`define CAS_LAT 2
`endif
`ifndef TRCD_WAIT
`define TRCD_WAIT 1
`endif

module tb_sdram_ch;

`include "sdram_pat.vh"

reg clk = 0;
always #(`CLK_PS/2) clk = ~clk;

reg init = 1;

// ---- DUT ports -------------------------------------------------------------
wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire        SDRAM_DQML, SDRAM_DQMH;
wire  [1:0] SDRAM_BA;
wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;

reg  [26:1] ch1_addr = 0;    wire [63:0] ch1_dout;   reg [15:0] ch1_din = 0;
reg         ch1_req  = 0;    reg         ch1_rnw = 1; wire       ch1_ready;

reg  [26:1] ch2_addr = 0;    wire [31:0] ch2_dout;   reg [31:0] ch2_din = 0;
reg   [3:0] ch2_be   = 4'hF; reg         ch2_req = 0; reg        ch2_cancel = 0;
reg         ch2_rnw  = 1;    wire        ch2_ready, ch2_ready16;

reg  [24:1] ch3_addr = 0;    wire [15:0] ch3_dout;   reg [15:0] ch3_din = 0;
reg         ch3_req  = 0;    reg         ch3_rnw = 1; wire       ch3_ready;

sdram #(.DQ_PIPE(`DQ_PIPE), .CAS_LATENCY(`CAS_LAT), .TRCD_WAIT(`TRCD_WAIT)) dut (
	.init(init), .clk(clk),
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
	.refresh_req(1'b0),
	.ch1_addr(ch1_addr), .ch1_dout(ch1_dout), .ch1_din(ch1_din),
	.ch1_req(ch1_req), .ch1_rnw(ch1_rnw), .ch1_ready(ch1_ready),
	.ch2_addr(ch2_addr), .ch2_dout(ch2_dout), .ch2_din(ch2_din), .ch2_be(ch2_be),
	.ch2_req(ch2_req), .ch2_cancel(ch2_cancel), .ch2_rnw(ch2_rnw),
	.ch2_ready(ch2_ready), .ch2_ready16(ch2_ready16),
	.ch3_addr(ch3_addr), .ch3_dout(ch3_dout), .ch3_din(ch3_din),
	.ch3_req(ch3_req), .ch3_rnw(ch3_rnw), .ch3_ready(ch3_ready)
);

sdram_model #(.TRCD_CK(`TRCD_CK)) mem (
	.clk_pin(SDRAM_CLK), .cke(SDRAM_CKE), .nCS(SDRAM_nCS),
	.nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE),
	.BA(SDRAM_BA), .A(SDRAM_A), .DQ(SDRAM_DQ)
);

// ---- captures --------------------------------------------------------------
// sync_* : what the real consumer sees (sample on the ready cycle)
// late_* : one cycle later, which is what a "@(posedge ready)" bench sees
reg [63:0] c1_sync, c1_late;  reg c1_got = 0;  reg r1_d = 0;
reg [31:0] c2_sync, c2_late;  reg c2_got = 0;  reg r2_d = 0;
reg [15:0] c3_sync, c3_late;  reg c3_got = 0;  reg r3_d = 0;

always @(posedge clk) begin
	if (ch1_ready) begin c1_sync <= ch1_dout; c1_got <= 1; end
	r1_d <= ch1_ready;  if (r1_d) c1_late <= ch1_dout;

	if (ch2_ready) begin c2_sync <= ch2_dout; c2_got <= 1; end
	r2_d <= ch2_ready;  if (r2_d) c2_late <= ch2_dout;

	if (ch3_ready) begin c3_sync <= ch3_dout; c3_got <= 1; end
	r3_d <= ch3_ready;  if (r3_d) c3_late <= ch3_dout;
end

// ---- expected data ---------------------------------------------------------
// ch1 and ch2 share a mapping: {2'b00, x, addr[25:1]} loads
//   BA = a[24:23], row = a[22:10], col = a[9:1]
function [15:0] expw(input [26:1] a, input integer k);
	reg [8:0] c;
	begin
		c    = {a[9:3], a[2:1] + k[1:0]};   // sequential burst wraps in its aligned quad
		expw = sdpat({a[24:23], a[22:10], c});
	end
endfunction

// ch3: {2'b00, rnw, addr[23:1], 2'b00} -> BA = a[22:21], row = a[20:8],
//      col = {a[7:1], 2'b00}
function [15:0] expw3(input [24:1] a, input integer k);
	reg [8:0] c;
	begin
		c     = {a[7:1], k[1:0]};
		expw3 = sdpat({a[22:21], a[20:8], c});
	end
endfunction

integer errors = 0, checks = 0;

task expectv(input [639:0] what, input [63:0] got, input [63:0] want);
	begin
		checks = checks + 1;
		if (got !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s", what);
			$display("         got  %h", got);
			$display("         want %h", want);
		end
		else $display("  ok   %0s", what);
	end
endtask

// ---- stimulus --------------------------------------------------------------
integer to;

task ch1_read(input [26:1] a);
	begin
		@(negedge clk);
		c1_got = 0; ch1_addr = a; ch1_rnw = 1; ch1_req = 1;
		@(negedge clk);
		ch1_req = 0;
		to = 0;
		while (!c1_got && to < 200) begin @(negedge clk); to = to + 1; end
		if (!c1_got) begin
			$display("  FAIL ch1 read %h: no ready within 200 clocks", a);
			errors = errors + 1;
		end
		repeat (3) @(negedge clk);   // let the late capture settle
	end
endtask

task ch2_access(input [26:1] a, input rnw, input [31:0] d, input [3:0] be);
	begin
		@(negedge clk);
		c2_got = 0; ch2_addr = a; ch2_rnw = rnw; ch2_din = d; ch2_be = be; ch2_req = 1;
		@(negedge clk);
		ch2_req = 0;
		to = 0;
		while (!c2_got && to < 200) begin @(negedge clk); to = to + 1; end
		if (!c2_got) begin
			$display("  FAIL ch2 %0s %h: no ready within 200 clocks", rnw ? "read" : "write", a);
			errors = errors + 1;
		end
		repeat (3) @(negedge clk);
	end
endtask

task ch3_read(input [24:1] a);
	begin
		@(negedge clk);
		c3_got = 0; ch3_addr = a; ch3_rnw = 1; ch3_req = 1;
		@(negedge clk);
		ch3_req = 0;
		to = 0;
		while (!c3_got && to < 200) begin @(negedge clk); to = to + 1; end
		if (!c3_got) begin
			$display("  FAIL ch3 read %h: no ready within 200 clocks", a);
			errors = errors + 1;
		end
		repeat (3) @(negedge clk);
	end
endtask

reg [26:1] a1;
reg [24:1] a3;
reg [63:0] w1;
reg [15:0] lo, hi;
integer    n;

initial begin
	$display("tb_sdram_ch: clk %0d ps | DQ_PIPE %0d | CAS_LATENCY %0d | TRCD_WAIT %0d | model tRCD %0d",
	         `CLK_PS, `DQ_PIPE, `CAS_LAT, `TRCD_WAIT, `TRCD_CK);

	repeat (5) @(negedge clk);
	init = 0;

	// power-up is 12100 clocks of NOPs interleaved with the init commands
	repeat (12600) @(negedge clk);
	$display("init done at %0t, model saw %0d refreshes", $time, mem.refreshes);

	$display("");
	$display("-- ch1, 8-byte aligned lines (what the renderer VRAM path issues) --");
	for (n = 0; n < 4; n = n + 1) begin
		case (n)
			0: a1 = 26'h0000004;
			1: a1 = 26'h0123454;
			2: a1 = 26'h1FFFFFC;
			3: a1 = 26'h0ABCDE0;
		endcase
		a1[2:1] = 2'b00;                       // 8-byte aligned line
		w1 = {expw(a1,3), expw(a1,2), expw(a1,1), expw(a1,0)};
		ch1_read(a1);
		$display("  addr %h", a1);
		expectv("ch1 sync capture (what NDS.sv:984 latches)", c1_sync, w1);
		expectv("ch1 late capture (one cycle later)        ", c1_late, w1);
	end

	$display("");
	$display("-- ch2 32-bit read --");
	ch2_access(26'h0044448, 1, 0, 4'hF);
	expectv("ch2 read sync capture", {32'd0, c2_sync},
	        {32'd0, expw(26'h0044448,1), expw(26'h0044448,0)});

	$display("");
	$display("-- ch2 write then read back --");
	ch2_access(26'h0044448, 0, 32'hDEADBEEF, 4'hF);
	ch2_access(26'h0044448, 1, 0, 4'hF);
	expectv("ch2 read-back of DEADBEEF", {32'd0, c2_sync}, {32'd0, 32'hDEADBEEF});

	$display("");
	$display("-- ch2 byte-enabled write: FFFFFFFF then 11223344 with be=0110 --");
	ch2_access(26'h0044460, 0, 32'hFFFFFFFF, 4'hF);
	ch2_access(26'h0044460, 0, 32'h11223344, 4'b0110);
	ch2_access(26'h0044460, 1, 0, 4'hF);
	expectv("ch2 byte-enabled merge", {32'd0, c2_sync}, {32'd0, 32'hFF2233FF});

	$display("");
	$display("-- ch3 16-bit read (low byte of burst words 0 and 2) --");
	a3 = 24'h123456;
	lo = expw3(a3, 0);
	hi = expw3(a3, 2);
	ch3_read(a3);
	expectv("ch3 read sync capture", {48'd0, c3_sync}, {48'd0, hi[7:0], lo[7:0]});

	$display("");
	$display("model: %0d reads, %0d writes, %0d refreshes, %0d protocol errors",
	         mem.reads, mem.writes, mem.refreshes, mem.errors);
	errors = errors + mem.errors;

	$display("");
	if (errors == 0) $display("TB PASS (%0d checks)", checks);
	else             $display("TB FAIL: %0d error(s) over %0d checks", errors, checks);
	$finish;
end

initial begin
	#2_000_000_000;   // 2 ms
	$display("TB FAIL: global timeout");
	$finish;
end

endmodule
