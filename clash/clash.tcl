# Checked-in Clash output and the two deliberately small compatibility
# wrappers. This file is sourced by NDS.qsf after the framework and core QIPs.
set_global_assignment -name SYSTEMVERILOG_FILE clash/rtl/nds_clash_video_mixer_core.sv
set_global_assignment -name SYSTEMVERILOG_FILE clash/rtl/nds_clash_video_mixer.sv
set_global_assignment -name SYSTEMVERILOG_FILE clash/rtl/nds_hps_io_boundary.sv
