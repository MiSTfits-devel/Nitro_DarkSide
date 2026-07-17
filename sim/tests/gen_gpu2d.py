#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Golden-model generator for the nds_gpu2d frame tests (tb_gpu2d).
#
# Emits (generated, not checked in):
#   gpu2d_bgvram.hex   512 KB BG space      gpu2d_objvram.hex  256 KB OBJ space
#   gpu2d_bgep.hex     32 KB BG ext-pal     gpu2d_objep.hex    8 KB OBJ ext-pal
#   gpu2d_pal.hex      1 KB std palettes    gpu2d_oam.hex      1 KB OAM
#   gpu2d_frames.hex   frame count, then per frame 32 register words +
#                      192*256 expected pixels (18-bit BGR666)
#
# The per-line renderers are the RTL-verified golden models from
# gen_gpu_bg/gen_gpu_obj/gen_gpu_merge, parameterized over the memories,
# composed exactly like nds_gpu2d: mode table, base summing, ext-pal slots,
# affine ref stepping per line, OBJ one line ahead (state-free here),
# backdrop from BG palette entry 0.

import random

rnd = random.Random(0x62D)

BGVRAM  = bytearray(rnd.getrandbits(8) for _ in range(0x80000))
OBJVRAM = bytearray(rnd.getrandbits(8) for _ in range(0x40000))
BGEP    = bytearray(rnd.getrandbits(8) for _ in range(0x8000))
OBJEP   = bytearray(rnd.getrandbits(8) for _ in range(0x2000))
PAL     = bytearray(rnd.getrandbits(8) for _ in range(0x400))
for i in range(0, 0x80000, 613):
    BGVRAM[i] = 0
for i in range(0, 0x40000, 741):
    OBJVRAM[i] = 0
for i in range(0, 0x40000, 523):   # clear some bitmap alpha bits
    OBJVRAM[i | 1] &= 0x7F

def rd16(m, a):
    return m[a] | (m[a+1] << 8)

def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def s28(v):
    v &= 0xFFFFFFF
    return v - (1 << 28) if v & (1 << 27) else v

def bgpal(idx):
    return rd16(PAL, (idx * 2) & 0x1FF) & 0x7FFF

def objpal(idx):
    return rd16(PAL, 0x200 + ((idx * 2) & 0x1FF)) & 0x7FFF

def bgep16(slot, palno, idx):
    return rd16(BGEP, (slot << 13) | (palno << 9) | (idx << 1)) & 0x7FFF

def objep16(palno, idx):
    return rd16(OBJEP, ((palno * 256 + idx) * 2) & 0x1FFF) & 0x7FFF

# ---------------- per-BG line renderers (RTL-verified logic) ----------------

