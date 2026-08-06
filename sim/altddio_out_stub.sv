// SPDX-License-Identifier: GPL-2.0-or-later
//
// Simulation stub for the Altera altddio_out megafunction, enough for
// rtl/sdram.sv's SDRAM_CLK generator. With datain_h=0 / datain_l=1 - which is
// how MiSTer drives it - dataout is simply the inverse of outclock, i.e. the
// clock the SDRAM chip sees is 180 degrees from the controller's clk. The bench
// depends on that phase, so it is modelled rather than idealised away.
module altddio_out #(
	parameter extend_oe_disable      = "OFF",
	parameter intended_device_family = "Cyclone V",
	parameter invert_output          = "OFF",
	parameter lpm_hint               = "UNUSED",
	parameter lpm_type               = "altddio_out",
	parameter oe_reg                 = "UNREGISTERED",
	parameter power_up_high          = "OFF",
	parameter integer width          = 1
)(
	input  [width-1:0] datain_h,
	input  [width-1:0] datain_l,
	input              outclock,
	input              outclocken,
	input              oe,
	input              aclr,
	input              aset,
	input              sclr,
	input              sset,
	output [width-1:0] dataout
);
	assign dataout = oe ? (outclock ? datain_h : datain_l) : {width{1'bz}};
endmodule
