#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Golden-model generator for the M5 part-2 OBJ drawer tests (tb_gpu_obj).
#
# Emits (not checked in - regenerate before running):
#   gpu_obj_vram.hex    256 KB OBJ char/bitmap space, 65536 words
#   gpu_obj_pal.hex     512 B  std OBJ palette, 128 words
#   gpu_obj_extpal.hex  8 KB   OBJ ext palette, 2048 words
#   gpu_obj_vectors.hex per case: 8 header words + 256 OAM words +
#                       256 expected color words (0x8000 = never written) +
#                       256 expected settings words
#                       (bit12 objwnd, bit8 = never written, [7:0] settings),
#                       preceded by a case-count word
#
# The golden renderer implements GBATEK/melonDS NDS OBJ semantics from the
# register descriptions (sizes, 1D/2D mapping + boundary, bitmap sprites,
# ext palettes, affine pipeline) - deliberately not transcribed from the
# VHDL so it cross-checks the fork. The priority merge mirrors the donor's
# hardware-verified behavior: sprites are scanned in OAM order; a pixel is
# taken when the slot is still transparent or the new priority is strictly
# lower; transparent pixels DO update the priority plane; OBJ-window
# sprites (mode 2) only set the window plane, from opaque pixels.
#
# settings byte: [1:0] priority, [2] semi-transparent (mode 1),
#                [3] bitmap sprite, [7:4] bitmap alpha (attr2 palette field)

import random

rnd = random.Random(0x0B15)

VRAM   = bytearray(rnd.getrandbits(8) for _ in range(0x40000))
PAL    = bytearray(rnd.getrandbits(8) for _ in range(0x200))
EXTPAL = bytearray(rnd.getrandbits(8) for _ in range(0x2000))

# fully-transparent 4bpp/8bpp tiles for merge tests (tiles 0x40..0x4F at
# char base 0): 4bpp tile n lives at n*32
for t in range(0x40, 0x50):
    VRAM[t*32 : t*32 + 32] = bytes(32)
# scattered zero bytes so transparency paths get hit everywhere
for i in range(0, 0x40000, 977):
    VRAM[i] = 0

def rd16(mem, a):
    return mem[a] | (mem[a+1] << 8)

def pal_obj(idx):
    return rd16(PAL, (idx * 2) & 0x1FF) & 0x7FFF

def extpal_obj(palno, idx):
    return rd16(EXTPAL, ((palno * 256 + idx) * 2) & 0x1FFF) & 0x7FFF

def sxt16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

SIZES = [
    [( 8,  8), (16, 16), (32, 32), (64, 64)],   # square
    [(16,  8), (32,  8), (32, 16), (64, 32)],   # horizontal
    [( 8, 16), ( 8, 32), (16, 32), (32, 64)],   # vertical
]

# ---------------------------------------------------------------- OAM build

def new_oam():
    oam = bytearray(1024)
    for i in range(128):           # all disabled: attr0 bit9 w/o affine
        oam[i*8 + 1] = 0x02
    return oam

def wr16(mem, a, v):
    mem[a] = v & 0xFF
    mem[a+1] = (v >> 8) & 0xFF

def obj(oam, idx, x, y, shape, size, tileno, prio=0, palno=0, mode=0,
        affine=0, dbl=0, hflip=0, vflip=0, hicolor=0, affsel=0, mosaic=0,
        disable=0):
    a0 = (y & 0xFF) | (affine << 8) | (((dbl if affine else disable) & 1) << 9) \
         | (mode << 10) | (mosaic << 12) | (hicolor << 13) | (shape << 14)
    a1 = (x & 0x1FF) | (size << 14)
    if affine:
        a1 |= (affsel & 0x1F) << 9
    else:
        a1 |= (hflip << 12) | (vflip << 13)
    a2 = (tileno & 0x3FF) | (prio << 10) | ((palno & 0xF) << 12)
    wr16(oam, idx*8,     a0)
    wr16(oam, idx*8 + 2, a1)
    wr16(oam, idx*8 + 4, a2)

def aff(oam, group, pa, pb, pc, pd):
    for k, v in enumerate((pa, pb, pc, pd)):
        wr16(oam, group*32 + k*8 + 6, v & 0xFFFF)

# ---------------------------------------------------------------- golden

