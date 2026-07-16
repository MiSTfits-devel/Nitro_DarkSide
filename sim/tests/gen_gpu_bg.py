#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Golden-model generator for the M5 part-1 BG drawer tests (tb_gpu_bg).
#
# Emits (not checked in - regenerate before streaming a DIRTY tree):
#   gpu_bg_vram.hex    512 KB BG VRAM space, 131072 words
#   gpu_bg_pal.hex     512 B  std BG palette, 128 words
#   gpu_bg_extpal.hex  32 KB  ext-pal space (4 slots x 8 KB), 8192 words
#   gpu_bg_vectors.hex per case: 16 header words + 256 expected line pixels
#                      (0x8000 = transparent), preceded by a case-count word
#
# The golden renderers implement GBATEK text/affine BG semantics with the
# RTL's exact truncation behavior (19-bit VRAM wrap, 15-bit color, mosaic
# repeat-if-opaque). Deliberately written from the register semantics, not
# transcribed from the VHDL, so it cross-checks the fork.

import random

rnd = random.Random(0xD51)

VRAM   = bytearray(rnd.getrandbits(8) for _ in range(0x80000))
PAL    = bytearray(rnd.getrandbits(8) for _ in range(0x200))
EXTPAL = bytearray(rnd.getrandbits(8) for _ in range(0x8000))

# sprinkle fully-transparent tiles so both nibble/byte zero paths get hit
for tile in range(0, 64):
    base = 0x10000 + tile * 64
    if tile % 3 == 0:
        VRAM[base:base+64] = bytes(64)
for i in range(0, 0x80000, 977):   # scattered zero bytes elsewhere
    VRAM[i] = 0

def rd16(mem, a):
    return mem[a] | (mem[a+1] << 8)

def pal16(idx):        # std BG palette, 256 entries
    return rd16(PAL, (idx * 2) & 0x1FF) & 0x7FFF

def extpal16(slot, palno, idx):
    a = (slot << 13) | (palno << 9) | (idx << 1)
    return rd16(EXTPAL, a) & 0x7FFF

def s28(v):
    v &= (1 << 28) - 1
    return v - (1 << 28) if v & (1 << 27) else v

