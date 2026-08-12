// Licensed under the repo LICENSE (see the LICENSE file at the repo root).
//
// HPS lightweight-bridge slave: gives the ARM direct register access into the
// fabric at physical 0xFF200000, span 2 MB.
//
// WHY, and what it does NOT solve. The debug mailbox (see the DEBUG MAILBOX
// block in NDS.sv) rides two DDR3 beats on ddram ch4 and is polled once per
// 4096 clk_sys cycles, so a command round-trip costs ~122 us minimum and every
// poll steals a ch4 grant. Across this bridge a register access is ~150-300 ns
// (measured for h2f in NDS_3D_HPS_BRIEF.md), and reads of live state need no
// command protocol at all - they are just loads. That is ~100x on the mailbox
// and it is what makes a *live* counter readable from the HPS, which the
// renderer ticket asks for and DDR3 polling cannot give.
//
// It does NOT fix nds_debug's PEEK blindness to IO space. PEEK borrows the ARM9
// main-RAM channel, so IO/WRAM reads come back as convincing garbage; that is a
// property of the peek path inside nds_debug, not of this transport. Do not
// expect this bridge to make PEEK trustworthy for IO.
//
// UNVERIFIED ON HARDWARE: the HPS end of this bridge has to be un-reset and
// enabled by the running Linux (brgmodrst / the fpga2hps-hps2fpga bridge
// enables). NDS_3D_HPS_BRIEF.md already flagged h2f as "unproven on MiSTer
// (preloader may not enable it)". skmp's DreamSTer drives the lightweight
// bridge on MiSTer hardware, so there is precedent, but nothing here has been
// observed working on silicon yet. If the bridge is held in reset, an HPS access
// to 0xFF200000 does not return garbage - it HANGS the access, so the host tool
// must be prepared for that rather than assuming a read always completes.
//
// PROTOCOL NOTES
//
// The primitive is an AXI-3 master (the HPS drives it, we are the slave): 32-bit
// data, 21-bit byte address, 12-bit IDs, no reset port, one clock we supply.
// Port list taken from Quartus's own
//   libraries/megafunctions/xml_info/cyclonev_hps_interface_hps2fpga_light_weight_info.xml
// rather than from a datasheet, because guessing a WYSIWYG's ports costs a build
// each time. Note it differs from the full hps2fpga primitive, which has a
// 30-bit address, a configurable data width and a 2-bit clk.
//
// This slave handles ONE transaction at a time and deasserts both address
// readies while busy, which AXI permits and which keeps the state small. Bursts
// are supported by incrementing the word address, so INCR works; WRAP is not
// modelled and no MiSTer host tool issues one (devmem does single beats).
//
// reg_rdata is expected to be a COMBINATIONAL mux of reg_addr. At 33.5 MHz a
// small mux is comfortable, and it keeps the read path free of the one-cycle
// address/data skew a registered read would need.

module hps_lw_bridge
(
	input             clk,

	// Word-addressed register file. reg_addr is a WORD index (the AXI byte
	// address shifted right by 2), so bit 0 of reg_addr is 4 bytes.
	output     [18:0] reg_addr,
	output            reg_wr,
	output     [31:0] reg_wdata,
	output      [3:0] reg_wstrb,
	input      [31:0] reg_rdata
);

// ---- AXI-3 wires. Directions are named from the PRIMITIVE's point of view:
// what the XML calls OUTPUT is driven by the HPS and is an input to this slave.
wire [11:0] awid, arid, wid;
wire [20:0] awaddr, araddr;
wire  [3:0] awlen, arlen;
wire  [2:0] awsize, arsize, awprot, arprot;
wire  [1:0] awburst, arburst, awlock, arlock;
wire  [3:0] awcache, arcache;
wire        awvalid, arvalid, wvalid, wlast, bready, rready;
wire [31:0] wdata;
wire  [3:0] wstrb;

reg         awready = 0, arready = 0, wready = 0, bvalid = 0, rvalid = 0, rlast = 0;
reg  [11:0] bid = 0, rid = 0;

