// Licensed under the repo LICENSE (see the LICENSE file at the repo root).
//
// Source-owned replacement for sys/hps_io.sv as used by NDS. It decodes the
// same HPS_BUS uio/fp sub-protocols the framework drives on the DE10, but
// implements only the commands this core consumes, so it is smaller and has
// no GPL dependency. It is a one-module drop-in for the legacy hps_io inside
// nds_hps_io_boundary; the boundary module itself remains the switch point.
//
// SUB-PROTOCOL SPLIT. The framework (sys_top.v) already runs the electrical
// HPS_BUS side: it derives io_uio/io_fpga/io_strobe/io_din from the general
// purpose register and ORs our io_dout onto the bus. This module only has to
// decode the command words on io_din while io_uio or io_fpga is selected, and
// drive io_dout and io_wait. Commands this core does not use (PS/2, RTC, SD
// bulk transfer, video_calc reads) are answered with a protocol-legal zero
// read rather than being implemented, which keeps an unknown HPS transaction
// from corrupting state - the failure mode a half-port would otherwise have.
module nds_hps_io
#(parameter CONF_STR = "", WIDE = 0, VDNUM = 1, BLKSZ = 2, STRLEN = $size(CONF_STR)>>3,
  DW = (WIDE) ? 15 : 7, VD = VDNUM-1)