def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def render_text(cfg):
    out = [0x8000] * 256
    y = cfg["ypos_mosaic"] if cfg["mosaic"] else cfg["ypos"]
    size = cfg["screensize"]
    sxmod = 512 if size in (1, 3) else 256
    symod = 512 if size in (2, 3) else 256
    y_s = y + cfg["scrollY"]
    y_mod = y_s % symod
    offset_y = ((y_s % 256) // 8) * 32
    period = (cfg["mosaic_h"] + 1) if cfg["mosaic"] else 1
    last = None
    for x in range(256):
        if cfg["mosaic"] and (x % period) != 0:
            if last is not None:
                out[x] = last
            continue
        xs = (x + cfg["scrollX"]) % sxmod
        ti = 0
        if xs >= 256 or (y_mod >= 256 and size == 2):
            ti += 1024
        if y_mod >= 256 and size == 3:
            ti += 2048
        tileaddr = ti + offset_y + ((xs & 255) >> 3)
        maddr = (cfg["mapbase"] + tileaddr * 2) & 0x7FFFF
        tile = rd16(VRAM, maddr)
        tno   = tile & 0x3FF
        hf    = (tile >> 10) & 1
        vf    = (tile >> 11) & 1
        palno = (tile >> 12) & 0xF
        px = xs & 7
        py = y_mod & 7
        if vf: py = 7 - py
        if hf: px = 7 - px
        if cfg["hicolor"]:
            addr = (cfg["tilebase"] + tno * 64 + py * 8 + px) & 0x7FFFF
            c = VRAM[addr]
            if c == 0:
                last = None
                continue
            col = extpal16(cfg["extpal_slot"], palno, c) if cfg["extpal"] else pal16(c)
        else:
            addr = (cfg["tilebase"] + tno * 32 + py * 4 + px // 2) & 0x7FFFF
            b = VRAM[addr]
            nib = (b >> (4 * (px & 1))) & 0xF
            if nib == 0:
                last = None
                continue
            col = pal16(palno * 16 + nib)
        out[x] = col
        last = col
    return out

def render_affine(cfg):
    out = [0x8000] * 256
    size = cfg["screensize"]
    dim = 128 << size
    shift = 4 + size
    rx, ry = s28(cfg["refX"]), s28(cfg["refY"])
    dx, dy = s16(cfg["dx"]), s16(cfg["dy"])
    for x in range(256):
        xxx = rx >> 8
        yyy = ry >> 8
        rx = s28(rx + dx)
        ry = s28(ry + dy)
        if cfg["wrapping"]:
            xxx %= dim
            yyy %= dim
        elif xxx < 0 or yyy < 0 or xxx >= dim or yyy >= dim:
            continue
        tidx = (xxx >> 3) + ((yyy >> 3) << shift)
        tno = VRAM[(cfg["mapbase"] + tidx) & 0x7FFFF]
        c = VRAM[(cfg["tilebase"] + tno * 64 + (yyy & 7) * 8 + (xxx & 7)) & 0x7FFFF]
        if c != 0:
            out[x] = pal16(c)
    return out

def text(ypos, mapbase, tilebase, hicolor=0, extpal=0, slot=0, mosaic=0,
         mosaic_h=0, ypos_mosaic=0, size=0, sx=0, sy=0):
    return dict(kind=0, ypos=ypos, ypos_mosaic=ypos_mosaic, mapbase=mapbase,
                tilebase=tilebase, hicolor=hicolor, extpal=extpal,
                extpal_slot=slot, mosaic=mosaic, mosaic_h=mosaic_h,
                wrapping=0, screensize=size, scrollX=sx, scrollY=sy,
                refX=0, refY=0, dx=0, dy=0)

def affine(mapbase, tilebase, size, wrap, refX, refY, dx, dy):
    return dict(kind=1, ypos=0, ypos_mosaic=0, mapbase=mapbase,
                tilebase=tilebase, hicolor=0, extpal=0, extpal_slot=0,
                mosaic=0, mosaic_h=0, wrapping=wrap, screensize=size,
                scrollX=0, scrollY=0, refX=refX & 0xFFFFFFF,
                refY=refY & 0xFFFFFFF, dx=dx & 0xFFFF, dy=dy & 0xFFFF)

cases = []
# text: 4bpp basics, all screen sizes, boundary-crossing scrolls
for ypos in (0, 7, 100):
    cases.append(text(ypos, mapbase=0x00000, tilebase=0x10000))
for ypos in (5, 191):
    cases.append(text(ypos, mapbase=0x7E000, tilebase=0x04000, size=3, sx=123, sy=250))
cases.append(text(63, mapbase=0x08800, tilebase=0x40000, size=1, sx=500, sy=10))
cases.append(text(64, mapbase=0x08800, tilebase=0x40000, size=2, sx=17, sy=300))
# text: 8bpp, std palette vs ext palettes on every slot
cases.append(text(42, mapbase=0x30000, tilebase=0x60000, hicolor=1))
for slot in range(4):
    cases.append(text(150, mapbase=0x30000, tilebase=0x60000, hicolor=1,
                      extpal=1, slot=slot, size=2, sx=200, sy=300))
cases.append(text(0, mapbase=0x02000, tilebase=0x7C000, hicolor=1, extpal=1,
                  slot=0, size=1, sx=509, sy=1))  # tile fetches wrap the 512K window
# text: mosaic
cases.append(text(33, mapbase=0x00000, tilebase=0x10000, mosaic=1, mosaic_h=3,
                  ypos_mosaic=32, sx=5))
cases.append(text(100, mapbase=0x30000, tilebase=0x60000, hicolor=1, extpal=1,
                  slot=2, mosaic=1, mosaic_h=7, ypos_mosaic=96))
# affine
cases.append(affine(0x00000, 0x10000, size=0, wrap=0, refX=0, refY=25 << 8, dx=0x100, dy=0))
cases.append(affine(0x7F800, 0x20000, size=2, wrap=1, refX=(-40) << 8, refY=300 << 8, dx=0x180, dy=0xC0))
cases.append(affine(0x08800, 0x40000, size=1, wrap=0, refX=(-10) << 8, refY=5 << 8, dx=0x100, dy=0x40))
cases.append(affine(0x30000, 0x60000, size=3, wrap=1, refX=0x123456, refY=(-0x23456), dx=-0x200, dy=0x100))
cases.append(affine(0x00000, 0x10000, size=0, wrap=0, refX=(-300) << 8, refY=0, dx=-0x100, dy=0))  # fully off-map

def whex(f, v):
    f.write(f"{v & 0xFFFFFFFF:08x}\n")

def dump_words(fname, mem):
    with open(fname, "w") as f:
        for i in range(0, len(mem), 4):
            whex(f, int.from_bytes(mem[i:i+4], "little"))

dump_words("gpu_bg_vram.hex", VRAM)
dump_words("gpu_bg_pal.hex", PAL)
dump_words("gpu_bg_extpal.hex", EXTPAL)

with open("gpu_bg_vectors.hex", "w") as f:
    whex(f, len(cases))
    for cfg in cases:
        flags = cfg["hicolor"] | (cfg["extpal"] << 1) | (cfg["mosaic"] << 2) | (cfg["wrapping"] << 3)
        hdr = [cfg["kind"], cfg["ypos"], cfg["ypos_mosaic"], cfg["mapbase"],
               cfg["tilebase"], flags, cfg["extpal_slot"], cfg["mosaic_h"],
               cfg["screensize"], cfg["scrollX"], cfg["scrollY"],
               cfg["refX"], cfg["refY"], cfg["dx"], cfg["dy"], 0]
        for w in hdr:
            whex(f, w)
        line = render_text(cfg) if cfg["kind"] == 0 else render_affine(cfg)
        for p in line:
            whex(f, p)

print(f"{len(cases)} cases")
