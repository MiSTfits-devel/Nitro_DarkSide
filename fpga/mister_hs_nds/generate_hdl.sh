#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Execute in the clash source directory with the repository's Clash in PATH.
# No ROM, memory initialization, or proprietary inputs are required.
set -eu
: "${1:?usage: generate_hdl.sh OUTPUT [CPU|TILE|CART|SYSTEM ...]}"
out=$1; shift; mkdir -p "$out"; out=$(cd "$out" && pwd)
if [[ $# == 0 ]]; then set -- CPU TILE CART SYSTEM; fi
for part in "$@"; do
    case "$part" in
        CPU) unit=BiosCpuUnit; entity=biosCpuTopEntity;;
        TILE) unit=BiosTileSoc; entity=biosTileSocTopEntity;;
        CART) unit=BiosCartUnit; entity=biosCartTopEntity;;
        SYSTEM) unit=BiosSystemUnit; entity=biosSystemTopEntity;;
        *) echo "unknown component: $part" >&2;exit 2;;
    esac
    clash +RTS -M6g -N1 -RTS --verilog -main-is "$entity" -isrc \
        -fclash-no-escaped-identifiers -outputdir "$out/obj-$part" \
        -fclash-hdldir "$out/hdl" "src/Nds/WholeCore/$unit.hs"
done
