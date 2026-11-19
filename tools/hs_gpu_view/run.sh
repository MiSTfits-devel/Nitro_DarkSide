#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Native host viewer for the Haskell GPU.
#
#   run.sh CART.nds [FRAMES]                closed-loop Haskell GPU + melonDS CPUs/peripherals
#   run.sh --replay TRACE.nsd2              recorded trace diagnostic, not live
#   run.sh --open-loop CART.nds [FRAMES]    explicit legacy trace diagnostic
#
# Default live mode makes the Haskell service authoritative for GPU I/O,
# memory, capture, video events, IRQ and DMA. No melonDS GPU is on that path.
# Replay/open-loop remain separate diagnostics. Any producer failure stops
# the machine and leaves the last actual bitmap visibly STOPPED, NOT LIVE.
# FBDUMP / HS_GPU_LIBRARY may select already-built binaries for a measured run.
set -euo pipefail
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=${OUT:-${TMPDIR:-/tmp}/nds-hsview}
mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd)

mode=closed-loop
case ${1:-} in
    --replay) mode=replay; trace=${2:?usage: run.sh --replay TRACE.nsd2} ;;
    --open-loop) mode=open-loop; cart=${2:?usage: run.sh --open-loop CART.nds [FRAMES]}; frames=${3:-1000000} ;;
    "") echo "usage: run.sh CART.nds [FRAMES] | --replay TRACE.nsd2 | --open-loop CART.nds [FRAMES]" >&2; exit 2 ;;
    *) cart=$1; frames=${2:-1000000} ;;
esac

: >"$out/build.log"
fbdump=${FBDUMP:-$repo/sim/melonds_tracer/build-vendored/melonds_fbdump}
if [ "$mode" != replay ] && [ -z "${FBDUMP:-}" ]; then
    sh "$repo/sim/melonds_tracer/build-fbdump-vendored.sh" >>"$out/build.log" 2>&1 ||
        { echo "CPU bridge build failed; see $out/build.log" >&2; exit 1; }
fi
if [ "$mode" = closed-loop ]; then
    service=${HS_GPU_LIBRARY:-$out/hs-gpu-$$.dylib}
    if [ -z "${HS_GPU_LIBRARY:-}" ]; then
        # This launch's private library; nothing else may map it after exit.
        trap 'rm -f "$service"' EXIT
        # A distinct output inode per launch: never overwrite a mapped dylib.
        (cd "$repo/clash" && stack --resolver lts-22.43 ghc -- -O2 -dynamic \
            -shared -fPIC -flink-rts -threaded -no-hs-main -isrc -itest \
            -outputdir "$out/obj-service" test/GpuService.hs -o "$service") >>"$out/build.log" 2>&1 ||
            { echo "Haskell GPU build failed; see $out/build.log" >&2; exit 1; }
    fi
    printf '%s\n' "$service" >"$out/service-path.txt"
else
    (cd "$repo/clash" && stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
        -outputdir "$out/obj-trace" test/TraceView.hs -o "$out/trace-view") >>"$out/build.log" 2>&1 ||
        { echo "Trace renderer build failed; see $out/build.log" >&2; exit 1; }
fi
swiftc -O "$repo/tools/hs_gpu_view/NdsView.swift" "$repo/tools/hs_gpu_view/main.swift" \
    -o "$out/nds-view" >>"$out/build.log" 2>&1 ||
    { echo "build failed; see $out/build.log" >&2; exit 1; }

if [ "$mode" = replay ]; then
    "$out/trace-view" "$trace" 2>"$out/trace-view.log" \
        | NDS_VIEW_MODE=replay NDS_VIEW_PRODUCER_LOG=$out/trace-view.log \
          "$out/nds-view" 2>"$out/nds-view.log"
    exit
fi

input=$out/input.bin
: >"$input"
if [ "$mode" = closed-loop ]; then
    "$fbdump" --direct --hs-gpu "$service" --hs-ndsf - --no-text-dump \
        --input "$input" "$cart" /dev/null "$frames" \
        2>"$out/melonds.log" \
        | NDS_VIEW_MODE=closed-loop NDS_VIEW_PRODUCER_LOG=$out/melonds.log \
          NDS_VIEW_INPUT=$input \
          "$out/nds-view" 2>"$out/nds-view.log"
    exit
fi
"$fbdump" --direct --input "$input" --trace2d /dev/fd/3 --trace2d-raw3d \
    "$cart" /dev/null "$frames" 3>&1 >"$out/melonds.log" 2>&1 \
    | "$out/trace-view" /dev/stdin 2>"$out/trace-view.log" \
    | NDS_VIEW_MODE=open-loop NDS_VIEW_PRODUCER_LOG=$out/trace-view.log \
      NDS_VIEW_INPUT=$input "$out/nds-view" 2>"$out/nds-view.log"
