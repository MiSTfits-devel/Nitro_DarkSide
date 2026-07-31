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
wire clk_video_67;   // 67.027964 MHz: VIDEO OUTPUT ONLY
assign CLK_VIDEO = clk_video_67;

// The ARM9 island used to share clk_video_67, which is why it was stuck at
// 67.028 MHz - a video number, never an ARM9 requirement. Giving it its own PLL
// output was tried (/16 = 50.270973 MHz, build/artifacts-isl16) and is a DEAD
// END: cross-domain setup budget is set by EDGE ALIGNMENT, not period, so a
// non-integer ratio makes timing far worse. See the .clk2x comment below.

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_mem),
	.outclk_1(clk_video_67),
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
	"FS3,NDS,Load,30000000;",
	"F4,BINROM,Load Firmware;",
	"F1,BINROM,Load ARM7 BIOS;",
	"F2,BINROM,Load ARM9 BIOS;",
	"-;",
	"O[9],Boot,Direct (HLE),Firmware;",
	"O[10],GPU pace,1-of-3 (all lines),1-of-1 (real speed);",
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
	"P4-,(Heni, Luigi & Co);",
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

// Keep the DE10 HPS transport behind a dedicated boundary. Its current
// implementation is the proven framework hps_io; the boundary is the switch
// point for the Clash command engine once file/SD transactions are covered.
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

//////////////////////////  ROM DETECT  /////////////////////////////////

