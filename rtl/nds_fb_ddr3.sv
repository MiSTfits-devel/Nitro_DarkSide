//
// nds_fb_ddr3.sv
// NDS_MiSTfits: DDR3-backed dual-screen framebuffer (M10K eviction).
//
// Write side (clk_sys): each 2D engine's merge drain (256 consecutive
// 1 px/cycle writes per line, monotonic x = 0..255, both engines at once)
// is pair-packed into a small per-engine MLAB line accumulator (2 banks);
// a drain FSM bursts finished lines to DDR3 through ddram ch5, whose
// ch5_next strobe advances the (asynchronous-read) feeder word index.
//
// Read side: the scanout (CLK_VIDEO) requests display line V+1 at the
// start of line V (toggle handshake into clk_sys); the pager bursts that
// line from DDR3 through ddram ch6 into a double-banked dual-clock line
// buffer, which the scanout reads by {bank, pair} address. Bank parity
// follows the display line index, so prefetch and display never share a
// bank. A drain (<10us even behind card traffic) always beats the
// engine's next line completion (>=56us), so one pending job per engine
// cannot overflow; a prefetch (<10us worst case) always beats its 31.8us
// scanout-line deadline.
//
// DDR3 layout: 32bpp {14'b0, BGR666} pixels, two per 64-bit beat;
// line = 1 KB, screen s at FB_HW_BASE(bytes) + s*0x40000.
//

module nds_fb_ddr3 #(
	parameter [27:1] FB_HW_BASE = 27'h7F00000,  // byte address 0x0FE00000 >> 1
	parameter  [7:0] FB_BURST   = 8'd128        // beats per command (divisor of 128)
)(
	input             clk_sys,
	input             CLK_VIDEO,

	// engine pixel streams (clk_sys)
	input       [7:0] pix_x,
	input       [7:0] pix_y,
	input      [17:0] pix_d,
	input             pix_we,
	input       [7:0] pixb_x,
	input       [7:0] pixb_y,
	input      [17:0] pixb_d,
	input             pixb_we,

	// scanout prefetch request (CLK_VIDEO): payload written with the toggle
	input             pf_tgl,
	input             pf_scr,
	input       [7:0] pf_line,
	input             pf_bank,

	// scanout fetch (CLK_VIDEO): pair address {bank, x[7:1]}, data next clock
	input       [7:0] lb_raddr,
	output reg [35:0] lb_q,

	// ddram ch5: framebuffer write bursts (clk_sys)
	output     [27:1] fb5_addr,
	output     [63:0] fb5_din,
	output            fb5_req,
	input             fb5_next,
	input             fb5_ready,

	// ddram ch6: scanout prefetch read bursts (clk_sys)
	output     [27:1] fb6_addr,
	output            fb6_req,
	input      [63:0] fb6_dout,
	input             fb6_valid,
	input             fb6_ready
);

// ---- write side: merge bursts -> pair-packed line accumulators ----
// MLAB (async read) so the ch5 burst feeder needs no read-latency
// pipeline; per engine: 2 banks x 128 pixel pairs, 36 bits each. The
// engine always writes the bank the drain is not reading.
(* ramstyle = "MLAB, no_rw_check" *) reg [35:0] acc_a[0:255];
(* ramstyle = "MLAB, no_rw_check" *) reg [35:0] acc_b[0:255];
reg [17:0] hold_a, hold_b;            // even pixel awaiting its odd partner
reg        bank_a = 0, bank_b = 0;
reg        job_tgl_a = 0, job_tgl_b = 0;
reg  [7:0] job_y_a, job_y_b;
reg        job_bank_a, job_bank_b;

