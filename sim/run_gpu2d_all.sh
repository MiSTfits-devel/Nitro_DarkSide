#!/bin/sh
# M9 fitting round 2 verification: all three gpu2d benches back-to-back
# (unit vectors, full-frame golden, timed) - BRAM line-buffer conversion
# must be pixel- and timing-identical.
set -eu
cd "$(dirname "$0")/.."
sh sim/run_gpu2d.sh
sh sim/run_gpu2d_frame.sh
sh sim/run_gpu2d_timed.sh
echo "gpu2d-all: OK"
