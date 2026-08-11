#!/bin/sh
# Card B7 block-read cost: measures a 512-word transfer against the melonDS
# pacing floor, with an image model shaped like ddram ch2 (beat cache, one
# request in flight, periodic framebuffer-burst collisions). See
# sim/tb_card_read.vhd.
# Usage: sim/run_card_read.sh [LAT] [CARDSPEED_SHIFT] [FBSTALL]
set -eu
cd "$(dirname "$0")/.."

LAT=${1:-60}
SHIFT=${2:-0}
FBSTALL=${3:-130}
PF=${4:-4}

WORK=sim/nvc_work
mkdir -p "$WORK"

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/nds_card.vhd \
   sim/tb_card_read.vhd

nvc -L "$WORK" --work="$WORK/work" -e tb_card_read \
   -gLAT="$LAT" -gSHIFT="$SHIFT" -gFBSTALL="$FBSTALL" -gPF="$PF"
nvc -L "$WORK" --work="$WORK/work" -r tb_card_read --ieee-warnings=off --exit-severity=failure
