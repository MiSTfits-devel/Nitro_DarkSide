
module nds_fb_ddr3 #(
	parameter [27:1] FB_HW_BASE = 27'h7F00000,
	parameter  [7:0] FB_BURST   = 8'd128
)(
	input             clk_sys,
	input             CLK_VIDEO,

	input       [7:0] pix_x,
	input       [7:0] pix_y,
	input      [17:0] pix_d,
	input             pix_we,
	input       [7:0] pixb_x,
	input       [7:0] pixb_y,
	input      [17:0] pixb_d,
	input             pixb_we,

	input      [17:0] dbg0,
	input      [17:0] dbg1,
	input      [17:0] dbg2,
	input      [17:0] dbg3,
	input      [17:0] dbg4,
	input      [17:0] dbg5,
	input      [17:0] dbg6,
	input      [17:0] dbg7,
	input      [17:0] dbg8,
	input      [17:0] dbg9,
	input      [17:0] dbg10,
	input      [17:0] dbg11,

	input             pf_tgl,
	input             pf_scr,
	input       [7:0] pf_line,
	input             pf_bank,

	input       [7:0] lb_raddr,
	output reg [35:0] lb_q,

	output     [27:1] fb5_addr,
	output     [63:0] fb5_din,
	output            fb5_req,
	input             fb5_next,
	input             fb5_ready,

	output     [27:1] fb6_addr,
	output            fb6_req,
	input      [63:0] fb6_dout,
	input             fb6_valid,
	input             fb6_ready
);

(* ramstyle = "M10K, no_rw_check" *) reg [35:0] acc_a[0:255];
(* ramstyle = "M10K, no_rw_check" *) reg [35:0] acc_b[0:255];
reg [17:0] hold_a, hold_b;
reg        bank_a = 0, bank_b = 0;
reg        job_tgl_a = 0, job_tgl_b = 0;
reg  [7:0] job_y_a, job_y_b;
reg        job_bank_a, job_bank_b;

always @(posedge clk_sys) begin
	if (pix_we) begin
		if (!pix_x[0]) hold_a <= pix_d;
		else           acc_a[{bank_a, pix_x[7:1]}] <= {pix_d, hold_a};
		if (pix_x == 8'd255) begin
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

reg        dbusy = 0;
reg        dscr;
reg  [7:0] dy;
reg        dbank;
reg  [6:0] widx;
reg  [7:0] dsent;
reg        drr = 0;
reg        ack_a = 0, ack_b = 0;
reg        fb5_req_r = 0;
reg        tjob = 0;
reg [21:0] telem_ctr = 0;
`ifdef NDS_FB_TELEMETRY
reg        telem_pending = 1;
`else
reg        telem_pending = 0;
`endif
wire       pend_a = job_tgl_a != ack_a;
wire       pend_b = job_tgl_b != ack_b;

wire        starting = !dbusy && (telem_pending || pend_a || pend_b);
wire        sel_bank = telem_pending                    ? 1'b0 :
                       (pend_a && (!pend_b || !drr))    ? job_bank_a : job_bank_b;
wire  [6:0] feed_idx = starting ? 7'd0 : (widx + (fb5_next ? 7'd1 : 7'd0));
wire  [7:0] racc     = {starting ? sel_bank : dbank, feed_idx};
reg  [35:0] acc_a_q, acc_b_q, telem_q_r;

always @(posedge clk_sys) begin
	acc_a_q   <= acc_a[racc];
	acc_b_q   <= acc_b[racc];
	telem_q_r <= (feed_idx == 7'd0) ? {dbg1, dbg0} :
	             (feed_idx == 7'd1) ? {dbg3, dbg2} :
	             (feed_idx == 7'd2) ? {dbg5, dbg4} :
	             (feed_idx == 7'd3) ? {dbg7, dbg6} :
	             (feed_idx == 7'd4) ? {dbg9, dbg8} :
	             (feed_idx == 7'd5) ? {dbg11, dbg10} : {36{1'b1}};
end

wire [35:0] acc_q = dscr ? acc_b_q : acc_a_q;

assign fb5_req  = fb5_req_r;
assign fb5_din  = tjob ? {14'd0, telem_q_r[35:18], 14'd0, telem_q_r[17:0]} :
	                       {14'd0, acc_q[35:18],   14'd0, acc_q[17:0]};
assign fb5_addr = FB_HW_BASE + {dscr, dy, 9'd0} + {17'd0, dsent, 2'd0};

always @(posedge clk_sys) begin
	telem_ctr <= telem_ctr + 1'd1;
`ifdef NDS_FB_TELEMETRY
	if (&telem_ctr) telem_pending <= 1;
`endif
	fb5_req_r <= 0;
	if (!dbusy) begin
		if (telem_pending) begin
			dscr          <= 0;
			dy            <= 8'd191;
			dbank         <= 0;
			widx          <= 0;
			dsent         <= 0;
			tjob          <= 1;
			telem_pending <= 0;
			fb5_req_r     <= 1;
			dbusy         <= 1;
		end
		else if (pend_a && (!pend_b || !drr)) begin
			dscr      <= 0;
			dy        <= job_y_a;
			dbank     <= job_bank_a;
			ack_a     <= job_tgl_a;
			drr       <= 1;
			widx      <= 0;
			dsent     <= 0;
			fb5_req_r <= 1;
			dbusy     <= 1;
			tjob      <= 0;
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
			tjob      <= 0;
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

reg [35:0] linebuf[0:255];
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

always @(posedge CLK_VIDEO) lb_q <= linebuf[lb_raddr];

endmodule
