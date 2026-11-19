project_open NDSHaskell
create_timing_netlist
read_sdc
update_timing_netlist
report_clocks -file output_files/clocks.rpt
set master {}
foreach_in_collection c [get_clocks {*|island_pll|*|divclk}] {
  set p [get_clock_info -period $c]
  if {$p>14.90 && $p<14.94} {lappend master [get_clock_info -name $c]}
}
if {[llength $master]!=1} {error "missing 67 MHz master"}
set mc [get_clocks [lindex $master 0]]
set cpu [get_registers {*|cpu|*}]
set dq [get_registers {*|dram|memory|dq_reg[*]}]
set relay [get_registers {*|dram|memory|dq_p2[*]}]
foreach_in_collection op [get_available_operating_conditions] {
  set_operating_conditions $op
  set corner [regsub -all {[^a-zA-Z0-9]} [get_operating_conditions_info -display_name $op] _]
  update_timing_netlist
  foreach typ {setup hold} {
    foreach {name args} [list core [list -from_clock $mc -to_clock $mc] cpu_from [list -from $cpu] cpu_to [list -to $cpu] dq_in [list -from_clock module_clk -to $dq] dq_relay [list -from $dq -to $relay] dq_consume [list -from $relay -to_clock $mc] dq_out [list -from_clock $mc -to_clock module_clk]] {
      report_timing -$typ {*}$args -npaths 4 -file output_files/${name}_${typ}_${corner}.rpt
    }
    foreach {name pat} {scaler {*ascal*|*} hps {*|hps_io|*} ddr {*|island|legacy|*} video {*|island|video|*}} {
      set nodes [get_registers $pat]
      if {[get_collection_size $nodes]} {report_timing -$typ -from $nodes -npaths 2 -file output_files/${name}_${typ}_${corner}.rpt}
    }
  }
}
project_close