(
	input             clk_sys,
	inout      [48:0] HPS_BUS,

	output reg [31:0] joystick_0 = 0,
	output reg [15:0] joystick_l_analog_0 = 0,

	output      [1:0] buttons,
	output            forced_scandoubler,

	inout      [21:0] gamma_bus,

	output reg [127:0] status = 0,

	// ARM -> FPGA download (file transfer)
	output reg        ioctl_download = 0,
	output reg [15:0] ioctl_index = 0,
	output reg        ioctl_wr = 0,
	output reg [26:0] ioctl_addr = 0,
	output reg [15:0] ioctl_dout = 0,
	input             ioctl_wait,

	// SD block-level access - implemented as a clean ack (this core drives the
	// SD side to zero; the handshake must still complete)
	input      [31:0] sd_lba[VDNUM],
	input       [5:0] sd_blk_cnt[VDNUM],
	input      [VD:0] sd_rd,
	input      [VD:0] sd_wr,
	output reg [VD:0] sd_ack = 0,

	// SD byte-level access
	output reg [12:0] sd_buff_addr = 0,
	output reg [15:0] sd_buff_dout = 0,
	input      [15:0] sd_buff_din[VDNUM],
	output reg        sd_buff_wr = 0,

	output reg [VD:0] img_mounted = 0,
	output reg        img_readonly = 0,
	output reg [63:0] img_size = 0
);

	wire io_strobe = HPS_BUS[33];
	wire io_enable = HPS_BUS[34];
	wire fp_enable = HPS_BUS[35];
	wire [15:0] io_din = HPS_BUS[31:16];
	reg  [15:0] io_dout;
	reg  [15:0] fp_dout;
	reg  [15:0] cfg;
	reg        gamma_en = 0;
	reg        gamma_wr = 0;
	reg  [9:0] gamma_wr_addr = 0;
	reg  [7:0] gamma_value = 0;
	reg  [5:0] byte_cnt;
	reg  [3:0] sd_rrb = 0;
	reg  [3:0] sdn_ack;
	reg  [3:0] sdn = 0;

	assign buttons = cfg[1:0];
	assign forced_scandoubler = cfg[4];

	assign HPS_BUS[37] = ioctl_wait;
	assign HPS_BUS[36] = clk_sys;
	assign HPS_BUS[32] = (WIDE) ? 1'b1 : 1'b0;
	assign HPS_BUS[15:0] = fp_enable ? fp_dout : io_dout;

	// gamma_bus[21] is the framework's gamma-done line, driven high by the
	// video mixer, not by this block - leave it as an input, like hps_io does.
	assign gamma_bus[20:0] = {clk_sys, gamma_en, gamma_wr, gamma_wr_addr, gamma_value};

	wire [15:0] disk = 16'd1 << io_din[11:8];

	wire [7:0] conf_byte = CONF_STR[{(STRLEN - byte_cnt),3'b000} +:8];

	// round-robin SD slot selection, same priority scheme as the legacy block.
	// Combinational in the reference; kept a combinational function here so the
	// 0x16 status word and 0x17/0x18 SD access agree with it.
	always @* begin
		integer i;
		integer n;
		sdn = 0;
		for (i = VDNUM - 1; i >= 0; i = i - 1) begin
			n = i + sd_rrb;
			if (n >= VDNUM) n = n - VDNUM;
			if (sd_wr[n] | sd_rd[n]) sdn = n[3:0];
		end
	end

	reg  [3:0] stflg = 0;
	reg  [3:0] sdn_r;

	always @(posedge clk_sys) begin : uio_block
		reg [15:0] cmd;
		integer n;

		sd_buff_wr <= 0;
		gamma_wr   <= 0;

		if (~io_enable) begin
			cmd       <= 0;
			byte_cnt  <= 0;
			sd_ack    <= 0;
			io_dout   <= 0;
			img_mounted <= 0;
		end
		else if (io_strobe) begin
			io_dout <= 0;
			if (~&byte_cnt) byte_cnt <= byte_cnt + 1'd1;

			if (byte_cnt == 0) begin
				cmd <= io_din;
				casex(io_din)
					'h16: begin io_dout <= {1'b1, sd_blk_cnt[sdn], BLKSZ[2:0], sdn, sd_wr[sdn], sd_rd[sdn]}; sdn_r <= sdn; end
					'h0X17,
					'h0X18: begin sd_ack <= disk[VD:0]; sdn_ack <= io_din[11:8]; end
					'h29: io_dout <= {4'hA, stflg};
					'h2B: io_dout <= {HPS_BUS[48:46],4'b0110};
					'h2F: io_dout <= 1;
					'h32: io_dout <= gamma_bus[21];
					'h39: io_dout <= 1;
					'h3E: io_dout <= 1; // shadow mask
					default: ;
				endcase
			end
			else begin
				casex(cmd)
					'h01: cfg <= io_din;
					'h02: if(byte_cnt==1) joystick_0[15:0] <= io_din; else joystick_0[31:16] <= io_din;
					'h14: if(byte_cnt <= STRLEN) io_dout[7:0] <= conf_byte;
				'h16: if(byte_cnt < 4) begin
						case(byte_cnt)
								1: sd_rrb  <= (sd_rrb == VD) ? 4'd0 : (sd_rrb + 1'd1);
								2: io_dout <= sd_lba[sdn_r][15:0];
								3: io_dout <= sd_lba[sdn_r][31:16];
						endcase
					end
					'h0X17: begin
							sd_buff_dout <= io_din[DW:0];
							sd_buff_wr   <= 1;
						end
					'h0X18: begin
							if(~&sd_buff_addr) sd_buff_addr <= sd_buff_addr + 1'b1;
							io_dout <= sd_buff_din[sdn_ack];
						end
					'h1a: if(byte_cnt < 3) begin
							case(byte_cnt)
								1: joystick_l_analog_0 <= io_din;
								2: ;
							endcase
						end
					'h1c: begin
							img_mounted  <= io_din[VD:0] ? io_din[VD:0] : 1'b1;
							img_readonly <= io_din[7];
						end
					'h1d: if(byte_cnt<5) img_size[{byte_cnt-1'b1, 4'b0000} +:16] <= io_din;
					'h1e: if(byte_cnt < 9) begin
							case(byte_cnt[3:0])
								1: status[15:00] <= io_din;
								2: status[31:16] <= io_din;
								3: status[47:32] <= io_din;
								4: status[63:48] <= io_din;
								5: status[79:64] <= io_din;
								6: status[95:80] <= io_din;
								7: status[111:96] <= io_din;
								8: status[127:112] <= io_din;
							endcase
						end
					'h32: gamma_en <= io_din[0];
					'h33: begin
							gamma_wr_addr <= {(byte_cnt[1:0]-1'b1),io_din[15:8]};
							{gamma_wr, gamma_value} <= {1'b1,io_din[7:0]};
							if (byte_cnt[1:0] == 3) byte_cnt <= 1;
						end
					default: ;
				endcase
			end
		end
	end

	// ---------------- file transfer (fp) ----------------
	always @(posedge clk_sys) begin : fio_block
		reg [15:0] cmd;
		reg  [2:0] cnt;
		reg        has_cmd;
		reg [26:0] addr;
		reg        wr;

		ioctl_wr <= wr;
		wr       <= 0;

		if (~fp_enable) has_cmd <= 0;
		else begin
			if (io_strobe) begin
				if (!has_cmd) begin
					cmd     <= io_din;
					has_cmd <= 1;
					cnt     <= 0;
				end
				else begin
					case(cmd)
						8'h55: ioctl_index <= io_din[15:0];
						8'h53: begin
							cnt <= cnt + 1'd1;
							case(cnt)
								0: if(io_din[7:0] == 8'hAA) begin
										ioctl_addr     <= 0;
										ioctl_download <= 0;
									end
									else if(io_din[7:0]) begin
										addr <= 0;
										ioctl_download <= 1;
									end
									else begin
										ioctl_download <= 0;
									end
								1: begin
										ioctl_addr[15:0] <= io_din;
										addr[15:0] <= io_din;
									end
								2: begin
										ioctl_addr[26:16] <= io_din[10:0];
										addr[26:16] <= io_din[10:0];
									end
							endcase
						end
						8'h54: if(ioctl_download) begin
							ioctl_addr <= addr;
							ioctl_dout <= io_din[DW:0];
							wr   <= 1;
							addr <= addr + (WIDE ? 2'd2 : 2'd1);
						end
						8'h56: begin
							fp_dout <= 0;
						end
					endcase
				end
			end
		end
	end

endmodule
