#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
"""Frames for the full renderer gate (Nds.Gpu3D.Render against the
production SoftRenderer3D::RenderFrame).

usage: gen_render_cases.py KIND SEED POLYS CASE_OUT VRAM_OUT

KIND is one of the directed kinds below, or "random". A directed kind
writes one or more frames aimed at one feature; "random" writes one frame of
POLYS polygons with every feature drawn at random. Frames of one case render
back to back on one renderer, so state carried between frames (lower layer,
stencil, previous-mask flag) is exercised too.

Polygons are what the geometry engine hands the renderer: convex polygons as
clipping produces them (a triangle or quad clipped to the screen and up to two
more planes, 3..10 vertices, X 0..256, Y 0..192), with the bounds, flags and
sort key computed exactly as GPU3D::SubmitPolygon computes them, sorted as
the VBlank swap sorts them. Degenerate polygons (W = 0, or Y past 192 after
the 8-bit wrap) are included and flagged as SubmitPolygon flags them.

The VRAM image is 512 KiB of random texture slots (slots 2 and 3 double as
the rear-plane clear image) and 96 KiB of random palette slots followed by
32 KiB of zeros (palette slots 6 and 7 are unmapped in the oracle).
"""
import math
import random
import sys

SW, SH = 256, 192


# --------------------------------------------------------------------------
# Polygon records

def submit(verts, attr, tp=0, pal=0, facing=None, wbuffer=0, wzero=False, rng=None):
    """Build a POLY record from screen vertices [x, y, r, g, b, s, t, z, w],
    deriving every field the way SubmitPolygon does."""
    n = len(verts)
    assert 1 <= n <= 10
    if facing is None:
        facing = 1 if area2(verts) < 0 else 0
    vtop = vbot = 0
    ytop, ybot, xtop, xbot = 192, 0, 256, 0
    for i, v in enumerate(verts):
        x, y = v[0], v[1]
        if y < ytop:
            xtop, ytop, vtop = x, y, i
        if y > ybot or (y == ybot and x > xbot):
            xbot, ybot, vbot = x, y, i
    texfmt = (tp >> 26) & 7
    alpha = (attr >> 16) & 0x1F
    translucent = 1 if (texfmt in (1, 6) or 0 < alpha < 31) else 0
    mask = 1 if (attr & 0x3F000030) == 0x30 else 0
    shadow = 1 if (attr & 0x30) == 0x30 and not mask else 0
    ptype = 0
    if n == 3:
        p = [(v[0], v[1]) for v in verts]
        if p[0] == p[1] or p[0] == p[2] or p[1] == p[2]:
            ptype = 1
    degenerate = 1 if (wzero or ybot > 192) else 0
    sortkey = (ybot << 8) | ytop | (translucent << 16)
    return {
        "n": n, "attr": attr & 0xFFFFFFFF, "tp": tp & 0xFFFFFFFF, "pal": pal,
        "degenerate": degenerate, "facing": facing, "translucent": translucent,
        "mask": mask, "shadow": shadow, "type": ptype, "wbuffer": wbuffer,
        "vtop": vtop, "vbot": vbot, "ytop": ytop, "ybot": ybot,
        "xtop": xtop, "xbot": xbot, "sortkey": sortkey,
        "verts": [list(map(int, v)) for v in verts],
    }


def area2(verts):
    s = 0
    for i in range(len(verts)):
        x0, y0 = verts[i][0], verts[i][1]
        x1, y1 = verts[(i + 1) % len(verts)][0], verts[(i + 1) % len(verts)][1]
        s += x0 * y1 - x1 * y0
    return s


def poly_text(p):
    head = [p["n"], p["attr"], p["tp"], p["pal"], p["degenerate"], p["facing"],
            p["translucent"], p["mask"], p["shadow"], p["type"], p["wbuffer"],
            p["vtop"], p["vbot"], p["ytop"], p["ybot"], p["xtop"], p["xbot"],
            p["sortkey"]]
    body = [c for v in p["verts"] for c in v]
    return "POLY " + " ".join(str(f) for f in head + body)


def vblank_sort(polys, manual):
    """Opaque polygons first, then translucent ones, each in submission
    order, Y-sorted by SortKey (translucent ones only without manual sort)."""
    opaque = sorted([p for p in polys if not p["translucent"]], key=lambda p: p["sortkey"])
    trans = [p for p in polys if p["translucent"]]
    if not manual:
        trans = sorted(trans, key=lambda p: p["sortkey"])
    return opaque + trans


# --------------------------------------------------------------------------
# Geometry

