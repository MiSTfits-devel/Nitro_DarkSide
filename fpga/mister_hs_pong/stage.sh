#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Stage a Quartus 17 project in a new directory. Never copy from the NDS worktree.
set -euo pipefail
if [[ $# != 2 || ${1##*/} != hs_pong.v || ! -s $1 ]]; then
    echo "usage: bash $0 <Clash-generated hs_pong.v> <new project directory>" >&2
    exit 2
fi
project=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(git -C "$project" rev-parse --show-toplevel)
from=fpga/mister_nitro_console_island/sys
# Source closure of sys/sys.tcl and sys/sys.qip on Quartus 17. Only read
# the checked-in shell at HEAD, not dirty files, console RTL or game media.
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
mkdir -- "$2"
git -C "$root" archive HEAD -- "${paths[@]}" | tar -xf - -C "$2" --strip-components 2
git -C "$root" show HEAD:rtl/nds_native_osd_memory.sv >"$2/sys/nds_native_osd_memory.sv"
git -C "$root" show HEAD:rtl/nds_dv1_osd_raster.sv >"$2/sys/nds_dv1_osd_raster.sv"
cp -- "$project/HaskellPong.qpf" "$project/HaskellPong.qsf" "$project/emu.sv" "$1" "$2/"
