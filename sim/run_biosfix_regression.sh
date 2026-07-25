#!/bin/sh
# Focused plus full integration gates for BIOS read-timing changes.
set -eu
cd "$(dirname "$0")/.."

sh sim/run_bios_hotload.sh
sh sim/run_arm7_island.sh
sh sim/run_arm9_island.sh
sh sim/run_arm9_cache.sh
sh sim/run_cache9_lookup.sh
sh sim/run_dual_boot.sh
sh sim/run_analyze_all.sh