def clip_halfplane(poly, a, b, c):
    """Sutherland-Hodgman against a*x + b*y + c >= 0. Each vertex is a list
    whose first two entries are x and y; the others are interpolated."""
    out = []
    n = len(poly)
    for i in range(n):
        cur, nxt = poly[i], poly[(i + 1) % n]
        dc = a * cur[0] + b * cur[1] + c
        dn = a * nxt[0] + b * nxt[1] + c
        if dc >= 0:
            out.append(cur)
        if (dc >= 0) != (dn >= 0):
            t = dc / (dc - dn)
            out.append([cur[k] + (nxt[k] - cur[k]) * t for k in range(len(cur))])
    return out


def clip_screen(poly, rng, extra):
    for a, b, c in ((1, 0, 0), (-1, 0, SW), (0, 1, 0), (0, -1, SH)):
        poly = clip_halfplane(poly, a, b, c)
        if not poly:
            return poly
    for _ in range(extra):
        # A near/far-plane style cut through the polygon.
        ang = rng.uniform(0, 2 * math.pi)
        a, b = math.cos(ang), math.sin(ang)
        cx = sum(v[0] for v in poly) / len(poly)
        cy = sum(v[1] for v in poly) / len(poly)
        c = -(a * cx + b * cy) + rng.uniform(5, 60)
        cut = clip_halfplane(poly, a, b, c)
        if len(cut) >= 3:
            poly = cut
    return poly


def colour(rng):
    if rng.randrange(4) == 0:
        return rng.randint(0, 511)
    c = rng.randint(0, 31)
    return (c << 4) | 0xF if c else 0


def wvalue(rng):
    return rng.randint(1, 0xFFFF)


def attr_vertex(rng, x, y, size, zmode, wmode, wbuf):
    w = wmode if wmode else wvalue(rng)
    if zmode is not None:
        z = zmode
    elif wbuf and rng.randrange(2):
        z = min(0xFFFFFF, w << rng.randint(0, 8))
    else:
        z = rng.randint(0, 0xFFFFFF)
    return [x, y, colour(rng), colour(rng), colour(rng),
            coord(rng, size[0]), coord(rng, size[1]), z, w]


def coord(rng, size):
    if rng.randrange(10) == 0:
        return rng.randint(-32768, 32767)
    return max(-32768, min(32767, rng.randint(-2 * size, 3 * size) * 16 + rng.randint(-15, 15)))


def finalize(poly):
    """Round a float polygon to FinalPosition and attribute integers."""
    out = []
    for v in poly:
        x = min(SW, max(0, int(math.floor(v[0] + 0.5))))
        y = min(SH, max(0, int(math.floor(v[1] + 0.5))))
        r, g, b = (min(511, max(0, int(round(c)))) for c in v[2:5])
        s, t = (min(32767, max(-32768, int(round(c)))) for c in v[5:7])
        z = min(0xFFFFFF, max(0, int(round(v[7]))))
        w = min(0xFFFF, max(1, int(round(v[8]))))
        out.append([x, y, r, g, b, s, t, z, w])
    return out


def shape(rng, kind, size, zmode, wmode, wbuf):
    """Screen vertices of one polygon of the given geometric kind."""
    def av(x, y):
        return attr_vertex(rng, x, y, size, zmode, wmode, wbuf)

    if kind == "clipped":
        k = rng.choice([3, 4])
        cx, cy = rng.uniform(-60, 316), rng.uniform(-40, 232)
        rad = rng.uniform(40, 260)
        angs = sorted(rng.uniform(0, 2 * math.pi) for _ in range(k))
        poly = [av(cx + rad * math.cos(a), cy + rad * math.sin(a)) for a in angs]
        poly = clip_screen(poly, rng, rng.choice([0, 0, 1, 2]))
        if len(poly) < 3:
            return None
        return finalize(poly)
    if kind in ("inside", "small"):
        k = rng.randint(3, 10)
        rad = rng.uniform(8, 90) if kind == "inside" else rng.uniform(0.5, 6)
        cx, cy = rng.uniform(0, SW), rng.uniform(0, SH)
        angs = sorted(rng.uniform(0, 2 * math.pi) for _ in range(k))
        ry = rad * rng.uniform(0.5, 1.5)
        poly = [av(cx + rad * math.cos(a), cy + ry * math.sin(a)) for a in angs]
        poly = clip_screen(poly, rng, 0)
        if len(poly) < 3:
            return None
        return finalize(poly)
    if kind == "line":
        x0, y0 = rng.randint(0, SW), rng.randint(0, SH)
        x1 = min(SW, max(0, x0 + rng.randint(-120, 120)))
        y1 = min(SH, max(0, y0 + rng.randint(-90, 90)))
        a, b = av(x0, y0), av(x1, y1)
        verts = [a, b, list(b)] if rng.randrange(2) else [a, list(a), b]
        verts[2][2:] = av(0, 0)[2:]
        return verts
    if kind == "point":
        x0, y0 = rng.randint(0, SW), rng.randint(0, SH)
        return [av(x0, y0) for _ in range(rng.randint(3, 5))]
    if kind == "horizontal":
        y0 = rng.randint(0, SH)
        return [av(rng.randint(0, SW), y0) for _ in range(rng.randint(3, 10))]
    if kind == "vertical":
        x0 = rng.randint(0, SW)
        return [av(x0, rng.randint(0, SH)) for _ in range(rng.randint(3, 6))]
    if kind == "collinear":
        x0, y0 = rng.randint(0, SW), rng.randint(0, SH)
        dx, dy = rng.randint(-40, 40), rng.randint(-30, 30)
        return [av(min(SW, max(0, x0 + dx * i)), min(SH, max(0, y0 + dy * i))) for i in range(rng.randint(3, 5))]
    if kind == "offscreen":
        # A vertex above the screen wraps to Y 193..255 in FinalPosition.
        verts = shape(rng, "inside", size, zmode, wmode, wbuf)
        if verts is None:
            return None
        verts[rng.randrange(len(verts))][1] = rng.randint(193, 255)
        return verts
    raise ValueError(kind)


