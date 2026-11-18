#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
"""Seeded scenes for the textured/translucent frame gates.

usage: gen_scene_cases.py KIND SEED COUNT SCENE_OUT VRAM_OUT

KIND selects the stage:
  gouraud      opaque, untextured, per-vertex colour (Gouraud) with perspective W
  textured     every texture format, size, wrap/flip mode and blend mode
  translucent  polygon alpha, polygon IDs, depth update, fog flag, alpha test,
               wireframe, shadow masks and shadows, blending on and off

SEED 0 adds a directed prefix of corner cases for the kind. The VRAM image is
512 KiB of random texture slots and 96 KiB of random palette slots followed by
32 KiB of zeros (palette slots 6 and 7 are unmapped in the oracle).

Vertices stay inside the post-clip viewport (X 0..256, Y 0..192) with W >= 1:
the geometry engine clips, and marks W = 0 polygons degenerate, before the
rasteriser sees them.
"""
import random
import sys


def colour(rng):
    """A FinalColor channel: mostly what the geometry engine produces from a
    5-bit vertex colour ((c << 4) | 0xF, or 0), sometimes any 9-bit value."""
    if rng.randrange(4) == 0:
        return rng.randint(0, 511)
    c = rng.randint(0, 31)
    return (c << 4) | 0xF if c else 0


def wvalue(rng, shared):
    k = rng.randrange(8)
    if k == 0:
        return shared                     # equal W on purpose
    if k == 1:
        return rng.randint(1, 0x1FF) << 7  # low bits clear: linear when equal
    return rng.randint(1, 0xFFFF)


def positions(rng):
    kind = rng.randrange(20)
    xs = [rng.randint(0, 256) for _ in range(3)]
    ys = [rng.randint(0, 192) for _ in range(3)]
    if kind == 0:                          # horizontal line polygon
        y = rng.randint(0, 191)
        ys = [y, y, y]
    elif kind == 1:                        # single point
        xs = [xs[0]] * 3
        ys = [ys[0]] * 3
    elif kind == 2:                        # vertical edge
        xs[1] = xs[0]
    elif kind == 3:                        # collinear sliver
        dx, dy = rng.randint(-40, 40), rng.randint(-30, 30)
        xs = [min(256, max(0, xs[0] + dx * i)) for i in range(3)]
        ys = [min(192, max(0, ys[0] + dy * i)) for i in range(3)]
    elif kind == 4:                        # right border
        xs[rng.randrange(3)] = 256
    elif kind == 5:                        # small triangle
        xs = [min(256, max(0, xs[0] + rng.randint(-6, 6))) for _ in range(3)]
        ys = [min(192, max(0, ys[0] + rng.randint(-6, 6))) for _ in range(3)]
    return xs, ys


def texparam(rng, fmt=None):
    if fmt is None:
        fmt = rng.choice([1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4, 5, 6, 7, 0])
    sw = rng.choice([0, 0, 1, 1, 2, 3, 4, 5, 6, 7])
    sh = rng.choice([0, 0, 1, 1, 2, 3, 4, 5, 6, 7])
    return (rng.randint(0, 0xFFFF) | (rng.randint(0, 15) << 16) | (sw << 20)
            | (sh << 23) | (fmt << 26) | (rng.randint(0, 1) << 29)
            | (rng.randint(0, 3) << 30)), 8 << sw, 8 << sh


def coord(rng, size):
    """A 12.4 texture coordinate near (and beyond) the texture's extent."""
    if rng.randrange(10) == 0:
        return rng.randint(-32768, 32767)
    return max(-32768, min(32767, rng.randint(-2 * size, 3 * size) * 16 + rng.randint(-15, 15)))


def poly_line(attr, tp, pal, face, verts):
    fields = [attr, tp, pal, face]
    for v in verts:
        fields += v
    return "POLY " + " ".join(str(f) for f in fields)


