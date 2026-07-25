// tb_fb_pager: self-checking bench for the DDR3 framebuffer path
// (rtl/nds_fb_ddr3.sv + the burst channels added to rtl/ddram.sv).
//
// What it proves:
//  * every displayed pixel equals what the engine drew for that
//    (screen, line, x) - tear-tolerant: the current or previous frame's
//    value for that line (single-buffered free-running scanout);
//  * every fb write beat landing in DDR3 carries exactly the pixels the
//    engine emitted (catches feeder/packing off-by-ones at the beat);
//  * prefetch always meets the scanout deadline and never fetches into
//    the bank being displayed;
//  * one-pending-job-per-engine never overflows;
//  * ch1 (fw-style 16-bit writes / beat reads) and ch2 (card-style cached
//    reads) keep working, checked, while fb bursts saturate the port -
//    the donor channels are regression-guarded.
//
// The Avalon slave model randomizes waitrequest, read latency and
// read-data gaps; readdatavalid is deliberately allowed while
// waitrequest is high (the reason ch6 collection is not BUSY-gated).
// Phases: frames 0-1 gentle, 2-3 heavy waitrequest, 4 ch1/ch2 hammer.
//
// Run: sim/run_fb_pager_tb.sh (iverilog -g2012). Prints "TB PASS" on
// success; any FAIL line is fatal at the end.

