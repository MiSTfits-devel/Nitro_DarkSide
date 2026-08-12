# Checked-in Clash output and the deliberately small compatibility wrappers.
# This file is sourced by NDS.qsf after the framework and core QIPs.
set_global_assignment -name SYSTEMVERILOG_FILE clash/rtl/nds_clash_video_mixer_core.sv
set_global_assignment -name SYSTEMVERILOG_FILE clash/rtl/nds_clash_video_mixer.sv
set_global_assignment -name SYSTEMVERILOG_FILE clash/rtl/nds_hps_io_boundary.sv
set_global_assignment -name SYSTEMVERILOG_FILE clash/rtl/nds_video_freak.sv
set_global_assignment -name VERILOG_FILE clash/rtl/nds_sigma_delta_dac.v
set_global_assignment -name SYSTEMVERILOG_FILE clash/rtl/nds_hps_io.sv
