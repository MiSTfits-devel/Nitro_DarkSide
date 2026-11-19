#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Stage a Quartus 17 project in a new directory. Never copy from the NDS worktree.
set -euo pipefail
if [[ $# != 3 || ${1##*/} != nds_tile_soc.v || ! -s $1 || ! -s $2 ]]; then
    echo "usage: bash $0 <Clash-generated nds_tile_soc.v> <assembled ROM .hex> <new project directory>" >&2
    exit 2
fi
project=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(git -C "$project" rev-parse --show-toplevel)
words=$(wc -l <"$2" | tr -d ' ')
if (( words > 1024 )) || grep -qvE '^[0-9a-f]{8}$' "$2"; then
    echo "ROM image must be at most 1024 lowercase 8-digit hex words" >&2
    exit 2
fi
hdl=$(cd "$(dirname "$1")" && pwd)
# Only Clash output may sit beside the netlist: its Verilog modules (the RAMs'
# power-up contents are inline initial blocks), which are staged, and its
# manifest, SDC and Verilator shim, which are not (sys_top.sdc constrains the
# clocks). Anything else means the directory is not a fresh Clash output.
others=$(find "$hdl" -maxdepth 1 -type f ! -name '*.v' ! -name 'clash-manifest.json' \
    ! -name 'nds_tile_soc.sdc' ! -name 'nds_tile_soc_shim.cpp')
if [[ -n $others ]]; then
    echo "unexpected files beside $1:" >&2
    echo "$others" >&2
    exit 2
fi
from=fpga/mister_nitro_console_island/sys
# The same allowlisted shell closure as fpga/mister_hs_gfx_slice/stage.sh,
# read from the checked-in shell at HEAD: no dirty files, console RTL or game
# media.
shell_files=(
    alsa.sv arcade_video.v ascal.vhd audio_out.sv build_id.tcl ddr_svc.sv
    emu_ports.vh f2sdram_safe_terminator.sv gamma_corr.sv hps_io.sv hq2x.sv
    i2c.v i2s.v iir_filter.v ltc2308.sv math.sv mcp23009.sv mt32pi.sv osd.v
    pll_audio.qip pll_audio.v pll_audio/pll_audio_0002.qip pll_audio/pll_audio_0002.v
    pll_cfg.qip pll_cfg/altera_pll_reconfig_core.v pll_cfg/altera_pll_reconfig_top.v
    pll_cfg/pll_cfg.v pll_cfg/pll_cfg_hdmi.v pll_hdmi.qip pll_hdmi.v
    pll_hdmi/pll_hdmi_0002.qip pll_hdmi/pll_hdmi_0002.v pll_hdmi_adj.vhd pll_q17.qip
    scandoubler.v scanlines.v sd_card.sv shadowmask.sv sigma_delta_dac.v spdif.v
    sys.qip sys.tcl sys_analog.tcl sys_top.sdc sys_top.v sysmem.sv
    vga_out.sv video_cleaner.sv video_freak.sv video_freezer.sv video_mixer.sv yc_out.sv
)
paths=()
for file in "${shell_files[@]}"; do paths+=("$from/$file"); done
mkdir -- "$3"
git -C "$root" archive HEAD -- "${paths[@]}" | tar -xf - -C "$3" --strip-components 2
git -C "$root" show HEAD:rtl/nds_native_osd_memory.sv >"$3/sys/nds_native_osd_memory.sv"
git -C "$root" show HEAD:rtl/nds_dv1_osd_raster.sv >"$3/sys/nds_dv1_osd_raster.sv"
cp -- "$project/HaskellTileSlice.qpf" "$project/HaskellTileSlice.qsf" "$project/emu.sv" "$3/"
mkdir -- "$3/hdl"
for v in "$hdl"/*.v; do
    cp -- "$v" "$3/hdl/"
    echo "set_global_assignment -name VERILOG_FILE hdl/${v##*/}" >>"$3/HaskellTileSlice.qsf"
done
# Pad to the full 4 KiB boot window so every ROM word is defined.
{ cat "$2"; for ((i = words; i < 1024; i++)); do echo 00000000; done; } >"$3/hs_tile_arm9.hex"
