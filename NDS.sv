//============================================================================
//  NDS
//  Copyright (C) 2026 NDS_MiSTfits
//
//  Port to MiSTer, derived from GBA_MiSTer (Robert Peip / Sorgelig)
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	input         CLK_50M,

	input         RESET,

	inout  [48:0] HPS_BUS,

	output        CLK_VIDEO,

	output        CE_PIXEL,

	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,

	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_DTR} = 0;
assign USER_OUT = '1;

assign AUDIO_S   = 1;
assign AUDIO_MIX = status[8:7];

assign LED_USER    = cart_download | boot_error;
assign LED_DISK    = 0;
assign LED_POWER   = 0;
assign BUTTONS     = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;


`ifdef NDS_CLKMEM_4X
localparam CLKMEM_RATIO = 4;
`else
localparam CLKMEM_RATIO = 3;
`endif
localparam IDX_ACCEPT = CLKMEM_RATIO - 1;
localparam IDX_DONE   = CLKMEM_RATIO - 2;

wire pll_locked;
wire clk_mem;
wire clk_sys;
wire clk_video_67;

`ifndef NDS_FIXEDRES
assign CLK_VIDEO = clk_video_67;
`else
wire clk_video_27;
wire pll_video_locked;
assign CLK_VIDEO = clk_video_27;

pll_video pll_video_inst
(
	.refclk   (CLK_50M),
	.rst      (1'b0),
	.outclk_0 (clk_video_27),
	.locked   (pll_video_locked)
);
`endif


pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_mem),
	.outclk_1(clk_video_67),
	.outclk_2(clk_sys),
	.locked(pll_locked)
);

reg tgl_1x = 0;
always @(posedge clk_sys) tgl_1x <= ~tgl_1x;

reg       tgl_mem = 0;
reg [1:0] clkMemIndex = 0;
always @(posedge clk_mem) begin
	tgl_mem <= tgl_1x;
	if (tgl_mem != tgl_1x) clkMemIndex <= 2'd1;
	else                   clkMemIndex <= (clkMemIndex == IDX_ACCEPT[1:0]) ? 2'd0 : clkMemIndex + 2'd1;
end

wire reset = RESET | buttons[1] | status[0] | cart_download;



`include "build_id.v"
parameter CONF_STR = {
	"NDS;;",
	"FS3,NDS,Load,30000000;",
	"F4,BINROM,Load Firmware;",
	"F1,BINROM,Load ARM7 BIOS;",
	"F2,BINROM,Load ARM9 BIOS;",
	"-;",
	"O[9],Boot,Direct (HLE),Firmware;",
	"-;",
	"P1,Video & Audio;",
	"P1-;",
	"P1O[6:5],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[4:2],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1O[36:35],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P1-;",
	"P1O[8:7],Stereo Mix,None,25%,50%,100%;",

	"P4,Credits;",
	"P4-;",
	"P4-,Sarah Aronson;",
	"P4-,(Heni/Luigi & Co);",
	"P4-,ko-fi.com/heni;",

	"- ;",
	"R0,Reset;",
	"J1,A,B,X,Y,L,R,Select,Start,Touch;",
	"jn,A,B,X,Y,L,R,Select,Start;",
	"V,v",`BUILD_DATE
};

wire  [1:0] buttons;
wire [63:0] status;
wire        forced_scandoubler;
reg  [31:0] sd_lba = 0;
reg         sd_rd = 0;
reg         sd_wr = 0;
wire        sd_ack;
wire  [7:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din = 0;
wire        sd_buff_wr;
wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire        ioctl_download;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire        ioctl_wr;
wire [15:0] ioctl_index;

wire [15:0] joy;
wire [21:0] gamma_bus;
wire [15:0] joystick_analog_0;

nds_hps_io_boundary #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.forced_scandoubler(forced_scandoubler),

	.joystick_0(joy),

	.status(status),

	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wait(fw_ioctl_wait),

	.sd_lba('{sd_lba}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din}),
	.sd_buff_wr(sd_buff_wr),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.gamma_bus(gamma_bus),

	.joystick_l_analog_0(joystick_analog_0)
);


reg cart_download, fw_download;
wire bios7_download = ioctl_download & ((ioctl_index[5:0] == 6'h01) ||
	                                     (ioctl_index == 16'h0040));
wire bios9_download = ioctl_download & ((ioctl_index[5:0] == 6'h02) ||
	                                     (ioctl_index == 16'h0080));
always @(posedge clk_sys) begin
	cart_download <= ioctl_download & ((ioctl_index[5:0] == 6'h03) ||
	                                  (ioctl_index == 16'h00C0));
	fw_download   <= ioctl_download & ((ioctl_index == 0) ||
	                                  (ioctl_index[5:0] == 6'h04) ||
	                                  (ioctl_index == 16'h0100));
end

reg bios7_download_d = 0;
reg bios9_download_d = 0;
reg fw_download_d    = 0;
reg bios7_loaded = 0;
reg bios9_loaded = 0;
reg bios7_seen_last = 0;
reg bios9_seen_last = 0;

always @(posedge clk_sys) begin
	bios7_download_d <= bios7_download;
	bios9_download_d <= bios9_download;
	fw_download_d    <= fw_download;

	if (bios7_download) begin
		bios7_loaded <= 0;
		if (!bios7_download_d) bios7_seen_last <= 0;
		if (ioctl_wr && ioctl_addr == 27'd16382) bios7_seen_last <= 1;
	end
	else if (bios7_download_d) begin
		bios7_loaded <= bios7_seen_last;
	end

	if (bios9_download) begin
		bios9_loaded <= 0;
		if (!bios9_download_d) bios9_seen_last <= 0;
		if (ioctl_wr && ioctl_addr == 27'd4094) bios9_seen_last <= 1;
	end
	else if (bios9_download_d) begin
		bios9_loaded <= bios9_seen_last;
	end
end

wire bios_load_reset = bios7_download | bios9_download |
	                     bios7_download_d | bios9_download_d |
	                     fw_download | fw_download_d;
wire bios7_load_we = bios7_download & ioctl_wr & (ioctl_addr < 27'd16384);
wire bios9_load_we = bios9_download & ioctl_wr & (ioctl_addr < 27'd4096);
wire [31:0] bios_load_data = {ioctl_dout, ioctl_dout};
wire [3:0]  bios_load_be = ioctl_addr[1] ? 4'b1100 : 4'b0011;

reg cart_loaded = 0;
reg flush_req   = 0;
wire cart_force;
always @(posedge clk_sys) begin
	reg old_download;
	old_download <= cart_download;
	if (old_download & ~cart_download) begin
		cart_loaded <= 1;
		flush_req   <= 1;
	end
	if (cart_force) begin
		cart_loaded <= 1;
		flush_req   <= 1;
	end
	if (flush_ack) flush_req <= 0;
end

reg nds_on = 0;
always @(posedge clk_sys) begin
	nds_on <= ~reset & cart_loaded;
end


localparam [27:1] FW_HW_BASE = 27'h7F80000;

wire [15:0] fw_addr;
wire        fw_req;
reg         fw_done;
reg  [31:0] fw_data;

reg         fwc_busy  = 0;
reg         fwc_req   = 0;
reg         fwc_rnw   = 1;
reg  [27:1] fwc_addr;
reg  [15:0] fwc_din;
reg         fwc_isread = 0;
reg         fwc_word;
reg         fwr_pend  = 0;
reg  [15:0] fwr_pend_addr;
wire        fwc_ready;
wire [63:0] fwc_dout;

wire        fw_ioctl_wait = fw_download & fwc_busy;

always @(posedge clk_sys) begin
	fw_done <= 0;
	fwc_req <= 0;
	if (fw_req) begin
		fwr_pend      <= 1;
		fwr_pend_addr <= fw_addr;
	end
	if (!fwc_busy) begin
		if (fw_download & ioctl_wr) begin
			fwc_addr   <= FW_HW_BASE + ioctl_addr[26:1];
			fwc_din    <= ioctl_dout;
			fwc_rnw    <= 0;
			fwc_isread <= 0;
			fwc_req    <= 1;
			fwc_busy   <= 1;
		end
		else if (fw_req | fwr_pend) begin
			fwc_addr   <= FW_HW_BASE + {10'd0, (fwr_pend ? fwr_pend_addr[15:1] : fw_addr[15:1]), 2'b00};
			fwc_word   <= fwr_pend ? fwr_pend_addr[0] : fw_addr[0];
			fwr_pend   <= 0;
			fwc_rnw    <= 1;
			fwc_isread <= 1;
			fwc_req    <= 1;
			fwc_busy   <= 1;
		end
	end
	else if (fwc_ready) begin
		fwc_busy <= 0;
		if (fwc_isread) begin
			fw_data <= fwc_word ? fwc_dout[63:32] : fwc_dout[31:0];
			fw_done <= 1;
		end
	end
end


assign DDRAM_CLK = clk_sys;

wire        card_ena;
wire [24:0] card_addr;
reg  [31:0] card_din;
reg         card_done;

reg         cd_busy  = 0;
reg         cd_flush = 0;
reg         cd_req   = 0;
reg  [24:0] cd_addr;
reg         cd_pend  = 0;
reg  [24:0] cd_pend_addr;
reg         flush_ack = 0;
wire        cd_ready;
wire [31:0] cd_dout;

always @(posedge clk_sys) begin
	card_done <= 0;
	cd_req    <= 0;
	flush_ack <= 0;
	if (cd_busy & card_ena) begin
		cd_pend      <= 1;
		cd_pend_addr <= card_addr;
	end
	if (!cd_busy) begin
		if (card_ena | cd_pend) begin
			cd_addr  <= cd_pend ? cd_pend_addr : card_addr;
			cd_pend  <= 0;
			cd_flush <= 0;
			cd_req   <= 1;
			cd_busy  <= 1;
		end
		else if (flush_req) begin
			cd_addr  <= 25'h1FFFFFE;
			cd_flush <= 1;
			cd_req   <= 1;
			cd_busy  <= 1;
			flush_ack <= 1;
		end
	end
	else if (cd_ready) begin
		cd_busy <= 0;
		if (!cd_flush) begin
			card_din  <= cd_dout;
			card_done <= 1;
		end
	end
end


localparam [27:1] DBG_CMD_ADDR = 27'h7FF8000;
localparam [27:1] DBG_RSP_ADDR = 27'h7FF8004;

wire [31:0] dbg_rsp_data;
wire        dbg_rsp_stb;
reg         mb_cmd_stb = 0;
reg   [7:0] mb_cmd_op;
reg  [31:0] mb_cmd_arg;

reg         lw_cmd_stb = 0;
reg   [7:0] lw_cmd_op  = 0;
reg  [31:0] lw_cmd_arg = 0;

wire        dbg_cmd_stb = mb_cmd_stb | lw_cmd_stb;
wire  [7:0] dbg_cmd_op  = lw_cmd_stb ? lw_cmd_op  : mb_cmd_op;
wire [31:0] dbg_cmd_arg = lw_cmd_stb ? lw_cmd_arg : mb_cmd_arg;

reg  [27:1] mb_addr;
reg  [63:0] mb_din;
reg   [7:0] mb_be;
reg         mb_req = 0;
reg         mb_rnw = 1;
wire        mb_ready;
wire [63:0] mb_dout;

reg   [1:0] mb_state = 0;
reg  [11:0] mb_tmr   = 0;
reg   [7:0] mb_seq   = 0;
reg   [7:0] mb_ack;
reg  [31:0] mb_answer;
reg  [17:0] mb_watchdog;
reg         mb_issued = 0;

assign cart_force = dbg_cmd_stb && (dbg_cmd_op == 8'h0B);


always @(posedge clk_sys) begin
	mb_req     <= 0;
	mb_cmd_stb <= 0;
	mb_tmr     <= mb_tmr + 1'd1;

	case (mb_state)
		2'd0: if (mb_tmr == 0) begin
			mb_addr  <= DBG_CMD_ADDR;
			mb_rnw   <= 1;
			mb_req   <= 1;
			mb_state <= 2'd1;
		end

		2'd1: if (mb_ready) begin
			if ((mb_dout[63:48] == 16'hDB90) && (mb_dout[47:40] != mb_seq)) begin
				mb_cmd_op   <= mb_dout[39:32];
				mb_cmd_arg  <= mb_dout[31:0];
				mb_cmd_stb  <= 1;
				mb_ack      <= mb_dout[47:40];
				mb_watchdog <= 0;
				mb_state    <= 2'd2;
			end
			else mb_state <= 2'd0;
		end

		2'd2: begin
			mb_watchdog <= mb_watchdog + 1'd1;
			if (dbg_rsp_stb) begin
				mb_answer <= dbg_rsp_data;
				mb_state  <= 2'd3;
			end
			else if (mb_watchdog == 18'h3FFFF) begin
				mb_answer <= 32'hBADACCE5;
				mb_state  <= 2'd3;
			end
		end

		2'd3: begin
			mb_addr <= DBG_RSP_ADDR;
			mb_din  <= {16'hDB91, mb_ack, 8'h00, mb_answer};
			mb_be   <= 8'hFF;
			mb_rnw  <= 0;
			if (!mb_issued) begin
				mb_req    <= 1;
				mb_issued <= 1;
			end
			else if (mb_ready) begin
				mb_seq    <= mb_ack;
				mb_issued <= 0;
				mb_state  <= 2'd0;
			end
		end
	endcase
end


localparam [27:1] AUD_HW_BASE = 27'h7FE8000;

wire [27:1] au3_addr;
wire [63:0] au3_din;
wire        au3_req, au3_rnw;
wire  [7:0] au3_be;
wire [63:0] au3_dout;
wire        au3_ready;
wire [15:0] hps_audio_l, hps_audio_r;
wire [15:0] hps_audio_ur;
wire        hps_audio_on;

`ifdef NDS_HPS_AUDIO
nds_audio_ddr3 #(.AUD_HW_BASE(AUD_HW_BASE)) u_audio
(
	.clk_sys(clk_sys),
	.reset(reset),
	.sample_l(hps_audio_l), .sample_r(hps_audio_r), .sample_stb(),
	.underruns(hps_audio_ur), .enabled(hps_audio_on),
	.au3_addr(au3_addr), .au3_din(au3_din), .au3_req(au3_req),
	.au3_rnw(au3_rnw), .au3_be(au3_be),
	.au3_dout(au3_dout), .au3_ready(au3_ready)
);
`else
assign au3_addr     = 27'd0;
assign au3_din      = 64'd0;
assign au3_req      = 1'b0;
assign au3_rnw      = 1'b1;
assign au3_be       = 8'd0;
assign hps_audio_l  = 16'd0;
assign hps_audio_r  = 16'd0;
assign hps_audio_ur = 16'd0;
assign hps_audio_on = 1'b0;
`endif

localparam [27:1] FB_HW_BASE = 27'h7F00000;
localparam  [7:0] FB_BURST   = 8'd128;

ddram ddram
(
	.*,

	.ch1_addr(fwc_addr),
	.ch1_din(fwc_din),
	.ch1_req(fwc_req),
	.ch1_rnw(fwc_rnw),
	.ch1_dout(fwc_dout),
	.ch1_ready(fwc_ready),

	.ch2_addr({1'b0, cd_addr, 1'b0}),
	.ch2_din(32'd0),
	.ch2_req(cd_req),
	.ch2_rnw(1'b1),
	.ch2_dout(cd_dout),
	.ch2_ready(cd_ready),

	.ch3_addr(au3_addr),
	.ch3_din(au3_din),
	.ch3_req(au3_req),
	.ch3_rnw(au3_rnw),
	.ch3_be(au3_be),
	.ch3_dout(au3_dout),
	.ch3_ready(au3_ready),

	.ch4_addr(mb_addr),
	.ch4_din(mb_din),
	.ch4_req(mb_req),
	.ch4_rnw(mb_rnw),
	.ch4_be(mb_be),
	.ch4_dout(mb_dout),
	.ch4_ready(mb_ready),

	.ch5_addr(fb5_addr),
	.ch5_din(fb5_din),
	.ch5_req(fb5_req),
	.ch5_burst(FB_BURST),
	.ch5_next(fb5_next),
	.ch5_ready(fb5_ready),

	.ch6_addr(fb6_addr),
	.ch6_burst(FB_BURST),
	.ch6_req(fb6_req),
	.ch6_dout(fb6_dout),
	.ch6_valid(fb6_valid),
	.ch6_ready(fb6_ready)
);



wire        mr_ena, mr_rnw;
wire [26:0] mr_adr;
wire [31:0] mr_din;
wire  [3:0] mr_be;
wire        mainram_active, mainram_busy;
reg         mainram_allow = 1;

wire        vsrv_req_c, vsrv_rnw_c;
wire  [1:0] vsrv_bank_c;
wire [14:0] vsrv_addr_c;
wire  [3:0] vsrv_be_c;
wire [31:0] vsrv_din_c;
wire        vrsrv_req_c;
wire  [1:0] vrsrv_bank_c;
wire [13:0] vrsrv_addr_c;
wire        vrsrv_ready_c;

reg  [31:0] vsrv_dout_r;
reg  [63:0] vrsrv_dout_r;
reg         vsrv_done_r,  vrsrv_done_r;

wire        sd_ch2_ready;
wire [31:0] sd_ch2_dout;
wire [31:0] sd_ch2_dout_hi;
wire        sd_ch2_ready64;
wire        sd_ch1_ready;
wire [63:0] sd_ch1_dout;
wire        sd_ch1_accept;

localparam A_IDLE  = 2'd0;
localparam A_DRAIN = 2'd1;
localparam A_WAIT  = 2'd2;

reg  [1:0] arb_state = A_IDLE;
reg        vs_req_d = 0, vs_pend = 0, vs_fin = 0;
reg        sd_vs_req = 0;
reg [26:0] vs_adr;
reg        vs_rnw;
reg  [3:0] vs_be;
reg [31:0] vs_din;
reg  [2:0] drain_cnt;

wire vs_owns = (arb_state == A_WAIT);
wire mr_done32 = sd_ch2_ready & ~vs_owns;
wire mr_done64 = sd_ch2_ready64 & ~vs_owns;

always @(posedge clk_mem) begin
	vs_req_d  <= vsrv_req_c;
	sd_vs_req <= 0;

	if (vsrv_req_c & ~vs_req_d) begin
		vs_pend <= 1;
		vs_adr  <= {8'd0, vsrv_bank_c, vsrv_addr_c, 2'b00};
		vs_rnw  <= vsrv_rnw_c;
		vs_be   <= vsrv_be_c;
		vs_din  <= vsrv_din_c;
	end

	case (arb_state)
		A_IDLE: begin
			mainram_allow <= 1;
			if (vs_pend) begin
				mainram_allow <= 0;
				drain_cnt     <= 0;
				arb_state     <= A_DRAIN;
			end
		end

		A_DRAIN: begin
			if (~&drain_cnt) drain_cnt <= drain_cnt + 1'd1;
			if (!mainram_busy && drain_cnt >= CLKMEM_RATIO[2:0] + 3'd1) begin
				sd_vs_req <= 1;
				vs_pend   <= 0;
				arb_state <= A_WAIT;
			end
		end

		A_WAIT: begin
			if (sd_ch2_ready) begin
				vsrv_dout_r <= sd_ch2_dout;
				vs_fin      <= 1;
				arb_state   <= A_IDLE;
			end
		end

		default: arb_state <= A_IDLE;
	endcase

	vsrv_done_r <= 0;
	if (vs_fin && clkMemIndex == IDX_DONE[1:0]) begin
		vsrv_done_r <= 1;
		vs_fin      <= 0;
	end
end

reg        vr_pend = 0;
reg  [1:0] vr_out  = 0;
reg        vr_fin  = 0;
reg        sd_vr_req = 0;
reg [25:0] vr_adr;

assign vrsrv_ready_c = ~vr_pend & (vr_out < 2'd2);

always @(posedge clk_mem) begin
	sd_vr_req <= 0;

	if (sd_ch1_accept) vr_pend <= 0;

	if (vrsrv_req_c & vrsrv_ready_c & (clkMemIndex == IDX_ACCEPT[1:0])) begin
		vr_adr    <= {8'd0, vrsrv_bank_c, vrsrv_addr_c, 2'b00};
		sd_vr_req <= 1;
		vr_pend   <= 1;
		if (!sd_ch1_ready) vr_out <= vr_out + 2'd1;
	end
	else if (sd_ch1_ready) vr_out <= vr_out - 2'd1;

	if (sd_ch1_ready) begin
		vrsrv_dout_r <= sd_ch1_dout;
		vr_fin       <= 1;
	end

	vrsrv_done_r <= 0;
	if (vr_fin && clkMemIndex == IDX_DONE[1:0]) begin
		vrsrv_done_r <= 1;
		vr_fin       <= 0;
	end
end

sdram #(
	.DQ_PIPE    (CLKMEM_RATIO >= 4 ? 1 : 0),
	.CAS_LATENCY(CLKMEM_RATIO >= 4 ? 3 : 2),
	.TRCD_WAIT  (CLKMEM_RATIO >= 4 ? 2 : 1)
) sdram
(
	.*,
	.init(~pll_locked),
	.clk(clk_mem),

	.refresh_req(1'b0),

	.ch1_addr(vr_adr),
	.ch1_din(16'd0),
	.ch1_dout(sd_ch1_dout),
	.ch1_req(sd_vr_req),
	.ch1_rnw(1'b1),
	.ch1_ready(sd_ch1_ready),
	.ch1_accept(sd_ch1_accept),

	.ch2_addr  (vs_owns ? vs_adr[26:1] : mr_adr[26:1]),
	.ch2_din   (vs_owns ? vs_din       : mr_din),
	.ch2_be    (vs_owns ? vs_be        : mr_be),
	.ch2_dout  (sd_ch2_dout),
	.ch2_req   (sd_vs_req | mr_ena),
	.ch2_cancel(1'b0),
	.ch2_rnw   (vs_owns ? vs_rnw       : mr_rnw),
	.ch2_ready (sd_ch2_ready),
	.ch2_ready16(),
	.ch2_dout_hi(sd_ch2_dout_hi),
	.ch2_ready64(sd_ch2_ready64),

	.ch3_addr(24'd0),
	.ch3_din(16'd0),
	.ch3_dout(),
	.ch3_req(1'b0),
	.ch3_rnw(1'b1),
	.ch3_ready()
);


wire        boot_error;
wire        boot_done;
wire [15:0] NDS_AUDIO_L, NDS_AUDIO_R;

wire  [7:0] pix_x,  pix_y,  pixb_x, pixb_y;
wire [17:0] pix_d,  pixb_d;
wire        pix_we, pixb_we;
wire [31:0] dbg_pc9, dbg_pc7;
wire [31:0] dbg_r0_9, dbg_lr9, dbg_cpsr9;
wire [17:0] dbg_vfy_bad;
wire [31:0] dbg_vfy_addr;
wire [17:0] dbg_hwstat;



`ifdef NDS_LW_DEBUG
wire [18:0] lwreg_addr;
wire        lwreg_wr;
wire [31:0] lwreg_wdata;
wire  [3:0] lwreg_wstrb;
wire [31:0] lwreg_rdata;

reg         lw_busy    = 0;
reg  [31:0] lw_rsp     = 0;
reg   [7:0] lw_ack     = 0;
reg  [17:0] lw_watchdog = 0;

always @(posedge clk_sys) begin
	lw_cmd_stb <= 0;

	if (lwreg_wr) begin
		case (lwreg_addr)
			19'd3: lw_cmd_arg <= lwreg_wdata;
			19'd2: begin
				lw_cmd_op   <= lwreg_wdata[7:0];
				lw_cmd_stb  <= 1;
				lw_busy     <= 1;
				lw_watchdog <= 0;
			end
			default: ;
		endcase
	end

	if (lw_busy) begin
		lw_watchdog <= lw_watchdog + 1'd1;
		if (dbg_rsp_stb) begin
			lw_rsp  <= dbg_rsp_data;
			lw_ack  <= lw_ack + 1'd1;
			lw_busy <= 0;
		end
		else if (lw_watchdog == 18'h3FFFF) begin
			lw_rsp  <= 32'hBADACCE5;
			lw_ack  <= lw_ack + 1'd1;
			lw_busy <= 0;
		end
	end
end

assign lwreg_rdata = (lwreg_addr == 19'd0)  ? 32'h4E44534C          :
                     (lwreg_addr == 19'd1)  ? {31'd0, lw_busy}      :
                     (lwreg_addr == 19'd3)  ? lw_cmd_arg            :
                     (lwreg_addr == 19'd4)  ? lw_rsp                :
                     (lwreg_addr == 19'd5)  ? {24'd0, lw_ack}       :
                     (lwreg_addr == 19'd8)  ? dbg_pc9               :
                     (lwreg_addr == 19'd9)  ? dbg_pc7               :
                     (lwreg_addr == 19'd10) ? dbg_cpsr9             :
                     (lwreg_addr == 19'd11) ? dbg_lr9               :
                     (lwreg_addr == 19'd12) ? dbg_r0_9              :
                     (lwreg_addr == 19'd13) ? {14'd0, dbg_hwstat}   :
                     (lwreg_addr == 19'd14) ? {14'd0, dbg_vfy_bad}  :
                     (lwreg_addr == 19'd15) ? dbg_vfy_addr          :
                                              32'h00000000;

hps_lw_bridge hps_lw_bridge
(
	.clk       (clk_sys),
	.reg_addr  (lwreg_addr),
	.reg_wr    (lwreg_wr),
	.reg_wdata (lwreg_wdata),
	.reg_wstrb (lwreg_wstrb),
	.reg_rdata (lwreg_rdata)
);

`endif



wire [7:0] touch_x = {~joystick_analog_0[7],  joystick_analog_0[6:0]};
wire [7:0] touch_y = {~joystick_analog_0[15], joystick_analog_0[14:8]};

nds_port_wrap nds
(
	.clk1x(clk_sys),
	.clk2x(clk_video_67),
	.clkMem(clk_mem),
	.clkMemIndex(clkMemIndex),
	.reset(reset | bios_load_reset),
	.nds_on(nds_on),
	.direct_boot(1'b1),
	.fw_boot(status[9]),

	.KeyA(joy[4]),
	.KeyB(joy[5]),
	.KeySelect(joy[10]),
	.KeyStart(joy[11]),
	.KeyRight(joy[0]),
	.KeyLeft(joy[1]),
	.KeyUp(joy[3]),
	.KeyDown(joy[2]),
	.KeyR(joy[9]),
	.KeyL(joy[8]),
	.KeyX(joy[6]),
	.KeyY(joy[7]),
	.lid_closed(1'b0),

	.touch_active(joy[12]),
	.touch_x(touch_x),
	.touch_y(touch_y),

	.boot_done(boot_done),
	.boot_error(boot_error),

	.card_ena(card_ena),
	.card_addr(card_addr),
	.card_din(card_din),
	.card_done(card_done),

	.fw_addr(fw_addr),
	.fw_req(fw_req),
	.fw_done(fw_done),
	.fw_data(fw_data),

	.bios7_load_addr(ioctl_addr[13:2]),
	.bios7_load_data(bios_load_data),
	.bios7_load_be(bios_load_be),
	.bios7_load_we(bios7_load_we),
	.bios7_load_done(bios7_loaded),
	.bios9_load_addr(ioctl_addr[11:2]),
	.bios9_load_data(bios_load_data),
	.bios9_load_be(bios_load_be),
	.bios9_load_we(bios9_load_we),
	.bios9_load_done(bios9_loaded),

	.mainram_allow(mainram_allow),
	.mainram_active(mainram_active),
	.mainram_busy(mainram_busy),
	.sdram_ena(mr_ena),
	.sdram_rnw(mr_rnw),
	.sdram_Adr(mr_adr),
	.sdram_Din(mr_din),
	.sdram_be(mr_be),
	.sdram_Dout(sd_ch2_dout),
	.sdram_done32(mr_done32),
	.sdram_Dout_hi(sd_ch2_dout_hi),
	.sdram_done64(mr_done64),

	.vsrv_req(vsrv_req_c),
	.vsrv_rnw(vsrv_rnw_c),
	.vsrv_bank(vsrv_bank_c),
	.vsrv_addr(vsrv_addr_c),
	.vsrv_be(vsrv_be_c),
	.vsrv_din(vsrv_din_c),
	.vsrv_dout(vsrv_dout_r),
	.vsrv_done(vsrv_done_r),
	.vrsrv_req(vrsrv_req_c),
	.vrsrv_bank(vrsrv_bank_c),
	.vrsrv_addr(vrsrv_addr_c),
	.vrsrv_dout(vrsrv_dout_r),
	.vrsrv_done(vrsrv_done_r),
	.vrsrv_ready(vrsrv_ready_c),

	.pixel_out_x(pix_x),
	.pixel_out_y(pix_y),
	.pixel_out_data(pix_d),
	.pixel_out_we(pix_we),
	.pixelb_out_x(pixb_x),
	.pixelb_out_y(pixb_y),
	.pixelb_out_data(pixb_d),
	.pixelb_out_we(pixb_we),
	.vblank_out(),

	.sound_out_left(NDS_AUDIO_L),
	.sound_out_right(NDS_AUDIO_R),

	.dbg_pc9(dbg_pc9),
	.dbg_pc7(dbg_pc7),
	.dbg_r0_9(dbg_r0_9),
	.dbg_lr9(dbg_lr9),
	.dbg_cpsr9(dbg_cpsr9),
	.dbg_vfy_bad(dbg_vfy_bad),
	.dbg_vfy_addr(dbg_vfy_addr),

	.dbg_cmd_stb(dbg_cmd_stb),
	.dbg_cmd_op(dbg_cmd_op),
	.dbg_cmd_arg(dbg_cmd_arg),
	.dbg_rsp_data(dbg_rsp_data),
	.dbg_rsp_stb(dbg_rsp_stb),

	.dbg_hwstat(dbg_hwstat)
);

assign AUDIO_L = hps_audio_on ? hps_audio_l : NDS_AUDIO_L;
assign AUDIO_R = hps_audio_on ? hps_audio_r : NDS_AUDIO_R;


reg        pf_tgl = 0;
reg        pf_scr;
reg  [7:0] pf_line;
reg        pf_bank;
wire [35:0] lb_q;
wire  [7:0] lb_raddr;
wire [27:1] fb5_addr, fb6_addr;
wire [63:0] fb5_din, fb6_dout;
wire        fb5_req, fb5_next, fb5_ready;
wire        fb6_req, fb6_valid, fb6_ready;

wire [17:0] dbg_shellstat = {10'b0, bios9_loaded, bios7_loaded, cart_loaded,
	                         nds_on, reset, bios9_download, bios7_download,
	                         boot_done};

nds_fb_ddr3 #(.FB_HW_BASE(FB_HW_BASE), .FB_BURST(FB_BURST)) fb_ddr3
(
	.clk_sys(clk_sys),
	.CLK_VIDEO(CLK_VIDEO),

	.pix_x(pix_x),   .pix_y(pix_y),   .pix_d(pix_d),   .pix_we(pix_we),
	.pixb_x(pixb_x), .pixb_y(pixb_y), .pixb_d(pixb_d), .pixb_we(pixb_we),
	.dbg0(dbg_pc9[17:0]), .dbg1({4'b0, dbg_pc9[31:18]}),
	.dbg2(dbg_vfy_bad), .dbg3(18'd0),
	.dbg4(dbg_vfy_addr[17:0]), .dbg5({4'b0, dbg_vfy_addr[31:18]}),
	.dbg6(dbg_cpsr9[17:0]), .dbg7(dbg_pc7[17:0]),
	.dbg8({4'b0, dbg_pc7[31:18]}), .dbg9(dbg_vfy_bad),
	.dbg10(dbg_hwstat), .dbg11(dbg_shellstat),

	.pf_tgl(pf_tgl),
	.pf_scr(pf_scr),
	.pf_line(pf_line),
	.pf_bank(pf_bank),
	.lb_raddr(lb_raddr),
	.lb_q(lb_q),

	.fb5_addr(fb5_addr), .fb5_din(fb5_din), .fb5_req(fb5_req),
	.fb5_next(fb5_next), .fb5_ready(fb5_ready),

	.fb6_addr(fb6_addr), .fb6_req(fb6_req), .fb6_dout(fb6_dout),
	.fb6_valid(fb6_valid), .fb6_ready(fb6_ready)
);

`ifndef NDS_FIXEDRES
localparam H_TOTAL  = 533;
localparam H_ACTIVE = 256;
localparam HS_BEG   = 320;
localparam HS_END   = 352;
localparam V_TOTAL  = 526;
localparam V_ACTIVE = 384;
localparam VS_BEG   = 408;
localparam VS_END   = 412;

reg  [10:0] hcnt = 0;
reg  [9:0]  vcnt = 0;
reg  [1:0] ce_cnt = 0;
reg        ce_pix = 0;
reg        hs, vs, hbl, vbl;
reg  [7:0] r_out, g_out, b_out;
reg        lbq_sel;

assign lb_raddr = {vcnt[0], hcnt[7:1]};

wire [9:0] vnext = (vcnt == V_TOTAL-1) ? 10'd0 : vcnt + 10'd1;
wire [9:0] vpf   = (vnext == V_TOTAL-1) ? 10'd0 : vnext + 10'd1;

always @(posedge CLK_VIDEO) begin
	lbq_sel <= hcnt[0];

	ce_cnt <= ce_cnt + 1'd1;
	ce_pix <= (ce_cnt == 2'd3);

	if (ce_cnt == 2'd3) begin
		hbl <= ~(hcnt < H_ACTIVE);
		vbl <= ~(vcnt < V_ACTIVE);
		hs  <= (hcnt >= HS_BEG && hcnt < HS_END);
		vs  <= (vcnt >= VS_BEG && vcnt < VS_END);

		{b_out, g_out, r_out} <= lbq_sel ?
			{lb_q[35:30], lb_q[35:34], lb_q[29:24], lb_q[29:28], lb_q[23:18], lb_q[23:22]} :
			{lb_q[17:12], lb_q[17:16], lb_q[11:6],  lb_q[11:10], lb_q[5:0],   lb_q[5:4]};
		if (hcnt == H_TOTAL-1) begin
			hcnt <= 0;
			vcnt <= vnext;
			if (vpf < V_ACTIVE) begin
				pf_scr  <= (vpf >= 10'd192);
				pf_line <= (vpf >= 10'd192) ? (vpf[7:0] - 8'd192) : vpf[7:0];
				pf_bank <= vpf[0];
				pf_tgl  <= ~pf_tgl;
			end
		end
		else hcnt <= hcnt + 1'd1;
	end
end

`else
localparam H_TOTAL  = 858;
localparam H_ACTIVE = 720;
localparam HS_BEG   = 736;
localparam HS_END   = 798;
localparam V_TOTAL  = 525;
localparam V_ACTIVE = 480;
localparam VS_BEG   = 489;
localparam VS_END   = 495;
localparam H_IMG0   = 10'd232;
localparam H_IMG1   = 10'd488;
localparam V_IMG0   = 10'd48;
localparam V_IMG1   = 10'd432;

reg  [9:0] hcnt = 0;
reg  [9:0] vcnt = 0;
reg        ce_pix = 0;
reg        hs, vs, hbl, vbl;
reg  [7:0] r_out, g_out, b_out;
reg        lbq_sel;

reg        hs_d, vs_d, hbl_d, vbl_d, img_d;

wire [9:0] hoff   = hcnt - H_IMG0;
wire [9:0] voff   = vcnt - V_IMG0;
wire       in_img = (hcnt >= H_IMG0) && (hcnt < H_IMG1) &&
                    (vcnt >= V_IMG0) && (vcnt < V_IMG1);
assign lb_raddr = {voff[0], hoff[7:1]};

wire [9:0] vnext = (vcnt == V_TOTAL-1) ? 10'd0 : vcnt + 10'd1;
wire [9:0] sy_pf = vnext + 10'd1 - V_IMG0;
wire       pf_go = (vnext + 10'd1 >= V_IMG0) && (sy_pf < 10'd384);

always @(posedge CLK_VIDEO) begin
	ce_pix <= 1'b1;

	lbq_sel <= hoff[0];
	img_d   <= in_img;
	hs_d    <= (hcnt >= HS_BEG && hcnt < HS_END);
	vs_d    <= (vcnt >= VS_BEG && vcnt < VS_END);
	hbl_d   <= ~(hcnt < H_ACTIVE);
	vbl_d   <= ~(vcnt < V_ACTIVE);

	hs  <= hs_d;
	vs  <= vs_d;
	hbl <= hbl_d;
	vbl <= vbl_d;

	if (img_d)
		{b_out, g_out, r_out} <= lbq_sel ?
			{lb_q[35:30], lb_q[35:34], lb_q[29:24], lb_q[29:28], lb_q[23:18], lb_q[23:22]} :
			{lb_q[17:12], lb_q[17:16], lb_q[11:6],  lb_q[11:10], lb_q[5:0],   lb_q[5:4]};
	else
		{b_out, g_out, r_out} <= 24'd0;

	if (hcnt == H_TOTAL-1) begin
		hcnt <= 0;
		vcnt <= vnext;
		if (pf_go) begin
			pf_scr  <= (sy_pf >= 10'd192);
			pf_line <= (sy_pf >= 10'd192) ? (sy_pf[7:0] - 8'd192) : sy_pf[7:0];
			pf_bank <= sy_pf[0];
			pf_tgl  <= ~pf_tgl;
		end
	end
	else hcnt <= hcnt + 1'd1;
end
`endif

assign VGA_F1 = 0;
assign VGA_SL = sl[1:0];

wire [2:0] scale = status[4:2];
wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;

`ifdef NDS_FIXEDRES
localparam VM_GAMMA = 0;
`else
localparam VM_GAMMA = 1;
`endif

nds_clash_video_mixer #(.LINE_LENGTH(600), .GAMMA(VM_GAMMA)) video_mixer
(
	.*,
	.scandoubler(1'b0),
	.hq2x(1'b0),
	.freeze_sync(),
	.ce_pix(ce_pix),
	.HSync(hs),
	.VSync(vs),
	.HBlank(hbl),
	.VBlank(vbl),
	.R(r_out),
	.G(g_out),
	.B(b_out)
);

wire [1:0] ar = status[6:5];
nds_video_freak video_freak
(
	.*,
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),

	.ARX((!ar) ? 12'd2 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(0),
	.CROP_OFF(0),
	.SCALE(status[36:35])
);

endmodule