def texparam(rng, fmt=None):
    if fmt is None:
        fmt = rng.choice([1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4, 5, 6, 7, 0])
    sw = rng.choice([0, 0, 1, 1, 2, 3, 4, 5, 6, 7])
    sh = rng.choice([0, 0, 1, 1, 2, 3, 4, 5, 6, 7])
    return (rng.randint(0, 0xFFFF) | (rng.randint(0, 15) << 16) | (sw << 20)
            | (sh << 23) | (fmt << 26) | (rng.randint(0, 1) << 29)
            | (rng.randint(0, 3) << 30)), (8 << sw, 8 << sh)


GEOMS = (["clipped"] * 6 + ["inside"] * 10 + ["small"] * 8
         + ["line", "point", "horizontal", "vertical", "collinear", "offscreen"])


def random_poly(rng, ids, wbuf, geom=None, attr=None, tex=True):
    """One random polygon with random attributes."""
    for _ in range(50):
        g = geom or rng.choice(GEOMS)
        if tex and rng.randrange(3):
            tp, size = texparam(rng)
        else:
            tp, size = rng.choice([0, 0, rng.randint(0, 0xFFFFFFFF) & ~(7 << 26)]), (8, 8)
        zmode = rng.choice([0x100000, 0x400000, 0x7FFFFF, 0xFFFFFE]) if rng.randrange(5) == 0 else None
        wk = rng.randrange(6)
        wmode = (rng.randint(1, 0x1FF) << 7) if wk == 0 else (rng.randint(1, 0xFFFF) if wk == 1 else None)
        verts = shape(rng, g, size, zmode, wmode, wbuf)
        if verts is None or len(verts) > 10:
            continue
        if attr is None:
            r = rng.randrange(16)
            alpha = 0 if r == 0 else (31 if r < 9 else rng.randint(1, 30))
            mode = rng.choice([0, 0, 1, 2, 3])
            pid = rng.choice(ids)
            if mode == 3 and rng.randrange(2):
                pid = rng.choice([0] + ids)
            a = ((rng.randint(0, 15)) | (mode << 4) | (rng.randint(0, 3) << 6)
                 | (rng.randrange(2) << 11) | (rng.randrange(2) << 12) | (rng.randrange(2) << 13)
                 | ((1 if rng.randrange(16) == 0 else 0) << 14) | (rng.randrange(2) << 15)
                 | (alpha << 16) | (pid << 24))
        else:
            a = attr
        rot = rng.randrange(len(verts))
        verts = verts[rot:] + verts[:rot]
        facing = None if rng.randrange(7) else rng.randrange(2)
        wbit = wbuf if rng.randrange(20) else 1 - wbuf
        return submit(verts, a, tp, rng.randint(0, 0x1FFF), facing, wbit,
                      wzero=rng.randrange(40) == 0)
    return None


def random_regs(rng, ids):
    disp = 0
    disp |= (rng.randrange(5) != 0) << 0
    disp |= (rng.randrange(3) == 0) << 1
    disp |= (rng.randrange(2)) << 2
    disp |= (rng.randrange(4) != 0) << 3
    disp |= (rng.randrange(5) < 2) << 4
    disp |= (rng.randrange(5) < 2) << 5
    disp |= (rng.randrange(3) == 0) << 6
    disp |= (rng.randrange(5) < 2) << 7
    disp |= rng.randint(0, 15) << 8
    disp |= (rng.randrange(5) == 0) << 14
    regs = base_regs(rng, ids)
    regs["disp"] = disp
    regs["alpharef"] = rng.randint(0, 31) if disp & 4 else 0
    regs["fogshift"] = (disp >> 8) & 0xF
    return regs