def render_line(cfg, oam):
    col  = [0x8000] * 256
    sett = [0x100]  * 256          # bit8 = never written
    slot_transp = [True] * 256
    slot_prio   = [3]    * 256

    objidx  = [-1] * 256
    mosflag = [False] * 256
    for i in range(128):
        a0 = rd16(oam, i*8)
        a1 = rd16(oam, i*8 + 2)
        a2 = rd16(oam, i*8 + 4)

        affine = (a0 >> 8) & 1
        if not affine and ((a0 >> 9) & 1):
            continue                                   # disabled
        shape = (a0 >> 14) & 3
        if shape == 3:
            continue                                   # prohibited
        mode    = (a0 >> 10) & 3
        mosaic  = (a0 >> 12) & 1
        hicolor = (a0 >> 13) & 1
        size    = (a1 >> 14) & 3
        w, h = SIZES[shape][size]
        dbl = affine and ((a0 >> 9) & 1)
        fw, fh = (2*w, 2*h) if dbl else (w, h)

        ybase = a0 & 0xFF
        posy = ybase - 0x100 if ybase > 0x100 - fh else ybase
        yline = cfg["ypos_mosaic"] if mosaic else cfg["ypos"]
        ty = yline - posy
        if ty < 0 or ty >= fh:
            continue

        isbmp = (mode == 3)
        if isbmp and cfg["bitmap_1d"] and cfg["bitmap_2d_wide"]:
            continue                                   # reserved combination
        alpha = (a2 >> 12) & 0xF
        if isbmp and alpha == 0:
            continue                                   # invisible bitmap

        tileno = a2 & 0x3FF
        prio   = (a2 >> 10) & 3
        palno  = (a2 >> 12) & 0xF
        x9 = a1 & 0x1FF
        posx = x9 - 0x200 if x9 > 0x100 else x9
        hflip = (not affine) and bool((a1 >> 12) & 1)
        vflip = (not affine) and bool((a1 >> 13) & 1)

        if isbmp:
            if cfg["bitmap_1d"]:
                base = tileno << (7 + cfg["bitmap_1d_boundary"])
                stride = w * 2
            elif cfg["bitmap_2d_wide"]:
                base = ((tileno & 0x1F) << 4) + ((tileno & 0x3E0) << 7)
                stride = 512
            else:
                base = ((tileno & 0x0F) << 4) + ((tileno & 0x3F0) << 7)
                stride = 256
        else:
            if cfg["one_dim"]:
                base = tileno * (32 << cfg["tile_boundary"])
                stride = (w // 8) * (64 if hicolor else 32)
            else:
                base = tileno * 32                     # NDS: no even masking
                stride = 1024

        if affine:
            g = (a1 >> 9) & 0x1F
            pa, pb, pc, pd = (sxt16(rd16(oam, g*32 + k*8 + 6)) for k in range(4))
            rx = (w << 7) - (fw // 2) * pa - (fh // 2) * pb + ty * pb
            ry = (h << 7) - (fw // 2) * pc - (fh // 2) * pd + ty * pd

        for sx in range(fw):
            if affine:
                cx, cy = rx, ry
                rx += pa
                ry += pc
                if cx < 0 or cy < 0 or (cx >> 8) >= w or (cy >> 8) >= h:
                    continue
                xxx, yyy = cx >> 8, cy >> 8
            else:
                xxx = (w - 1 - sx) if hflip else sx
                yyy = (h - 1 - ty) if vflip else ty

            target = sx + posx
            if not (0 <= target < 256):
                continue

            if isbmp:
                v = rd16(VRAM, (base + yyy * stride + xxx * 2) & 0x3FFFF)
                transparent = not (v & 0x8000)
                pixcol = v & 0x7FFF
            elif hicolor:
                c = VRAM[(base + (yyy // 8) * stride + (yyy % 8) * 8
                          + (xxx // 8) * 64 + (xxx % 8)) & 0x3FFFF]
                transparent = (c == 0)
                pixcol = extpal_obj(palno, c) if cfg["obj_extpal"] else pal_obj(c)
            else:
                b = VRAM[(base + (yyy // 8) * stride + (yyy % 8) * 4
                          + (xxx // 8) * 32 + (xxx % 8) // 2) & 0x3FFFF]
                nib = (b >> (4 * (xxx & 1))) & 0xF
                transparent = (nib == 0)
                pixcol = pal_obj(palno * 16 + nib)

            if mode == 2:                              # OBJ window
                if not transparent:
                    sett[target] |= 0x1000
                continue

            if slot_transp[target] or prio < slot_prio[target]:
                if isbmp:
                    s = (alpha << 4) | 0x8 | prio
                else:
                    s = (0x4 if mode == 1 else 0) | prio
                sett[target] = (sett[target] & 0x1000) | s
                slot_prio[target] = prio
                if not transparent:
                    col[target] = pixcol
                    slot_transp[target] = False
                    objidx[target] = i
                    mosflag[target] = bool(mosaic)

    # H mosaic, melonDS ApplySpriteMosaicX (hardware rule: the repeat grid
    # is screen-aligned and restarts at sprite changes / after holes; only
    # opaque mosaic-sprite pixels are replaced)
    mh = cfg["mosaic_h"]
    if mh > 0:
        last_col, last_sett = col[0], sett[0]
        for x in range(1, 256):
            if not mosflag[x]:
                continue
            if objidx[x] != objidx[x - 1] or (x % (mh + 1)) == 0:
                last_col, last_sett = col[x], sett[x]
            else:
                col[x] = last_col
                sett[x] = (sett[x] & 0x1000) | (last_sett & ~0x1000)
    return col, sett

# ---------------------------------------------------------------- cases

def cfg(ypos=64, ypos_mosaic=64, one_dim=0, tile_boundary=0, bitmap_1d=0,
        bitmap_2d_wide=0, bitmap_1d_boundary=0, obj_extpal=0, mosaic_h=0):
    return dict(ypos=ypos, ypos_mosaic=ypos_mosaic, one_dim=one_dim,
                tile_boundary=tile_boundary, bitmap_1d=bitmap_1d,
                bitmap_2d_wide=bitmap_2d_wide,
                bitmap_1d_boundary=bitmap_1d_boundary,
                obj_extpal=obj_extpal, mosaic_h=mosaic_h)

cases = []   # (cfg, oam)

# 0: basic 4bpp 16x16, 1D b0
c = cfg(one_dim=1); o = new_oam()
obj(o, 0, 10, 56, 0, 1, 5, prio=1, palno=2)
cases.append((c, o))

# 1: 4bpp 32x32 2D with hflip / vflip pair
c = cfg(); o = new_oam()
obj(o, 0,  20, 40, 0, 2, 33, prio=0, palno=1, hflip=1)
obj(o, 1, 100, 40, 0, 2, 33, prio=0, palno=1, vflip=1)
obj(o, 2, 180, 40, 0, 2, 33, prio=0, palno=1, hflip=1, vflip=1)
cases.append((c, o))

# 2: 8bpp 2D, odd tile number (NDS: no even masking), std palette
c = cfg(); o = new_oam()
obj(o, 0, 30, 48, 0, 2, 0x81, prio=2, palno=5, hicolor=1)
cases.append((c, o))

# 3: 8bpp 2D odd tile, OBJ ext palette on (palette number matters)
c = cfg(obj_extpal=1); o = new_oam()
obj(o, 0, 30, 48, 0, 2, 0x81, prio=2, palno=7, hicolor=1)
obj(o, 1, 130, 48, 0, 2, 0x81, prio=2, palno=12, hicolor=1)
cases.append((c, o))

# 4: 8bpp 1D boundary 2 + ext palette
c = cfg(one_dim=1, tile_boundary=2, obj_extpal=1); o = new_oam()
obj(o, 0, 60, 33, 1, 3, 0x155, prio=0, palno=3, hicolor=1)
cases.append((c, o))

# 5: 4bpp 64x64 1D boundary 3, vflip
c = cfg(one_dim=1, tile_boundary=3); o = new_oam()
obj(o, 0, 96, 20, 0, 3, 0x0AB, prio=3, palno=9, vflip=1)
cases.append((c, o))

# 6: affine identity 16x16 vs plain copy of the same tiles
c = cfg(one_dim=1); o = new_oam()
obj(o, 0,  40, 56, 0, 1, 5, prio=0, palno=2, affine=1, affsel=0)
obj(o, 1, 120, 56, 0, 1, 5, prio=0, palno=2)
aff(o, 0, 0x100, 0, 0, 0x100)
cases.append((c, o))

# 7: affine rotated + double-size 32x32
c = cfg(one_dim=1); o = new_oam()
obj(o, 0, 30, 30, 0, 2, 64, prio=1, palno=4, affine=1, dbl=1, affsel=3)
aff(o, 3, 0x0B5, -0x0B5 & 0xFFFF, 0x0B5, 0x0B5)     # ~45 deg
cases.append((c, o))

# 8: affine 8bpp + ext palette, anisotropic scale
c = cfg(one_dim=1, tile_boundary=1, obj_extpal=1); o = new_oam()
obj(o, 0, 140, 40, 0, 2, 0x19D, prio=2, palno=11, hicolor=1, affine=1, affsel=7)
aff(o, 7, 0x080, 0, 0, 0x180)
cases.append((c, o))

# 9: bitmap 1D boundary 0, 16x16, alpha=5
c = cfg(bitmap_1d=1); o = new_oam()
obj(o, 0, 12, 56, 0, 1, 9, prio=1, palno=5, mode=3)
cases.append((c, o))

# 10: bitmap 1D boundary 1, 64x64, alpha=15
c = cfg(bitmap_1d=1, bitmap_1d_boundary=1); o = new_oam()
obj(o, 0, 150, 30, 0, 3, 0x83, prio=0, palno=15, mode=3)
cases.append((c, o))

# 11: bitmap 2D narrow 32x32, tile number split across mask fields
c = cfg(); o = new_oam()
obj(o, 0, 50, 44, 0, 2, 0x123, prio=2, palno=8, mode=3)
cases.append((c, o))

# 12: bitmap 2D wide 64x32
c = cfg(bitmap_2d_wide=1); o = new_oam()
obj(o, 0, 90, 50, 1, 3, 0x2A7, prio=1, palno=9, mode=3)
cases.append((c, o))

# 13: bitmap hflip + vflip (1D)
c = cfg(bitmap_1d=1); o = new_oam()
obj(o, 0,  20, 48, 0, 1, 20, prio=0, palno=7, mode=3, hflip=1)
obj(o, 1,  80, 48, 0, 1, 20, prio=0, palno=7, mode=3, vflip=1)
obj(o, 2, 140, 48, 0, 1, 20, prio=0, palno=7, mode=3, hflip=1, vflip=1)
obj(o, 3, 200, 48, 0, 1, 20, prio=0, palno=7, mode=3)
cases.append((c, o))

# 14: affine bitmap, rotated, double-size (1D)
c = cfg(bitmap_1d=1); o = new_oam()
obj(o, 0, 60, 30, 0, 2, 40, prio=2, palno=10, mode=3, affine=1, dbl=1, affsel=5)
aff(o, 5, 0x0DD, 0x055, -0x055 & 0xFFFF, 0x0DD)
cases.append((c, o))

# 15: bitmap alpha=0 invisible; control sprite next to it
c = cfg(bitmap_1d=1); o = new_oam()
obj(o, 0, 40, 56, 0, 1, 9, prio=0, palno=0, mode=3)        # invisible
obj(o, 1, 90, 56, 0, 1, 9, prio=0, palno=6, mode=3)        # visible
cases.append((c, o))

# 16: semi-transparent tile sprite (mode 1) - settings bit 2
c = cfg(one_dim=1); o = new_oam()
obj(o, 0, 70, 52, 0, 2, 77, prio=1, palno=3, mode=1)
cases.append((c, o))

# 17: OBJ window sprite over a normal sprite
c = cfg(one_dim=1); o = new_oam()
obj(o, 0, 100, 56, 0, 1, 5, prio=0, palno=2, mode=2)       # window
obj(o, 1, 104, 56, 0, 1, 6, prio=1, palno=2)               # normal, overlaps
cases.append((c, o))

# 18: priority merge incl. transparent-prio-update quirk:
#     A idx0 prio3 opaque; B idx1 prio1 fully-transparent tile (0x40) on top
#     of A's left half; C idx2 prio2 opaque overlapping both -> C is blocked
#     where B stamped prio1, wins over A's right half
c = cfg(one_dim=1); o = new_oam()
obj(o, 0, 60, 48, 0, 2, 200, prio=3, palno=1)
obj(o, 1, 60, 56, 0, 1, 0x40, prio=1, palno=0)             # transparent 16x16
obj(o, 2, 68, 52, 0, 1, 90, prio=2, palno=4)
cases.append((c, o))

# 19: x clipping: partially off left (x=-8 via 0x1F8), off right, x=0x100
c = cfg(one_dim=1); o = new_oam()
obj(o, 0, 0x1F8, 56, 0, 1, 5, prio=0, palno=2)
obj(o, 1, 250,  56, 0, 1, 6, prio=0, palno=2)
obj(o, 2, 0x100, 56, 0, 1, 7, prio=0, palno=2)             # invisible
cases.append((c, o))

# 20: y wraparound: y=240, 32x64 sprite -> posy=-16, line 40 hits ty=56
c = cfg(one_dim=1, ypos=40, ypos_mosaic=40); o = new_oam()
obj(o, 0, 30, 240, 2, 3, 300, prio=1, palno=6)
cases.append((c, o))

# 21: reserved bitmap 1D+wide draws nothing; tile control sprite unaffected
c = cfg(bitmap_1d=1, bitmap_2d_wide=1); o = new_oam()
obj(o, 0, 40, 56, 0, 1, 9, prio=0, palno=5, mode=3)        # reserved -> skip
obj(o, 1, 90, 56, 0, 1, 5, prio=0, palno=2)                # tile sprite
cases.append((c, o))

# 22: kitchen sink - mixed modes on one line (kept under the time budget)
c = cfg(one_dim=1, tile_boundary=1, bitmap_1d=1, obj_extpal=1); o = new_oam()
obj(o, 0,   0, 60, 0, 1, 5,    prio=3, palno=2)
obj(o, 1,  30, 50, 0, 2, 0x91, prio=2, palno=6, hicolor=1)
obj(o, 2,  70, 58, 0, 1, 9,    prio=1, palno=8, mode=3)
obj(o, 3, 110, 56, 0, 1, 6,    prio=0, palno=3, mode=1, hflip=1)
obj(o, 4, 150, 40, 0, 2, 64,   prio=1, palno=4, affine=1, affsel=1)
obj(o, 5, 200, 56, 0, 1, 0x40, prio=0, palno=0)            # transparent
obj(o, 6, 210, 52, 0, 1, 90,   prio=2, palno=4)
aff(o, 1, 0x100, 0x040, 0, 0x100)
cases.append((c, o))

# 23: disabled + prohibited-shape sprites draw nothing; control visible
c = cfg(one_dim=1); o = new_oam()
obj(o, 0, 40, 56, 0, 1, 5, prio=0, palno=2, disable=1)
o[1*8] = 60; o[1*8 + 1] = 0xC0                              # idx1: enabled, shape 3
wr16(o, 1*8 + 2, 60); wr16(o, 1*8 + 4, 6)
obj(o, 2, 120, 56, 0, 1, 7, prio=0, palno=2)
cases.append((c, o))

# 24: H mosaic, screen-aligned grid (melonDS rule): sprites at x NOT
# aligned to the grid (40 % 3 = 1, 91 % 3 = 1), plus a non-mosaic control.
# The sprite-relative counting the donor used renders these differently.
c = cfg(mosaic_h=2); o = new_oam()
obj(o, 0, 40, 56, 0, 1, 33, prio=0, palno=1, mosaic=1)
obj(o, 1, 91, 56, 0, 1, 33, prio=1, palno=3, mosaic=1, hflip=1)
obj(o, 2, 180, 56, 0, 1, 33, prio=0, palno=2)
cases.append((c, o))

# 25: H mosaic across transparency holes (4bpp tiles with zero nibbles)
# and a second mosaic sprite: a hole or a sprite change restarts the
# repeat block; grid size 4, both sprites off-grid (10 % 5 = 0 though -
# one aligned, one at 74 % 5 = 4)
c = cfg(mosaic_h=4); o = new_oam()
obj(o, 0, 10, 56, 0, 2, 1, prio=0, palno=1, mosaic=1)
obj(o, 1, 74, 56, 0, 2, 1, prio=0, palno=2, mosaic=1)
cases.append((c, o))

# --- magnified rot/scal -------------------------------------------------
# pa/pd are the INVERSE scale, so small values magnify: 0x100 is 1:1 and
# 0x020 is 8x. Every case above stays at 0x080 (2x) or coarser, which
# leaves the drawer's word-reuse path almost untested - reuse only fires
# when consecutive screen pixels land in the same VRAM word, and that is
# exactly what heavy magnification does for run after run.
#
# This is the regime a scaling star-burst / pickup effect runs in, and it
# is where a reuse bug shows up as a sprite drawn in ONE FLAT COLOUR
# instead of a chunky version of its graphic.

# NB tile 0x60, NOT 0x40: tiles 0x40..0x4F are zeroed above for the merge
# tests, so a sprite pointed at them draws nothing at all. Case 7 above is
# pointed at 0x40 and reports pixels=0 - it exercises the affine ADDRESS
# walk but never a single opaque pixel, which is not what its name implies.

# 26: affine 4bpp tile, 8x magnification (4 source columns over 32 px)
c = cfg(one_dim=1); o = new_oam()
obj(o, 0, 40, 48, 0, 2, 0x60, prio=0, palno=4, affine=1, affsel=2)
aff(o, 2, 0x020, 0, 0, 0x020)
cases.append((c, o))

# 27: affine 4bpp tile, 32x magnification + double size - the extreme end,
#     where a whole field can sit inside a single source word. y=16 with a
#     64x64 field spans 16..79, so the y=64 render line lands at ty=48.
c = cfg(one_dim=1); o = new_oam()
obj(o, 0, 30, 16, 0, 2, 0x60, prio=0, palno=4, affine=1, dbl=1, affsel=4)
aff(o, 4, 0x008, 0, 0, 0x008)
cases.append((c, o))

# 28: affine BITMAP, 8x magnification - the direct-colour path, two pixels
#     per word rather than eight, so it reuses on a different boundary
c = cfg(bitmap_1d=1); o = new_oam()
obj(o, 0, 60, 48, 0, 2, 40, prio=2, palno=10, mode=3, affine=1, affsel=6)
aff(o, 6, 0x020, 0, 0, 0x020)
cases.append((c, o))

# 29: affine 8bpp + ext palette, magnified AND rotated, so the address
#     walks diagonally through VRAM while still revisiting words
c = cfg(one_dim=1, tile_boundary=1, obj_extpal=1); o = new_oam()
obj(o, 0, 100, 40, 0, 2, 0x19D, prio=1, palno=11, hicolor=1,
    affine=1, dbl=1, affsel=8)
aff(o, 8, 0x030, 0x010, -0x010 & 0xFFFF, 0x030)
cases.append((c, o))

# --- affine vs normal, same pixel count ---------------------------------
# The pixel walk costs one cycle per pixel for a normal sprite but TWO for a
# rot/scal one, because the affine address needs its own cycle to sum the
# partial terms (NEXTADDR -> AFF_SUM -> NEXTADDR). These two cases are the
# same eight 64-wide sprites on the same line, differing only in the affine
# bit, so busy_cyc between them IS the affine penalty - measured rather than
# read off the state machine. Scaled effects (a star trail, a pickup burst)
# are exactly the content that pays it.

# 30: eight 64x64 normal sprites on one line - 512 walked pixels
c = cfg(one_dim=1); o = new_oam()
for k in range(8):
    obj(o, k, k * 24, 40, 0, 3, 0x60, prio=0, palno=(k % 8))
cases.append((c, o))

# 31: the same eight as rot/scal at 1:1 - identical pixels, double the walk
c = cfg(one_dim=1); o = new_oam()
for k in range(8):
    obj(o, k, k * 24, 40, 0, 3, 0x60, prio=0, palno=(k % 8),
        affine=1, affsel=k)
for k in range(8):
    aff(o, k, 0x100, 0, 0, 0x100)
cases.append((c, o))

# ---------------------------------------------------------------- emit

def whex(f, v):
    f.write(f"{v & 0xFFFFFFFF:08x}\n")

def dump_mem(fname, mem):
    with open(fname, "w") as f:
        for a in range(0, len(mem), 4):
            whex(f, mem[a] | (mem[a+1] << 8) | (mem[a+2] << 16) | (mem[a+3] << 24))

dump_mem("gpu_obj_vram.hex",   VRAM)
dump_mem("gpu_obj_pal.hex",    PAL)
dump_mem("gpu_obj_extpal.hex", EXTPAL)

with open("gpu_obj_vectors.hex", "w") as f:
    whex(f, len(cases))
    for c, oam in cases:
        flags = (c["one_dim"] | (c["bitmap_1d"] << 1) | (c["bitmap_2d_wide"] << 2)
                 | (c["bitmap_1d_boundary"] << 3) | (c["obj_extpal"] << 4))
        hdr = [c["ypos"], c["ypos_mosaic"], flags, c["tile_boundary"],
               c["mosaic_h"], 0, 0, 0]
        for w in hdr:
            whex(f, w)
        for a in range(0, 1024, 4):
            whex(f, oam[a] | (oam[a+1] << 8) | (oam[a+2] << 16) | (oam[a+3] << 24))
        col, sett = render_line(c, oam)
        for p in col:
            whex(f, p)
        for s in sett:
            whex(f, s)

print(f"{len(cases)} cases")
