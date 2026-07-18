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
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
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
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
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

	//SDRAM interface with lower latency
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
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
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

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
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

///////////////////////  CLOCK/RESET  ///////////////////////////////////

// NDS clock plan (docs/ROADMAP.md M9): render/memory fabric 100.542 MHz,
// video 67.028 MHz (2x system), system clk1x 33.514 MHz. clkMem is exactly
// 3x clk1x from the same VCO, phase-locked - nds_top's clkMemIndex contract.
wire pll_locked;
wire clk_mem;
wire clk_sys;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_mem),
	.outclk_1(CLK_VIDEO),
	.outclk_2(clk_sys),
	.locked(pll_locked)
);

// clkMemIndex: which of the 3 clkMem phases inside one clk1x period, 0 on
// the clk1x rising edge. A clk1x-domain toggle re-locks the mod-3 counter
// every clk1x edge (same-VCO related clocks, so the cross-sample is a
// timed path, not a synchronizer).
reg tgl_1x = 0;
always @(posedge clk_sys) tgl_1x <= ~tgl_1x;

reg       tgl_mem = 0;
reg [1:0] clkMemIndex = 0;
always @(posedge clk_mem) begin
	tgl_mem <= tgl_1x;
	if (tgl_mem != tgl_1x) clkMemIndex <= 2'd1;
	else                   clkMemIndex <= (clkMemIndex == 2'd2) ? 2'd0 : clkMemIndex + 2'd1;
end

wire reset = RESET | buttons[1] | status[0] | cart_download;

////////////////////////////  HPS I/O  //////////////////////////////////

// Status Bit Map: (0..31 => "O", 32..63 => "o")
// 0         1         2         3          4         5         6
// 01234567890123456789012345678901 23456789012345678901234567890123
// 0123456789ABCDEFGHIJKLMNOPQRSTUV 0123456789ABCDEFGHIJKLMNOPQRSTUV
// XXXXXXXXXX                       XXXX

`include "build_id.v"
parameter CONF_STR = {
	"NDS;;",
	// v1 decision: the .nds image is staged straight into DDR3 by the HPS
	// (load-address form, donor GBA pattern) - the card interface pages it
	// from there, no SDRAM copy of the ROM.
	"FS1,NDS,Load,30000000;",
	"F2,BIN,Load Firmware;",
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
	"P4-,Robert Peip;",
	"P4-,(FPGAzumSpass);",
	"P4-,GBA donor core;",
	"P4-;",
	"P4-,The awesome hackers;",
	"P4-,of MiSTer-FPGA;",

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
wire  [7:0] ioctl_index;

wire [15:0] joy;
wire [21:0] gamma_bus;
wire [15:0] joystick_analog_0;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
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
	.ioctl_wait(1'b0),

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

//////////////////////////  ROM DETECT  /////////////////////////////////

reg cart_download, fw_download;
always @(posedge clk_sys) begin
	cart_download <= ioctl_download & (ioctl_index == 1);
	// firmware image: boot0.rom auto-load (index 0) or the OSD "Load
	// Firmware" entry (index 2). Only the first 128 KB is staged - that is
	// the window nds_spi's fw_addr port can address (user settings live at
	// the image top in a real 256 KB firmware; the sim image is 128 KB).
	fw_download   <= ioctl_download & ((ioctl_index == 0) || (ioctl_index == 2));
end

reg cart_loaded = 0;
reg flush_req   = 0;   // displace ddram.sv's read cache after the HPS re-wrote DDR3 behind it
always @(posedge clk_sys) begin
	reg old_download;
	old_download <= cart_download;
	if (old_download & ~cart_download) begin
		cart_loaded <= 1;
		flush_req   <= 1;
	end
	if (flush_ack) flush_req <= 0;
end

reg nds_on = 0;
always @(posedge clk_sys) begin
	nds_on <= ~reset & cart_loaded;   // off->on = HLE boot of the staged card image
end

/////////////////////////  FIRMWARE IMAGE  //////////////////////////////

// SPI firmware flash backing store: 128 KB BRAM, written 16 bits at a time
// from the ioctl stream, read one word per clk1x by nds_spi (1-cycle port).
reg [31:0] fw_ram[0:32767];
reg [31:0] fw_data;
reg [15:0] fw_lo;

wire [14:0] fw_addr;

always @(posedge clk_sys) begin
	if (fw_download & ioctl_wr) begin
		if (~ioctl_addr[1]) fw_lo <= ioctl_dout;
		else if (ioctl_addr < 27'h20000) fw_ram[ioctl_addr[16:2]] <= {ioctl_dout, fw_lo};
	end
	fw_data <= fw_ram[fw_addr];
end

////////////////////////////  CARD PAGER  ///////////////////////////////

// The .nds image sits in DDR3 at 0x30000000 (HPS-staged, see CONF_STR).
// nds_top's card port is a word-read with a done pulse - served from
// ddram.sv ch2. Everything here is clk1x (DDRAM_CLK = clk_sys, donor style).
assign DDRAM_CLK = clk_sys;

wire        card_ena;
wire [24:0] card_addr;
reg  [31:0] card_din;
reg         card_done;

reg         cd_busy  = 0;
reg         cd_flush = 0;
reg         cd_req   = 0;
reg  [24:0] cd_addr;
reg         cd_pend  = 0;   // card_ena is a 1-cycle pulse - latch one that lands mid-flush
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
			// dummy read far away from the image: ddram.sv caches the last
			// 64-bit line per channel and the HPS just re-wrote the ROM
			// underneath it - this displaces the stale line
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

ddram ddram
(
	.*,

	.ch1_addr(27'd0),
	.ch1_din(16'd0),
	.ch1_req(1'b0),
	.ch1_rnw(1'b1),
	.ch1_dout(),
	.ch1_ready(),

	.ch2_addr({1'b0, cd_addr, 1'b0}),  // word address -> byte addr [27:1]
	.ch2_din(32'd0),
	.ch2_req(cd_req),
	.ch2_rnw(1'b1),
	.ch2_dout(cd_dout),
	.ch2_ready(cd_ready),

	.ch3_addr(25'd0),
	.ch3_din(16'd0),
	.ch3_req(1'b0),
	.ch3_rnw(1'b1),
	.ch3_dout(),
	.ch3_ready(),

	.ch4_addr(27'd0),
	.ch4_din(64'd0),
	.ch4_req(1'b0),
	.ch4_rnw(1'b1),
	.ch4_be(8'd0),
	.ch4_dout(),
	.ch4_ready(),

	.ch5_addr(27'd0),
	.ch5_din(64'd0),
	.ch5_req(1'b0),
	.ch5_ready()
);

////////////////////////////  SDRAM  ////////////////////////////////////

// SDRAM map (v1): VRAM banks A..D at 0x000000..0x07FFFF (bank * 128 KB),
// 4 MB main RAM at 0x800000 (nds_top's Softmap_NDS_MAINRAM_ADDR default).
//
// ch2 (32-bit r/w + byte enables) is shared: main RAM normally owns it; the
// CPU VRAM channel (vsrv) borrows it through the allow/busy scheduler
// handshake. The renderer VRAM feed (vrsrv, read-only) lives on ch1 and
// never needs the scheduler - sdram.sv serializes the channels internally.
// Refresh: sdram.sv self-refreshes when idle (refresh_req tied low), so
// mainram_allow only gates the vsrv borrow, not refresh.

wire        mr_ena, mr_rnw;
wire [26:0] mr_adr;
wire [31:0] mr_din;
wire  [3:0] mr_be;
wire        mainram_active, mainram_busy;
reg         mainram_allow = 1;

// core-side VRAM channels (clk1x domain, req pulse -> done pulse)
wire        vsrv_req_c, vsrv_rnw_c;
wire  [1:0] vsrv_bank_c;
wire [14:0] vsrv_addr_c;
wire  [3:0] vsrv_be_c;
wire [31:0] vsrv_din_c;
wire        vrsrv_req_c;
wire  [1:0] vrsrv_bank_c;
wire [14:0] vrsrv_addr_c;

reg  [31:0] vsrv_dout_r,  vrsrv_dout_r;
reg         vsrv_done_r,  vrsrv_done_r;

wire        sd_ch2_ready;
wire [31:0] sd_ch2_dout;
wire        sd_ch1_ready;
wire [63:0] sd_ch1_dout;

// ---- vsrv arbiter: park main RAM, run one ch2 op, hand ch2 back ----
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

always @(posedge clk_mem) begin
	vs_req_d  <= vsrv_req_c;
	sd_vs_req <= 0;

	// vsrv_req is clk1x-registered (3 clkMem cycles wide) - edge detect
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
			// allow has been low through at least one full clk1x period and
			// no main-RAM op is in flight -> ch2 is ours
			if (~&drain_cnt) drain_cnt <= drain_cnt + 1'd1;
			if (!mainram_busy && drain_cnt >= 3'd4) begin
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

	// done pulse aligned to exactly one clk1x period: raise it during the
	// clkMem cycle whose end is the clk1x rising edge (index 2)
	vsrv_done_r <= 0;
	if (vs_fin && clkMemIndex == 2'd1) begin
		vsrv_done_r <= 1;
		vs_fin      <= 0;
	end
end

// ---- vrsrv: renderer read feed on ch1 (no scheduler needed) ----
reg        vr_req_d = 0, vr_busy = 0, vr_fin = 0;
reg        sd_vr_req = 0;
reg [25:0] vr_adr;

always @(posedge clk_mem) begin
	vr_req_d  <= vrsrv_req_c;
	sd_vr_req <= 0;

	if (vrsrv_req_c & ~vr_req_d & ~vr_busy) begin
		vr_adr    <= {8'd0, vrsrv_bank_c, vrsrv_addr_c, 1'b0};  // halfword addr [26:1]
		sd_vr_req <= 1;
		vr_busy   <= 1;
	end

	if (vr_busy & sd_ch1_ready) begin
		vrsrv_dout_r <= sd_ch1_dout[31:0];   // first word of the burst = word at the requested address
		vr_fin       <= 1;
		vr_busy      <= 0;
	end

	vrsrv_done_r <= 0;
	if (vr_fin && clkMemIndex == 2'd1) begin
		vrsrv_done_r <= 1;
		vr_fin       <= 0;
	end
end

sdram sdram
(
	.*,
	.init(~pll_locked),
	.clk(clk_mem),

	.refresh_req(1'b0),          // controller self-refreshes when idle

	.ch1_addr(vr_adr),
	.ch1_din(16'd0),
	.ch1_dout(sd_ch1_dout),
	.ch1_req(sd_vr_req),
	.ch1_rnw(1'b1),
	.ch1_ready(sd_ch1_ready),

	.ch2_addr  (vs_owns ? vs_adr[26:1] : mr_adr[26:1]),
	.ch2_din   (vs_owns ? vs_din       : mr_din),
	.ch2_be    (vs_owns ? vs_be        : mr_be),
	.ch2_dout  (sd_ch2_dout),
	.ch2_req   (sd_vs_req | mr_ena),
	.ch2_cancel(1'b0),
	.ch2_rnw   (vs_owns ? vs_rnw       : mr_rnw),
	.ch2_ready (sd_ch2_ready),
	.ch2_ready16(),

	.ch3_addr(24'd0),
	.ch3_din(16'd0),
	.ch3_dout(),
	.ch3_req(1'b0),
	.ch3_rnw(1'b1),
	.ch3_ready()
);

////////////////////////////  SYSTEM  ///////////////////////////////////

wire        boot_error;
wire [15:0] NDS_AUDIO_L, NDS_AUDIO_R;

wire  [7:0] pix_x,  pix_y,  pixb_x, pixb_y;
wire [17:0] pix_d,  pixb_d;
wire        pix_we, pixb_we;

// touchscreen v1: left analog stick as the pen, "Touch" button as pen-down
wire [7:0] touch_x = {~joystick_analog_0[7],  joystick_analog_0[6:0]};
wire [7:0] touch_y = {~joystick_analog_0[15], joystick_analog_0[14:8]};

nds_port_wrap nds
(
	.clk1x(clk_sys),
	.clkMem(clk_mem),
	.clkMemIndex(clkMemIndex),
	.reset(reset),
	.nds_on(nds_on),
	.direct_boot(1'b1),          // firmware boot menu = never (docs/ARCHITECTURE.md)

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

	.boot_done(),
	.boot_error(boot_error),

	.card_ena(card_ena),
	.card_addr(card_addr),
	.card_din(card_din),
	.card_done(card_done),

	.fw_addr(fw_addr),
	.fw_data(fw_data),

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
	.sound_out_right(NDS_AUDIO_R)
);

assign AUDIO_L = NDS_AUDIO_L;
assign AUDIO_R = NDS_AUDIO_R;

////////////////////////////  VIDEO  ////////////////////////////////////

// v1 decision: dual 256x192 screens stacked vertically (like a real DS held
// open), one BRAM framebuffer per screen, single-buffered. The core writes
// pixels at its own frame cadence; the scanout below free-runs at ~59.8 Hz,
// so an occasional tear is possible - the DDR3 compose stage with layout
// options (side-by-side, single+swap) replaces this later.
reg [17:0] fb_top[0:49151];
reg [17:0] fb_bot[0:49151];

always @(posedge clk_sys) begin
	if (pix_we)  fb_top[{pix_y,  pix_x }] <= pix_d;
	if (pixb_we) fb_bot[{pixb_y, pixb_x}] <= pixb_d;
end

// scanout timing: 256x384 active in a 533x526 frame, pixel ce = CLK_VIDEO/4
// = 16.757 MHz -> 59.77 Hz
localparam H_TOTAL  = 533;
localparam H_ACTIVE = 256;
localparam HS_BEG   = 320;
localparam HS_END   = 352;
localparam V_TOTAL  = 526;
localparam V_ACTIVE = 384;
localparam VS_BEG   = 408;
localparam VS_END   = 412;

reg  [9:0] hcnt = 0;
reg  [9:0] vcnt = 0;
reg  [1:0] ce_cnt = 0;
reg        ce_pix = 0;
reg        hs, vs, hbl, vbl;
reg  [7:0] r_out, g_out, b_out;
reg [17:0] fbq_top, fbq_bot;
reg        fbq_bot_sel;

wire [7:0] vline = (vcnt < 192) ? vcnt[7:0] : vcnt[7:0] - 8'd192;
wire [15:0] fb_raddr = {vline, hcnt[7:0]};

always @(posedge CLK_VIDEO) begin
	// fetch runs every clock; the addressed pixel is stable 4 clocks per dot
	fbq_top     <= fb_top[fb_raddr];
	fbq_bot     <= fb_bot[fb_raddr];
	fbq_bot_sel <= (vcnt >= 192);

	ce_cnt <= ce_cnt + 1'd1;
	ce_pix <= (ce_cnt == 2'd3);

	if (ce_cnt == 2'd3) begin
		// output the dot for the current counters (fetched during the last
		// 4 clocks), then advance
		hbl <= ~(hcnt < H_ACTIVE);
		vbl <= ~(vcnt < V_ACTIVE);
		hs  <= (hcnt >= HS_BEG && hcnt < HS_END);
		vs  <= (vcnt >= VS_BEG && vcnt < VS_END);

		// BGR666 -> RGB888 (B in [17:12])
		{b_out, g_out, r_out} <= fbq_bot_sel ?
			{fbq_bot[17:12], fbq_bot[17:16], fbq_bot[11:6], fbq_bot[11:10], fbq_bot[5:0], fbq_bot[5:4]} :
			{fbq_top[17:12], fbq_top[17:16], fbq_top[11:6], fbq_top[11:10], fbq_top[5:0], fbq_top[5:4]};

		if (hcnt == H_TOTAL-1) begin
			hcnt <= 0;
			vcnt <= (vcnt == V_TOTAL-1) ? 10'd0 : vcnt + 1'd1;
		end
		else hcnt <= hcnt + 1'd1;
	end
end

assign VGA_F1 = 0;
assign VGA_SL = sl[1:0];

wire [2:0] scale = status[4:2];
wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;

video_mixer #(.LINE_LENGTH(600), .GAMMA(1)) video_mixer
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
video_freak video_freak
(
	.*,
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),

	// stacked dual screen: 256x384 = 2:3
	.ARX((!ar) ? 12'd2 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(0),
	.CROP_OFF(0),
	.SCALE(status[36:35])
);

endmodule