def base_regs(rng, ids):
    table = sorted(rng.randint(0, 127) for _ in range(32))
    if rng.randrange(3) == 0:
        table = [rng.randint(0, 127) for _ in range(32)]
    if rng.randrange(4) == 0:
        # A saturated tail: density exactly 127, which the hardware rounds to 128.
        k = rng.randint(1, 12)
        table = table[:32 - k] + [127] * k
    clear_alpha = rng.choice([0, 31, rng.randint(1, 30)])
    return {
        "disp": 0, "alpharef": 0,
        "clear1": (rng.randint(0, 0x7FFF) | (rng.randrange(2) << 15) | (clear_alpha << 16)
                   | (rng.choice(ids + [rng.randint(0, 63)]) << 24) | (rng.randint(0, 3) << 30)),
        "clear2": (rng.choice([0x7FFF, rng.randint(0, 0x7FFF)]) | (rng.randrange(2) << 15)
                   | (rng.randint(0, 0xFFFF) << 16)),
        "fogcolor": rng.randint(0, 0xFFFFFFFF),
        "fogoffset": rng.choice([0, rng.randint(0, 0x7FFF), rng.randint(0x2000, 0x7000)]) * 0x200,
        "fogshift": 0,
        "xpos": 0 if rng.randrange(2) else rng.randint(1, 511),
        "fog": [table[0]] + table + [table[31]],
        "edge": [rng.randint(0, 0xFFFF) for _ in range(8)],
        "toon": [rng.randint(0, 0xFFFF) for _ in range(32)],
    }


def frame_text(regs, polys):
    out = ["FRAME",
           "REGS " + " ".join(str(regs[k]) for k in
                              ("disp", "alpharef", "clear1", "clear2", "fogcolor",
                               "fogoffset", "fogshift", "xpos")),
           "FOG " + " ".join(map(str, regs["fog"])),
           "EDGE " + " ".join(map(str, regs["edge"])),
           "TOON " + " ".join(map(str, regs["toon"]))]
    out += [poly_text(p) for p in polys]
    return out


def set_disp(regs, disp, alpharef=0):
    regs["disp"] = disp
    regs["fogshift"] = (disp >> 8) & 0xF
    regs["alpharef"] = alpharef
    return regs


# --------------------------------------------------------------------------
# Directed frames

def V(x, y, z=0x400000, w=0x1000, r=511, g=511, b=511, s=0, t=0):
    return [x, y, r, g, b, s, t, z, w]


def A(alpha=31, pid=1, mode=0, fog=0, depthw=0, equal=0):
    return (mode << 4) | (depthw << 11) | (equal << 14) | (fog << 15) | (alpha << 16) | (pid << 24)


def ngon(cx, cy, rad, n, rot=0.0, **kw):
    return [V(int(round(cx + rad * math.cos(rot + 2 * math.pi * i / n))),
              int(round(cy - rad * math.sin(rot + 2 * math.pi * i / n))), **kw) for i in range(n)]


def directed_ngon(rng, ids):
    regs = set_disp(base_regs(rng, ids), 0x8)
    polys = []
    # 3..10-gons, both windings, each with the matching facing.
    for n in range(3, 11):
        cx = 14 + (n - 3) * 32
        cw = ngon(cx, 22, 14, n, rot=0.3 * n)
        polys.append(submit([v[:] for v in cw], A(pid=n), facing=None))
        polys.append(submit([v[:] for v in reversed(cw)], A(pid=n + 10), facing=None))
        # Same vertex lists with the facing contradicting the winding: the
        # edges cross and every span is drawn swapped.
        ccw = [v[:] for v in ngon(cx, 58, 14, n, rot=0.1 * n, z=0x300000)]
        polys.append(submit(ccw, A(pid=n + 20), facing=1 if area2(ccw) >= 0 else 0))
    # Horizontal polygons: the left/right dummy edges come from vertices 0, 1
    # and n - 1 only, so vertex 2 being the extreme is ignored.
    for i, xs in enumerate(([60, 40, 10, 90, 70], [100, 120, 200, 30, 110, 105, 100],
                            [5, 5, 250, 250], [128, 129, 127])):
        polys.append(submit([V(x, 90 + 3 * i, z=0x200000 - i) for x in xs], A(pid=40 + i), facing=i & 1))
    # Lines, points, vertical and collinear polygons, duplicate vertices.
    polys.append(submit([V(10, 100), V(120, 140), V(120, 140)], A(pid=50)))
    polys.append(submit([V(130, 100), V(130, 100), V(250, 120)], A(pid=51), facing=0))
    polys.append(submit([V(200, 150), V(200, 150), V(200, 150)], A(pid=52)))
    polys.append(submit([V(30, 105), V(30, 170), V(30, 130)], A(pid=53)))
    polys.append(submit([V(40, 110), V(60, 130), V(80, 150), V(100, 170)], A(pid=54)))
    polys.append(submit([V(150, 110), V(150, 110), V(140, 160), V(140, 160), V(190, 160), V(190, 130)],
                        A(pid=55), facing=0))
    # Right border, bottom edge at Y 192, a full-screen 8-gon.
    polys.append(submit([V(200, 100), V(256, 120), V(256, 192), V(180, 192)], A(pid=56), facing=0))
    polys.append(submit(ngon(128, 96, 140, 8, rot=0.2, z=0xF00000), A(pid=57)))
    # Degenerate (W = 0) and off-screen (Y past 192) polygons, and one whose
    # every vertex is on line 192.
    polys.append(submit([V(10, 10), V(100, 10), V(10, 100)], A(pid=58), wzero=True))
    polys.append(submit([V(10, 180), V(100, 200), V(10, 240)], A(pid=59)))
    polys.append(submit([V(10, 192), V(100, 192), V(50, 192)], A(pid=60)))
    # Clipped n-gons with random attributes.
    for _ in range(24):
        p = random_poly(rng, ids, 0, geom="clipped", tex=False)
        if p:
            polys.append(p)
    return [(regs, vblank_sort(polys, False))]


