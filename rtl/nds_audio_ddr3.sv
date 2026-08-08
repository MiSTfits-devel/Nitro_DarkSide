// SPDX-License-Identifier: GPL-2.0-or-later
//
// nds_audio_ddr3.sv
// NDS_MiSTfits: DDR3 audio ring reader - the FPGA end of the HPS sound pipe.
//
// The SPU is moving off the fabric and onto the HPS ARM (see docs/HPS_AUDIO.md).
// This module is the half that stays: it drains a DDR3 ring the ARM fills, one
// 16-bit stereo frame per FRAME_DIV clk_sys cycles, and drives AUDIO_L/R. It
// knows nothing about the NDS - it is a plain sample transport, which is exactly
// why it can be brought up and proved before any SPU state moves anywhere.
//
// PROTOCOL (all little-endian 32-bit words; HPS address = FPGA address +
// 0x30000000, so the default base is HPS 0x3FFD0000)
//
//   +0x0000  wr_ptr    producer frame count, free-running, ARM writes
//   +0x0004  {magic 0xAD10, flags}      flags: bit0 ENABLE, bit1 LOOP
//   +0x0008  rd_ptr    consumer frame count, free-running, THIS writes
//   +0x000C  {magic 0xAD11, underruns}
//   +0x0100  ring: RING_FRAMES frames, each {int16 left, int16 right}
//
// The magic words are load-bearing in the same way the debug mailbox's are: an
// all-zero or stale DDR3 region must not read as "enabled", or a core built with
// this module would emit garbage on every machine that has never run the daemon.
// No magic, no audio - the reset state of the world is silence.
//
// FRAMING. wr_ptr must advance in multiples of 2 frames. Fetches are whole
// 64-bit beats and a beat is exactly 2 frames, so an odd wr_ptr would strand a
// frame until its partner arrived; requiring even counts removes the case
// instead of handling it. The ARM is producing in blocks of hundreds of frames
// anyway.
//
// STARTUP AND RESYNC. On the 0->1 edge of ENABLE both pointers are zeroed and
// the FIFO is flushed, so the contract is: fill the ring from frame 0, set
// wr_ptr, then set ENABLE. The FPGA can be reset out from under a running
// daemon (DDR3 survives reconfiguration), and then ENABLE is already set in
// memory when we come up - we resync to frame 0 and the daemon sees rd_ptr jump
// BACKWARDS. That is the agreed signal to restart the stream: clear ENABLE,
// re-prime from frame 0, set ENABLE again.
//
// LOOP is for bring-up: it ignores wr_ptr and walks the ring forever, so a ring
// prefilled by hand plays continuously with no daemon and no ARM toolchain in
// the picture. That is milestone 0's exit test.
//
// SLACK. Steady state is one beat fetched per 2*FRAME_DIV cycles (61us at
// 33.5 MHz) against a 16-beat FIFO, so the port may stall for ~977us before a
// sample is missed. For scale, the framebuffer pager next door is built on a
// worst case of ~10us, and ch3 outranks the mailbox and both framebuffer
// channels in ddram.sv's grant chain. Starvation here means the ARM stopped
// producing, not that DDR3 was slow, which is why the underrun counter is
// published rather than merely counted.

module nds_audio_ddr3 #(
	parameter [27:1] AUD_HW_BASE = 27'h7FE8000,  // byte 0x0FFD0000 >> 1
	parameter [27:1] RING_OFF    = 27'h0000080,  // byte 0x100 >> 1
	parameter        RING_LOG2   = 13,           // ring frames = 2^13 = 8192
	parameter        FRAME_DIV   = 1024,         // clk_sys per frame: 32.729 kHz
	parameter        POLL_DIV    = 512,          // control-beat poll period
	parameter        STATUS_DIV  = 2048          // rd_ptr writeback period
)(
	input             clk_sys,
	input             reset,

	// held between frames: the MiSTer framework samples these continuously
	output reg [15:0] sample_l = 0,
	output reg [15:0] sample_r = 0,
	output reg        sample_stb = 0,   // one clk_sys pulse per emitted frame

	// health taps
	output reg [15:0] underruns = 0,
	output            enabled,

	// ddram ch3: single-beat 64-bit R/W with byte enables. addr/din/be must be
	// HELD until ready - ddram samples them at grant, which can be many cycles
	// after the request pulse is latched into its ch_rq bit.
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

// ---------------- producer state, refreshed by the control poll ----------------
reg [31:0] wr_ptr   = 0;
reg        enable   = 0;
reg        loopmode = 0;
assign     enabled  = enable;

// ---------------- our two free-running frame counters ----------------
reg [31:0] fetch_ptr = 0;    // frames pulled out of DDR3 into the FIFO
reg [31:0] rd_ptr    = 0;    // frames handed to the output

// ---------------- beat FIFO ----------------
// Registered read so this infers an MLAB rather than 1024 flops behind a 16:1
// mux; an async-read array of this shape is exactly what blew the fitter up in
// FITTING.md round 2. Pops are >=FRAME_DIV cycles apart, so the read latency is
// invisible and the two-cycle-stale count below can only ever delay a pop.
reg  [63:0] fbuf[0:15];
reg  [63:0] fbuf_q = 0;
reg   [4:0] f_wr = 0, f_rd = 0;
wire  [4:0] f_cnt  = f_wr - f_rd;
wire        f_full = f_cnt[4];

// f_cnt delayed two cycles. One cycle covers "fbuf was written this edge, so
// fbuf_q still holds the old word"; the second covers the same hazard after
// f_rd itself moves. The count can only DROP on a pop, and a pop sets cur_have
// for at least FRAME_DIV cycles, so a stale-high count can never authorise a
// pop from an empty FIFO.
reg   [4:0] f_cnt_d1 = 0, f_cnt_d2 = 0;

// ---------------- output side ----------------
reg [63:0] cur_beat = 0;
reg        cur_have = 0;
reg        cur_half = 0;     // 0 = low frame of the beat, 1 = high frame
reg        primed   = 0;     // first frame emitted since ENABLE rose
reg [15:0] fdiv     = 0;

// ---------------- ddram request FSM ----------------
localparam [1:0] OP_NONE = 2'd0, OP_POLL = 2'd1, OP_FETCH = 2'd2, OP_STAT = 2'd3;
reg  [1:0] op = OP_NONE;
reg [15:0] poll_cnt = 0;
reg [15:0] stat_cnt = 0;
reg        poll_due = 1;     // poll once at power-up, before anything else
reg        stat_due = 0;

// The producer may not write more than RING_FRAMES ahead of rd_ptr, and
// fetch_ptr never trails rd_ptr, so a legal `avail` cannot exceed RING_FRAMES.
// A larger one means wr_ptr moved BACKWARDS and the subtraction underflowed -
// which is what a daemon that restarted without clearing ENABLE first looks
// like. Refusing to fetch turns that into silence instead of a ring's worth of
// garbage played at full volume, and silence is the far easier thing to
// diagnose. LOOP ignores wr_ptr entirely, so the bound does not apply there.
wire [31:0] avail     = wr_ptr - fetch_ptr;
wire        can_fetch = enable && !f_full &&
                        (loopmode || ((avail >= 32'd2) && (avail <= RING_FRAMES)));

wire [RING_LOG2-1:0] ring_idx = fetch_ptr[RING_LOG2-1:0];
// beat index is ring_idx >> 1; one beat is 8 bytes, i.e. 4 units of a [27:1]
// address, so the byte offset of the beat is {beat_index, 2'b00}
wire [27:1] fetch_addr = AUD_HW_BASE + RING_OFF + {ring_idx[RING_LOG2-1:1], 2'b00};
wire [27:1] prod_addr  = AUD_HW_BASE;
wire [27:1] cons_addr  = AUD_HW_BASE + 27'd4;

wire        magic_ok   = (au3_dout[63:48] == MAGIC_PROD);
wire        want_en    = magic_ok & au3_dout[32];   // flags bit 0

// Starvation ramp. A plain x - (x >>> 6) does NOT reach zero from the positive
// side: >>> is an arithmetic shift, so the step is floor(x/64), which is 0 for
// every x below 64 and parks the output on a DC step of up to 63 LSB. Biasing
// positive values by +63 before the shift rounds the step away from zero on
// both sides, so the ramp lands exactly on 0 and stays there. The 17-bit
// intermediate is not decoration - x + 63 overflows a signed 16-bit near full
// scale, and the sign flip would make a loud sample get LOUDER.
function [15:0] decay_step(input [15:0] x);
	reg signed [16:0] e;
	begin
		e          = $signed({x[15], x}) + (x[15] ? 17'sd0 : 17'sd63);
		decay_step = (e >>> 6);      // range [-512, 513], fits 16 bits
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

	// ---- issue: fetch outranks poll outranks status writeback. Fetch first
	// because it is the only op with a deadline; the other two are periodic and
	// a delayed poll costs nothing but latency on a pointer that is already
	// polled 60 times per emitted beat.
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

	// ---- completion
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
					loopmode <= au3_dout[33];       // flags bit 1
					wr_ptr   <= au3_dout[31:0];
				end
				// ENABLE 0->1: the ring is read from frame 0, per the contract
				// documented at the top. Everything in flight is dropped.
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

	// ---- refill the output beat register. cur_have drops with a whole frame
	// still to play, so this has FRAME_DIV cycles to complete, not zero.
	//
	// The `enable` gate closes a hazard by construction. This assignment to f_rd
	// sits AFTER the completion block, so if it ran on the cycle of the ENABLE
	// 0->1 flush it would win, leaving f_rd = old+1 against f_wr = 0; f_cnt then
	// reads as a large unsigned value, f_full sticks high and fetching stops for
	// good. Without the gate that state is in fact unreachable - only one ddram
	// op is ever in flight, so a push and the DISABLING poll cannot share a
	// cycle, no fetch is issued while disabled, and the refill therefore always
	// parks cur_have at 1 well before the next ENABLE edge arrives. That is a
	// three-step argument about ops in flight standing between this line and a
	// permanently silent core. `enable` still holds its pre-flush 0 on the flush
	// cycle, so the gate makes it a local invariant instead. It also stops the
	// FIFO quietly draining into cur_beat while the daemon is stopped, which was
	// never wanted either.
	if (enable && !cur_have && (f_cnt_d2 != 0)) begin
		cur_beat <= fbuf_q;
		cur_have <= 1;
		f_rd     <= f_rd + 1'd1;
	end

	// ---- output: one frame per FRAME_DIV cycles
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
			// Starved. Ramping to zero rather than holding the last value keeps
			// a stall from parking a DC offset on the output; tau is ~64
			// frames (~2 ms at 32.7 kHz), full scale to silence in ~14 ms.
			// Startup before the first frame is not an underrun, and is not
			// counted as one.
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
