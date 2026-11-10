// Licensed under the repo LICENSE (see the LICENSE file at the repo root).

module hps_lw_bridge
(
	input             clk,

	output     [18:0] reg_addr,
	output            reg_wr,
	output     [31:0] reg_wdata,
	output      [3:0] reg_wstrb,
	input      [31:0] reg_rdata
);

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

localparam S_IDLE  = 3'd0, S_AW = 3'd1, S_WDATA = 3'd2,
           S_BRESP = 3'd3, S_AR = 3'd4, S_RDATA = 3'd5;
reg  [2:0]  state = S_IDLE;
reg [20:2]  addr = 0;
reg  [3:0]  beats = 0;

reg         wr_r = 0;
reg [31:0]  wdata_r = 0;
reg  [3:0]  wstrb_r = 0;
reg [20:2]  waddr_r = 0;

assign reg_addr  = wr_r ? waddr_r : addr;
assign reg_wr    = wr_r;
assign reg_wdata = wdata_r;
assign reg_wstrb = wstrb_r;

always @(posedge clk) begin
	wr_r <= 0;

	case (state)
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
	.bresp     (2'b00),
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