def overlap_polys(rng, ids, count, tex=False, wbuf=0, alpha_choices=(31,), geoms=("inside", "clipped", "small")):
    polys = []
    for _ in range(count):
        a = rng.choice(alpha_choices)
        attr = A(alpha=a, pid=rng.choice(ids), mode=rng.choice([0, 0, 1, 2]),
                 fog=rng.randrange(2), depthw=rng.randrange(2))
        p = random_poly(rng, ids, wbuf, geom=rng.choice(geoms), attr=attr, tex=tex)
        if p:
            polys.append(p)
    return polys


def directed_aa(rng, ids):
    frames = []
    # AA with blending; opaque overlaps, swapped polygons, translucency over
    # edges (both layers), pixels behind edges (lower-layer depth test).
    regs = set_disp(base_regs(rng, ids), 0x19)
    polys = [
        submit([V(20, 10, z=0x500000), V(200, 40, z=0x500000), V(60, 150, z=0x500000)], A(pid=1)),
        submit([V(30, 20, z=0x400000), V(220, 25, z=0x400000), V(240, 180, z=0x400000), V(10, 170, z=0x400000)], A(pid=2)),
        submit([V(100, 5, z=0x300000), V(110, 185, z=0x300000), V(95, 100, z=0x300000)], A(pid=3)),
        submit([V(5, 60), V(250, 70), V(250, 75), V(5, 66)], A(pid=4)),
        submit([V(120, 100, z=0x380000), V(250, 100, z=0x380000), V(185, 100, z=0x380000)], A(pid=5)),
        submit([V(50, 50), V(51, 190), V(52, 120)], A(pid=6), facing=1),
        submit([V(150, 30, z=0x200000), V(230, 160, z=0x200000), V(140, 120, z=0x200000)], A(pid=7), facing=0),
    ]
    polys += overlap_polys(rng, ids, 30)
    polys += overlap_polys(rng, ids, 12, alpha_choices=(8, 16, 24, 30))
    frames.append((regs, vblank_sort(polys, False)))
    # AA without blending, textured, W-buffer.
    regs = set_disp(base_regs(rng, ids), 0x11)
    polys = overlap_polys(rng, ids, 40, tex=True, wbuf=1, alpha_choices=(31, 31, 31, 12))
    frames.append((regs, vblank_sort(polys, True)))
    return frames


def directed_edge(rng, ids):
    frames = []
    edge = [0x001F, 0x03E0, 0x7C00, 0x7FFF, 0x0000, 0x4210, 0x1234, 0x7BDE]
    # Edge marking against neighbours, the screen border and the clear ID.
    regs = set_disp(base_regs(rng, ids), 0x20)
    regs["edge"] = edge
    regs["clear1"] = 0x7FFF | (31 << 16) | (9 << 24)
    polys = [
        submit([V(0, 0, z=0x100000), V(80, 0, z=0x100000), V(0, 60, z=0x100000)], A(pid=9)),
        submit([V(256, 0, z=0x100000), V(256, 60, z=0x100000), V(180, 0, z=0x100000)], A(pid=17), facing=0),
        submit([V(0, 192, z=0x100000), V(0, 130, z=0x100000), V(90, 192, z=0x100000)], A(pid=25), facing=0),
        submit([V(40, 40, z=0x300000), V(200, 40, z=0x300000), V(200, 150, z=0x300000), V(40, 150, z=0x300000)], A(pid=33), facing=0),
        submit([V(60, 60, z=0x200000), V(150, 60, z=0x200000), V(150, 130, z=0x200000), V(60, 130, z=0x200000)], A(pid=33), facing=0),
        submit([V(120, 90, z=0x180000), V(230, 90, z=0x180000), V(230, 180, z=0x180000), V(120, 180, z=0x180000)], A(pid=41), facing=0),
        submit([V(100, 70, z=0x500000), V(140, 70, z=0x500000), V(120, 120, z=0x500000)], A(pid=49), facing=0),
        submit([V(10, 100, z=0x150000), V(60, 100, z=0x150000), V(35, 140, z=0x150000)], A(pid=57, alpha=15), facing=0),
    ]
    polys += overlap_polys(rng, ids, 24)
    frames.append((regs, vblank_sort(polys, False)))
    # Edge marking with anti-aliasing (coverage forced to 0x10) and fog.
    regs = set_disp(base_regs(rng, ids), 0x38 | 0x80 | (3 << 8))
    regs["edge"] = edge
    polys = overlap_polys(rng, ids, 40, alpha_choices=(31, 31, 20))
    frames.append((regs, vblank_sort(polys, False)))
    return frames