def random_poly(rng, kind, ids):
    xs, ys = positions(rng)
    zflat = rng.randrange(5) == 0
    zshared = rng.choice([0x100000, 0x400000, 0x7FFFFF, 0xFFFFFE])
    wshared = rng.randint(1, 0xFFFF)
    face = rng.randrange(2)
    fog = rng.randrange(2) << 15
    equal = (1 << 14) if rng.randrange(16) == 0 else 0
    pid = rng.choice(ids) << 24

    if kind == "gouraud":
        attr = (31 << 16) | pid | fog | equal | (rng.randrange(2) << 4)
        tp, pal, w, h = 0, 0, 8, 8
    elif kind == "textured":
        alpha = 31 if rng.randrange(6) else rng.randint(1, 30)
        attr = (alpha << 16) | pid | fog | equal | (rng.randrange(3) << 4)
        tp, w, h = texparam(rng)
        pal = rng.randint(0, 0x1FFF)
    else:
        r = rng.randrange(16)
        alpha = 0 if r == 0 else (31 if r < 5 else rng.randint(1, 30))
        mode = rng.choice([0, 0, 1, 2, 3])
        attr = ((alpha << 16) | pid | fog | equal | (mode << 4)
                | (rng.randrange(2) << 11))
        if rng.randrange(2):
            tp, w, h = texparam(rng)
        else:
            tp, w, h = 0, 8, 8
        pal = rng.randint(0, 0x1FFF)

    verts = []
    for i in range(3):
        z = zshared if zflat else rng.randint(0, 0xFFFFFF)
        verts.append([xs[i], ys[i], z, wvalue(rng, wshared),
                      colour(rng), colour(rng), colour(rng),
                      coord(rng, w), coord(rng, h)])
    return poly_line(attr, tp, pal, face, verts)


def shadow_pair(rng, ids):
    """A shadow-mask polygon followed by a shadow polygon over the same area,
    the order a game submits a shadow volume in. The mask is sometimes
    wireframe (alpha 0), which production treats as alpha 31 for its test."""
    xs, ys = positions(rng)
    alpha = rng.randint(1, 31)
    face = rng.randrange(2)
    out = []
    for pid in (0, rng.choice([i for i in ids if i] or [1])):
        a = 0 if pid == 0 and rng.randrange(4) == 0 else alpha
        attr = (a << 16) | (pid << 24) | (3 << 4) | (rng.randrange(2) << 11)
        verts = [[xs[i], ys[i], rng.randint(0, 0xFFFFFF), rng.randint(1, 0xFFFF),
                  colour(rng), colour(rng), colour(rng), 0, 0] for i in range(3)]
        out.append(poly_line(attr, 0, 0, face, verts))
    return out


def directed(kind):
    """Corner cases that random frames hit rarely."""
    lines = []
    if kind == "gouraud":
        # Red/green/blue corners, linear (equal aligned W) and perspective W.
        lines.append(poly_line(31 << 16, 0, 0, 1, [
            [10, 10, 0x400000, 0x4000, 511, 0, 0, 0, 0],
            [120, 20, 0x400000, 0x4000, 0, 511, 0, 0, 0],
            [40, 150, 0x400000, 0x4000, 0, 0, 511, 0, 0]]))
        lines.append(poly_line(31 << 16, 0, 0, 1, [
            [130, 10, 0x300000, 0x0100, 511, 0, 0, 0, 0],
            [250, 30, 0x300000, 0xFFFF, 0, 511, 0, 0, 0],
            [160, 180, 0x300000, 0x2000, 0, 0, 511, 0, 0]]))
        # Horizontal colour ramp and a single point.
        lines.append(poly_line(31 << 16, 0, 0, 0, [
            [0, 170, 0x200000, 0x1234, 0, 0, 0, 0, 0],
            [256, 170, 0x200000, 0x0042, 511, 511, 511, 0, 0],
            [128, 170, 0x200000, 0x7FFF, 255, 0, 255, 0, 0]]))
        lines.append(poly_line(31 << 16, 0, 0, 1, [
            [200, 160, 0x100000, 0x4000, 31, 63, 95, 0, 0]] * 3))
    elif kind == "textured":
        # Each format once, 32x32, repeat+flip, over its own tile.
        for fmt in range(1, 8):
            x0 = 8 + 34 * (fmt - 1)
            tp = (0x100 * fmt) | (0xF << 16) | (2 << 20) | (2 << 23) | (fmt << 26) | (1 << 29)
            lines.append(poly_line((31 << 16) | (fmt << 24), tp, 0x10 * fmt, 1, [
                [x0, 8, 0x200000, 0x1000, 511, 511, 511, -256, -256],
                [x0 + 32, 8, 0x200000, 0x1000, 511, 511, 511, 1280, -256],
                [x0, 72, 0x200000, 0x1000, 511, 511, 511, -256, 1280]]))
        # Clamp on both axes, perspective-correct across a long span.
        lines.append(poly_line(31 << 16, (3 << 20) | (3 << 23) | (7 << 26), 0, 1, [
            [0, 90, 0x300000, 0x0200, 511, 511, 511, -512, -512],
            [256, 100, 0x300000, 0xF000, 511, 511, 511, 2048, 0],
            [20, 190, 0x300000, 0x0800, 511, 511, 511, 0, 2048]]))
        # Decal and toon over the same texture.
        for mode, x0 in ((1, 0), (2, 128)):
            lines.append(poly_line((31 << 16) | (mode << 4), (2 << 20) | (2 << 23) | (4 << 26), 3, 1, [
                [x0, 120, 0x100000, 0x1000, 300, 100, 50, 0, 0],
                [x0 + 120, 120, 0x100000, 0x1000, 60, 400, 200, 512, 0],
                [x0, 190, 0x100000, 0x1000, 20, 30, 500, 0, 512]]))
    else:
        # Translucent over opaque, same translucent ID twice (second skipped),
        # depth update on and off, and a wireframe polygon.
        lines.append(poly_line((31 << 16) | (5 << 24), 0, 0, 1, [
            [0, 0, 0x800000, 0x1000, 400, 400, 400, 0, 0],
            [256, 0, 0x800000, 0x1000, 400, 400, 400, 0, 0],
            [0, 192, 0x800000, 0x1000, 400, 400, 400, 0, 0]]))
        for i, (pid, depthw) in enumerate(((9, 1), (9, 0), (10, 0))):
            lines.append(poly_line((12 << 16) | (pid << 24) | (depthw << 11), 0, 0, 1, [
                [20 + 30 * i, 20, 0x400000 - i, 0x1000, 511, 0, 0, 0, 0],
                [140 + 30 * i, 30, 0x400000 - i, 0x1000, 0, 511, 0, 0, 0],
                [60 + 30 * i, 150, 0x400000 - i, 0x1000, 0, 0, 511, 0, 0]]))
        lines.append(poly_line((0 << 16) | (3 << 24), 0, 0, 1, [
            [150, 100, 0x200000, 0x1000, 511, 511, 0, 0, 0],
            [250, 110, 0x200000, 0x1000, 511, 511, 0, 0, 0],
            [170, 185, 0x200000, 0x1000, 511, 511, 0, 0, 0]]))
        # A shadow volume: mask (ID 0) then shadow (ID 7) over an opaque floor.
        for pid in (0, 7):
            lines.append(poly_line((20 << 16) | (pid << 24) | (3 << 4), 0, 0, 1, [
                [30, 160, 0x900000, 0x1000, 0, 0, 0, 0, 0],
                [120, 160, 0x900000, 0x1000, 0, 0, 0, 0, 0],
                [60, 191, 0x900000, 0x1000, 0, 0, 0, 0, 0]]))
    return lines


