derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# The fixed-resolution video PLL is genuinely asynchronous to everything else.
#
# sys/sys_top.sdc already declares one exclusive group per PLL it knows about
# (the core's main PLL, pll_hdmi, pll_audio, ...). pll_video is ours and is not
# in that list, so without this TimeQuest relates it to the main PLL and tries
# to close every clk_sys <-> CLK_VIDEO path as if the two were phase-locked.
# They are not: 27.000000 MHz is not a divisor of any VCO that also yields the
# 33.513982 MHz NDS master clock, which is the whole reason it has its own PLL.
#
# MEASURED, first 480p fit: without this the design reports four negative-slack
# domains at up to -7.090 ns and TNS -219, all on crossings that are already
# handled properly in RTL - nds_fb_ddr3 passes the prefetch request as a toggle
# and reads the line buffer on CLK_VIDEO. The paths are safe; the analysis was
# wrong.
#
# This is a CORRECT constraint rather than a silencer, but it is only correct
# while that stays true: anything new crossing clk_sys <-> CLK_VIDEO needs its
# own synchroniser, because this tells the fitter not to check.
#
# Guarded so the native (non-NDS_FIXEDRES) build, which has no pll_video and
# runs the scanout off the main PLL's 67.028 MHz output, still reads this file.
# ---------------------------------------------------------------------------
# A SINGLE group is deliberate: -asynchronous with one group declares that
# group unrelated to every other clock in the design, which is what an
# independent PLL actually is. Naming only the main PLL was not enough - the
# first attempt did that and left Setup 'sysmem' at -7.139 / TNS -28.107,
# because sys_top.sdc puts h2f_user0_clk in its own group and pll_video was in
# nobody's.
#
# Those h2f paths are not new and are not newly unchecked. The clock-transfer
# table shows exactly 4 of them, and while CLK_VIDEO came off the main PLL they
# sat inside sys_top.sdc's existing h2f <-> main-PLL false-path cut. Giving the
# video clock its own PLL only moved them out of that cut; this puts them back
# under the same treatment they already shipped with.
if {[llength [get_clocks -nowarn {*|pll_video_inst|altera_pll_i|*|divclk}]] > 0} {
   set_clock_groups -asynchronous \
      -group [get_clocks {*|pll_video_inst|altera_pll_i|*|divclk}]
}