def directed_fog(rng, ids):
    frames = []
    sat = [rng.randint(0, 127) for _ in range(24)] + [127] * 8
    for disp, offset, table, fogcolor, clear_alpha in (
            (0x88 | (2 << 8), 0x2000 * 0x200, list(range(0, 128, 4)), None, None),
            (0xC8 | (0 << 8), 0x1000 * 0x200, [127] * 32, 0x001F0000, 0),
            (0x88 | (1 << 8), 0x1000 * 0x200, [127] * 32, 0x001F7FFF, 3),
            (0x98 | (12 << 8), 0x3800 * 0x200, [rng.randint(0, 127) for _ in range(32)], None, None),
            (0x88 | (6 << 8), 0x0800 * 0x200, sat, 0x001E6B5A, 1),
            (0x89 | (15 << 8), 0, sorted(rng.randint(0, 127) for _ in range(32)), None, None)):
        regs = set_disp(base_regs(rng, ids), disp)
        regs["fogoffset"] = offset
        regs["fog"] = [table[0]] + table + [table[31]]
        regs["clear1"] |= 0x8000
        if fogcolor is not None:
            regs["fogcolor"] = fogcolor
            regs["clear1"] = (regs["clear1"] & ~(0x1F << 16)) | (clear_alpha << 16)
        polys = []
        for i in range(48):
            z0 = rng.randint(max(0, offset - 0x40000), min(0xFFFFFF, offset + 0x400000))
            attr = A(alpha=rng.choice([31, 31, 12, 3]), pid=rng.choice(ids), fog=rng.randrange(2),
                     depthw=rng.randrange(2))
            p = random_poly(rng, ids, 0, attr=attr, tex=bool(disp & 1))
            if p:
                for v in p["verts"]:
                    v[7] = min(0xFFFFFF, max(0, z0 + rng.randint(-0x20000, 0x20000)))
                polys.append(p)
        frames.append((regs, vblank_sort(polys, False)))
    return frames


def directed_clear(rng, ids):
    frames = []
    for disp, clear2 in ((0x4000, 0x00007FFF), (0x40A0 | (4 << 8), 0x9C407123),
                         (0x4010, 0xFF01_0000 | 0x1234), (0x4030 | 0x80, 0x80F0_4000)):
        regs = set_disp(base_regs(rng, ids), disp)
        regs["clear2"] = clear2
        regs["fogoffset"] = rng.randint(0, 0x3FFF) * 0x200
        polys = overlap_polys(rng, ids, 20, alpha_choices=(31, 31, 10))
        frames.append((regs, vblank_sort(polys, False)))
    return frames


def directed_lower(rng, ids):
    frames = []
    # Without anti-aliasing: depth tests fall through to the lower layer on
    # edge pixels, translucent pixels plot on both layers.
    regs = set_disp(base_regs(rng, ids), 0x08)
    polys = [submit([V(20, 20, z=0x200000), V(230, 30, z=0x200000), V(120, 180, z=0x200000)], A(pid=1))]
    for i in range(20):
        polys.append(submit([V(25 + 9 * i, 22, z=0x300000 + i), V(30 + 9 * i, 150, z=0x300000 + i),
                             V(40 + 9 * i, 60, z=0x300000 + i)], A(pid=2 + (i & 3)), facing=i & 1))
    polys += overlap_polys(rng, ids, 30, alpha_choices=(31, 9, 18, 27))
    frames.append((regs, vblank_sort(polys, False)))
    # The same with anti-aliasing: pushes, coverage, blends.
    regs = set_disp(dict(regs), 0x18)
    frames.append((regs, vblank_sort(polys, False)))
    return frames