def main():
    kind, seed, count, scene_out, vram_out = (
        sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5])
    rng = random.Random(f"{kind}:{seed}")

    texture = rng.randbytes(512 * 1024)
    palette = rng.randbytes(96 * 1024) + bytes(32 * 1024)
    with open(vram_out, "wb") as f:
        f.write(texture + palette)

    if kind == "gouraud":
        dispcnt = rng.choice([0x0, 0x8])
        alpharef = 0
    elif kind == "textured":
        dispcnt = 0x1 | (rng.randrange(2) << 1) | (rng.randrange(2) << 3)
        if rng.randrange(8) == 0:
            dispcnt &= ~0x1                    # texturing off, TexParam still set
        alpharef = rng.choice([0, 0, rng.randint(0, 31)])
    else:
        dispcnt = 0x1 | (rng.randrange(2) << 1) | ((rng.randrange(4) != 0) << 3)
        alpharef = rng.choice([0, 0, rng.randint(0, 15), rng.randint(0, 31)])
    ids = [rng.randint(0, 63) for _ in range(rng.randint(2, 6))]
    clear_alpha = rng.choice([0, 31, rng.randint(1, 30)])
    clear1 = (rng.randint(0, 0x7FFF) | (rng.randrange(2) << 15) | (clear_alpha << 16)
              | (rng.choice(ids) << 24))
    clear2 = rng.choice([0x7FFF, rng.randint(0, 0x7FFF)])
    wbuffer = rng.randrange(2)
    toon = [rng.randint(0, 0x7FFF) for _ in range(32)]

    lines = [f"CFG {dispcnt} {alpharef} {clear1} {clear2} {wbuffer}",
             "TOON " + " ".join(str(t) for t in toon)]
    if seed == 0:
        lines += directed(kind)
    while len(lines) < count + 2:
        if kind == "translucent" and rng.randrange(8) == 0 and len(lines) + 2 <= count + 2:
            lines += shadow_pair(rng, ids)
        else:
            lines.append(random_poly(rng, kind, ids))
    with open(scene_out, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