// Six states rather than four, because of one AXI rule that is easy to get
// wrong: if awready and arready are BOTH high while the master has both valids
// high, both addresses are accepted in that same cycle. A slave that then
// services only the write has silently dropped a read, and the master waits for
// rvalid forever. So exactly one ready is ever asserted, and the extra state is
// how the ready is raised only after the matching valid has been seen. valid is
// required to stay high until ready, so sampling the address a cycle later is safe.
localparam S_IDLE  = 3'd0, S_AW = 3'd1, S_WDATA = 3'd2,
           S_BRESP = 3'd3, S_AR = 3'd4, S_RDATA = 3'd5;
reg  [2:0]  state = S_IDLE;
reg [20:2]  addr = 0;
reg  [3:0]  beats = 0;

reg         wr_r = 0;
reg [31:0]  wdata_r = 0;
reg  [3:0]  wstrb_r = 0;
reg [20:2]  waddr_r = 0;

// reg_addr is the WORD index inside the 2 MB window. On a write cycle it must
// present the LATCHED address: reg_wr is a one-cycle pulse and `addr` has
// already incremented by then, so using `addr` here would write the next word.
assign reg_addr  = wr_r ? waddr_r : addr;
assign reg_wr    = wr_r;
assign reg_wdata = wdata_r;
assign reg_wstrb = wstrb_r;

always @(posedge clk) begin
	wr_r <= 0;

	case (state)
		// Writes are offered first, arbitrarily: only one channel is ever
		// armed, so the choice is a priority, not a race.
		S_IDLE: begin
			if (awvalid) begin
				awready <= 1;
				state   <= S_AW;
			end
			else if (arvalid) begin
				arready <= 1;
				state   <= S_AR;
			end
		end

		// awready is high this cycle and awvalid is still high, so the address
		// transfer happens now.
		S_AW: begin
			addr    <= awaddr[20:2];
			bid     <= awid;
			awready <= 0;
			wready  <= 1;
			state   <= S_WDATA;
		end

		S_AR: begin
			addr    <= araddr[20:2];
			rid     <= arid;
			beats   <= arlen;
			arready <= 0;
			rvalid  <= 1;
			rlast   <= (arlen == 4'd0);
			state   <= S_RDATA;
		end

		S_WDATA: if (wvalid & wready) begin
			// Present the write for one cycle. addr has already advanced by the
			// time a consumer sees reg_wr, so the address is captured too.
			wr_r    <= 1;
			waddr_r <= addr;
			wdata_r <= wdata;
			wstrb_r <= wstrb;
			addr    <= addr + 1'd1;
			if (wlast) begin
				wready <= 0;
				bvalid <= 1;
				state  <= S_BRESP;
			end
		end

		S_BRESP: if (bready) begin
			bvalid <= 0;
			state  <= S_IDLE;
		end

		S_RDATA: if (rvalid & rready) begin
			if (rlast) begin
				rvalid <= 0;
				rlast  <= 0;
				state  <= S_IDLE;
			end
			else begin
				addr  <= addr + 1'd1;
				beats <= beats - 1'd1;
				rlast <= (beats == 4'd1);
			end
		end
	endcase
end

cyclonev_hps_interface_hps2fpga_light_weight h2f_lw
(
	.clk       (clk),

	.awid      (awid),
	.awaddr    (awaddr),
	.awlen     (awlen),
	.awsize    (awsize),
	.awburst   (awburst),
	.awlock    (awlock),
	.awcache   (awcache),
	.awprot    (awprot),
	.awvalid   (awvalid),
	.awready   (awready),

	.wid       (wid),
	.wdata     (wdata),
	.wstrb     (wstrb),
	.wlast     (wlast),
	.wvalid    (wvalid),
	.wready    (wready),

	.bid       (bid),
	.bresp     (2'b00),      // OKAY: this slave has no error case to report
	.bvalid    (bvalid),
	.bready    (bready),

	.arid      (arid),
	.araddr    (araddr),
	.arlen     (arlen),
	.arsize    (arsize),
	.arburst   (arburst),
	.arlock    (arlock),
	.arcache   (arcache),
	.arprot    (arprot),
	.arvalid   (arvalid),
	.arready   (arready),

	.rid       (rid),
	.rdata     (reg_rdata),
	.rresp     (2'b00),
	.rlast     (rlast),
	.rvalid    (rvalid),
	.rready    (rready)
);

endmodule