def shadow_volume(rng, ids, mask_alpha=None, shadow_alpha=None, geom=None):
    out = []
    verts = None
    while verts is None:
        verts = shape(rng, geom or rng.choice(["inside", "clipped", "small"]), (8, 8), None, None, 0)
        if verts and len(verts) > 10:
            verts = None
    rot = rng.randrange(len(verts))
    verts = verts[rot:] + verts[:rot]
    facing = rng.randrange(2)
    ma = rng.choice([31, 20, 0]) if mask_alpha is None else mask_alpha
    sa = rng.choice([31, 16, 8]) if shadow_alpha is None else shadow_alpha
    pid = rng.choice([i for i in ids if i] or [1])
    out.append(submit([v[:] for v in verts], A(alpha=ma, pid=0, mode=3, depthw=rng.randrange(2)),
                      facing=facing))
    sv = [v[:] for v in verts]
    for v in sv:
        v[2:5] = [colour(rng), colour(rng), colour(rng)]
    out.append(submit(sv, A(alpha=sa, pid=pid, mode=3, fog=rng.randrange(2)), facing=facing))
    return out


def directed_shadow(rng, ids):
    frames = []
    regs = set_disp(base_regs(rng, ids), 0x08, alpharef=0)
    polys = overlap_polys(rng, ids, 16)
    trans = []
    for _ in range(6):
        trans += shadow_volume(rng, ids)
    # Two masks in a row (the second does not clear the stencil), a shadow
    # with no mask on its lines (stale stencil), a wireframe mask.
    trans += shadow_volume(rng, ids)[:1] + shadow_volume(rng, ids)
    trans += shadow_volume(rng, ids)[1:]
    trans += shadow_volume(rng, ids, mask_alpha=0)
    frames.append((regs, vblank_sort(polys, False) + trans))
    # Alpha test rejecting the mask (alpha <= AlphaRef: stencil cleared, no
    # bits set), anti-aliasing (stencil bit 1 from the lower layer); the frame
    # ends on a mask so the next frame's first mask keeps the stencil.
    regs = set_disp(base_regs(rng, ids), 0x1C, alpharef=10)
    polys = overlap_polys(rng, ids, 20)
    trans = []
    for _ in range(4):
        trans += shadow_volume(rng, ids, mask_alpha=rng.choice([8, 31]))
    trans += shadow_volume(rng, ids)[:1]
    frames.append((regs, vblank_sort(polys, False) + trans))
    regs = set_disp(base_regs(rng, ids), 0x08)
    trans = []
    for _ in range(4):
        trans += shadow_volume(rng, ids)
    frames.append((regs, vblank_sort(overlap_polys(rng, ids, 10), False) + trans))
    return frames


def directed_shade(rng, ids):
    frames = []
    for disp, alpharef in ((0x0B, 0), (0x09, 0), (0x0F, 12), (0x03, 0), (0x01 | 0x10, 20)):
        regs = set_disp(base_regs(rng, ids), disp, alpharef)
        polys = []
        for _ in range(40):
            alpha = rng.choice([0, 0, 31, 31, 5, 15, 25])
            mode = rng.choice([0, 1, 2, 2])
            attr = A(alpha=alpha, pid=rng.choice(ids), mode=mode, fog=rng.randrange(2),
                     depthw=rng.randrange(2), equal=1 if rng.randrange(8) == 0 else 0)
            p = random_poly(rng, ids, rng.randrange(2), attr=attr, tex=True)
            if p:
                polys.append(p)
        frames.append((regs, vblank_sort(polys, rng.randrange(2))))
    return frames


def directed_texture(rng, ids):
    regs = set_disp(base_regs(rng, ids), 0x09)
    polys = []
    for fmt in range(1, 8):
        x0 = 4 + 36 * (fmt - 1)
        for row, (sw, sh, wrap) in enumerate(((2, 2, 0xF), (0, 3, 0x5), (3, 0, 0xA), (1, 1, 0x0))):
            tp = ((0x400 * fmt + 0x40 * row) | (wrap << 16) | (sw << 20) | (sh << 23)
                  | (fmt << 26) | ((row & 1) << 29))
            y0 = 4 + 46 * row
            polys.append(submit([
                V(x0, y0, z=0x200000, w=0x1000 + 0x100 * row, s=-256, t=-256),
                V(x0 + 32, y0, z=0x200000, w=0x1000, s=1280, t=-256),
                V(x0 + 32, y0 + 42, z=0x200000, w=0x3000, s=1280, t=1280),
                V(x0, y0 + 42, z=0x200000, w=0x0800, s=-256, t=1280)],
                A(pid=fmt, mode=row & 1), tp, 0x10 * fmt + row, facing=0))
    polys += [p for p in (random_poly(rng, ids, 0, tex=True) for _ in range(20)) if p]
    return [(regs, vblank_sort(polys, False))]


def directed_wbuffer(rng, ids):
    frames = []
    for disp in (0x09, 0x19):
        regs = set_disp(base_regs(rng, ids), disp)
        polys = []
        for _ in range(48):
            p = random_poly(rng, ids, 1, tex=True)
            if p:
                p["wbuffer"] = 1
                polys.append(p)
        frames.append((regs, vblank_sort(polys, False)))
    return frames


