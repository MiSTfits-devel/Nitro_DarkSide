#!/usr/bin/env python3
"""Compare two tb_top_frame framebuffer dumps, bucketing differences by scanline.

    sim/tests/fbdiff.py <a.txt> <b.txt>

Dump format: "frame <n>" followed by 49152 lines of hex (256x192, row-major).

WHY BY SCANLINE. Two configurations that both DROP render lines will differ in the
framebuffer even when both are perfectly correct, because a dropped line leaves
whole-row stale content. So a raw pixel-difference count cannot distinguish "the
renderer is wrong" from "the two runs dropped different lines", and reading it as
the former sends you hunting a bug that is not there.

The shape of the difference tells them apart:

  * differences filling ENTIRE 256-pixel rows, on a handful of rows
        -> drop-pattern difference. Expected whenever renders < 192.
  * differences SCATTERED WITHIN rows, or partial rows
        -> a real rendering difference. This is the one that condemns a change.

Calibration: the GPU_FAST clkMem work compared GPUFAST=0 vs 1. At GPUCEDIV=1 both
dropped ~2/3 and ~1/2 of lines respectively, so that comparison was meaningless -
it was rerun at GPUCEDIV=3, where the per-line budget is 6390 cycles and both fit,
leaving only ~4 drops per frame.
"""
import sys

W, H = 256, 192


def load(path):
    frames, cur = {}, None
    for line in open(path):
        line = line.strip()
        if line.startswith('frame '):
            cur = int(line.split()[1])
            frames[cur] = []
        elif cur is not None and line:
            frames[cur].append(line)
    return frames


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    a, b = load(sys.argv[1]), load(sys.argv[2])
    common = sorted(set(a) & set(b))
    print("frames: A %s   B %s   common %s"
          % (sorted(a), sorted(b), common))
    if not common:
        print("NO COMMON FRAMES - nothing to compare")
        return 2
    verdict_bad = False
    for f in common:
        pa, pb = a[f], b[f]
        if len(pa) != len(pb) or len(pa) != W * H:
            print("frame %d: unexpected length %d vs %d (want %d)"
                  % (f, len(pa), len(pb), W * H))
            verdict_bad = True
            continue
        full, partial, total = [], [], 0
        for y in range(H):
            row = sum(1 for x in range(W) if pa[y * W + x] != pb[y * W + x])
            total += row
            if row == W:
                full.append(y)
            elif row:
                partial.append((y, row))
        if total == 0:
            print("frame %d: IDENTICAL" % f)
            continue
        print("frame %d: %d pixels differ - %d full rows, %d partial rows"
              % (f, total, len(full), len(partial)))
        if full:
            print("   full rows (drop-pattern, expected if renders < 192): %s"
                  % (full if len(full) <= 12 else str(full[:12]) + " ..."))
        if partial:
            print("   PARTIAL rows (real rendering difference): %s"
                  % (partial if len(partial) <= 12 else str(partial[:12]) + " ..."))
            verdict_bad = True
    print()
    print("VERDICT: %s" % ("RENDERING DIFFERENCE - do not ship this change"
                           if verdict_bad else
                           "no partial-row differences; consistent with drop pattern only"))
    return 1 if verdict_bad else 0


if __name__ == '__main__':
    sys.exit(main())
