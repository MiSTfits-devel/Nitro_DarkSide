`timescale 1ns/10ps
module nitro_pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'
	output wire outclk_0,

	// interface 'outclk1'
	output wire outclk_1,

	// interface 'outclk2'
	output wire outclk_2,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(3),
		// outclk_0 = clkMem, an exact integer multiple of clk1x (outclk_2)
		// from this same VCO. Kept in step with NDS.sv's
		// CLKMEM_RATIO by the one macro: raising the PLL without raising the
		// phase indices would double-serve renderer reads, so neither is
		// allowed to move on its own.
		//   3x = 100.541946 MHz (default)
		//   fast = 134.055928/67.027964/33.513982 MHz (NDS_CLKMEM_4X;
		//          native DS cadence with a 4x SDRAM clock).
		//   bring-up = 80/40/20 MHz (NDS_PLL_BRINGUP; see below).
		// The whole clock family moves together to preserve its exact 4:2:1
		// phase relationship; changing clkMem alone is not a legal PLL setup.
		//
		// NDS_PLL_BRINGUP builds the console below its measured Fmax so the
		// image is timing-clean and can answer one question on hardware: does
		// the RTL work at all? Seed 2 was constrained at the native cadence and
		// closed at 126.77 / 43.67 / 25.06 MHz -- the ARM9 domain reaching 65%
		// of its required frequency across TNS -35,389 ns -- so that image
		// could not execute regardless of what it showed on screen. clk2x is
		// the binding domain at 43.67 MHz; 40 MHz leaves 8.4% margin and keeps
		// the family on exact 4:2:1 round numbers. The console then runs at
		// 40/67.027964 = 59.7% of native speed. Note the emulated RTC counts
		// nds_rtc.vhd's CYCLES_PER_SEC = 33513982 clk1x cycles per second and
		// will therefore run ~1.68x fast in this configuration; that constant
		// is deliberately left alone so the build differs from a shipping one
		// by clock frequency only.
`ifdef NDS_PLL_BRINGUP
		.output_clock_frequency0("80.0 MHz"),
`elsif NDS_CLKMEM_4X
		.output_clock_frequency0("134.055928 MHz"),
`else
		.output_clock_frequency0("100.541946 MHz"),
`endif
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
`ifdef NDS_PLL_BRINGUP
		.output_clock_frequency1("40.0 MHz"),
`elsif NDS_CLKMEM_4X
		.output_clock_frequency1("67.027964 MHz"),
`else
		.output_clock_frequency1("67.027964 MHz"),
`endif
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
`ifdef NDS_PLL_BRINGUP
		.output_clock_frequency2("20.0 MHz"),
`elsif NDS_CLKMEM_4X
		.output_clock_frequency2("33.513982 MHz"),
`else
		.output_clock_frequency2("33.513982 MHz"),
`endif
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
		.outclk	({outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule
