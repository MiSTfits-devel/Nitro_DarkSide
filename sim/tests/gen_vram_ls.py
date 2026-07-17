#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Golden-model generator for the VRAM line-server tests (tb_vram_ls).
#
# Emits vram_ls_vectors.hex (not checked in - regenerate before running):
#   word 0:            config count
#   per config:        3 words packed VRAMCNT A..I, 1 word read count, then
#                      per read: (chan<<28 | cc<<27 | byteaddr), expected32
#     chan: 0=BG (512 KB main-BG space), 1=OBJ (256 KB main-OBJ space),
#           2=BG ext pal (32 KB), 3=OBJ ext pal (8 KB),
#           4=sub BG (128 KB), 5=sub OBJ (128 KB),
#           6=sub BG ext pal (32 KB), 7=sub OBJ ext pal (8 KB)
#     cc:   the last eight reads of each config carry cc=1, one per channel
#           in order 0..7 - the TB fires those eight requests simultaneously
#           to exercise the round-robin arbiter.
#
# Bank contents are the shared deterministic fill
#   word(b, widx) = (widx * 0x9E3779B1 + (b+1) * 0x85EBCA77) & 0xFFFFFFFF
# (the TB writes E..I through the CPU port in LCDC mode; A..D live in the
# behavioral srv/rsrv models which compute it on the fly).
#
# The mapping semantics below are implemented from GBATEK "DS Video Memory
# Control" / NitroSDK gx_vramcnt.c - independently of both nds_vram_map and
# the ext-palette decode in nds_vram - so this cross-checks the whole
# renderer read path, engine A and engine B.

import random

rnd = random.Random(0x715)

BANKSIZE = [0x20000]*4 + [0x10000, 0x4000, 0x4000, 0x8000, 0x4000]

def word(b, widx):
    return (widx * 0x9E3779B1 + (b + 1) * 0x85EBCA77) & 0xFFFFFFFF

def fields(byte, i):
    ena = (byte >> 7) & 1
    mst = byte & (3 if i in (0, 1, 7, 8) else 7)
    ofs = (byte >> 3) & 3
    return ena, mst, ofs

def hits_bg(cnt, a):                      # a: byte addr in 512 KB BG space
    h = []
    for i in range(4):
        ena, mst, ofs = fields(cnt[i], i)
        if ena and mst == 1 and (a >> 17) == ofs:
            h.append((i, a & 0x1FFFF))
    ena, mst, ofs = fields(cnt[4], 4)
    if ena and mst == 1 and a < 0x10000:
        h.append((4, a))
    for i in (5, 6):
        ena, mst, ofs = fields(cnt[i], i)
        if (ena and mst == 1 and (a >> 17) == 0 and ((a >> 16) & 1) == (ofs >> 1)
                and ((a >> 15) & 1) == 0 and ((a >> 14) & 1) == (ofs & 1)):
            h.append((i, a & 0x3FFF))
    return h

def hits_obj(cnt, a):                     # a: byte addr in 256 KB OBJ space
    h = []
    for i in (0, 1):
        ena, mst, ofs = fields(cnt[i], i)
        if ena and mst == 2 and ((a >> 17) & 1) == (ofs & 1):
            h.append((i, a & 0x1FFFF))
    ena, mst, ofs = fields(cnt[4], 4)
    if ena and mst == 2 and a < 0x10000:
        h.append((4, a))
    for i in (5, 6):
        ena, mst, ofs = fields(cnt[i], i)
        if (ena and mst == 2 and (a >> 17) == 0 and ((a >> 16) & 1) == (ofs >> 1)
                and ((a >> 15) & 1) == 0 and ((a >> 14) & 1) == (ofs & 1)):
            h.append((i, a & 0x3FFF))
    return h

def hits_bgep(cnt, a):                    # a: byte addr in 32 KB BG ext-pal
    h = []
    ena, mst, ofs = fields(cnt[4], 4)
    if ena and mst == 4:
        h.append((4, a))
    for i in (5, 6):
        ena, mst, ofs = fields(cnt[i], i)
        if ena and mst == 4 and ((a >> 14) & 1) == (ofs & 1):
            h.append((i, a & 0x3FFF))
    return h

def hits_objep(cnt, a):                   # a: byte addr in 8 KB OBJ ext-pal
    h = []
    for i in (5, 6):
        ena, mst, ofs = fields(cnt[i], i)
        if ena and mst == 5:
            h.append((i, a & 0x1FFF))
    return h

def hits_bgb(cnt, a):                     # a: byte addr in 128 KB sub-BG space
    h = []
    ena, mst, ofs = fields(cnt[2], 2)     # C MST=4: full 128 KB
    if ena and mst == 4:
        h.append((2, a))
    ena, mst, ofs = fields(cnt[7], 7)     # H MST=1: first 32 KB
    if ena and mst == 1 and a < 0x8000:
        h.append((7, a))
    ena, mst, ofs = fields(cnt[8], 8)     # I MST=1: 0x8000..0xBFFF
    if ena and mst == 1 and (a >> 14) == 2:
        h.append((8, a & 0x3FFF))
    return h

def hits_objb(cnt, a):                    # a: byte addr in 128 KB sub-OBJ space
    h = []
    ena, mst, ofs = fields(cnt[3], 3)     # D MST=4: full 128 KB
    if ena and mst == 4:
        h.append((3, a))
    ena, mst, ofs = fields(cnt[8], 8)     # I MST=2: first 16 KB
    if ena and mst == 2 and a < 0x4000:
        h.append((8, a & 0x3FFF))
    return h

def hits_bgepb(cnt, a):                   # a: byte addr in 32 KB sub BG ext-pal
    h = []
    ena, mst, ofs = fields(cnt[7], 7)     # H MST=2: all 4 slots
    if ena and mst == 2:
        h.append((7, a))
    return h

def hits_objepb(cnt, a):                  # a: byte addr in 8 KB sub OBJ ext-pal
    h = []
    ena, mst, ofs = fields(cnt[8], 8)     # I MST=3
    if ena and mst == 3:
        h.append((8, a & 0x1FFF))
    return h

HITS = [hits_bg, hits_obj, hits_bgep, hits_objep,
        hits_bgb, hits_objb, hits_bgepb, hits_objepb]
SPACE = [0x80000, 0x40000, 0x8000, 0x2000, 0x20000, 0x20000, 0x8000, 0x2000]

def expected(cnt, chan, a):
    v = 0
    for b, off in HITS[chan](cnt, a):
        v |= word(b, off >> 2)
    return v

def b(mst, ofs=0):
    return 0x80 | (ofs << 3) | mst

# configs: [A,B,C,D,E,F,G,H,I]
configs = [
    # 0: full 512 KB BG out of A..D
    [b(1, 0), b(1, 1), b(1, 2), b(1, 3), 0, 0, 0, 0, 0],
    # 1: OBJ from A/B, BG from E/F/G
    [b(2, 0), b(2, 1), 0, 0, b(1), b(1, 0), b(1, 3), 0, 0],
    # 2: triple overlap in the first 64 KB of BG (A + B + E, ORed)
    [b(1, 0), b(1, 0), 0, 0, b(1), 0, 0, 0, 0],
    # 3: sparse - only D at BG slot 2, everything else holes
    [0, 0, 0, b(1, 2), 0, 0, 0, 0, 0],
    # 4: OBJ from the small banks (B slot 1, E, F ofs1, G ofs2) w/ E-F overlap
    [0, b(2, 1), 0, 0, b(2), b(2, 1), b(2, 2), 0, 0],
    # 5: ext palettes - E all BG slots, F OBJ ext pal
    [0, 0, 0, 0, b(4), b(5), 0, 0, 0],
    # 6: BG ext pal split across F (slots 0-1) / G (slots 2-3)
    [0, 0, 0, 0, 0, b(4, 0), b(4, 1), 0, 0],
    # 7: BG ext pal overlap (E + F on slots 2-3), OBJ ext pal from G
    [0, 0, 0, 0, b(4), b(4, 1), b(5), 0, 0],
    # 8: everything disabled
    [0, 0, 0, 0, 0, 0, 0, 0, 0],
    # 9: everything LCDC - renderer spaces all unmapped
    [b(0), b(0), b(0), b(0), b(0), b(0), b(0), b(0), b(0)],
    # 10: kitchen sink; H/I in sub roles must NOT hit engine A
    [b(1, 3), b(2, 0), b(1, 0), b(1, 1), b(1), b(4, 0), b(5), b(1), b(2)],
    # 11: F/G BG windows at the other OFS combinations + OBJ ext pal on F
    [0, 0, b(1, 1), 0, b(2), b(1, 2), b(1, 1), 0, 0],
    # 12: full engine B: C sub-BG, D sub-OBJ, H BG ext pal B, I OBJ ext pal B
    [0, 0, b(4), b(4), 0, 0, 0, b(2), b(3)],
    # 13: sub-BG from the small banks only (H @0, I @0x8000), sub-OBJ from D
    [0, 0, 0, b(4), 0, 0, 0, b(1), b(1)],
    # 14: both engines + overlaps: C and H OR in the low sub-BG window,
    #     D and I OR in the low sub-OBJ window, engine A from A/B/E/F/G
    [b(1, 0), b(2, 0), b(4), b(4), b(1), b(4, 0), b(5), b(1), b(2)],
    # 15: B ext pals alone - sub-BG/OBJ spaces unmapped read 0
    [0, 0, 0, 0, 0, 0, 0, b(2), b(3)],
]
# config 11: F ofs2 -> BG window 0x10000, G ofs1 -> BG window 0x4000; F also
# claims mst... F is mst=1 there; OBJ ep comes from nowhere (checks zero)