always @(posedge clk_sys) begin
	if (pix_we) begin
		if (!pix_x[0]) hold_a <= pix_d;
		else           acc_a[{bank_a, pix_x[7:1]}] <= {pix_d, hold_a};
		if (pix_x == 8'd255) begin     // merge drain is monotonic 0..255
			job_tgl_a  <= ~job_tgl_a;
			job_y_a    <= pix_y;
			job_bank_a <= bank_a;
			bank_a     <= ~bank_a;
		end
	end
	if (pixb_we) begin
		if (!pixb_x[0]) hold_b <= pixb_d;
		else            acc_b[{bank_b, pixb_x[7:1]}] <= {pixb_d, hold_b};
		if (pixb_x == 8'd255) begin
			job_tgl_b  <= ~job_tgl_b;
			job_y_b    <= pixb_y;
			job_bank_b <= bank_b;
			bank_b     <= ~bank_b;
		end
	end
end

// ---- drain FSM: one pending line per engine -> ch5 write bursts ----
reg        dbusy = 0;
reg        dscr;                      // 0 = top screen (A), 1 = bottom (B)
reg  [7:0] dy;
reg        dbank;
reg  [6:0] widx;                      // feeder word (pixel pair) index
reg  [7:0] dsent;                     // beats already commanded this line
reg        drr = 0;                   // round-robin when both engines pend
reg        ack_a = 0, ack_b = 0;
reg        fb5_req_r = 0;
wire       pend_a = job_tgl_a != ack_a;
wire       pend_b = job_tgl_b != ack_b;

wire [35:0] acc_q = dscr ? acc_b[{dbank, widx}] : acc_a[{dbank, widx}];

assign fb5_req  = fb5_req_r;
assign fb5_din  = {14'd0, acc_q[35:18], 14'd0, acc_q[17:0]};
assign fb5_addr = FB_HW_BASE + {dscr, dy, 9'd0} + {17'd0, dsent, 2'd0};

always @(posedge clk_sys) begin
	fb5_req_r <= 0;
	if (!dbusy) begin
		if (pend_a && (!pend_b || !drr)) begin
			dscr      <= 0;
			dy        <= job_y_a;
			dbank     <= job_bank_a;
			ack_a     <= job_tgl_a;
			drr       <= 1;
			widx      <= 0;
			dsent     <= 0;
			fb5_req_r <= 1;
			dbusy     <= 1;
		end
		else if (pend_b) begin
			dscr      <= 1;
			dy        <= job_y_b;
			dbank     <= job_bank_b;
			ack_b     <= job_tgl_b;
			drr       <= 0;
			widx      <= 0;
			dsent     <= 0;
			fb5_req_r <= 1;
			dbusy     <= 1;
		end
	end
	else begin
		if (fb5_next) widx <= widx + 1'd1;
		if (fb5_ready) begin
			if (dsent + FB_BURST >= 8'd128) dbusy <= 0;
			else begin
				dsent     <= dsent + FB_BURST;
				fb5_req_r <= 1;
			end
		end
	end
end

// ---- read side: scanout line prefetch -> ch6 read bursts ----
reg [35:0] linebuf[0:255];            // dual-clock: pager writes, scanout reads
reg  [2:0] pf_sync = 0;
reg        pf_pend = 0;
reg        rbusy = 0;
reg        rscr;
reg  [7:0] rline;
reg        rbank;
reg  [6:0] rwidx;
reg  [7:0] rsent;
reg        fb6_req_r = 0;

assign fb6_req  = fb6_req_r;
assign fb6_addr = FB_HW_BASE + {rscr, rline, 9'd0} + {17'd0, rsent, 2'd0};

always @(posedge clk_sys) begin
	pf_sync <= {pf_sync[1:0], pf_tgl};
	fb6_req_r <= 0;
	if (pf_sync[2] != pf_sync[1]) pf_pend <= 1;
	if (pf_pend && !rbusy) begin
		// pf_* payload is stable: written with the toggle, sampled >=2
		// clk_sys later, next update >=31.8us away
		pf_pend   <= 0;
		rscr      <= pf_scr;
		rline     <= pf_line;
		rbank     <= pf_bank;
		rwidx     <= 0;
		rsent     <= 0;
		fb6_req_r <= 1;
		rbusy     <= 1;
	end
	if (rbusy && fb6_valid) begin
		linebuf[{rbank, rwidx}] <= {fb6_dout[49:32], fb6_dout[17:0]};
		rwidx <= rwidx + 1'd1;
	end
	if (rbusy && fb6_ready) begin
		if (rsent + FB_BURST >= 8'd128) rbusy <= 0;
		else begin
			rsent     <= rsent + FB_BURST;
			fb6_req_r <= 1;
		end
	end
end

// ---- scanout fetch: runs every clock, pair stable 4 clocks per dot ----
always @(posedge CLK_VIDEO) lb_q <= linebuf[lb_raddr];

endmodule