def render_text(y, mapbase, tilebase, hicolor, extpal, slot, size, sx, sy,
                mosaic, mos_h, y_mos):
    out = [0x8000] * 256
    yy = y_mos if mosaic else y
    sxmod = 512 if size in (1, 3) else 256
    symod = 512 if size in (2, 3) else 256
    y_s = yy + sy
    y_mod = y_s % symod
    offset_y = ((y_s % 256) // 8) * 32
    period = (mos_h + 1) if mosaic else 1
    last = None
    for x in range(256):
        if mosaic and (x % period) != 0:
            if last is not None:
                out[x] = last
            continue
        xs = (x + sx) % sxmod
        ti = 1024 if (xs >= 256 or (y_mod >= 256 and size == 2)) else 0
        if y_mod >= 256 and size == 3:
            ti += 2048
        tile = rd16(BGVRAM, (mapbase + (ti + offset_y + ((xs & 255) >> 3)) * 2) & 0x7FFFF)
        tno, hf, vf, palno = tile & 0x3FF, (tile >> 10) & 1, (tile >> 11) & 1, (tile >> 12) & 0xF
        px, py = xs & 7, y_mod & 7
        if vf: py = 7 - py
        if hf: px = 7 - px
        if hicolor:
            c = BGVRAM[(tilebase + tno * 64 + py * 8 + px) & 0x7FFFF]
            if c == 0:
                last = None
                continue
            col = bgep16(slot, palno, c) if extpal else bgpal(c)
        else:
            b = BGVRAM[(tilebase + tno * 32 + py * 4 + px // 2) & 0x7FFFF]
            nib = (b >> (4 * (px & 1))) & 0xF
            if nib == 0:
                last = None
                continue
            col = bgpal(palno * 16 + nib)
        out[x] = col
        last = col
    return out

def render_affine(refx, refy, dx, dy, mapbase, tilebase, size, wrap, mosaic=0, mos_h=0):
    # H-mosaic mirrors the RTL handoff pipeline: the repeat counter only
    # advances on handed-off (in-range) pixels, and a repeat re-emits the
    # last *fetched* pixel - nothing if that fetch was transparent.
    # V-mosaic for affine BGs is not implemented on either side yet (the
    # orchestrator wires refX_mosaic = refX); revisit for melonDS parity.
    out = [0x8000] * 256
    dim = 128 << size
    rx, ry = refx, refy
    cnt, last = 15, None
    for x in range(256):
        xxx, yyy = rx >> 8, ry >> 8
        rx, ry = s28(rx + dx), s28(ry + dy)
        if wrap:
            xxx %= dim
            yyy %= dim
        elif xxx < 0 or yyy < 0 or xxx >= dim or yyy >= dim:
            continue
        if mosaic and cnt < mos_h:
            cnt += 1
            if last is not None:
                out[x] = last
            continue
        cnt = 0
        tno = BGVRAM[(mapbase + (xxx >> 3) + ((yyy >> 3) << (4 + size))) & 0x7FFFF]
        c = BGVRAM[(tilebase + tno * 64 + (yyy & 7) * 8 + (xxx & 7)) & 0x7FFFF]
        last = bgpal(c) if c else None
        if c:
            out[x] = bgpal(c)
    return out

def render_extended(refx, refy, dx, dy, variant, base, tilebase, size, wrap,
                    extpal, slot):
    out = [0x8000] * 256
    if variant == 0:
        w, h = 128 << size, 128 << size
    else:
        w, h = [(128, 128), (256, 256), (512, 256), (512, 512)][size]
    rx, ry = refx, refy
    for x in range(256):
        xxx, yyy = rx >> 8, ry >> 8
        rx, ry = s28(rx + dx), s28(ry + dy)
        if wrap:
            xxx %= w
            yyy %= h
        elif xxx < 0 or yyy < 0 or xxx >= w or yyy >= h:
            continue
        if variant == 0:
            tile = rd16(BGVRAM, (base + ((xxx >> 3) + (yyy >> 3) * (w >> 3)) * 2) & 0x7FFFF)
            tno, palno = tile & 0x3FF, (tile >> 12) & 0xF
            px = (7 - (xxx & 7)) if (tile >> 10) & 1 else (xxx & 7)
            py = (7 - (yyy & 7)) if (tile >> 11) & 1 else (yyy & 7)
            c = BGVRAM[(tilebase + tno * 64 + py * 8 + px) & 0x7FFFF]
            if c:
                out[x] = bgep16(slot, palno, c) if extpal else bgpal(c)
        elif variant == 1:
            c = BGVRAM[(base + yyy * w + xxx) & 0x7FFFF]
            if c:
                out[x] = bgpal(c)
        else:
            v = rd16(BGVRAM, (base + (yyy * w + xxx) * 2) & 0x7FFFF)
            if v & 0x8000:
                out[x] = v & 0x7FFF
    return out

SIZES = [
    [( 8,  8), (16, 16), (32, 32), (64, 64)],
    [(16,  8), (32,  8), (32, 16), (64, 32)],
    [( 8, 16), ( 8, 32), (16, 32), (32, 64)],
]

def render_objs(oam, y, cfg):
    col  = [0x8000] * 256
    sett = [0x00] * 256
    ownd = [0] * 256
    st_tr = [True] * 256
    st_pr = [3] * 256
    for i in range(128):
        a0, a1, a2 = rd16(oam, i*8), rd16(oam, i*8+2), rd16(oam, i*8+4)
        affine = (a0 >> 8) & 1
        if not affine and ((a0 >> 9) & 1):
            continue
        shape = (a0 >> 14) & 3
        if shape == 3:
            continue
        mode, mosaic, hicolor = (a0 >> 10) & 3, (a0 >> 12) & 1, (a0 >> 13) & 1
        size = (a1 >> 14) & 3
        w, h = SIZES[shape][size]
        dbl = affine and ((a0 >> 9) & 1)
        fw, fh = (2*w, 2*h) if dbl else (w, h)
        ybase = a0 & 0xFF
        posy = ybase - 0x100 if ybase > 0x100 - fh else ybase
        yy = cfg["obj_ymos"](y) if mosaic else y
        ty = yy - posy
        if ty < 0 or ty >= fh:
            continue
        isbmp = (mode == 3)
        if isbmp and cfg["bmp1d"] and cfg["bmp2dw"]:
            continue
        alpha = (a2 >> 12) & 0xF
        if isbmp and alpha == 0:
            continue
        tileno, prio, palno = a2 & 0x3FF, (a2 >> 10) & 3, (a2 >> 12) & 0xF
        x9 = a1 & 0x1FF
        posx = x9 - 0x200 if x9 > 0x100 else x9
        hflip = (not affine) and bool((a1 >> 12) & 1)
        vflip = (not affine) and bool((a1 >> 13) & 1)
        if isbmp:
            if cfg["bmp1d"]:
                base, stride = tileno << (7 + cfg["bmpbound"]), w * 2
            elif cfg["bmp2dw"]:
                base, stride = ((tileno & 0x1F) << 4) + ((tileno & 0x3E0) << 7), 512
            else:
                base, stride = ((tileno & 0x0F) << 4) + ((tileno & 0x3F0) << 7), 256
        else:
            if cfg["obj1d"]:
                base = tileno * (32 << cfg["objbound"])
                stride = (w // 8) * (64 if hicolor else 32)
            else:
                base, stride = tileno * 32, 1024
        if affine:
            g = (a1 >> 9) & 0x1F
            pa, pb, pc, pd = (s16(rd16(oam, g*32 + k*8 + 6)) for k in range(4))
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
            tgt = sx + posx
            if not (0 <= tgt < 256):
                continue
            if isbmp:
                v = rd16(OBJVRAM, (base + yyy * stride + xxx * 2) & 0x3FFFF)
                tr, pix = not (v & 0x8000), v & 0x7FFF
            elif hicolor:
                c = OBJVRAM[(base + (yyy//8)*stride + (yyy%8)*8 + (xxx//8)*64 + (xxx%8)) & 0x3FFFF]
                tr = (c == 0)
                pix = objep16(palno, c) if cfg["objextpal"] else objpal(c)
            else:
                b = OBJVRAM[(base + (yyy//8)*stride + (yyy%8)*4 + (xxx//8)*32 + (xxx%8)//2) & 0x3FFFF]
                nib = (b >> (4 * (xxx & 1))) & 0xF
                tr = (nib == 0)
                pix = objpal(palno * 16 + nib)
            if mode == 2:
                if not tr:
                    ownd[tgt] = 1
                continue
            if st_tr[tgt] or prio < st_pr[tgt]:
                sett[tgt] = ((alpha << 4) | 0x8 | prio) if isbmp else ((0x4 if mode == 1 else 0) | prio)
                st_pr[tgt] = prio
                if not tr:
                    col[tgt] = pix
                    st_tr[tgt] = False
    return col, sett, ownd

# ---------------- merge (from gen_gpu_merge) ----------------

BG0, BG1, BG2, BG3, OBJ, BD = range(6)

def expand666(c15):
    return (((c15 & 0x1F) << 1)
            | ((((c15 >> 5) & 0x1F) << 1) << 6)
            | ((((c15 >> 10) & 0x1F) << 1) << 12))

def in_range(v, a, b):
    return (a <= b and a <= v < b) or (a > b and (v >= a or v < b))

def pick_top(ena, objprio, prios):
    cand = list(ena)
    for bg in range(4):
        if cand[bg] and cand[OBJ] and objprio > prios[bg]:
            cand[OBJ] = 0
    for a in range(4):
        for b in range(4):
            if a < b and cand[a] and cand[b] and prios[a] > prios[b]:
                cand[a] = 0
    for lay in (OBJ, BG0, BG1, BG2, BG3):
        if cand[lay]:
            return lay
    return BD

def merge_line(r, y, bg, objcol, objsett, objwnd):
    out = []
    prios = [r[f"bg{i}prio"] for i in range(4)]
    eva, evb, bldy = min(r["eva"], 16), min(r["evb"], 16), min(r["bldy"], 16)
    anywin = r["win0"] or r["win1"] or r["winobj"]
    backdrop = bgpal(0)
    for x in range(256):
        colors = [bg[i][x] & 0x7FFF for i in range(4)]
        transp = [(bg[i][x] >> 15) & 1 for i in range(4)]
        ocol, osett = objcol[x], objsett[x]
        otr = (ocol >> 15) & 1
        ocol &= 0x7FFF
        oprio, osemi, obmp, obalpha = osett & 3, (osett >> 2) & 1, (osett >> 3) & 1, (osett >> 4) & 0xF
        special_en, mask = 1, 0x1F
        if anywin:
            if r["win0"] and in_range(y, r["w0y1"], r["w0y2"]) and in_range(x, r["w0x1"], r["w0x2"]):
                sel = r["en_win0"]
            elif r["win1"] and in_range(y, r["w1y1"], r["w1y2"]) and in_range(x, r["w1x1"], r["w1x2"]):
                sel = r["en_win1"]
            elif r["winobj"] and objwnd[x]:
                sel = r["en_winobj"]
            else:
                sel = r["en_winout"]
            special_en, mask = (sel >> 5) & 1, sel & 0x1F
        ena = [0] * 6
        for i in range(4):
            ena[i] = r["ena"][i] and not transp[i] and ((mask >> i) & 1)
        ena[OBJ] = r["ena"][4] and not otr and ((mask >> 4) & 1)
        ena[BD] = 1
        top = pick_top(ena, oprio, prios)
        force = (top == OBJ) and (osemi or obmp)
        first = top if (((r["bld1st"] >> top) & 1) or force) else None
        sec_ena = list(ena)
        if first is not None:
            sec_ena[first] = 0
        sec = pick_top(sec_ena, oprio, prios)
        sec_m = sec if ((r["bld2nd"] >> sec) & 1) else None

        def layercolor(lay):
            return ocol if lay == OBJ else (backdrop if lay == BD else colors[lay])

        fp = layercolor(first) if first is not None else backdrop
        sp = layercolor(sec_m) if sec_m is not None else backdrop
        eff = r["bldeff"]
        apply = 0
        if special_en and eff > 0 and first is not None:
            apply = 1 if (eff != 1 or sec_m is not None) else 0
        if (osemi or obmp) and first == OBJ and sec_m is not None:
            eff, apply = 1, 1
        if eff > 1 and first == OBJ and not ((r["bld1st"] >> OBJ) & 1):
            apply = 0
        if apply:
            res = 0
            if eff == 1:
                ea, eb = (obalpha + 1, 16 - (obalpha + 1)) if (obmp and first == OBJ) else (eva, evb)
                for i, sh in enumerate((0, 5, 10)):
                    res |= min(63, ((((fp >> sh) & 31) << 1) * ea + (((sp >> sh) & 31) << 1) * eb + 8) // 16) << (6 * i)
            elif eff == 2:
                for i, sh in enumerate((0, 5, 10)):
                    c = ((fp >> sh) & 31) << 1
                    res |= (c + ((63 - c) * bldy + 8) // 16) << (6 * i)
            else:
                for i, sh in enumerate((0, 5, 10)):
                    c = ((fp >> sh) & 31) << 1
                    res |= (c - (c * bldy + 7) // 16) << (6 * i)
            out.append(res)
        else:
            out.append(expand666(layercolor(top)))
    return out

# ---------------- frame composition (mirrors nds_gpu2d) ----------------

MODES = {0: (1,1,1,1), 1: (1,1,1,2), 2: (1,1,2,2), 3: (1,1,1,3), 4: (1,1,2,3), 5: (1,1,3,3)}

def render_frame(r, oam):
    fb = []
    bgtype = list(MODES.get(r["mode"], (0,0,0,0)))
    if r["bg0_3d"]:
        bgtype[0] = 0
    refx = [0, 0, s28(r["bg2refx"]), s28(r["bg3refx"])]
    refy = [0, 0, s28(r["bg2refy"]), s28(r["bg3refy"])]
    dmx  = [0, 0, s16(r["bg2dmx"]), s16(r["bg3dmx"])]
    dmy  = [0, 0, s16(r["bg2dmy"]), s16(r["bg3dmy"])]
    dx   = [0, 0, s16(r["bg2dx"]), s16(r["bg3dx"])]
    dy   = [0, 0, s16(r["bg2dy"]), s16(r["bg3dy"])]
    objcfg = dict(obj1d=r["obj1d"], objbound=r["objbound"], bmp1d=r["bmp1d"],
                  bmp2dw=r["bmp2dw"], bmpbound=r["bmpbound"], objextpal=r["objextpal"],
                  obj_ymos=lambda y: y - y % (r["mos_objv"] + 1))
    for y in range(192):
        bglines = []
        for i in range(4):
            mapb  = (r["screenbase"] * 65536 + r[f"bg{i}scr"] * 2048) & 0x7FFFF
            tileb = (r["charbase"] * 65536 + r[f"bg{i}chr"] * 16384) & 0x7FFFF
            bmpb  = (r[f"bg{i}scr"] * 16384) & 0x7FFFF
            slot  = (i + 2 if r[f"bg{i}slot"] else i) if i < 2 else i
            if bgtype[i] == 1:
                line = render_text(y, mapb, tileb, r[f"bg{i}hicol"], r["bgextpal"],
                                   slot, r[f"bg{i}size"], r[f"bg{i}sx"], r[f"bg{i}sy"],
                                   r[f"bg{i}mos"], r["mos_bgh"],
                                   y - y % (r["mos_bgv"] + 1))
            elif bgtype[i] == 2:
                line = render_affine(refx[i], refy[i], dx[i], dy[i], mapb, tileb,
                                     r[f"bg{i}size"], r[f"bg{i}slot"],
                                     r[f"bg{i}mos"], r["mos_bgh"])
            elif bgtype[i] == 3:
                var = 0 if not r[f"bg{i}hicol"] else (1 if (r[f"bg{i}chr"] & 1) == 0 else 2)
                line = render_extended(refx[i], refy[i], dx[i], dy[i], var,
                                       mapb if var == 0 else bmpb, tileb,
                                       r[f"bg{i}size"], r[f"bg{i}slot"],
                                       r["bgextpal"], i)
            else:
                line = [0x8000] * 256
            bglines.append(line)
        ocol, osett, ownd = render_objs(oam, y, objcfg)
        fb.append(merge_line(r, y, bglines, ocol, osett, ownd))
        for i in (2, 3):
            refx[i] = s28(refx[i] + dmx[i])
            refy[i] = s28(refy[i] + dmy[i])
    return fb

# ---------------- registers -> word list ----------------

def regs(**kw):
    r = dict(mode=0, bg0_3d=0, obj1d=0, bmp2dw=0, bmp1d=0, objbound=0, bmpbound=0,
             charbase=0, screenbase=0, bgextpal=0, objextpal=0,
             ena=[1,1,1,1,1], win0=0, win1=0, winobj=0,
             w0x1=0, w0x2=0, w0y1=0, w0y2=0, w1x1=0, w1x2=0, w1y1=0, w1y2=0,
             en_win0=0x3F, en_win1=0x3F, en_winobj=0x3F, en_winout=0x3F,
             bldeff=0, bld1st=0, bld2nd=0, eva=16, evb=0, bldy=0,
             mos_bgh=0, mos_bgv=0, mos_objh=0, mos_objv=0,
             bg2dx=0x100, bg2dmx=0, bg2dy=0, bg2dmy=0x100, bg2refx=0, bg2refy=0,
             bg3dx=0x100, bg3dmx=0, bg3dy=0, bg3dmy=0x100, bg3refx=0, bg3refy=0)
    for i in range(4):
        r[f"bg{i}prio"] = i
        r[f"bg{i}chr"] = 0
        r[f"bg{i}scr"] = 0
        r[f"bg{i}hicol"] = 0
        r[f"bg{i}slot"] = 0
        r[f"bg{i}size"] = 0
        r[f"bg{i}mos"] = 0
        r[f"bg{i}sx"] = 0
        r[f"bg{i}sy"] = 0
    r.update(kw)
    return r

def reg_words(r):
    dispcnt = (r["mode"] | (r["bg0_3d"] << 3) | (r["obj1d"] << 4) | (r["bmp2dw"] << 5)
               | (r["bmp1d"] << 6)
               | (r["ena"][0] << 8) | (r["ena"][1] << 9) | (r["ena"][2] << 10)
               | (r["ena"][3] << 11) | (r["ena"][4] << 12)
               | (r["win0"] << 13) | (r["win1"] << 14) | (r["winobj"] << 15)
               | (1 << 16)
               | (r["objbound"] << 20) | (r["bmpbound"] << 22)
               | (r["charbase"] << 24) | (r["screenbase"] << 27)
               | (r["bgextpal"] << 30) | (r["objextpal"] << 31))
    def bgcnt(i):
        return (r[f"bg{i}prio"] | (r[f"bg{i}chr"] << 2) | (r[f"bg{i}mos"] << 6)
                | (r[f"bg{i}hicol"] << 7) | (r[f"bg{i}scr"] << 8)
                | (r[f"bg{i}slot"] << 13) | (r[f"bg{i}size"] << 14))
    words = [
        dispcnt,                                    # 0x000
        0,                                          # 0x004 (dispstat, unused)
        bgcnt(0) | (bgcnt(1) << 16),                # 0x008
        bgcnt(2) | (bgcnt(3) << 16),                # 0x00C
        r["bg0sx"] | (r["bg0sy"] << 16),            # 0x010
        r["bg1sx"] | (r["bg1sy"] << 16),
        r["bg2sx"] | (r["bg2sy"] << 16),
        r["bg3sx"] | (r["bg3sy"] << 16),
        (r["bg2dx"] & 0xFFFF) | ((r["bg2dmx"] & 0xFFFF) << 16),   # 0x020
        (r["bg2dy"] & 0xFFFF) | ((r["bg2dmy"] & 0xFFFF) << 16),
        r["bg2refx"] & 0xFFFFFFF,
        r["bg2refy"] & 0xFFFFFFF,
        (r["bg3dx"] & 0xFFFF) | ((r["bg3dmx"] & 0xFFFF) << 16),   # 0x030
        (r["bg3dy"] & 0xFFFF) | ((r["bg3dmy"] & 0xFFFF) << 16),
        r["bg3refx"] & 0xFFFFFFF,
        r["bg3refy"] & 0xFFFFFFF,
        (r["w0x2"] | (r["w0x1"] << 8) | (r["w1x2"] << 16) | (r["w1x1"] << 24)),  # 0x040
        (r["w0y2"] | (r["w0y1"] << 8) | (r["w1y2"] << 16) | (r["w1y1"] << 24)),  # 0x044
        (r["en_win0"] | (r["en_win1"] << 8) | (r["en_winout"] << 16) | (r["en_winobj"] << 24)),  # 0x048
        (r["mos_bgh"] | (r["mos_bgv"] << 4) | (r["mos_objh"] << 8) | (r["mos_objv"] << 12)),     # 0x04C
        (r["bld1st"] | (r["bldeff"] << 6) | (r["bld2nd"] << 8)
         | (r["eva"] << 16) | (r["evb"] << 24)),    # 0x050
        r["bldy"],                                  # 0x054
    ]
    words += [0] * (32 - len(words))
    return words

# ---------------- OAM ----------------

def new_oam():
    oam = bytearray(1024)
    for i in range(128):
        oam[i*8 + 1] = 0x02
    return oam

def wr16(m, a, v):
    m[a] = v & 0xFF
    m[a+1] = (v >> 8) & 0xFF

def obj(oam, idx, x, y, shape, size, tileno, prio=0, palno=0, mode=0, affine=0,
        dbl=0, hflip=0, vflip=0, hicolor=0, affsel=0):
    a0 = (y & 0xFF) | (affine << 8) | ((dbl if affine else 0) << 9) | (mode << 10) \
         | (hicolor << 13) | (shape << 14)
    a1 = (x & 0x1FF) | (size << 14)
    a1 |= ((affsel & 0x1F) << 9) if affine else ((hflip << 12) | (vflip << 13))
    a2 = (tileno & 0x3FF) | (prio << 10) | ((palno & 0xF) << 12)
    wr16(oam, idx*8, a0)
    wr16(oam, idx*8+2, a1)
    wr16(oam, idx*8+4, a2)

def aff(oam, g, pa, pb, pc, pd):
    for k, v in enumerate((pa, pb, pc, pd)):
        wr16(oam, g*32 + k*8 + 6, v & 0xFFFF)

OAM = new_oam()
obj(OAM, 0, 30, 40, 0, 2, 80, prio=1, palno=3)
obj(OAM, 1, 90, 60, 0, 3, 200, prio=0, palno=7, hicolor=1, hflip=1)
obj(OAM, 2, 170, 30, 1, 2, 300, prio=2, palno=2, vflip=1)
obj(OAM, 3, 60, 120, 0, 2, 111, prio=1, mode=1, palno=5)          # semi-transparent
obj(OAM, 4, 130, 100, 0, 2, 0x155, prio=0, mode=3, palno=9)       # bitmap
obj(OAM, 5, 200, 140, 0, 2, 400, prio=1, palno=4, affine=1, dbl=1, affsel=2)
obj(OAM, 6, 20, 150, 0, 1, 64, prio=0, mode=2)                    # obj window
obj(OAM, 7, 490, 80, 0, 2, 128, prio=3, palno=1)                  # left clip
aff(OAM, 2, 0x0B5, -0x0B5 & 0xFFFF, 0x0B5, 0x0B5)

frames = []
# frame 0: mode 0, four text BGs, windows, alpha blend, objs
frames.append(regs(
    mode=0, bgextpal=1, objextpal=1, obj1d=1, objbound=1, bmp1d=1,
    bg0chr=1, bg0scr=2, bg0size=0, bg0sx=13, bg0sy=200, bg0prio=3,
    bg1chr=3, bg1scr=9, bg1size=1, bg1sx=500, bg1sy=7, bg1prio=2, bg1hicol=1, bg1slot=1,
    bg2chr=5, bg2scr=17, bg2size=2, bg2sx=88, bg2sy=300, bg2prio=1, bg2hicol=1,
    bg3chr=7, bg3scr=25, bg3size=3, bg3sx=123, bg3sy=250, bg3prio=0,
    win0=1, w0x1=40, w0x2=180, w0y1=20, w0y2=150, en_win0=0x35, en_winout=0x3F,
    winobj=1, en_winobj=0x1B,
    bldeff=1, bld1st=0x04, bld2nd=0x0A, eva=9, evb=7))
# frame 1: mode 5, extended tile + direct bitmap, brightness, win1 wrap
frames.append(regs(
    mode=5, bgextpal=1, screenbase=1, charbase=1,
    bg0chr=2, bg0scr=4, bg0size=1, bg0sx=77, bg0sy=400, bg0prio=1, bg0hicol=1, bg0slot=1,
    bg1chr=4, bg1scr=6, bg1size=0, bg1sx=3, bg1sy=9, bg1prio=2,
    bg2chr=0, bg2scr=8, bg2size=1, bg2prio=0, bg2slot=1,      # ext variant 0, wrap
    bg2dx=0x0C0, bg2dy=0x30, bg2dmx=-0x20 & 0xFFFF, bg2dmy=0xE0, bg2refx=0x5000, bg2refy=(-0x2000) & 0xFFFFFFF,
    bg3chr=1, bg3scr=20, bg3size=2, bg3prio=3, bg3hicol=1,    # ext variant 2 (chr odd)
    bg3dx=0x140, bg3dy=-0x40 & 0xFFFF, bg3dmy=0x100, bg3refx=0x3000, bg3refy=0x8000,
    win1=1, w1x1=200, w1x2=60, w1y1=100, w1y2=30, en_win1=0x17, en_winout=0x2F,
    bldeff=2, bld1st=0x3F, bldy=6))
# frame 2: mode 2, double affine with per-line stepping, mosaic, no windows
frames.append(regs(
    mode=2, objextpal=1,
    bg0prio=0, bg0chr=1, bg0scr=1, bg0sx=45, bg0sy=100,
    bg1prio=1, bg1chr=2, bg1scr=3, bg1size=3, bg1sx=300, bg1sy=411, bg1hicol=1,
    bg2chr=3, bg2scr=12, bg2size=2, bg2prio=2, bg2slot=1, bg2mos=1,
    bg2dx=0x0F8, bg2dy=0x08, bg2dmx=0x04, bg2dmy=0x0FC, bg2refx=0x2000, bg2refy=0x1000,
    bg3chr=6, bg3scr=30, bg3size=1, bg3prio=3,
    bg3dx=0x80, bg3dy=0x40, bg3dmx=-0x10 & 0xFFFF, bg3dmy=0x120,
    bg3refx=(-0x3000) & 0xFFFFFFF, bg3refy=0x6000,
    mos_bgh=2, mos_bgv=3, ena=[1,1,1,1,1]))

def whex(f, v):
    f.write(f"{v & 0xFFFFFFFF:08x}\n")

def dump(fname, mem):
    with open(fname, "w") as f:
        for i in range(0, len(mem), 4):
            whex(f, int.from_bytes(mem[i:i+4], "little"))

dump("gpu2d_bgvram.hex", BGVRAM)
dump("gpu2d_objvram.hex", OBJVRAM)
dump("gpu2d_bgep.hex", BGEP)
dump("gpu2d_objep.hex", OBJEP)
dump("gpu2d_pal.hex", PAL)
dump("gpu2d_oam.hex", OAM)

with open("gpu2d_frames.hex", "w") as f:
    whex(f, len(frames))
    for r in frames:
        for w in reg_words(r):
            whex(f, w)
        fb = render_frame(r, OAM)
        for line in fb:
            for p in line:
                whex(f, p)

print(f"{len(frames)} frames")