def window_probes(cnt, chan):
    """boundary addresses of every active window + fixed probes"""
    probes = set()
    space = SPACE[chan]
    # canonical window starts/ends per bank role
    if chan == 0:
        for i in range(4):
            ena, mst, ofs = fields(cnt[i], i)
            if ena and mst == 1:
                base = ofs << 17
                probes |= {base, base + 0x1FFFC, base + 0x10000}
        ena, mst, ofs = fields(cnt[4], 4)
        if ena and mst == 1:
            probes |= {0, 0xFFFC, 0x10000}
        for i in (5, 6):
            ena, mst, ofs = fields(cnt[i], i)
            if ena and mst == 1:
                base = ((ofs >> 1) << 16) | ((ofs & 1) << 14)
                probes |= {base, base + 0x3FFC, (base + 0x4000) % space}
        probes |= {0x7FFFC, 0x20000, 0x60000}
    elif chan == 1:
        for i in (0, 1):
            ena, mst, ofs = fields(cnt[i], i)
            if ena and mst == 2:
                base = (ofs & 1) << 17
                probes |= {base, base + 0x1FFFC}
        ena, mst, ofs = fields(cnt[4], 4)
        if ena and mst == 2:
            probes |= {0, 0xFFFC, 0x10000}
        for i in (5, 6):
            ena, mst, ofs = fields(cnt[i], i)
            if ena and mst == 2:
                base = ((ofs >> 1) << 16) | ((ofs & 1) << 14)
                probes |= {base, base + 0x3FFC}
        probes |= {0x3FFFC, 0x20000}
    elif chan == 2:
        probes |= {0, 0x1FFC, 0x2000, 0x3FFC, 0x4000, 0x5FFC, 0x6000, 0x7FFC}
    elif chan == 3:
        probes |= {0, 0xFFC, 0x1000, 0x1FFC}
    elif chan == 4:
        # sub-BG windows: H 0..0x7FFF, I 0x8000..0xBFFF, C full
        probes |= {0, 0x7FFC, 0x8000, 0xBFFC, 0xC000, 0x1FFFC, 0x10000}
    elif chan == 5:
        # sub-OBJ windows: I 0..0x3FFF, D full
        probes |= {0, 0x3FFC, 0x4000, 0x1FFFC, 0x10000}
    elif chan == 6:
        probes |= {0, 0x1FFC, 0x4000, 0x7FFC}
    else:
        probes |= {0, 0xFFC, 0x1000, 0x1FFC}
    return sorted(a for a in probes if a < space)

reads = []   # per config: list of (chan, cc, addr, expected)
for cnt in configs:
    r = []
    for chan in range(8):
        for a in window_probes(cnt, chan):
            r.append((chan, 0, a, expected(cnt, chan, a)))
        nrand = 16 if chan in (0, 1, 4, 5) else 8
        for _ in range(nrand):
            a = rnd.randrange(0, SPACE[chan]) & ~3
            r.append((chan, 0, a, expected(cnt, chan, a)))
    # concurrent batch: one read per channel, fired simultaneously by the TB
    for chan in range(8):
        a = rnd.randrange(0, SPACE[chan]) & ~3
        r.append((chan, 1, a, expected(cnt, chan, a)))
    reads.append(r)

with open("vram_ls_vectors.hex", "w") as f:
    def whex(v):
        f.write(f"{v & 0xFFFFFFFF:08x}\n")
    whex(len(configs))
    for cnt, r in zip(configs, reads):
        whex(cnt[0] | cnt[1] << 8 | cnt[2] << 16 | cnt[3] << 24)
        whex(cnt[4] | cnt[5] << 8 | cnt[6] << 16 | cnt[7] << 24)
        whex(cnt[8])
        whex(len(r))
        for chan, cc, a, exp in r:
            whex(chan << 28 | cc << 27 | a)
            whex(exp)

total = sum(len(r) for r in reads)
print(f"{len(configs)} configs, {total} reads")
