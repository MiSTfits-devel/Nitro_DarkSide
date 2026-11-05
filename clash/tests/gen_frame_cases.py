#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
"""Seeded random frames for the depth-tested frame gate.

Each frame mixes general triangles (independent 24-bit Z and 16-bit W per
vertex), flat-Z triangles that tie on purpose so the front/back comparators
differ, and horizontal triangles. Coordinates stay inside the post-clip
viewport (X 0..256, Y 0..192): the geometry engine clips before rasterising,
and melonDS starts its edge walk at YTop, so off-screen Y is not an input the
rasteriser has to reproduce.
"""
import random
import sys


def tri(rng):
    kind = rng.randrange(16)
    xs = [rng.randint(0, 256) for _ in range(3)]
    ys = [rng.randint(0, 192) for _ in range(3)]
    if kind == 0:  # horizontal: all three on one scanline, Z still varies
        y = rng.randint(0, 192)
        ys = [y, y, y]
    elif kind in (1, 2):  # touch the right border: raw xend reaches 256
        xs[rng.randrange(3)] = 256
    if kind in (3, 4, 5):  # flat depth at a shared value, so ties happen
        z = rng.choice([0x100000, 0x400000, 0x7FFFFF])
        zs = [z, z, z]
    else:
        zs = [rng.randint(0, 0xFFFFFF) for _ in range(3)]
    ws = [rng.randint(1, 0xFFFF) for _ in range(3)]
    rgb = [rng.randint(0, 31) for _ in range(3)]
    if rgb == [0, 0, 0]:
        rgb[0] = 1
    face = rng.randrange(2)
    fields = []
    for i in range(3):
        fields += [xs[i], ys[i], zs[i], ws[i]]
    return "TRIZW " + " ".join(map(str, fields + rgb + [face]))


def main():
    seed = int(sys.argv[1])
    count = int(sys.argv[2])
    rng = random.Random(seed)
    for _ in range(count):
        print(tri(rng))


if __name__ == "__main__":
    main()
