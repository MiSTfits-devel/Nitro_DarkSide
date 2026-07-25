#!/bin/sh
# Cartridge chip-ID agreement test: nds_loader's direct-boot env block word at
# 0x02FFF800 and nds_card's B8 command answer must match for any ROM size
# (nds_card used to hardcode the 64 MB value). See sim/tb_card_chipid.vhd.
set -eu
cd "$(dirname "$0")/.."

WORK=sim/nvc_work
mkdir -p "$WORK"

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/nds_loader.vhd \
   rtl/nds_card.vhd \
   sim/tb_card_chipid.vhd

nvc -L "$WORK" --work="$WORK/work" -e tb_card_chipid
nvc -L "$WORK" --work="$WORK/work" -r tb_card_chipid --ieee-warnings=off --exit-severity=failure
