#!/usr/bin/env bash
# Unit test for the VRAM bank mapping decoder (nds_vram_map).
# Follows the GBA_MiSTfits nvc flow; no ROM/BIOS assets needed.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORK=sim/nvc_work
mkdir -p "$WORK"

nvc --work="$WORK/work" -a --relaxed \
   rtl/nds_vram_map.vhd \
   sim/tb_vram_map.vhd

nvc --work="$WORK/work" -e tb_vram_map
nvc --work="$WORK/work" -r tb_vram_map --ieee-warnings=off --exit-severity=failure
