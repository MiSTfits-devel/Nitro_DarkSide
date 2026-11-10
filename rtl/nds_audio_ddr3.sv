// Licensed under the repo LICENSE (see the LICENSE file at the repo root).

module nds_audio_ddr3 #(
	parameter [27:1] AUD_HW_BASE = 27'h7FE8000,
	parameter [27:1] RING_OFF    = 27'h0000080,
	parameter        RING_LOG2   = 13,
	parameter        FRAME_DIV   = 1024,
	parameter        POLL_DIV    = 512,
	parameter        STATUS_DIV  = 2048
)(
	input             clk_sys,
	input             reset,

	output reg [15:0] sample_l = 0,
	output reg [15:0] sample_r = 0,
	output reg        sample_stb = 0,

	output reg [15:0] underruns = 0,
	output            enabled,

	output reg [27:1] au3_addr = 0,
	output reg [63:0] au3_din = 0,
	output reg        au3_req = 0,
	output reg        au3_rnw = 1,
	output reg  [7:0] au3_be = 8'hFF,
	input      [63:0] au3_dout,
	input             au3_ready
);

localparam [15:0] MAGIC_PROD = 16'hAD10;
localparam [15:0] MAGIC_CONS = 16'hAD11;

localparam [31:0] RING_FRAMES = 32'd1 << RING_LOG2;

localparam [15:0] FRAME_END  = FRAME_DIV  - 1;
localparam [15:0] POLL_END   = POLL_DIV   - 1;
localparam [15:0] STATUS_END = STATUS_DIV - 1;

reg [31:0] wr_ptr   = 0;
reg        enable   = 0;
reg        loopmode = 0;
assign     enabled  = enable;

reg [31:0] fetch_ptr = 0;
reg [31:0] rd_ptr    = 0;

reg  [63:0] fbuf[0:15];
reg  [63:0] fbuf_q = 0;
reg   [4:0] f_wr = 0, f_rd = 0;
wire  [4:0] f_cnt  = f_wr - f_rd;
wire        f_full = f_cnt[4];

reg   [4:0] f_cnt_d1 = 0, f_cnt_d2 = 0;

reg [63:0] cur_beat = 0;
reg        cur_have = 0;
reg        cur_half = 0;
reg        primed   = 0;
reg [15:0] fdiv     = 0;

localparam [1:0] OP_NONE = 2'd0, OP_POLL = 2'd1, OP_FETCH = 2'd2, OP_STAT = 2'd3;
reg  [1:0] op = OP_NONE;
reg [15:0] poll_cnt = 0;
reg [15:0] stat_cnt = 0;
reg        poll_due = 1;
reg        stat_due = 0;

wire [31:0] avail     = wr_ptr - fetch_ptr;
wire        can_fetch = enable && !f_full &&
                        (loopmode || ((avail >= 32'd2) && (avail <= RING_FRAMES)));

wire [RING_LOG2-1:0] ring_idx = fetch_ptr[RING_LOG2-1:0];
wire [27:1] fetch_addr = AUD_HW_BASE + RING_OFF + {ring_idx[RING_LOG2-1:1], 2'b00};
wire [27:1] prod_addr  = AUD_HW_BASE;
wire [27:1] cons_addr  = AUD_HW_BASE + 27'd4;

wire        magic_ok   = (au3_dout[63:48] == MAGIC_PROD);
wire        want_en    = magic_ok & au3_dout[32];

function [15:0] decay_step(input [15:0] x);
	reg signed [16:0] e;
	begin
		e          = $signed({x[15], x}) + (x[15] ? 17'sd0 : 17'sd63);
		decay_step = (e >>> 6);
	end
endfunction

always @(posedge clk_sys) begin
	au3_req    <= 0;
	sample_stb <= 0;

	f_cnt_d1 <= f_cnt;
	f_cnt_d2 <= f_cnt_d1;
	fbuf_q   <= fbuf[f_rd[3:0]];

	if (poll_cnt == POLL_END) begin poll_cnt <= 0; poll_due <= 1; end
	else                            poll_cnt <= poll_cnt + 1'd1;
	if (stat_cnt == STATUS_END) begin stat_cnt <= 0; stat_due <= 1; end
	else                             stat_cnt <= stat_cnt + 1'd1;

	if (op == OP_NONE) begin
		if (can_fetch) begin
			au3_addr <= fetch_addr;
			au3_rnw  <= 1;
			au3_req  <= 1;
			op       <= OP_FETCH;
		end
		else if (poll_due) begin
			au3_addr <= prod_addr;
			au3_rnw  <= 1;
			au3_req  <= 1;
			op       <= OP_POLL;
			poll_due <= 0;
		end
		else if (stat_due) begin
			au3_addr <= cons_addr;
			au3_din  <= {MAGIC_CONS, underruns, rd_ptr};
			au3_be   <= 8'hFF;
			au3_rnw  <= 0;
			au3_req  <= 1;
			op       <= OP_STAT;
			stat_due <= 0;
		end
	end

	if (au3_ready) begin
		op <= OP_NONE;
		case (op)
			OP_FETCH: begin
				fbuf[f_wr[3:0]] <= au3_dout;
				f_wr            <= f_wr + 1'd1;
				fetch_ptr       <= fetch_ptr + 32'd2;
			end
			OP_POLL: begin
				enable <= want_en;
				if (magic_ok) begin
					loopmode <= au3_dout[33];
					wr_ptr   <= au3_dout[31:0];
				end
				if (want_en & ~enable) begin
					fetch_ptr <= 0;
					rd_ptr    <= 0;
					f_wr      <= 0;
					f_rd      <= 0;
					f_cnt_d1  <= 0;
					f_cnt_d2  <= 0;
					cur_have  <= 0;
					cur_half  <= 0;
					primed    <= 0;
					underruns <= 0;
				end
			end
			default: ;
		endcase
	end

	if (enable && !cur_have && (f_cnt_d2 != 0)) begin
		cur_beat <= fbuf_q;
		cur_have <= 1;
		f_rd     <= f_rd + 1'd1;
	end

	if (fdiv == FRAME_END) begin
		fdiv <= 0;
		if (!enable) begin
			sample_l <= 0;
			sample_r <= 0;
		end
		else if (cur_have) begin
			if (!cur_half) begin
				sample_l <= cur_beat[15:0];
				sample_r <= cur_beat[31:16];
				cur_half <= 1;
			end
			else begin
				sample_l <= cur_beat[47:32];
				sample_r <= cur_beat[63:48];
				cur_half <= 0;
				cur_have <= 0;
			end
			rd_ptr     <= rd_ptr + 1'd1;
			sample_stb <= 1;
			primed     <= 1;
		end
		else begin
			sample_l <= sample_l - decay_step(sample_l);
			sample_r <= sample_r - decay_step(sample_r);
			if (primed && (underruns != 16'hFFFF)) underruns <= underruns + 1'd1;
		end
	end
	else fdiv <= fdiv + 1'd1;

	if (reset) begin
		op        <= OP_NONE;
		au3_req   <= 0;
		enable    <= 0;
		loopmode  <= 0;
		wr_ptr    <= 0;
		fetch_ptr <= 0;
		rd_ptr    <= 0;
		f_wr      <= 0;
		f_rd      <= 0;
		f_cnt_d1  <= 0;
		f_cnt_d2  <= 0;
		cur_have  <= 0;
		cur_half  <= 0;
		primed    <= 0;
		underruns <= 0;
		fdiv      <= 0;
		poll_due  <= 1;
		stat_due  <= 0;
		sample_l  <= 0;
		sample_r  <= 0;
	end
end

endmodule
