`timescale 1ns/10ps
// SPDX-License-Identifier: GPL-2.0-or-later
// Video-output PLL: exactly 27.000000 MHz for CEA-861 720x480p.
//
// WHY A SECOND PLL. The main PLL (rtl/pll/pll_0002.v) is locked to the NDS
// master clock: 33.513982 MHz and its integer multiples 67.027964 and
// 100.541946 / 134.055928. A PLL's output counters are integer divisors of one
// VCO, so every output has to divide the same VCO exactly - and 27 MHz does
// not, because 33.513982 / 27 = 1.2413 is not a ratio of small integers. There
// is no VCO that yields both, so the video clock has to come from its own PLL.
//
// WHY 27 MHz AT ALL. The scanout used to run off the 67.027964 MHz CLK_VIDEO
// because that made 2x scaling free. Measured on hardware 2026-08-10: the sink
// never saw a signal - the monitor slept rather than reporting out-of-range,
// while the MENU core's 15.7 kHz output on the same cable was measured and
// rejected. MiSTer's direct_video path exists for VGA converters and the HPS
// sets the ADV7513 up for that range; at 67 MHz nothing valid leaves the
// board. 27 MHz / 720x480p is a MANDATORY HDMI sink mode and sits inside the
// range this path is built for.
//
// The reference is the same 50 MHz board clock the main PLL uses.
module pll_video(
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,   // 27.000000 MHz
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(1),
		.output_clock_frequency0("27.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("0 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("0 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule
