#!/usr/bin/env python3
# M5 frame diff: tb_top_frame RTL dump (RGB555) vs melonds_fbdump (ARGB8888).
#
#   compare_fb.py <rtl_dump.txt> <melonds_dump.txt> [--rtl-frame N] [--mds-frame N]
#                 [--ppm-prefix out]
#
# The RTL pixel is expanded exactly like melonDS's pipeline: c6 = c5 << 1,
# c8 = (c6 << 2) | (c6 >> 4), so an unblended scene must match bit-exact.
# Default compares the LAST frame of each dump (both must be stable frames).
# Exit 0 on pixel-perfect match, 1 otherwise.
import argparse
import sys

W, H = 256, 192


def load_frames(path):
    frames = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("frame"):
                frames.append([])
            else:
                frames[-1].append(int(line, 16))
    for n, fr in enumerate(frames):
        if len(fr) != W * H:
            sys.exit(f"{path}: frame {n} has {len(fr)} pixels, want {W*H}")
    return frames


def rgb555_to_argb(p):
    out = 0xFF000000
    for shift, dst in ((0, 16), (5, 8), (10, 0)):
        c5 = (p >> shift) & 0x1F
        c6 = c5 << 1
        c8 = ((c6 << 2) | (c6 >> 4)) & 0xFF
        out |= c8 << dst
    return out


def write_ppm(path, argb):
    with open(path, "wb") as f:
        f.write(f"P6 {W} {H} 255\n".encode())
        for p in argb:
            f.write(bytes(((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rtl")
    ap.add_argument("mds")
    ap.add_argument("--rtl-frame", type=int, default=-1)
    ap.add_argument("--mds-frame", type=int, default=-1)
    ap.add_argument("--ppm-prefix", default=None)
    ap.add_argument("--max-report", type=int, default=24)
    args = ap.parse_args()

    rtl = load_frames(args.rtl)[args.rtl_frame]
    mds = load_frames(args.mds)[args.mds_frame]

    rtl_argb = [rgb555_to_argb(p) for p in rtl]

    if args.ppm_prefix:
        write_ppm(f"{args.ppm_prefix}_rtl.ppm", rtl_argb)
        write_ppm(f"{args.ppm_prefix}_mds.ppm", mds)

    bad = [(i % W, i // W, rtl_argb[i], mds[i])
           for i in range(W * H) if rtl_argb[i] != mds[i]]
    if not bad:
        print(f"PASS: pixel-perfect ({W}x{H})")
        return 0
    print(f"FAIL: {len(bad)} / {W*H} pixels differ")
    # summarize by line to show structure (dropped/stale lines show as full rows)
    lines = {}
    for x, y, a, b in bad:
        lines[y] = lines.get(y, 0) + 1
    fullrows = [y for y, c in sorted(lines.items()) if c == W]
    if fullrows:
        print(f"  full-row mismatches ({len(fullrows)} rows): {fullrows[:16]}"
              f"{' ...' if len(fullrows) > 16 else ''}")
    for x, y, a, b in bad[:args.max_report]:
        print(f"  ({x:3},{y:3}) rtl={a:08x} mds={b:08x}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