reg cart_download, fw_download;
// OSD F1/F2 transfers use indices 1/2. Automatic bootN files are encoded
// differently by MiSTer: boot1.rom is 0x40 and boot2.rom is 0x80 (the boot
// file number lives above ioctl_index[5:0], whose value remains zero).
// Accept both forms so startup auto-load and later manual replacement share
// the same atomic BIOS write path.
wire bios7_download = ioctl_download & ((ioctl_index[5:0] == 6'h01) ||
	                                     (ioctl_index == 16'h0040));
wire bios9_download = ioctl_download & ((ioctl_index[5:0] == 6'h02) ||
	                                     (ioctl_index == 16'h0080));
always @(posedge clk_sys) begin
	// Same dual-form match as the BIOS lines above. An .mgl <file index="N">
	// arrives as N<<6, not N, so the old exact `== 3` only ever matched an OSD
	// menu load and a cart launched from an .mgl was silently never loaded -
	// the core sat at shellstat 0xC0 (BIOSes in, no cart, CPUs held).
	cart_download <= ioctl_download & ((ioctl_index[5:0] == 6'h03) ||
	                                  (ioctl_index == 16'h00C0));
	// firmware image: boot0.rom auto-load (index 0), the OSD "Load Firmware"
	// entry (index 4), or the same entry from an .mgl (4<<6 = 0x100). Full
	// 256 KB staged so a retail image's user settings (top of the image) are
	// addressable via nds_spi.
	fw_download   <= ioctl_download & ((ioctl_index == 0) ||
	                                  (ioctl_index[5:0] == 6'h04) ||
	                                  (ioctl_index == 16'h0100));
end

// Retail CPU BIOS images are writable M10Ks inside nds_top. MiSTer
// auto-loads games/NDS/boot1.rom and boot2.rom as indices 0x40 and 0x80; the
// matching OSD F1/F2 entries use indices 1 and 2. A complete file
// is activated only after its last halfword arrives. Both CPUs remain reset
// for the transfer and one settling cycle, so they never execute a partial
// image.
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

// The firmware download must hold the core in reset too, not just the two BIOS
// images. ARM7 reads the SPI firmware through the DDR3 pager (see FIRMWARE
// IMAGE below), and while fw_download is active that pager's ioctl-write branch
// has priority over its read branch. A fw_req landing in the same cycle as an
// ioctl_wr while the channel is idle is dropped outright: the pend latch only
// arms when fwc_busy is already set, so nothing remembers the request, fw_done
// never arrives, and nds_spi holds SPI busy forever - wedging ARM7 and, through
// the stalled ARM7, leaving ARM9 parked in the NitroSDK idle thread. boot0.rom
// auto-loads at index 0 exactly while ARM7 is running its init, so this window
// is live on real hardware and invisible in simulation (no ioctl there).
// Holding reset also stops ARM7 from reading a half-written image.
wire bios_load_reset = bios7_download | bios9_download |
	                     bios7_download_d | bios9_download_d |
	                     fw_download | fw_download_d;
wire bios7_load_we = bios7_download & ioctl_wr & (ioctl_addr < 27'd16384);
wire bios9_load_we = bios9_download & ioctl_wr & (ioctl_addr < 27'd4096);
wire [31:0] bios_load_data = {ioctl_dout, ioctl_dout};
wire [3:0]  bios_load_be = ioctl_addr[1] ? 4'b1100 : 4'b0011;

reg cart_loaded = 0;
reg flush_req   = 0;   // displace ddram.sv's read cache after the HPS re-wrote DDR3 behind it
wire cart_force;       // mailbox op 0x0B, driven from the DEBUG MAILBOX section below
always @(posedge clk_sys) begin
	reg old_download;
	old_download <= cart_download;
	if (old_download & ~cart_download) begin
		cart_loaded <= 1;
		flush_req   <= 1;
	end
	// Mailbox op 0x0B: declare the card image already present in DDR3. The OSD is
	// the only thing that can produce a cart_download edge and it needs a human;
	// DDR3 itself survives FPGA reconfiguration, and the HPS can write
	// 0x30000000 directly. With this, deploy -> declare -> softreset boots with
	// no OSD interaction, so a build can be tested unattended. Raise flush_req
	// exactly as a real download does: the bytes under ddram.sv's read cache
	// have changed.
	if (cart_force) begin
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

// The firmware image lives in DDR3 (M10K eviction, FITTING.md round 2): the
// ioctl stream stages it through ddram ch1 (16-bit write lanes match the
// ioctl beat), and nds_spi reads words back through the same channel with
// the fw_req/fw_done handshake. SPI reads are byte-paced and sequential;
// ddram caches the last 64-bit beat per channel, so most reads never reach
// DDR3, and ch1 writes invalidate that cache (download/read coherency).
// 0x0FF00000 sits far above the card image window (cd_addr tops out at 128MB).
localparam [27:1] FW_HW_BASE = 27'h7F80000;   // byte address 0x0FF00000 >> 1

wire [15:0] fw_addr;   // word address from the wrapper (byte addr 17:2)
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
reg         fwr_pend  = 0;    // fw_req is a 1-cycle pulse - latch one that lands mid-write
reg  [15:0] fwr_pend_addr;
wire        fwc_ready;
wire [63:0] fwc_dout;

wire        fw_ioctl_wait = fw_download & fwc_busy;

always @(posedge clk_sys) begin
	fw_done <= 0;
	fwc_req <= 0;
	// Latch every fw_req, not just ones that land while the channel is busy.
	// fw_req is a single cycle and nds_spi holds SPI busy until fw_done, so a
	// dropped request stalls ARM7 permanently - and the ioctl-write branch
	// below outranks the read branch, so an idle-channel request could be lost
	// with nothing remembering it. When the read is issued in this same cycle
	// the branch below re-clears fwr_pend, and its address mux reads the old
	// (still zero) value, so it correctly uses fw_addr directly.
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
			// beat-aligned read; the addressed 32-bit word is muxed from
			// the 64-bit beat on completion
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

/////////////////////////  DEBUG MAILBOX  ///////////////////////////////

// Transport for nds_debug (the IS-NITRO-style unit in rtl/nds_debug.vhd): two
// 64-bit DDR3 beats the HPS drives with devmem, no JTAG and no host Quartus.
// FPGA 0x0FFF0000 == HPS 0x3FFF0000 (see the ddram RAM base), which is above
// the firmware image, the framebuffer window and the 128 MB card ceiling.
//
//   command beat @ 0x3FFF0000   {16'hDB90, seq[7:0], op[7:0], arg[31:0]}
//   response beat @ 0x3FFF0008  {16'hDB91, ack[7:0], 8'h00,   data[31:0]}
//
// The HPS bumps `seq` to fire a command and spins until `ack` matches it. The
// magic word means an all-zero (uninitialised) beat is never mistaken for
// command 0x00, so the debugger stays quiet until it is deliberately poked.
//
// ch4 is the only ddram channel with no beat cache (`cached` is [2:1] in
// rtl/ddram.sv:114), so re-reading one address always reaches DDR3 and sees the
// HPS write - none of the cache-displacement dance ch1/ch2 need. ch4 also
// outranks only the framebuffer in the grant chain, so the poll is throttled to
// one read per 4096 clk_sys cycles (~122us at 33.5 MHz): invisible to ch5/ch6
// bandwidth, and instant next to a human typing devmem commands.
localparam [27:1] DBG_CMD_ADDR = 27'h7FF8000;   // byte 0x0FFF0000 >> 1
localparam [27:1] DBG_RSP_ADDR = 27'h7FF8004;   // byte 0x0FFF0008 >> 1

wire [31:0] dbg_rsp_data;
wire        dbg_rsp_stb;
reg         dbg_cmd_stb = 0;
reg   [7:0] dbg_cmd_op;
reg  [31:0] dbg_cmd_arg;

reg  [27:1] mb_addr;
reg  [63:0] mb_din;
reg   [7:0] mb_be;
reg         mb_req = 0;
reg         mb_rnw = 1;
wire        mb_ready;
wire [63:0] mb_dout;

reg   [1:0] mb_state = 0;     // 0 poll, 1 await read, 2 await nds_debug, 3 write
reg  [11:0] mb_tmr   = 0;
reg   [7:0] mb_seq   = 0;     // last sequence number acted on
reg   [7:0] mb_ack;
reg  [31:0] mb_answer;
// Outer timeout, deliberately 4x nds_debug's own 16-bit PEEK timeout: that unit
// must always be the one to give up first, or its late rsp_stb would land on the
// *next* command and answer it with the wrong data.
reg  [17:0] mb_watchdog;
reg         mb_issued = 0;    // response write posted, waiting on ch4 ready

// Op 0x0B (FORCE_CART) is answered by NDS.sv, not nds_debug: cart_loaded lives
// here. nds_debug still sees the strobe and falls through to its STATUS reply,
// so the host gets an ack like any other command.
assign cart_force = dbg_cmd_stb && (dbg_cmd_op == 8'h0B);

always @(posedge clk_sys) begin
	mb_req      <= 0;
	dbg_cmd_stb <= 0;
	mb_tmr      <= mb_tmr + 1'd1;

	case (mb_state)
		2'd0: if (mb_tmr == 0) begin
			mb_addr  <= DBG_CMD_ADDR;
			mb_rnw   <= 1;
			mb_req   <= 1;
			mb_state <= 2'd1;
		end

		2'd1: if (mb_ready) begin
			if ((mb_dout[63:48] == 16'hDB90) && (mb_dout[47:40] != mb_seq)) begin
				dbg_cmd_op  <= mb_dout[39:32];
				dbg_cmd_arg <= mb_dout[31:0];
				dbg_cmd_stb <= 1;
				mb_ack      <= mb_dout[47:40];
				mb_watchdog <= 0;
				mb_state    <= 2'd2;
			end
			else mb_state <= 2'd0;
		end

		2'd2: begin
			// nds_debug answers every command with exactly one rsp_stb, except
			// that PEEK waits on the ARM9 bus - an unmapped address would never
			// complete. Answer for it rather than stranding the channel.
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
			// One request only: mb_req is re-cleared at the top of the block
			// every cycle, so an unguarded assert here would post a fresh write
			// on each pass while waiting for ready.
			mb_addr <= DBG_RSP_ADDR;
			mb_din  <= {16'hDB91, mb_ack, 8'h00, mb_answer};
			mb_be   <= 8'hFF;
			mb_rnw  <= 0;
			if (!mb_issued) begin
				mb_req    <= 1;
				mb_issued <= 1;
			end
			else if (mb_ready) begin
				// advance the acked sequence only once the beat is posted
				mb_seq    <= mb_ack;
				mb_issued <= 0;
				mb_state  <= 2'd0;
			end
		end
	endcase
end

// DDR3 framebuffer window (machinery in the VIDEO section below): 32bpp
// {14'b0, BGR666}, line = 1 KB, screen s at +s*0x40000; [0x0FE00000,
// 0x0FF00000) sits below the firmware image, above the card ceiling.
localparam [27:1] FB_HW_BASE = 27'h7F00000;  // byte address 0x0FE00000 >> 1
localparam  [7:0] FB_BURST   = 8'd128;       // beats per command (any divisor of 128)

ddram ddram
(
	.*,

	.ch1_addr(fwc_addr),
	.ch1_din(fwc_din),
	.ch1_req(fwc_req),
	.ch1_rnw(fwc_rnw),
	.ch1_dout(fwc_dout),
	.ch1_ready(fwc_ready),

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

	// ch4: nds_debug mailbox (uncached channel, see DEBUG MAILBOX above)
	.ch4_addr(mb_addr),
	.ch4_din(mb_din),
	.ch4_req(mb_req),
	.ch4_rnw(mb_rnw),
	.ch4_be(mb_be),
	.ch4_dout(mb_dout),
	.ch4_ready(mb_ready),

	// ch5/ch6: DDR3 framebuffer (write bursts / scanout prefetch), see VIDEO
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
wire [13:0] vrsrv_addr_c;
wire        vrsrv_ready_c;

reg  [31:0] vsrv_dout_r;
reg  [63:0] vrsrv_dout_r;   // 64-bit A..D line, see nds_vram's rsrv_* port
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
// sdram.sv's ch1 holds ONE request at a time (ch1_rq is a single bit), while
// nds_vram's renderer server issues its A..D reads pipelined. Without a ready
// line, every request arriving while ch1 was busy was simply dropped - the core
// would then wait forever for a word that was never asked for. So the channel
// exports back-pressure and the core throttles itself to what ch1 can actually
// take. Pipelining ch1 itself is a separate change and needs hardware to
// validate; this makes the current depth correct rather than lucky.
//
// req/ready is now a proper VALID/READY handshake: nds_vram HOLDS the request
// until an edge at which ready is high, and that edge is the transfer. It gave
// up pulsing because a pulse is issued on a ready sampled BEFORE the request
// exists, so its correctness depends on how fast ready falls after acceptance -
// see nds_vram's port comment for the drop that produced in simulation.
//
// This side had to change with it, and the edge detect it replaces is why:
// `vrsrv_req_c & ~vr_req_d` needs the request to go low between requests. A held
// request never does, so the first would have been taken and every later one
// silently ignored - a wedge on hardware only. It is not an independent fix.
//
// For both ends to agree on WHICH edge the transfer was, this side must sample
// the interface at exactly the edge the core does: clkMemIndex == 2 is the clkMem
// edge coincident with the clk1x rising edge (see the counter's contract at the
// top of this file). Accepting at any other phase would take a request the core
// goes on holding, and then serve it twice.
//
// Note what is NOT claimed here. The old pulse scheme did not drop on hardware:
// vr_busy rises, and so ready falls, one clkMem cycle after acceptance, a third
// of a clk1x period before the core samples again - so the core never issued
// into a busy channel. It was correct by a timing coincidence between two
// domains, and this removes the reliance on it rather than fixing a silicon bug.
// The hardware white screen was a livelock in nds_gpu2d's drawline routing.
//
// It also removes the need to latch a dropped request the way the firmware
// channel does with fwr_pend: with a held request there is nothing to drop.
reg        vr_busy = 0, vr_fin = 0;
reg        sd_vr_req = 0;
reg [25:0] vr_adr;

// ready must be a clk1x-observable level: low from acceptance until the done
// pulse has been presented, so the core never issues into a busy channel
assign vrsrv_ready_c = ~vr_busy & ~vr_fin;

always @(posedge clk_mem) begin
	sd_vr_req <= 0;

	if (vrsrv_req_c & vrsrv_ready_c & (clkMemIndex == 2'd2)) begin
		// halfword addr [26:1]; the line address makes it 8-byte aligned, which is
		// what lets the whole burst be used - a sequential SDRAM burst wraps inside
		// its aligned block, so an unaligned request returns these same eight bytes
		// rotated and dout[63:32] would not be the neighbouring word.
		vr_adr    <= {8'd0, vrsrv_bank_c, vrsrv_addr_c, 2'b00};
		sd_vr_req <= 1;
		vr_busy   <= 1;
	end

	if (vr_busy & sd_ch1_ready) begin
		vrsrv_dout_r <= sd_ch1_dout;   // the whole aligned 8-byte line
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

// touchscreen v1: left analog stick as the pen, "Touch" button as pen-down
wire [7:0] touch_x = {~joystick_analog_0[7],  joystick_analog_0[6:0]};
wire [7:0] touch_y = {~joystick_analog_0[15], joystick_analog_0[14:8]};

nds_port_wrap nds
(
	.clk1x(clk_sys),
	// ISLAND=0 CONFIGURATION. The island runs at clk_sys, i.e. 1:1.
	//
	// A slower island at a NON-INTEGER ratio is counterproductive and the /16 fit
	// proved it: cross-domain setup budget is set by EDGE ALIGNMENT, not by period.
	// At 2:1 with coincident edges a clk1x->island path gets a full fast-clock
	// period (14.919 ns); at 3:2 the closest opposing edge is only half an island
	// period (9.946 ns), so every crossing lost a third of its budget and the
	// island went -2.809 -> -8.362 (build/artifacts-isl16) even though its own
	// period grew. Only integer ratios are viable, and there is no integer between
	// 1 and 2 - so the choice is 2:1 (fails at -2.809) or 1:1 (this).
	//
	// 1:1 is now known to be functionally correct: bootreq passes with
	// pass=0x5A5BDE7F and the IO chain fully matched. The old "ISLAND=0 stalls"
	// result was a testbench delta cycle, and no ARM9:ARM7 ratio is required by
	// Kirby's handshake (both sides wait unboundedly). The cost is ARM9 clock, to
	// be won back on CPI - the caches are not even enabled in anything measured so
	// far.
	.clk2x(clk_sys),
	.clkMem(clk_mem),
	.clkMemIndex(clkMemIndex),
	.reset(reset | bios_load_reset),
	.nds_on(nds_on),
	// REVERSED 2026-07-29. docs/ARCHITECTURE.md recorded "firmware boot menu =
	// never" and this was hardwired to 1. A real firmware boot path now exists
	// and is OSD-selectable on status[9]:
	//   0 = HLE direct boot, unchanged, the path everything so far was tested on
	//   1 = both retail BIOSes run from their reset vectors and the firmware
	//       boots the cart itself, which is what initialises ARM9 CP15 properly
	//       instead of us faking melonDS's SetupDirectBoot values at CPU reset
	// Needs all three images loaded from the OSD: ARM7 BIOS, ARM9 BIOS, Firmware.
	// direct_boot stays 1 because fw_boot short-circuits nds_loader's CARTID_CALC
	// before ENV_SET is ever reached, so the env-block choice is moot when set.
	//
	// KNOWN LIMIT: firmware boot reaches 1.588 s of DS time in sim and then the
	// ARM7 executes Thumb code in ARM state at 0x037FE28C (lost T bit - see
	// HANDOFF). Expect it to reach the firmware's video init and then wedge.
	.direct_boot(1'b1),
	.fw_boot(status[9]),
	.gpu_full_pace(status[10]),

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

assign AUDIO_L = NDS_AUDIO_L;
assign AUDIO_R = NDS_AUDIO_R;

////////////////////////////  VIDEO  ////////////////////////////////////

// v1 decision: dual 256x192 screens stacked vertically (like a real DS held
// open), single-buffered, free-running ~59.8 Hz scanout - an occasional
// tear is accepted (per-line atomicity makes it a horizontal seam only).
// The framebuffers live in DDR3 (M10K eviction, FITTING.md): each engine's
// merge drain (256 consecutive clk_sys writes per line, both engines at
// once) lands in a per-engine line accumulator, a drain FSM bursts finished
// lines to DDR3 through ddram ch5, and the scanout prefetches display line
// N+1 through ddram ch6 into a double-banked line buffer while line N
// shows. Pixels are 32bpp {14'b0, BGR666} - full 18-bit DS fidelity, two
// per 64-bit beat. FB_HW_BASE/FB_BURST are declared above the ddram
// instance they feed; the machinery lives in rtl/nds_fb_ddr3.sv.
reg        pf_tgl = 0;                // prefetch request toggle (CLK_VIDEO)
reg        pf_scr;
reg  [7:0] pf_line;
reg        pf_bank;
wire [35:0] lb_q;
wire [27:1] fb5_addr, fb6_addr;
wire [63:0] fb5_din, fb6_dout;
wire        fb5_req, fb5_next, fb5_ready;
wire        fb6_req, fb6_valid, fb6_ready;

// Temporary live-hardware telemetry. The DDR writer periodically stores twelve
// raw state words where SSH/devmem can read them without depending on rendering:
//   x0/x1 PC9, x2/x3 ARM9 r0, x4/x5 ARM9 lr, x6 ARM9 CPSR,
//   x7/x8 PC7, x9 reserved, x10 core status, x11 shell status.
wire [17:0] dbg_shellstat = {10'b0, bios9_loaded, bios7_loaded, cart_loaded,
	                         nds_on, reset, bios9_download, bios7_download,
	                         boot_done};

nds_fb_ddr3 #(.FB_HW_BASE(FB_HW_BASE), .FB_BURST(FB_BURST)) fb_ddr3
(
	.clk_sys(clk_sys),
	.CLK_VIDEO(CLK_VIDEO),

	.pix_x(pix_x),   .pix_y(pix_y),   .pix_d(pix_d),   .pix_we(pix_we),
	.pixb_x(pixb_x), .pixb_y(pixb_y), .pixb_d(pixb_d), .pixb_we(pixb_we),
	// Lanes 2..5 and 9 now carry the main-RAM verify result instead of ARM9
	// r0/lr: r0 reads 0 and lr is a known constant in the idle thread, so they
	// tell us nothing further, whereas nothing has ever observed whether SDRAM
	// main RAM reads back what the loader wrote. dbg9 mirrors the mismatch
	// count so a single beat at 0x3FE2FC20 answers the question.
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
	.lb_raddr({vcnt[0], hcnt[7:1]}),
	.lb_q(lb_q),

	.fb5_addr(fb5_addr), .fb5_din(fb5_din), .fb5_req(fb5_req),
	.fb5_next(fb5_next), .fb5_ready(fb5_ready),

	.fb6_addr(fb6_addr), .fb6_req(fb6_req), .fb6_dout(fb6_dout),
	.fb6_valid(fb6_valid), .fb6_ready(fb6_ready)
);

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
reg        lbq_sel;

// vnext = the line about to start at the wrap; vpf = the one to prefetch
// while vnext displays. Bank parity is vpf[0], so the prefetch target is
// always the opposite bank of the line being read.
wire [9:0] vnext = (vcnt == V_TOTAL-1) ? 10'd0 : vcnt + 10'd1;
wire [9:0] vpf   = (vnext == V_TOTAL-1) ? 10'd0 : vnext + 10'd1;

always @(posedge CLK_VIDEO) begin
	// the pair fetch runs every clock inside nds_fb_ddr3 (lb_raddr -> lb_q);
	// lbq_sel tracks it with the same one-clock lag
	lbq_sel <= hcnt[0];

	ce_cnt <= ce_cnt + 1'd1;
	ce_pix <= (ce_cnt == 2'd3);

	if (ce_cnt == 2'd3) begin
		// output the dot for the current counters (fetched during the last
		// 4 clocks), then advance
		hbl <= ~(hcnt < H_ACTIVE);
		vbl <= ~(vcnt < V_ACTIVE);
		hs  <= (hcnt >= HS_BEG && hcnt < HS_END);
		vs  <= (vcnt >= VS_BEG && vcnt < VS_END);

		// BGR666 -> RGB888 (B in [17:12]); pair half picked by x parity
		{b_out, g_out, r_out} <= lbq_sel ?
			{lb_q[35:30], lb_q[35:34], lb_q[29:24], lb_q[29:28], lb_q[23:18], lb_q[23:22]} :
			{lb_q[17:12], lb_q[17:16], lb_q[11:6],  lb_q[11:10], lb_q[5:0],   lb_q[5:4]};
		if (hcnt == H_TOTAL-1) begin
			hcnt <= 0;
			vcnt <= vnext;
			// request the prefetch of vpf into bank vpf[0] for the line
			// starting now; blanking lines (vpf >= 384) fetch nothing
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

assign VGA_F1 = 0;
assign VGA_SL = sl[1:0];

wire [2:0] scale = status[4:2];
wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;

// Clash port of the NDS-active video_mixer branch. Gamma RAM stays in the
// wrapper; NDS ties the non-portable scandoubler/HQ2x/freeze branches low.
nds_clash_video_mixer #(.LINE_LENGTH(600), .GAMMA(1)) video_mixer
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
