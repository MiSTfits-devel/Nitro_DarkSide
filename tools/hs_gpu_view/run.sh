#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Visible host viewer for the Haskell GPU models.
#
#   tools/hs_gpu_view/run.sh CART.nds [FRAMES]    live: melonDS CPU -> pipe -> Haskell -> window
#   tools/hs_gpu_view/run.sh --replay TRACE.nsd2  recorded v12 trace -> Haskell -> window
#
# Live mode runs melonds_fbdump (vendored melonDS: ARM9/ARM7, memory, cart,
# and its own GPU, which the CPU keeps reading) and pipes its NSD2 v12 trace
# (fd 3) into trace-view. Every displayed pixel comes from
# Nds.Gpu3D.Chip + Nds.Gpu2D; melonDS's own screen records are only counted
# for the status line. This is open loop: the Haskell GPU never feeds back into
# the emulated CPU. Pad/keyboard/mouse-touch input goes to melonDS via the
# --input control file. Logs (stderr) go to $OUT/*.log; stdout carries frames.
# Closing the window ends the pipeline (SIGPIPE); if melonDS or trace-view
# stops, the window stays open on the last actual frame, marked STOPPED.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=${OUT:-${TMPDIR:-/tmp}/nds-hsview}
mkdir -p "$out"

mode=live
case ${1:-} in
    --replay) mode=replay; trace=${2:?usage: run.sh --replay TRACE.nsd2} ;;
    "") echo "usage: run.sh CART.nds [FRAMES] | run.sh --replay TRACE.nsd2" >&2; exit 2 ;;
    *) cart=$1; frames=${2:-1000000} ;;
esac

fbdump=$repo/sim/melonds_tracer/build-vendored/melonds_fbdump
[ -x "$fbdump" ] || sh "$repo/sim/melonds_tracer/build-fbdump-vendored.sh"
(cd "$repo/clash" && stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    -outputdir "$out/obj" test/TraceView.hs -o "$out/trace-view") >"$out/build.log" 2>&1 &&
swiftc -O "$repo/tools/hs_gpu_view/NdsView.swift" "$repo/tools/hs_gpu_view/main.swift" \
    -o "$out/nds-view" >>"$out/build.log" 2>&1 ||
    { echo "build failed; see $out/build.log" >&2; exit 1; }

if [ "$mode" = replay ]; then
    "$out/trace-view" "$trace" 2>"$out/trace-view.log" \
        | NDS_VIEW_SNAPSHOT=$out/shown.png "$out/nds-view" 2>"$out/nds-view.log"
    exit
fi

input=$out/input.bin
: >"$input"
"$fbdump" --direct --input "$input" --trace2d /dev/fd/3 --trace2d-raw3d \
    "$cart" /dev/null "$frames" 3>&1 >"$out/melonds.log" 2>&1 \
    | "$out/trace-view" /dev/stdin 2>"$out/trace-view.log" \
    | NDS_VIEW_INPUT=$input NDS_VIEW_SNAPSHOT=$out/shown.png "$out/nds-view" 2>"$out/nds-view.log"