def directed_xpos(rng, ids):
    frames = []
    polys = [p for p in (random_poly(rng, ids, 0) for _ in range(30)) if p]
    for xpos in (1, 100, 255, 256, 257, 400, 511):
        regs = set_disp(base_regs(rng, ids), 0x09)
        regs["xpos"] = xpos
        frames.append((regs, vblank_sort(polys, False)))
    return frames


def directed_carry(rng, ids):
    """Frames on one renderer that read state the previous frame left: an
    anti-aliased frame leaves its lower layer and a trailing mask; then a
    frame whose last polygon drawn is a mask reaching line 191, followed by a
    frame whose first polygon drawn is a mask, which therefore keeps the
    stale stencil line for the shadow drawn after it."""
    frames = []
    regs = set_disp(base_regs(rng, ids), 0x18)
    trans = []
    for _ in range(3):
        trans += shadow_volume(rng, ids)
    trans += shadow_volume(rng, ids)[:1]
    frames.append((regs, vblank_sort(overlap_polys(rng, ids, 30), False) + trans))
    regs = set_disp(base_regs(rng, ids), 0x08)
    trans = []
    for _ in range(3):
        trans += shadow_volume(rng, ids)[::-1]
    frames.append((regs, vblank_sort(overlap_polys(rng, ids, 30, alpha_choices=(31, 14)), False) + trans))
    regs = set_disp(base_regs(rng, ids), 0x98 | (1 << 8))
    frames.append((regs, vblank_sort(overlap_polys(rng, ids, 30), False)))
    # A floor in front of a full-width mask over lines 120..191: the mask
    # fails its depth test everywhere and is the last polygon drawn.
    regs = set_disp(base_regs(rng, ids), 0x08)
    regs["clear2"] = 0x7FFF
    floor = submit([V(0, 100, z=0x100000), V(256, 100, z=0x100000), V(256, 192, z=0x100000),
                    V(0, 192, z=0x100000)], A(pid=5), facing=0)
    mask = submit([V(0, 120, z=0x600000), V(256, 120, z=0x600000), V(256, 192, z=0x600000),
                   V(0, 192, z=0x600000)], A(alpha=20, pid=0, mode=3), facing=0)
    frames.append((regs, [floor, mask]))
    # First polygon drawn is a small mask in front of everything (sets no
    # stencil bits), then a full-width shadow over the same lines.
    regs = set_disp(base_regs(rng, ids), 0x08)
    regs["clear2"] = 0x7FFF
    mask = submit([V(10, 0, z=0x100000), V(40, 0, z=0x100000), V(40, 12, z=0x100000),
                   V(10, 12, z=0x100000)], A(alpha=20, pid=0, mode=3), facing=0)
    shadow = submit([V(0, 0, z=0x200000), V(256, 0, z=0x200000), V(256, 12, z=0x200000),
                     V(0, 12, z=0x200000)], A(alpha=16, pid=9, mode=3), facing=0)
    frames.append((regs, [mask, shadow]))
    return frames


DIRECTED = {
    "ngon": directed_ngon,
    "aa": directed_aa,
    "edge": directed_edge,
    "fog": directed_fog,
    "clear": directed_clear,
    "lower": directed_lower,
    "shadow": directed_shadow,
    "shade": directed_shade,
    "texture": directed_texture,
    "wbuffer": directed_wbuffer,
    "xpos": directed_xpos,
    "carry": directed_carry,
}


def random_frame(rng, count):
    ids = [rng.randint(0, 63) for _ in range(rng.randint(2, 6))]
    regs = random_regs(rng, ids)
    wbuf = rng.randrange(2)
    polys = []
    shadows = []
    while len(polys) + len(shadows) < count:
        if rng.randrange(10) == 0:
            shadows += shadow_volume(rng, ids)
            continue
        p = random_poly(rng, ids, wbuf)
        if p:
            polys.append(p)
    manual = rng.randrange(2)
    ordered = vblank_sort(polys, manual)
    if manual or rng.randrange(2):
        ordered += shadows
    else:
        ordered = vblank_sort(polys + shadows, False)
    return [(regs, ordered)]


def main():
    kind, seed, count, case_out, vram_out = (
        sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5])
    rng = random.Random(f"render:{kind}:{seed}")
    texture = rng.randbytes(512 * 1024)
    palette = rng.randbytes(96 * 1024) + bytes(32 * 1024)
    with open(vram_out, "wb") as f:
        f.write(texture + palette)
    if kind == "random":
        frames = random_frame(rng, count)
    else:
        ids = [rng.randint(1, 63) for _ in range(rng.randint(3, 6))]
        frames = DIRECTED[kind](rng, ids)
    lines = []
    for regs, polys in frames:
        lines += frame_text(regs, polys)
    with open(case_out, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
