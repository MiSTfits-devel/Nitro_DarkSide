#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# All-Haskell native vertical slice on macOS: the production Clash ARM9 slice
# plus its timer/IRQ-latch router (Nds.WholeCore.Arm9Soc) executes an assembled
# fixture and drives the authoritative Nds.Gpu.Live device over its GPU
# ready/valid link. No melonDS anywhere.
#
#   run.sh [--soc] [FRAMES]          headless: BMP+PNG frames, frames.ndsf, report.txt
#   run.sh --view [--soc] [FRAMES]   same producer piped into NativeSliceView (AppKit)
#
# Default fixture: sim/tests/hs_native_slice.S (display only). --soc selects
# sim/tests/hs_native_soc.S (display + timer 0 IRQ latch + GPU VBlank IRQ latch)
# and its acceptance checks.
#
# Outputs go to $OUT (default ${TMPDIR:-/tmp}/nds-native-slice). Exit status is
# the host's acceptance verdict (headless) or the viewer's (view).
set -euo pipefail
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=${OUT:-${TMPDIR:-/tmp}/nds-native-slice}
view=0
if [ "${1:-}" = --view ]; then view=1; shift; fi
fixture=hs_native_slice
check=()
if [ "${1:-}" = --soc ]; then fixture=hs_native_soc; check=(--soc); shift; fi
frames=${1:-12}
mkdir -p "$out/frames"
out=$(CDPATH= cd -- "$out" && pwd)
: >"$out/build.log"

for tool in arm-none-eabi-as arm-none-eabi-objcopy stack; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 2; }
done
arm-none-eabi-as -EL -o "$out/rom.o" "$repo/sim/tests/$fixture.S"
arm-none-eabi-objcopy -j .text -O binary "$out/rom.o" "$out/rom.bin"
od -An -v -tx4 "$out/rom.bin" | awk '{for (i=1; i<=NF; i++) print $i}' >"$out/rom.hex"

(cd "$repo/clash" && stack --resolver lts-22.43 ghc -- -O2 -isrc -itest \
    -outputdir "$out/ghc" test/NativeSliceFrames.hs -o "$out/native-slice-frames") >>"$out/build.log" 2>&1 ||
    { echo "Haskell build failed; see $out/build.log" >&2; exit 1; }

rm -f "$out"/frames/frame-*.bmp "$out"/frames/frame-*.png
if [ "$view" = 1 ]; then
    swiftc -O "$repo/tools/hs_native_slice/NativeSliceView.swift" -o "$out/native-slice-view" >>"$out/build.log" 2>&1 ||
        { echo "viewer build failed; see $out/build.log" >&2; exit 1; }
    "$out/native-slice-frames" "$out/rom.hex" ${check[@]+"${check[@]}"} --frames "$frames" --out "$out/frames" --ndsf - \
        2>"$out/report.txt" | "$out/native-slice-view" 2>"$out/view.log"
    exit
fi
status=0
"$out/native-slice-frames" "$out/rom.hex" ${check[@]+"${check[@]}"} --frames "$frames" --out "$out/frames" \
    --ndsf "$out/frames.ndsf" >"$out/report.txt" 2>&1 || status=$?
for bmp in "$out"/frames/frame-*.bmp; do
    [ -e "$bmp" ] || continue
    sips -s format png "$bmp" --out "${bmp%.bmp}.png" >/dev/null
done
cat "$out/report.txt"
echo "frames: $out/frames  stream: $out/frames.ndsf"
exit $status
