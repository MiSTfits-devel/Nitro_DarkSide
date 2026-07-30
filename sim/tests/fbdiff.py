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

COMPARE LIKE WITH LIKE, OR THIS TOOL WILL LIE TO YOU. Three separate attempts at
one gate were invalid before the setup was right:

  1. GPUFAST=0 vs 1 at GPUCEDIV=1 - both dropped most lines (126/192 and 98/192),
     so the output differed for reasons unrelated to the change.
  2. Same pair at GPUCEDIV=3 - valid, and it gave the clean answer (0 partial rows).
  3. v1 drawer at GPUCEDIV=3 vs v2 drawer at GPUCEDIV=1 - invalid on THREE counts,
     and it produced a confident "RENDERING DIFFERENCE" verdict that was a false
     alarm. Different pacing means different drop patterns; it also means lines
     that were STARTED AND PREEMPTED, which show up as partial rows (the signature
     was exactly 192 of 256 pixels on the even rows between dropped odd rows); and
     the frame numbering does not correspond, so "frame 4" is a different moment in
     each run.

Rules, then: vary ONE thing, keep GPUCEDIV equal, and prefer a config where
`renders` is at or near 192. If both sides drop lines, this tool cannot help you.
And when a drawer or renderer is replaced wholesale, a dedicated equivalence bench
against the old implementation (see sim/run_drawer_text_equiv.sh) is a far stronger
argument than any framebuffer diff.
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