`timescale 1ns/1ns

module tb_fb_pager;

localparam N_FRAMES = 5;             // engine frames to run

// ---------------- clocks: 2:1, rising edges aligned ----------------
reg clk_sys = 0;
reg clk_vid = 1;
always #16 clk_sys = ~clk_sys;
always #8  clk_vid = ~clk_vid;

// ---------------- error accounting ----------------
integer errors = 0;
task failf;   // count + abort; the caller prints its own FAIL detail line
	begin
		errors = errors + 1;
		if (errors > 20) begin
			$display("TB FAILED: too many errors, aborting");
			$finish;
		end
	end
endtask
task fail(input [511:0] msg);
	begin
		$display("FAIL @%0t: %0s", $time, msg);
		failf;
	end
endtask

// ---------------- phase config ----------------
integer busy_pct = 20;               // Avalon waitrequest probability
integer gap_pct  = 15;               // read-beat gap probability
integer ch_gap_min = 40, ch_gap_max = 400;   // ch1/ch2 op spacing

// ---------------- DUT: nds_fb_ddr3 + ddram ----------------
localparam [27:1] FB_HW_BASE = 27'h7F00000;   // byte 0x0FE00000 >> 1
localparam  [7:0] FB_BURST   = 8'd128;
localparam [27:1] FW_HW_BASE = 27'h7F80000;   // byte 0x0FF00000 >> 1 (B's fw)
localparam [27:1] CD_HW_BASE = 27'h7A00000;   // byte 0x0F400000 >> 1 (pseudo-card)

reg   [7:0] pix_x = 0,  pixb_x = 0;
reg   [7:0] pix_y = 0,  pixb_y = 0;
reg  [17:0] pix_d = 0,  pixb_d = 0;
reg         pix_we = 0, pixb_we = 0;

reg         pf_tgl = 0;
reg         pf_scr = 0;
reg   [7:0] pf_line = 0;
reg         pf_bank = 0;
wire  [7:0] lb_raddr;
wire [35:0] lb_q;

// diagnostic telemetry words: distinct known values so the telemetry
// burst's shared-feeder beat alignment is checkable at the DDR write side
reg [17:0] dbg [0:11];
integer dbi;
initial for (dbi = 0; dbi < 12; dbi = dbi + 1) dbg[dbi] = 18'h10000 | dbi[17:0];

wire [27:1] fb5_addr, fb6_addr;
wire [63:0] fb5_din, fb6_dout;
wire        fb5_req, fb5_next, fb5_ready;
wire        fb6_req, fb6_valid, fb6_ready;

nds_fb_ddr3 #(.FB_HW_BASE(FB_HW_BASE), .FB_BURST(FB_BURST)) u_fb
(
	.clk_sys(clk_sys),
	.CLK_VIDEO(clk_vid),
	.pix_x(pix_x),   .pix_y(pix_y),   .pix_d(pix_d),   .pix_we(pix_we),
	.pixb_x(pixb_x), .pixb_y(pixb_y), .pixb_d(pixb_d), .pixb_we(pixb_we),
	.pf_tgl(pf_tgl), .pf_scr(pf_scr), .pf_line(pf_line), .pf_bank(pf_bank),
	.dbg0(dbg[0]),   .dbg1(dbg[1]),   .dbg2(dbg[2]),   .dbg3(dbg[3]),
	.dbg4(dbg[4]),   .dbg5(dbg[5]),   .dbg6(dbg[6]),   .dbg7(dbg[7]),
	.dbg8(dbg[8]),   .dbg9(dbg[9]),   .dbg10(dbg[10]), .dbg11(dbg[11]),
	.lb_raddr(lb_raddr), .lb_q(lb_q),
	.fb5_addr(fb5_addr), .fb5_din(fb5_din), .fb5_req(fb5_req),
	.fb5_next(fb5_next), .fb5_ready(fb5_ready),
	.fb6_addr(fb6_addr), .fb6_req(fb6_req), .fb6_dout(fb6_dout),
	.fb6_valid(fb6_valid), .fb6_ready(fb6_ready)
);

// ch1/ch2 tb drivers (fw / card stand-ins)
reg  [27:1] ch1_addr = 0;
reg  [15:0] ch1_din = 0;
reg         ch1_req = 0;
reg         ch1_rnw = 1;
wire [63:0] ch1_dout;
wire        ch1_ready;
reg  [27:1] ch2_addr = 0;
reg         ch2_req = 0;
wire [31:0] ch2_dout;
wire        ch2_ready;

wire        DDRAM_BUSY;
wire  [7:0] DDRAM_BURSTCNT;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DOUT;
wire        DDRAM_DOUT_READY;
wire        DDRAM_RD;
wire [63:0] DDRAM_DIN;
wire  [7:0] DDRAM_BE;
wire        DDRAM_WE;

ddram u_ddram
(
	.DDRAM_CLK(clk_sys),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),

	.ch1_addr(ch1_addr), .ch1_din(ch1_din), .ch1_req(ch1_req),
	.ch1_rnw(ch1_rnw), .ch1_dout(ch1_dout), .ch1_ready(ch1_ready),

	.ch2_addr(ch2_addr), .ch2_din(32'd0), .ch2_req(ch2_req),
	.ch2_rnw(1'b1), .ch2_dout(ch2_dout), .ch2_ready(ch2_ready),

	.ch3_addr(25'd0), .ch3_din(16'd0), .ch3_req(1'b0), .ch3_rnw(1'b1),
	.ch3_dout(), .ch3_ready(),

	.ch4_addr(27'd0), .ch4_din(64'd0), .ch4_req(1'b0), .ch4_rnw(1'b1),
	.ch4_be(8'd0), .ch4_dout(), .ch4_ready(),

	.ch5_addr(fb5_addr), .ch5_din(fb5_din), .ch5_req(fb5_req),
	.ch5_burst(FB_BURST), .ch5_next(fb5_next), .ch5_ready(fb5_ready),

	.ch6_addr(fb6_addr), .ch6_burst(FB_BURST), .ch6_req(fb6_req),
	.ch6_dout(fb6_dout), .ch6_valid(fb6_valid), .ch6_ready(fb6_ready)
);

// ---------------- reference data ----------------
function [17:0] px_hash(input scr, input integer frame, input integer y,
                        input integer x);
	reg [17:0] base;
	begin
		base = {frame[1:0], y[7:0], x[7:0]};
		px_hash = scr ? (base ^ 18'h2AAAA) : base;
	end
endfunction

// last frame the engine FINISHED writing per (screen, line)
integer last_frame[0:1][0:191];
// last frame whose drain fully LANDED in DDR3 per (screen, line)
integer landed[0:1][0:191];
integer li, lj;
initial for (li = 0; li < 2; li = li + 1)
	for (lj = 0; lj < 192; lj = lj + 1) begin
		last_frame[li][lj] = -1;
		landed[li][lj]     = -1;
	end

// ---------------- Avalon DDR3 slave model ----------------
// models the 16 MB span 0x0F000000..0x0FFFFFFF (fb + fw + pseudo-card)
localparam [24:0] MEM_BASE_BEAT = 25'h1E00000;    // byte 0x0F000000 >> 3
localparam [24:0] FB_BEAT0      = 25'h1FC0000 - MEM_BASE_BEAT;  // fb start
localparam [24:0] FB_BEATN      = FB_BEAT0 + 25'h10000;         // fb end (+512KB)

reg [63:0] mem[0:2097151];

function [63:0] init_beat(input [24:0] i);
	init_beat = {2{7'h2B, i}} ^ 64'hA5A5_5A5A_C3C3_3C3C;
endfunction
integer mi;
initial for (mi = 0; mi < 2097152; mi = mi + 1) mem[mi] = init_beat(mi[24:0]);

reg        busy_r = 0;
reg [63:0] dout_r = 0;
reg        dout_v = 0;
reg [24:0] wr_idx = 0;
reg [24:0] wr_cmd_addr = 0;
integer    wr_left = 0;
reg [24:0] rd_idx = 0;
integer    rd_left = 0;
integer    rd_lat = 0;

assign DDRAM_BUSY       = busy_r;
assign DDRAM_DOUT       = dout_r;
assign DDRAM_DOUT_READY = dout_v;

wire [24:0] beat_idx = DDRAM_ADDR[24:0] - MEM_BASE_BEAT;

// checks one accepted fb write beat against the engine-emitted pixels
task check_fb_beat(input [24:0] idx, input [63:0] din, input [7:0] be);
	integer s, y, pair, f;
	reg [24:0] fboff;
	reg [35:0] tw;
	begin
		fboff = idx - FB_BEAT0;
		s    = fboff[15];
		y    = fboff[14:7];
		pair = fboff[6:0];
		if (be != 8'hFF) fail("fb write with partial byte enables");
		if (u_fb.tjob) begin
			// diagnostic telemetry burst (screen 0, line 191): the shared
			// feeder must present the dbg words in the first 6 pairs, then
			// all-ones. This exercises the registered telem_q alignment.
			if (s != 0 || y != 191) fail("telemetry burst wrong target");
			tw = (pair == 0) ? {dbg[1],  dbg[0]}  :
			     (pair == 1) ? {dbg[3],  dbg[2]}  :
			     (pair == 2) ? {dbg[5],  dbg[4]}  :
			     (pair == 3) ? {dbg[7],  dbg[6]}  :
			     (pair == 4) ? {dbg[9],  dbg[8]}  :
			     (pair == 5) ? {dbg[11], dbg[10]} : {36{1'b1}};
			if (din !== {14'd0, tw[35:18], 14'd0, tw[17:0]}) begin
				$display("FAIL @%0t: telemetry beat pair=%0d got=%h", $time, pair, din);
				failf;
			end
		end
		else begin
			if (y > 191) fail("fb write beyond line 191");
			f = last_frame[s][y];
			if (f < 0) fail("fb write for a line never drawn");
			else begin
				if (din !== {14'd0, px_hash(s[0], f, y, pair*2+1),
				             14'd0, px_hash(s[0], f, y, pair*2)}) begin
					$display("FAIL @%0t: fb beat data s=%0d y=%0d pair=%0d f=%0d got=%h",
					         $time, s, y, pair, f, din);
					failf;
				end
				if (pair == 127) landed[s][y] = f;   // whole line is one burst
			end
		end
	end
endtask

integer b;
always @(posedge clk_sys) begin
	busy_r <= (($urandom % 100) < busy_pct);
	dout_v <= 0;

	// write beats: accepted when WE && !waitrequest
	if (DDRAM_WE && !busy_r) begin
		if (wr_left == 0) begin
			wr_idx      = beat_idx;
			wr_cmd_addr = DDRAM_ADDR[24:0];
			wr_left     = DDRAM_BURSTCNT;
			if (wr_idx >= 25'h200000) fail("write outside modeled span");
		end
		else if (DDRAM_ADDR[24:0] !== wr_cmd_addr)
			fail("address moved during write burst");
		for (b = 0; b < 8; b = b + 1)
			if (DDRAM_BE[b]) mem[wr_idx][b*8 +: 8] = DDRAM_DIN[b*8 +: 8];
		if (wr_idx >= FB_BEAT0 && wr_idx < FB_BEATN)
			check_fb_beat(wr_idx, DDRAM_DIN, DDRAM_BE);
		wr_idx  = wr_idx + 1;
		wr_left = wr_left - 1;
	end

	// read command
	if (DDRAM_RD && !busy_r) begin
		if (rd_left != 0) fail("read command while a burst is in flight");
		if (wr_left != 0) fail("read command while a write burst is in flight");
		rd_idx  = beat_idx;
		rd_left = DDRAM_BURSTCNT;
		rd_lat  = 4 + ($urandom % 9);
	end

	// read beats: independent of waitrequest (deliberate)
	if (rd_left != 0) begin
		if (rd_lat != 0) rd_lat = rd_lat - 1;
		else if (($urandom % 100) >= gap_pct) begin
			dout_r  <= mem[rd_idx];
			dout_v  <= 1;
			rd_idx  = rd_idx + 1;
			rd_left = rd_left - 1;
		end
	end
end

// ---------------- engine stimulus ----------------
// per line: a 2130-cycle slot (63.6us at 33.5 MHz); the 256-pixel merge
// burst starts at a random offset. Engine B sometimes copies engine A's
// offset so the two bursts overlap exactly.
integer frames_done_a = 0, frames_done_b = 0;
integer off_a_cur = 0;

task automatic engine_line(input scr, input integer f, input integer y,
                           input integer off);
	integer x;
	begin
		repeat (off) @(posedge clk_sys);
		// previous job for this engine must be consumed by now
		if (scr == 0) begin
			if (u_fb.pend_a) fail("engine A job overflow (drain too slow)");
		end
		else begin
			if (u_fb.pend_b) fail("engine B job overflow (drain too slow)");
		end
		for (x = 0; x < 256; x = x + 1) begin
			if (scr == 0) begin
				pix_x <= x[7:0];
				pix_y <= y[7:0];
				pix_d <= px_hash(0, f, y, x);
				pix_we <= 1;
			end
			else begin
				pixb_x <= x[7:0];
				pixb_y <= y[7:0];
				pixb_d <= px_hash(1, f, y, x);
				pixb_we <= 1;
			end
			@(posedge clk_sys);
		end
		if (scr == 0) pix_we <= 0;
		else          pixb_we <= 0;
		last_frame[scr][y] = f;
		repeat (2130 - off - 256) @(posedge clk_sys);
	end
endtask

initial begin : eng_a
	integer f, y;
	repeat (60) @(posedge clk_sys);
	for (f = 0; f < N_FRAMES; f = f + 1) begin
		for (y = 0; y < 263; y = y + 1) begin
			if (y < 192) begin
				off_a_cur = $urandom % 1800;
				engine_line(0, f, y, off_a_cur);
			end
			else repeat (2130) @(posedge clk_sys);
		end
		frames_done_a = f + 1;
	end
end

initial begin : eng_b
	integer f, y, off;
	repeat (60) @(posedge clk_sys);
	for (f = 0; f < N_FRAMES; f = f + 1) begin
		for (y = 0; y < 263; y = y + 1) begin
			if (y < 192) begin
				off = (($urandom % 4) == 0) ? off_a_cur : ($urandom % 1800);
				engine_line(1, f, y, off);
			end
			else repeat (2130) @(posedge clk_sys);
		end
		frames_done_b = f + 1;
	end
end

// ---------------- scanout model (mirrors NDS.sv exactly) ----------------
localparam H_TOTAL  = 533;
localparam H_ACTIVE = 256;
localparam V_TOTAL  = 526;
localparam V_ACTIVE = 384;

reg  [9:0] hcnt = 0;
reg  [9:0] vcnt = 0;
reg  [1:0] ce_cnt = 0;
reg        lbq_sel = 0;
integer    checks_done = 0;
// landed[] snapshot taken when the prefetch for this bank was REQUESTED:
// the displayed content is some version in [landed@request, landed@display]
integer    pf_req_landed[0:1];
initial begin
	pf_req_landed[0] = -1;
	pf_req_landed[1] = -1;
end

wire [9:0] vnext = (vcnt == V_TOTAL-1) ? 10'd0 : vcnt + 10'd1;
wire [9:0] vpf   = (vnext == V_TOTAL-1) ? 10'd0 : vnext + 10'd1;
assign lb_raddr = {vcnt[0], hcnt[7:1]};

task check_pixel(input integer v, input integer x);
	integer s, line, f_lo, f_hi, f;
	reg [17:0] px;
	reg ok;
	begin
		s    = (v >= 192);
		line = s ? (v - 192) : v;
		px   = lbq_sel ? lb_q[35:18] : lb_q[17:0];
		f_lo = pf_req_landed[v[0]];
		f_hi = landed[s][line];
		if (f_lo >= 0) begin
			ok = 0;
			for (f = f_lo; f <= f_hi; f = f + 1)
				if (px === px_hash(s[0], f, line, x)) ok = 1;
			if (!ok) begin
				$display("FAIL @%0t: display s=%0d line=%0d x=%0d got=%h want f=%0d..%0d",
				         $time, s, line, x, px, f_lo, f_hi);
				failf;
			end
			else checks_done = checks_done + 1;
		end
	end
endtask

always @(posedge clk_vid) begin
	lbq_sel <= hcnt[0];
	ce_cnt  <= ce_cnt + 1'd1;
	if (ce_cnt == 2'd3) begin
		if (vcnt < V_ACTIVE && hcnt < H_ACTIVE) check_pixel(vcnt, hcnt);
		if (hcnt == H_TOTAL-1) begin
			hcnt <= 0;
			vcnt <= vnext;
			// deadline: the line about to display must not still be fetching
			if (vnext < V_ACTIVE && u_fb.rbusy && (u_fb.rbank == vnext[0]))
				fail("prefetch missed the scanout deadline");
			if (vpf < V_ACTIVE) begin
				if (u_fb.pf_pend) fail("prefetch request overrun (previous still pending)");
				pf_scr  <= (vpf >= 10'd192);
				pf_line <= (vpf >= 10'd192) ? (vpf[7:0] - 8'd192) : vpf[7:0];
				pf_bank <= vpf[0];
				pf_tgl  <= ~pf_tgl;
				pf_req_landed[vpf[0]] =
					landed[(vpf >= 192)][(vpf >= 192) ? (vpf - 192) : vpf];
			end
		end
		else hcnt <= hcnt + 1'd1;
	end
end

// ---------------- ch1 (fw-style) checked traffic ----------------
reg [15:0] fwmir[0:131071];          // 256 KB of halfwords, index = addr[17:1]
reg        fwvalid[0:131071];
integer    fi;
initial for (fi = 0; fi < 131072; fi = fi + 1) fwvalid[fi] = 0;

initial begin : ch1drv
	integer a, gap;
	reg [15:0] d;
	repeat (200) @(posedge clk_sys);
	forever begin
		gap = ch_gap_min + ($urandom % (ch_gap_max - ch_gap_min));
		repeat (gap) @(posedge clk_sys);
		a = $urandom % 131072;
		if (fwvalid[a] && (($urandom % 2) == 0)) begin
			// read at the exact halfword address; ch1_dout is the beat with
			// its 32-bit halves swapped by addr[2], so the addressed halfword
			// always lands at bit 16*addr[1] (= bit 0 of the offset)
			ch1_addr <= FW_HW_BASE + a[17:0];
			ch1_rnw  <= 1;
			ch1_req  <= 1;
			@(posedge clk_sys);
			ch1_req <= 0;
			@(posedge ch1_ready);
			#1;   // settle same-timestep NBA updates (ready and data land together)
			if (ch1_dout[16*a[0] +: 16] !== fwmir[a]) begin
				$display("FAIL @%0t: ch1 read a=%0h got=%h want=%h",
				         $time, a, ch1_dout[16*a[0] +: 16], fwmir[a]);
				failf;
			end
			@(posedge clk_sys);
		end
		else begin
			d = $urandom;
			ch1_addr <= FW_HW_BASE + a[17:0];
			ch1_din  <= d;
			ch1_rnw  <= 0;
			ch1_req  <= 1;
			@(posedge clk_sys);
			ch1_req <= 0;
			@(posedge ch1_ready);
			fwmir[a]   = d;
			fwvalid[a] = 1;
			@(posedge clk_sys);
		end
	end
end

// ---------------- ch2 (card-style) checked reads ----------------
task automatic ch2_read_check(input [27:1] a);
	reg [63:0] beat;
	reg [31:0] want;
	begin
		beat = init_beat(a[27:3] - MEM_BASE_BEAT);   // matches the slave's init
		want = a[2] ? beat[63:32] : beat[31:0];
		ch2_addr <= a;
		ch2_req  <= 1;
		@(posedge clk_sys);
		ch2_req <= 0;
		@(posedge ch2_ready);
		#1;   // settle same-timestep NBA updates (ready and data land together)
		if (ch2_dout !== want) begin
			$display("FAIL @%0t: ch2 read a=%h got=%h want=%h", $time, a, ch2_dout, want);
			failf;
		end
		@(posedge clk_sys);
	end
endtask

initial begin : ch2drv
	integer gap;
	reg [27:1] a;
	repeat (300) @(posedge clk_sys);
	forever begin
		gap = ch_gap_min + ($urandom % (ch_gap_max - ch_gap_min));
		repeat (gap) @(posedge clk_sys);
		a = CD_HW_BASE + (($urandom % 16384) * 2);
		ch2_read_check(a);          // cold read (burst-2 fill)
		ch2_read_check(a + 2);      // same-beat cache hit
		ch2_read_check(a + 4);      // next-beat prefetch hit
	end
end

// ---------------- phases + termination ----------------
initial begin : phases
	// 40% waitrequest is already far beyond the real f2sdram port's duty
	// under this core's ~66 MB/s total demand; at ~50%+ the port is
	// genuinely oversubscribed and the (assert-guarded) job overflow is
	// physics - a dropped line that self-heals the next frame.
	wait (frames_done_a >= 2 && frames_done_b >= 2);
	$display("phase 2: heavy waitrequest");
	busy_pct = 40;
	gap_pct  = 20;
	// B measured the fastest real card streaming at ~1 word-read per 146
	// clk1x cycles (0.56ms/512B block) and fw reads are SPI-byte-paced;
	// 24-96 cycle op gaps are still several times denser than that. The
	// donor channels outrank fb by design, so an unbounded hammer can
	// starve the drains - that is priority physics, not a pager bug.
	wait (frames_done_a >= 4 && frames_done_b >= 4);
	$display("phase 3: ch1/ch2 hammer");
	busy_pct   = 35;
	gap_pct    = 15;
	ch_gap_min = 24;
	ch_gap_max = 96;
end

initial begin : finisher
	wait (frames_done_a >= N_FRAMES && frames_done_b >= N_FRAMES);
	// let the last lines drain and display once more
	repeat (600000) @(posedge clk_sys);
	if (checks_done < 300000) begin
		$display("FAIL: suspiciously few display checks ran: %0d", checks_done);
		failf;
	end
	if (errors == 0) $display("TB PASS (%0d display checks)", checks_done);
	else             $display("TB FAILED (%0d errors)", errors);
	$finish;
end

// watchdog: absolute cap
initial begin
	#600_000_000;
	fail("watchdog timeout");
	$display("TB FAILED (watchdog)");
	$finish;
end
endmodule
