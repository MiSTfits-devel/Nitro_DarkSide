# 67.027964 MHz clk2x is both CPU master and 67 MHz SDRAM controller.
# The 134 MHz and 33.51 MHz outputs of the stock PLL are not its source.
set master {}
foreach_in_collection c [get_clocks {*|island_pll|*|divclk}] {
    set p [get_clock_info -period $c]
    if {$p > 14.90 && $p < 14.94} { lappend master [get_clock_info -name $c] }
}
if {[llength $master] != 1} {error "Cannot identify single native 67 MHz SDRAM master: $master"}
create_generated_clock -name module_clk -invert -source [get_pins -compatibility_mode [lindex $master 0]] [get_ports SDRAM_CLK]
# IS42S16160G-6 CL2: tAC max 5.4, tOH min 2.7; input setup 1.5,
# hold 0.8. Assumed PCB return/clock flight 1.0 ns, output skew 0.5 ns.
set_input_delay -clock module_clk -max 6.4 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock module_clk -min 2.7 [get_ports {SDRAM_DQ[*]}]
set sd_outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_n* SDRAM_DQML SDRAM_DQMH SDRAM_CKE}]
set_output_delay -clock module_clk -max 2.0 $sd_outputs
set_output_delay -clock module_clk -min -1.3 $sd_outputs
