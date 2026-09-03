derive_pll_clocks
derive_clock_uncertainty

# sys_top.sdc decouples the shell's clock domains from each other with an
# -exclusive group list, but that list predates this core and does not mention
# the Nitro island PLL. Clocks absent from every group stay related to all of
# them, so TimeQuest analysed island <-> audio / HDMI / h2f / FPGA_CLK* as
# synchronous transfers and reported large violations on crossings that are
# resynchronised in RTL. Declare the island PLL asynchronous against every
# shell domain, and against the retained 60 MHz shell/DDR PLL: all paths
# between them terminate in explicit toggle synchronizers or the Gray-pointer
# pixel FIFO.
set_clock_groups -asynchronous \
    -group [get_clocks { *|island_pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
    -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
    -group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks { spi_sck}] \
    -group [get_clocks { hdmi_sck}] \
    -group [get_clocks { *|h2f_user0_clk}] \
    -group [get_clocks { FPGA_CLK1_50 }] \
    -group [get_clocks { FPGA_CLK2_50 }] \
    -group [get_clocks { FPGA_CLK3_50 }]
