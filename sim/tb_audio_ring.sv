// tb_audio_ring: self-checking bench for the DDR3 audio pipe
// (rtl/nds_audio_ddr3.sv against the real rtl/ddram.sv).
//
// What it proves:
//  * silence is the reset state - with no magic word in DDR3 the module never
//    enables and never emits a frame, however long it is left running;
//  * every emitted frame is the next one the producer wrote, in order, with no
//    repeats, no drops and no reordering across the ring wrap;
//  * the output cadence is exactly FRAME_DIV cycles, forever, independent of
//    how badly the DDR3 port is being abused;
//  * starvation degrades correctly: underruns are counted only once the stream
//    has started, and when the producer comes back the stream RESUMES at the
//    next frame rather than skipping - frames are late, never lost;
//  * the rd_ptr/underrun writeback that the daemon steers by actually lands in
//    DDR3 and matches what was played;
//  * LOOP mode plays ring[k mod RING_FRAMES] forever with no producer at all -
//    the milestone-0 hardware test, run in sim first.
//
// The Avalon slave model randomises waitrequest, read latency and read-data
// gaps, and the framebuffer's 128-beat bursts plus ch1/ch2 traffic run
// throughout so ch3 never has the port to itself. The "daemon" writes the ring
// and the control word straight into the memory array on the negedge, which is
// exactly what the HPS does through /dev/mem - it does not go through ddram.
//
// Run: sim/run_audio_ring_tb.sh (iverilog -g2012). Prints "TB PASS" on success.

`timescale 1ns/1ns

module tb_audio_ring;

// DUT scaling: a 64-frame ring and a 64-cycle frame make the wrap, the FIFO
// refill and the starvation edge all reachable in a short sim. The FIFO is 16
// beats = 32 frames, so it holds HALF the ring here against ~1/256th of it in
// the shipping configuration - the refill path is stressed far harder than on
// hardware, not less.
localparam        RING_LOG2   = 6;
localparam        RING_FRAMES = 1 << RING_LOG2;
localparam        FRAME_DIV   = 64;
localparam        POLL_DIV    = 32;
localparam        STATUS_DIV  = 128;

localparam [27:1] AUD_HW_BASE = 27'h7FE8000;   // byte 0x0FFD0000 >> 1
localparam [27:1] RING_OFF    = 27'h0000080;   // byte 0x100 >> 1

// ---------------- clock ----------------
reg clk_sys = 0;
always #16 clk_sys = ~clk_sys;

// ---------------- error accounting ----------------
integer errors = 0;
task failf;
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

// ---------------- DUT ----------------
reg         reset = 1;

wire [15:0] sample_l, sample_r;
wire        sample_stb;
wire [15:0] underruns;
wire        enabled;

wire [27:1] au3_addr;
wire [63:0] au3_din;
wire        au3_req, au3_rnw;
wire  [7:0] au3_be;
wire [63:0] au3_dout;
wire        au3_ready;

nds_audio_ddr3 #(
	.AUD_HW_BASE(AUD_HW_BASE), .RING_OFF(RING_OFF), .RING_LOG2(RING_LOG2),
	.FRAME_DIV(FRAME_DIV), .POLL_DIV(POLL_DIV), .STATUS_DIV(STATUS_DIV)
) u_aud (
	.clk_sys(clk_sys), .reset(reset),
	.sample_l(sample_l), .sample_r(sample_r), .sample_stb(sample_stb),
	.underruns(underruns), .enabled(enabled),
	.au3_addr(au3_addr), .au3_din(au3_din), .au3_req(au3_req),
	.au3_rnw(au3_rnw), .au3_be(au3_be),
	.au3_dout(au3_dout), .au3_ready(au3_ready)
);

// ---------------- competing traffic: fb bursts + ch1/ch2 ----------------
localparam [27:1] FB_HW_BASE = 27'h7F00000;   // byte 0x0FE00000 >> 1
localparam  [7:0] FB_BURST   = 8'd128;
localparam [27:1] FW_HW_BASE = 27'h7F80000;   // byte 0x0FF00000 >> 1

reg  [27:1] ch1_addr = 0;
reg  [15:0] ch1_din = 0;
reg         ch1_req = 0, ch1_rnw = 1;
wire [63:0] ch1_dout;
wire        ch1_ready;

reg  [27:1] ch2_addr = 0;
reg         ch2_req = 0;
wire [31:0] ch2_dout;
wire        ch2_ready;

reg  [27:1] fb5_addr = 0;
reg  [63:0] fb5_din = 0;
reg         fb5_req = 0;
wire        fb5_next, fb5_ready;

reg  [27:1] fb6_addr = 0;
reg         fb6_req = 0;
wire [63:0] fb6_dout;
wire        fb6_valid, fb6_ready;

wire        DDRAM_BUSY;
wire  [7:0] DDRAM_BURSTCNT;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DOUT;
wire        DDRAM_DOUT_READY;
wire        DDRAM_RD;
wire [63:0] DDRAM_DIN;
wire  [7:0] DDRAM_BE;
wire        DDRAM_WE;

ddram u_ddram (
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

	.ch3_addr(au3_addr), .ch3_din(au3_din), .ch3_req(au3_req),
	.ch3_rnw(au3_rnw), .ch3_be(au3_be),
	.ch3_dout(au3_dout), .ch3_ready(au3_ready),

	.ch4_addr(27'd0), .ch4_din(64'd0), .ch4_req(1'b0), .ch4_rnw(1'b1),
	.ch4_be(8'd0), .ch4_dout(), .ch4_ready(),

	.ch5_addr(fb5_addr), .ch5_din(fb5_din), .ch5_req(fb5_req),
	.ch5_burst(FB_BURST), .ch5_next(fb5_next), .ch5_ready(fb5_ready),

	.ch6_addr(fb6_addr), .ch6_burst(FB_BURST), .ch6_req(fb6_req),
	.ch6_dout(fb6_dout), .ch6_valid(fb6_valid), .ch6_ready(fb6_ready)
);

// ---------------- Avalon DDR3 slave model ----------------
// models 0x0F000000..0x0FFFFFFF, the span holding fb, fw and the audio region
localparam [24:0] MEM_BASE_BEAT = 25'h1E00000;    // byte 0x0F000000 >> 3
localparam [24:0] AUD_BEAT0     = 25'h1FFA000 - MEM_BASE_BEAT;  // byte 0x0FFD0000
localparam [24:0] AUD_RINGB0    = AUD_BEAT0 + 25'd32;           // + byte 0x100

reg [63:0] mem[0:2097151];
integer    mi;
initial begin
	for (mi = 0; mi < 2097152; mi = mi + 1) mem[mi] = 64'hDEAD_BEEF_DEAD_BEEF;
	// the control beats start as plain zero: no magic, so the DUT must stay off
	mem[AUD_BEAT0]     = 64'd0;
	mem[AUD_BEAT0 + 1] = 64'd0;
end

integer busy_pct = 25;
integer gap_pct  = 15;

reg        busy_r = 0;
reg [63:0] dout_r = 0;
reg        dout_v = 0;
reg [24:0] wr_idx = 0, wr_cmd_addr = 0;
integer    wr_left = 0;
reg [24:0] rd_idx = 0;
integer    rd_left = 0, rd_lat = 0;

assign DDRAM_BUSY       = busy_r;
assign DDRAM_DOUT       = dout_r;
assign DDRAM_DOUT_READY = dout_v;

wire [24:0] beat_idx = DDRAM_ADDR[24:0] - MEM_BASE_BEAT;

integer b;
always @(posedge clk_sys) begin
	busy_r <= (($urandom % 100) < busy_pct);
	dout_v <= 0;

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
		wr_idx  = wr_idx + 1;
		wr_left = wr_left - 1;
	end

	if (DDRAM_RD && !busy_r) begin
		if (rd_left != 0) fail("read command while a burst is in flight");
		if (wr_left != 0) fail("read command while a write burst is in flight");
		rd_idx  = beat_idx;
		rd_left = DDRAM_BURSTCNT;
		rd_lat  = 4 + ($urandom % 9);
	end

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

// ---------------- competing-traffic drivers ----------------
// The point is port pressure, not correctness of these clients - tb_fb_pager
// already proves the framebuffer path. Everything here stays clear of the audio
// region so a stray write can never fake a passing audio check.
reg [63:0] fbfeed = 0;
always @(posedge clk_sys) if (fb5_next) fbfeed <= fbfeed + 64'd1;
always @(posedge clk_sys) fb5_din <= fbfeed;

initial begin : fbdrv
	forever begin
		repeat (200 + ($urandom % 400)) @(posedge clk_sys);
		fb5_addr <= FB_HW_BASE + (($urandom % 128) * 512);
		fb5_req  <= 1;
		@(posedge clk_sys);
		fb5_req <= 0;
		@(posedge fb5_ready);
		repeat (200 + ($urandom % 400)) @(posedge clk_sys);
		fb6_addr <= FB_HW_BASE + (($urandom % 128) * 512);
		fb6_req  <= 1;
		@(posedge clk_sys);
		fb6_req <= 0;
		@(posedge fb6_ready);
	end
end

initial begin : ch12drv
	forever begin
		repeat (40 + ($urandom % 200)) @(posedge clk_sys);
		ch1_addr <= FW_HW_BASE + ($urandom % 1024);
		ch1_rnw  <= 1;
		ch1_req  <= 1;
		@(posedge clk_sys);
		ch1_req <= 0;
		@(posedge ch1_ready);
		repeat (40 + ($urandom % 200)) @(posedge clk_sys);
		ch2_addr <= FW_HW_BASE + ($urandom % 1024);
		ch2_req  <= 1;
		@(posedge clk_sys);
		ch2_req <= 0;
		@(posedge ch2_ready);
	end
end

// ---------------- reference content ----------------
// Frame content is a function of the FREE-RUNNING frame number, not of the ring
// slot, so a wrap that replayed a stale slot would be caught immediately.
function [31:0] frame_val(input [31:0] f);      // {right, left}
	frame_val = {f[15:0] ^ 16'h5A5A, f[15:0] ^ 16'hA5A5};
endfunction
// LOOP content is a function of the SLOT, since loop playback has no producer
// and repeats the ring forever by design.
function [31:0] slot_val(input [31:0] s);
	slot_val = {s[15:0] ^ 16'h3C3C, s[15:0] ^ 16'hC3C3};
endfunction

// ---------------- the "daemon": writes memory directly, like /dev/mem ----------------
integer prod_ptr = 0;        // frames written
reg     daemon_run = 0;      // gate for the starvation phase
reg     loop_phase = 0;

task put_frame(input integer f, input [31:0] v);
	reg [24:0] beat;
	begin
		beat = AUD_RINGB0 + ((f % RING_FRAMES) >> 1);
		if (f[0]) mem[beat][63:32] = v;
		else      mem[beat][31:0]  = v;
	end
endtask

task set_ctrl(input [15:0] flags, input [31:0] wp);
	begin
		mem[AUD_BEAT0] = {16'hAD10, flags, wp};
	end
endtask

// the consumer beat as the daemon would see it through its own mmap
wire [31:0] dut_rd_ptr     = mem[AUD_BEAT0 + 1][31:0];
wire [15:0] dut_underruns  = mem[AUD_BEAT0 + 1][47:32];
wire [15:0] dut_cons_magic = mem[AUD_BEAT0 + 1][63:48];

// The producer keeps the ring topped up but never writes past what the DUT has
// already consumed - it steers by the rd_ptr the DUT publishes, exactly as the
// ARM daemon will. Frames are written two at a time to honour the even-wr_ptr
// rule the protocol requires.
initial begin : daemon
	forever begin
		@(negedge clk_sys);
		if (daemon_run && !loop_phase) begin
			if ((prod_ptr - dut_rd_ptr) <= (RING_FRAMES - 4)) begin
				put_frame(prod_ptr,     frame_val(prod_ptr));
				put_frame(prod_ptr + 1, frame_val(prod_ptr + 1));
				prod_ptr = prod_ptr + 2;
				set_ctrl(16'h0001, prod_ptr);      // ENABLE
			end
		end
	end
end

// ---------------- white-box FIFO invariant ----------------
// The beat FIFO holds at most 16, so f_wr - f_rd is in [0, 16] at every instant
// there has ever been. Anything above that means the two writers of f_rd/f_wr
// desynchronised, which shows up downstream as f_full stuck high and fetching
// stopped forever - a silent core that no restart recovers. Checked every cycle
// rather than by a scenario, because the window where it could happen is one
// cycle wide and no realistic stimulus reliably lands on it.
always @(posedge clk_sys) begin
	if (u_aud.f_cnt > 5'd16) begin
		$display("FAIL @%0t: FIFO count %0d out of range (f_wr=%0d f_rd=%0d)",
		         $time, u_aud.f_cnt, u_aud.f_wr, u_aud.f_rd);
		failf;
	end
end

// ---------------- output checker ----------------
integer frames_out   = 0;    // frames emitted in the current streaming phase
integer stb_gap      = 0;
integer last_stb     = -1;
integer cadence_chk  = 0;
integer underrun_seen = 0;
reg     check_stream = 0;    // phase 1/2: content follows frame_val
reg     check_loop   = 0;    // phase 3: content follows slot_val
reg     check_free   = 0;    // phase 4: cadence and liveness only
integer loop_base    = 0;    // frames_out value at which loop playback started

always @(posedge clk_sys) begin
	if (sample_stb) begin
		// cadence: exactly FRAME_DIV cycles between consecutive frames. Checked
		// across every phase including starvation - a starved frame slot must
		// still tick, it just does not emit, so gaps are always a multiple of
		// FRAME_DIV.
		if (last_stb >= 0) begin
			stb_gap = ($time - last_stb) / 32;   // 32ns per clk_sys period
			if ((stb_gap % FRAME_DIV) != 0) begin
				$display("FAIL @%0t: frame gap %0d is not a multiple of %0d",
				         $time, stb_gap, FRAME_DIV);
				failf;
			end
			else cadence_chk = cadence_chk + 1;
		end
		last_stb = $time;

		if (check_stream) begin
			if ({sample_r, sample_l} !== frame_val(frames_out)) begin
				$display("FAIL @%0t: frame %0d got {r,l}=%h want %h",
				         $time, frames_out, {sample_r, sample_l},
				         frame_val(frames_out));
				failf;
			end
			frames_out = frames_out + 1;
		end
		else if (check_loop) begin
			if ({sample_r, sample_l} !== slot_val((frames_out - loop_base) % RING_FRAMES)) begin
				$display("FAIL @%0t: loop frame %0d got {r,l}=%h want %h",
				         $time, frames_out - loop_base, {sample_r, sample_l},
				         slot_val((frames_out - loop_base) % RING_FRAMES));
				failf;
			end
			frames_out = frames_out + 1;
		end
		else if (check_free) begin
			frames_out = frames_out + 1;
		end
		else begin
			fail("a frame was emitted while the DUT should have been silent");
		end
	end
end

// ---------------- phases ----------------
integer i, j;
integer ur_at_stall, frames_at_stall;

initial begin : phases
	repeat (10) @(posedge clk_sys);
	reset <= 0;

	// -- phase 0: no magic word anywhere. Nothing may happen.
	$display("phase 0: silence without a magic word");
	repeat (20 * FRAME_DIV) @(posedge clk_sys);
	if (enabled)          fail("enabled with no magic word in DDR3");
	if (sample_l !== 0 || sample_r !== 0) fail("non-zero output while disabled");
	if (underruns !== 0)  fail("underruns counted while disabled");
	// a wrong magic must be rejected just as firmly as none
	@(negedge clk_sys);
	mem[AUD_BEAT0] = {16'hAD00, 16'h0001, 32'd64};
	repeat (20 * FRAME_DIV) @(posedge clk_sys);
	if (enabled) fail("enabled on a WRONG magic word");

	// -- phase 1: streaming
	$display("phase 1: streaming");
	@(negedge clk_sys);
	mem[AUD_BEAT0] = 64'd0;              // clear, so ENABLE makes a clean 0->1
	prod_ptr = 0;
	for (i = 0; i < RING_FRAMES - 4; i = i + 1) put_frame(i, frame_val(i));
	prod_ptr = RING_FRAMES - 4;
	check_stream = 1;
	set_ctrl(16'h0001, prod_ptr);
	daemon_run = 1;

	wait (frames_out >= 1500);
	if (underruns !== 0) begin
		$display("FAIL: %0d underruns while the producer kept up", underruns);
		failf;
	end
	// the published pointer must track what was played, within one writeback
	if (dut_cons_magic !== 16'hAD11) fail("consumer beat has no magic word");
	if ((frames_out - dut_rd_ptr) > (STATUS_DIV / FRAME_DIV + 4) || dut_rd_ptr > frames_out) begin
		$display("FAIL: rd_ptr writeback %0d vs %0d frames played",
		         dut_rd_ptr, frames_out);
		failf;
	end

	// -- phase 2: starve it, then resume
	$display("phase 2: starvation and resume");
	daemon_run       = 0;
	frames_at_stall  = frames_out;
	// Drain the ring and the FIFO, then sit starved long enough for the ramp to
	// finish: ~64 frames of ring+FIFO, then ~470 frames of decay from whatever
	// amplitude the last frame happened to be at.
	repeat (900 * FRAME_DIV) @(posedge clk_sys);
	if (underruns == 0) fail("no underruns counted while starved");
	if (sample_l !== 0 || sample_r !== 0)
		fail("output did not decay to zero while starved");
	ur_at_stall = underruns;
	daemon_run  = 1;
	// resume must continue the sequence: the checker is still comparing against
	// frame_val(frames_out), so any skipped or repeated frame fails here
	wait (frames_out >= frames_at_stall + 400);
	if (underruns < ur_at_stall) fail("underrun counter went backwards");

	// -- phase 3: LOOP mode, no producer at all
	$display("phase 3: loop mode");
	daemon_run   = 0;
	@(negedge clk_sys);
	set_ctrl(16'h0000, 32'd0);           // ENABLE low: forces a clean restart
	repeat (4 * POLL_DIV) @(posedge clk_sys);
	if (enabled) fail("still enabled after ENABLE was cleared");
	check_stream = 0;
	@(negedge clk_sys);
	for (i = 0; i < RING_FRAMES; i = i + 1) put_frame(i, slot_val(i));
	loop_phase = 1;
	loop_base  = frames_out;
	check_loop = 1;
	set_ctrl(16'h0003, 32'd0);           // ENABLE | LOOP, wr_ptr ignored
	ur_at_stall = underruns;

	// four full wraps with no producer keeping up at all
	wait (frames_out >= loop_base + 4 * RING_FRAMES);
	if (underruns !== 0)
		fail("loop mode underran - it must never consult wr_ptr");

	// -- phase 4: daemon restarts. This is the path the ARM takes every time it
	// starts, dies or resyncs, and it is where the pointer bookkeeping is
	// easiest to corrupt - the ENABLE flush and the FIFO pop both write f_rd.
	// Content is not re-checked here (phases 1-3 own that); what is checked is
	// that every restart still produces frames, on cadence, from a rebased
	// rd_ptr. The f_rd collision itself is guarded by the always-on FIFO
	// invariant below rather than by this phase: the two writers can only
	// coincide in a one-cycle window that a randomised soak does not reliably
	// reach, so a passing phase 4 is NOT evidence that the gate in the DUT is
	// present. Do not read it as one.
	$display("phase 4: daemon restarts");
	check_loop   = 0;
	check_free   = 1;
	loop_phase   = 0;
	for (i = 0; i < 8; i = i + 1) begin
		// Stop the producer and let its negedge process go quiet BEFORE
		// touching the control word. Both write mem[AUD_BEAT0], and if the
		// clear shares a timestep with a top-up the daemon can re-assert
		// ENABLE straight back - a bench race that reads exactly like the DUT
		// ignoring the disable.
		daemon_run = 0;
		repeat (2) @(posedge clk_sys);
		@(negedge clk_sys);
		mem[AUD_BEAT0] = {16'hAD10, 16'h0000, 32'd0};    // flags first: ENABLE off
		// stop for a randomised span so the restart lands at a different point
		// in the fetch/pop cycle each time. The floor covers several poll
		// periods plus a DDR3 round trip, since a poll queues behind fetches.
		repeat (16 * POLL_DIV + ($urandom % 300)) @(posedge clk_sys);
		if (enabled) fail("still enabled well after ENABLE was cleared");

		@(negedge clk_sys);
		prod_ptr = 0;
		for (j = 0; j < RING_FRAMES - 4; j = j + 1) put_frame(j, frame_val(j));
		prod_ptr = RING_FRAMES - 4;
		set_ctrl(16'h0001, prod_ptr);
		daemon_run = 1;

		frames_at_stall = frames_out;
		repeat (500 * FRAME_DIV) @(posedge clk_sys);
		if ((frames_out - frames_at_stall) < 400) begin
			$display("FAIL: restart %0d produced only %0d frames in 500 slots",
			         i, frames_out - frames_at_stall);
			failf;
		end
		if (dut_rd_ptr > (frames_out - frames_at_stall) + 8) begin
			$display("FAIL: restart %0d did not rebase rd_ptr (published %0d)",
			         i, dut_rd_ptr);
			failf;
		end
	end

	// -- phase 5: producer rewinds wr_ptr without clearing ENABLE. This is what
	// a daemon that crashed and restarted looks like from the FPGA side, and it
	// underflows wr_ptr - fetch_ptr into a huge unsigned `avail`. The DUT must
	// refuse to fetch and go quiet, not stream a ring of garbage at full volume.
	$display("phase 5: producer rewinds wr_ptr with ENABLE still set");
	daemon_run = 0;
	repeat (2) @(posedge clk_sys);
	@(negedge clk_sys);
	set_ctrl(16'h0001, 32'd4);           // far behind fetch_ptr, ENABLE still high
	// let the FIFO and the ring in flight drain
	repeat (200 * FRAME_DIV) @(posedge clk_sys);
	if (!enabled) fail("phase 5 wanted ENABLE still set - the test proves nothing otherwise");
	frames_at_stall = frames_out;
	ur_at_stall     = underruns;
	repeat (200 * FRAME_DIV) @(posedge clk_sys);
	if (frames_out != frames_at_stall) begin
		$display("FAIL: kept emitting %0d frames on a rewound wr_ptr",
		         frames_out - frames_at_stall);
		failf;
	end
	if (underruns <= ur_at_stall) fail("rewound wr_ptr did not register as starvation");

	if (cadence_chk < 2000) begin
		$display("FAIL: suspiciously few cadence checks: %0d", cadence_chk);
		failf;
	end
	if (errors == 0)
		$display("TB PASS (%0d frames, %0d cadence checks, %0d underruns at exit)",
		         frames_out, cadence_chk, underruns);
	else
		$display("TB FAILED (%0d errors)", errors);
	$finish;
end

// watchdog
initial begin
	#400_000_000;
	$display("TB FAILED (watchdog: frames_out=%0d enabled=%0d underruns=%0d)",
	         frames_out, enabled, underruns);
	$finish;
end

endmodule
