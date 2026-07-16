#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Full-frame golden for the engine-A orchestrator (tb_gpu2d_frame).
#
# Emits (not checked in - regenerate before running):
#   gpu2d_banks.hex    all 9 VRAM banks concatenated as words, fixed order
#                      A,B,C,D (32768 w each), E (16384), F/G (4096),
#                      H (8192), I (4096) - 167936 words
#   gpu2d_vectors.hex  case count; per case: reg-write count, (offset,value)
#                      pairs, 256 palette words (BG then OBJ), 256 OAM words,
#                      49152 expected frame words (15-bit color)
#
# The TB maps banks with the fixed VRAMCNT below (A=BG 0x00000, D=BG 0x20000,
# B=OBJ, E=BG ext pal, F=OBJ ext pal; C/G/H/I off) and this model reads
# through the same mapping - unmapped renderer space reads as 0.
#
# The line renderers are the validated per-drawer goldens (gen_gpu_bg,
# gen_gpu_obj, gen_gpu_merge) re-hosted onto register-level state: base
# addresses from DISPCNT+BGxCNT, ext-pal slots per BG, the NDS mode table,
# vblank refpoint reload + per-line dmx/dmy stepping. Mosaic stays off in
# these frames (drawer-level tests cover it). 3D-as-BG0 renders transparent.

import random

rnd = random.Random(0x2D2D)

# ---------------------------------------------------------------- banks

BANKSIZES = [0x20000, 0x20000, 0x20000, 0x20000, 0x10000, 0x4000, 0x4000, 0x8000, 0x4000]
BANKS = [bytearray(rnd.getrandbits(8) for _ in range(sz)) for sz in BANKSIZES]
# zero G/H/I (unmapped in the TB config; keeps the hex honest)
for b in (6, 7, 8):
    BANKS[b] = bytearray(BANKSIZES[b])
# transparency: sprinkle zero bytes + some fully transparent 4bpp tiles
for b in (0, 1, 3):
    for i in range(0, BANKSIZES[b], 613):
        BANKS[b][i] = 0
for t in range(0x40, 0x48):                    # OBJ tiles 0x40..0x47 empty
    BANKS[1][t*32 : t*32 + 32] = bytes(32)

# fixed test VRAMCNT: A=BG ofs0, B=OBJ ofs0, D=BG ofs1, E=BG extpal, F=OBJ extpal
def bg_hits(a):
    h = []
    if a < 0x20000:
        h.append((0, a))
    elif a < 0x40000:
        h.append((3, a & 0x1FFFF))
    return h

def obj_hits(a):
    return [(1, a)] if a < 0x20000 else []

def rd_or(hits):
    v = 0
    for b, off in hits:
        v |= BANKS[b][off] | (BANKS[b][off+1] << 8) if False else 0
    return v

def bg8(a):
    a &= 0x7FFFF
    v = 0
    for b, off in bg_hits(a):
        v |= BANKS[b][off]
    return v

def bg16(a):
    return bg8(a) | (bg8(a + 1) << 8)

def obj8(a):
    a &= 0x3FFFF
    v = 0
    for b, off in obj_hits(a):
        v |= BANKS[b][off]
    return v

def obj16(a):
    return obj8(a) | (obj8(a + 1) << 8)

def bgep16(a):                                # bank E covers all 32 KB
    a &= 0x7FFF
    return (BANKS[4][a] | (BANKS[4][a+1] << 8)) & 0x7FFF

def objep16(a):                               # bank F lower 8 KB
    a &= 0x1FFF
    return (BANKS[5][a] | (BANKS[5][a+1] << 8)) & 0x7FFF

def s28(v):
    v &= (1 << 28) - 1
    return v - (1 << 28) if v & (1 << 27) else v

def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

# ---------------------------------------------------------------- BG lines

def pal16(pal, idx):                          # pal: 512-byte engine half
    return (pal[(idx*2) & 0x1FF] | (pal[(idx*2+1) & 0x1FF] << 8)) & 0x7FFF

def render_text(c, y, palbg):
    out = [0x8000] * 256
    size = c["size"]
    sxmod = 512 if size in (1, 3) else 256
    symod = 512 if size in (2, 3) else 256
    y_s = y + c["scrolly"]
    y_mod = y_s % symod
    offset_y = ((y_s % 256) // 8) * 32
    for x in range(256):
        xs = (x + c["scrollx"]) % sxmod
        ti = 0
        if xs >= 256 or (y_mod >= 256 and size == 2):
            ti += 1024
        if y_mod >= 256 and size == 3:
            ti += 2048
        tile = bg16(c["mapbase"] + (ti + offset_y + ((xs & 255) >> 3)) * 2)
        tno   = tile & 0x3FF
        hf    = (tile >> 10) & 1
        vf    = (tile >> 11) & 1
        palno = (tile >> 12) & 0xF
        px = 7 - (xs & 7) if hf else xs & 7
        py = 7 - (y_mod & 7) if vf else y_mod & 7
        if c["hicolor"]:
            cc = bg8(c["tilebase"] + tno * 64 + py * 8 + px)
            if cc == 0:
                continue
            out[x] = (bgep16((c["slot"] << 13) | (palno << 9) | (cc << 1))
                      if c["extpal"] else pal16(palbg, cc))
        else:
            b = bg8(c["tilebase"] + tno * 32 + py * 4 + px // 2)
            nib = (b >> (4 * (px & 1))) & 0xF
            if nib == 0:
                continue
            out[x] = pal16(palbg, palno * 16 + nib)
    return out

def render_affine(c, y, palbg, rx, ry):
    out = [0x8000] * 256
    size = c["size"]
    w = 128 << size
    dx, dy = sxt16(c["dx"]), sxt16(c["dy"])
    for x in range(256):
        xxx, yyy = rx >> 8, ry >> 8
        rx, ry = s28(rx + dx), s28(ry + dy)
        if c["wrap"]:
            xxx %= w
            yyy %= w
        elif xxx < 0 or yyy < 0 or xxx >= w or yyy >= w:
            continue
        tno = bg8(c["mapbase"] + (xxx >> 3) + (yyy >> 3) * (w >> 3))
        cc = bg8(c["tilebase"] + tno * 64 + (yyy & 7) * 8 + (xxx & 7))
        if cc != 0:
            out[x] = pal16(palbg, cc)
    return out

def render_extended(c, y, palbg, rx, ry):
    out = [0x8000] * 256
    size = c["size"]
    var = c["variant"]
    if var == 0:
        w, h = 128 << size, 128 << size
    else:
        w, h = [(128, 128), (256, 256), (512, 256), (512, 512)][size]
    dx, dy = sxt16(c["dx"]), sxt16(c["dy"])
    for x in range(256):
        xxx, yyy = rx >> 8, ry >> 8
        rx, ry = s28(rx + dx), s28(ry + dy)
        if c["wrap"]:
            xxx %= w
            yyy %= h
        elif xxx < 0 or yyy < 0 or xxx >= w or yyy >= h:
            continue
        if var == 0:
            tile = bg16(c["mapbase"] + ((xxx >> 3) + (yyy >> 3) * (w >> 3)) * 2)
            tno   = tile & 0x3FF
            palno = (tile >> 12) & 0xF
            px = (7 - (xxx & 7)) if (tile >> 10) & 1 else (xxx & 7)
            py = (7 - (yyy & 7)) if (tile >> 11) & 1 else (yyy & 7)
            cc = bg8(c["tilebase"] + tno * 64 + py * 8 + px)
            if cc == 0:
                continue
            out[x] = (bgep16((c["slot"] << 13) | (palno << 9) | (cc << 1))
                      if c["extpal"] else pal16(palbg, cc))
        elif var == 1:
            cc = bg8(c["mapbase"] + yyy * w + xxx)
            if cc != 0:
                out[x] = pal16(palbg, cc)
        else:
            v = bg16(c["mapbase"] + (yyy * w + xxx) * 2)
            if v & 0x8000:
                out[x] = v & 0x7FFF
    return out

# ---------------------------------------------------------------- OBJ line

SIZES = [
    [( 8,  8), (16, 16), (32, 32), (64, 64)],
    [(16,  8), (32,  8), (32, 16), (64, 32)],
    [( 8, 16), ( 8, 32), (16, 32), (32, 64)],
]

def rd16m(mem, a):
    return mem[a] | (mem[a+1] << 8)

def sxt16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def render_obj_line(d, y, oam, palobj):
    col  = [0x8000] * 256
    sett = [0] * 256
    ownd = [0] * 256
    slot_transp = [True] * 256
    slot_prio   = [3] * 256
    for i in range(128):
        a0 = rd16m(oam, i*8)
        a1 = rd16m(oam, i*8 + 2)
        a2 = rd16m(oam, i*8 + 4)
        affine = (a0 >> 8) & 1
        if not affine and ((a0 >> 9) & 1):
            continue
        shape = (a0 >> 14) & 3
        if shape == 3:
            continue
        mode    = (a0 >> 10) & 3
        hicolor = (a0 >> 13) & 1
        size    = (a1 >> 14) & 3
        w, h = SIZES[shape][size]
        dbl = affine and ((a0 >> 9) & 1)
        fw, fh = (2*w, 2*h) if dbl else (w, h)
        ybase = a0 & 0xFF
        posy = ybase - 0x100 if ybase > 0x100 - fh else ybase
        ty = y - posy
        if ty < 0 or ty >= fh:
            continue
        isbmp = (mode == 3)
        if isbmp and d["bmp1d"] and d["bmp2dwide"]:
            continue
        alpha = (a2 >> 12) & 0xF
        if isbmp and alpha == 0:
            continue
        tileno = a2 & 0x3FF
        prio   = (a2 >> 10) & 3
        palno  = (a2 >> 12) & 0xF
        x9 = a1 & 0x1FF
        posx = x9 - 0x200 if x9 > 0x100 else x9
        hflip = (not affine) and bool((a1 >> 12) & 1)
        vflip = (not affine) and bool((a1 >> 13) & 1)

        if isbmp:
            if d["bmp1d"]:
                base = tileno << (7 + d["bmpbound"])
                stride = w * 2
            elif d["bmp2dwide"]:
                base = ((tileno & 0x1F) << 4) + ((tileno & 0x3E0) << 7)
                stride = 512
            else:
                base = ((tileno & 0x0F) << 4) + ((tileno & 0x3F0) << 7)
                stride = 256
        else:
            if d["obj1d"]:
                base = tileno * (32 << d["objbound"])
                stride = (w // 8) * (64 if hicolor else 32)
            else:
                base = tileno * 32
                stride = 1024

        if affine:
            g = (a1 >> 9) & 0x1F
            pa, pb, pc, pd_ = (sxt16(rd16m(oam, g*32 + k*8 + 6)) for k in range(4))
            rx = (w << 7) - (fw // 2) * pa - (fh // 2) * pb + ty * pb
            ry = (h << 7) - (fw // 2) * pc - (fh // 2) * pd_ + ty * pd_

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
                v = obj16(base + yyy * stride + xxx * 2)
                transparent = not (v & 0x8000)
                pixcol = v & 0x7FFF
            elif hicolor:
                cc = obj8(base + (yyy // 8) * stride + (yyy % 8) * 8
                          + (xxx // 8) * 64 + (xxx % 8))
                transparent = (cc == 0)
                pixcol = (objep16((palno * 256 + cc) * 2) if d["objextpal"]
                          else pal16(palobj, cc))
            else:
                b = obj8(base + (yyy // 8) * stride + (yyy % 8) * 4
                         + (xxx // 8) * 32 + (xxx % 8) // 2)
                nib = (b >> (4 * (xxx & 1))) & 0xF
                transparent = (nib == 0)
                pixcol = pal16(palobj, palno * 16 + nib)

            if mode == 2:
                if not transparent:
                    ownd[target] = 1
                continue
            if slot_transp[target] or prio < slot_prio[target]:
                if isbmp:
                    s = (alpha << 4) | 0x8 | prio
                else:
                    s = (0x4 if mode == 1 else 0) | prio
                sett[target] = s
                slot_prio[target] = prio
                if not transparent:
                    col[target] = pixcol
                    slot_transp[target] = False
    return col, sett, ownd

# ---------------------------------------------------------------- merge

def in_range(v, a, b):
    return (a <= v < b) if a <= b else (v >= a or v < b)

def pick_top(ena, objprio, prios):
    best, bestp = 5, 4
    for lay in (3, 2, 1, 0):
        if ena[lay] and prios[lay] <= bestp:
            best, bestp = lay, prios[lay]
    if ena[4] and objprio <= bestp:
        best = 4
    return best

OBJ, BD = 4, 5

def merge_line(m, y, bg, obj, objwnd):
    out = []
    prios = m["prios"]
    eva, evb, bldy = min(m["eva"], 16), min(m["evb"], 16), min(m["bldy"], 16)
    anywin = m["win0_on"] or m["win1_on"] or m["winobj_on"]
    for x in range(256):
        colors = [bg[i][x] & 0x7FFF for i in range(4)]
        transp = [(bg[i][x] >> 15) & 1 for i in range(4)]
        o = obj[x]
        ocol, otr = o & 0x7FFF, (o >> 15) & 1
        oprio, osemi, obmp, obalpha = (o >> 16) & 3, (o >> 18) & 1, (o >> 19) & 1, (o >> 20) & 0xF
        special_en = 1
        mask = 0x1F
        if anywin:
            if m["win0_on"] and in_range(y, m["w0y1"], m["w0y2"]) and in_range(x, m["w0x1"], m["w0x2"]):
                sel = m["en_win0"]
            elif m["win1_on"] and in_range(y, m["w1y1"], m["w1y2"]) and in_range(x, m["w1x1"], m["w1x2"]):
                sel = m["en_win1"]
            elif m["winobj_on"] and objwnd[x]:
                sel = m["en_winobj"]
            else:
                sel = m["en_winout"]
            special_en = (sel >> 5) & 1
            mask = sel & 0x1F
        ena = [0] * 6
        for i in range(4):
            ena[i] = m["ena"][i] and not transp[i] and ((mask >> i) & 1)
        ena[OBJ] = m["ena"][4] and not otr and ((mask >> 4) & 1)
        ena[BD] = 1
        top = pick_top(ena, oprio, prios)
        force = (top == OBJ) and (osemi or obmp)
        first = top if (((m["first"] >> top) & 1) or force) else None
        sec_ena = list(ena)
        if first is not None:
            sec_ena[first] = 0
        sec = pick_top(sec_ena, oprio, prios)
        sec_masked = sec if ((m["second"] >> sec) & 1) else None

        def layercolor(lay):
            if lay == OBJ:
                return ocol
            if lay == BD:
                return m["backdrop"] & 0x7FFF
            return colors[lay]

        firstpixel = layercolor(first) if first is not None else m["backdrop"] & 0x7FFF
        secondpixel = layercolor(sec_masked) if sec_masked is not None else m["backdrop"] & 0x7FFF
        eff = m["effect"]
        apply = 0
        if special_en and eff > 0 and first is not None:
            apply = 1 if (eff != 1 or sec_masked is not None) else 0
        if (osemi or obmp) and first == OBJ and sec_masked is not None:
            eff = 1
            apply = 1
        if eff > 1 and first == OBJ and not ((m["first"] >> OBJ) & 1):
            apply = 0
        if apply:
            def ch(v, sh):
                return (v >> sh) & 31
            res = 0
            if eff == 1:
                if obmp and first == OBJ:
                    ea, eb = obalpha + 1, 16 - (obalpha + 1)
                else:
                    ea, eb = eva, evb
                for sh in (0, 5, 10):
                    res |= min(31, (ch(firstpixel, sh) * ea + ch(secondpixel, sh) * eb) // 16) << sh
            elif eff == 2:
                for sh in (0, 5, 10):
                    cch = ch(firstpixel, sh)
                    res |= min(31, cch + ((31 - cch) * bldy) // 16) << sh
            else:
                for sh in (0, 5, 10):
                    cch = ch(firstpixel, sh)
                    res |= max(0, cch - (cch * bldy) // 16) << sh
            out.append(res)
        else:
            out.append(layercolor(top))
    return out

# ---------------------------------------------------------------- frame

BGTYPE = {0: (1, 1, 1, 1), 1: (1, 1, 1, 2), 2: (1, 1, 2, 2),
          3: (1, 1, 1, 3), 4: (1, 1, 2, 3), 5: (1, 1, 3, 3), 6: (0, 0, 0, 0)}

def render_frame(case, palbg, palobj, oam):
    d = case["dispcnt"]
    bgs = case["bgs"]
    bgtype = list(BGTYPE[d["mode"]])
    if d["bg0_3d"]:
        bgtype[0] = 0
    refs = {i: [s28(bgs[i]["refx"]), s28(bgs[i]["refy"])] for i in (2, 3)}
    fb = []
    for y in range(192):
        bglines = []
        for i in range(4):
            c = bgs[i]
            t = bgtype[i]
            line = [0x8000] * 256
            if t == 1:
                line = render_text(c, y, palbg)
            elif t == 2:
                line = render_affine(c, y, palbg, refs[i][0], refs[i][1])
            elif t == 3:
                line = render_extended(c, y, palbg, refs[i][0], refs[i][1])
            bglines.append(line)
        ocol, osett, ownd = ([0x8000]*256, [0]*256, [0]*256)
        ocol, osett, ownd = render_obj_line(d, y, oam, palobj)
        objline = [(osett[x] << 16) | ocol[x] for x in range(256)]
        m = dict(case["merge"])
        m["backdrop"] = pal16(palbg, 0)
        fb.extend(merge_line(m, y, bglines, objline, ownd))
        for i in (2, 3):
            refs[i][0] = s28(refs[i][0] + sxt16(bgs[i]["dmx"]))
            refs[i][1] = s28(refs[i][1] + sxt16(bgs[i]["dmy"]))
    return fb

# ---------------------------------------------------------------- reg pack

def pack_regs(case):
    d = case["dispcnt"]
    bgs = case["bgs"]
    m = case["merge"]
    regs = []
    v = (d["mode"] | (d["bg0_3d"] << 3) | (d["obj1d"] << 4) | (d["bmp2dwide"] << 5)
         | (d["bmp1d"] << 6) | (0 << 7)
         | (m["ena"][0] << 8) | (m["ena"][1] << 9) | (m["ena"][2] << 10)
         | (m["ena"][3] << 11) | (m["ena"][4] << 12)
         | (m["win0_on"] << 13) | (m["win1_on"] << 14) | (m["winobj_on"] << 15)
         | (1 << 16)
         | (d["objbound"] << 20) | (d["bmpbound"] << 22)
         | (d["charbase"] << 24) | (d["screenbase"] << 27)
         | (d["bgextpal"] << 30) | (d["objextpal"] << 31))
    regs.append((0x000, v))
    for pair, off in ((0, 0x008), (2, 0x00C)):
        w = 0
        for k in (0, 1):
            c = bgs[pair + k]
            b = (m["prios"][pair + k] | (c["cntchar"] << 2) | (0 << 6)
                 | (c["hicolor"] << 7) | (c["cntscreen"] << 8)
                 | (c["slotwrap"] << 13) | (c["size"] << 14))
            w |= b << (16 * k)
        regs.append((off, w))
    for i in range(4):
        regs.append((0x010 + 4*i, bgs[i]["scrollx"] | (bgs[i]["scrolly"] << 16)))
    for i, base in ((2, 0x020), (3, 0x030)):
        c = bgs[i]
        regs.append((base + 0x0, (c["dx"] & 0xFFFF) | ((c["dmx"] & 0xFFFF) << 16)))
        regs.append((base + 0x4, (c["dy"] & 0xFFFF) | ((c["dmy"] & 0xFFFF) << 16)))
        regs.append((base + 0x8, c["refx"] & 0xFFFFFFF))
        regs.append((base + 0xC, c["refy"] & 0xFFFFFFF))
    regs.append((0x040, (m["w0x2"] | (m["w0x1"] << 8) | (m["w1x2"] << 16) | (m["w1x1"] << 24))))
    regs.append((0x044, (m["w0y2"] | (m["w0y1"] << 8) | (m["w1y2"] << 16) | (m["w1y1"] << 24))))
    regs.append((0x048, (m["en_win0"] | (m["en_win1"] << 8) | (m["en_winout"] << 16) | (m["en_winobj"] << 24))))
    regs.append((0x04C, 0))
    regs.append((0x050, (m["first"] | (m["effect"] << 6) | (m["second"] << 8)
                         | (m["eva"] << 16) | (m["evb"] << 24))))
    regs.append((0x054, m["bldy"]))
    return regs

# ---------------------------------------------------------------- cases

def dispcnt(mode, **kw):
    d = dict(mode=mode, bg0_3d=0, obj1d=1, bmp2dwide=0, bmp1d=1, objbound=0,
             bmpbound=0, charbase=0, screenbase=0, bgextpal=0, objextpal=0)
    d.update(kw)
    return d

def bgcfg(cntchar=0, cntscreen=0, hicolor=0, size=0, slotwrap=0, scrollx=0,
          scrolly=0, dx=0x100, dmx=0, dy=0, dmy=0x100, refx=0, refy=0,
          extpal=0, slot=0, variant=0, d=None, bgno=0):
    """returns the golden-side view; mapbase/tilebase resolved from d"""
    c = dict(cntchar=cntchar, cntscreen=cntscreen, hicolor=hicolor, size=size,
             slotwrap=slotwrap, scrollx=scrollx, scrolly=scrolly,
             dx=dx, dmx=dmx, dy=dy, dmy=dmy, refx=refx, refy=refy,
             extpal=extpal, slot=slot, variant=variant, wrap=slotwrap)
    return c

def resolve(case):
    """derive golden bases/slots exactly like the RTL derived-config block"""
    d = case["dispcnt"]
    for i, c in enumerate(case["bgs"]):
        c["mapbase"]  = (d["screenbase"] * 65536 + c["cntscreen"] * 2048) & 0x7FFFF
        c["tilebase"] = (d["charbase"] * 65536 + c["cntchar"] * 16384) & 0x7FFFF
        c["extpal"]   = d["bgextpal"]
        if i == 0:
            c["slot"] = 2 if c["slotwrap"] else 0
        elif i == 1:
            c["slot"] = 3 if c["slotwrap"] else 1
        else:
            c["slot"] = i
        # extended variant + base
        if c["hicolor"] == 0:
            c["variant"] = 0
        elif c["cntchar"] & 1 == 0:
            c["variant"] = 1
        else:
            c["variant"] = 2
        if c["hicolor"]:
            c["mapbase_ext"] = (c["cntscreen"] * 16384) & 0x7FFFF
        else:
            c["mapbase_ext"] = c["mapbase"]
    return case

def mergecfg(**kw):
    m = dict(prios=[0, 1, 2, 3], ena=[1, 1, 1, 1, 1], first=0, second=0,
             effect=0, eva=16, evb=0, bldy=0, win0_on=0, win1_on=0,
             winobj_on=0, w0x1=0, w0x2=0, w0y1=0, w0y2=0, w1x1=0, w1x2=0,
             w1y1=0, w1y2=0, en_win0=0x3F, en_win1=0x3F, en_winobj=0x3F,
             en_winout=0x3F)
    m.update(kw)
    return m

def make_pal():
    p = bytearray(rnd.getrandbits(8) for _ in range(1024))
    return p

def make_oam(d, nspr=24, bitmap_ok=True):
    oam = bytearray(1024)
    for i in range(128):
        oam[i*8 + 1] = 0x02
    def wr16(a, v):
        oam[a] = v & 0xFF
        oam[a+1] = (v >> 8) & 0xFF
    for k in range(nspr):
        i = rnd.randrange(128)
        shape = rnd.randrange(3)
        size = rnd.randrange(4)
        mode = rnd.choice([0, 0, 0, 1, 2] + ([3] if bitmap_ok else []))
        affine = rnd.random() < 0.25
        hicolor = rnd.getrandbits(1) if mode != 3 else 0
        a0 = (rnd.randrange(256) | (int(affine) << 8)
              | ((rnd.getrandbits(1) if affine else 0) << 9)
              | (mode << 10) | (hicolor << 13) | (shape << 14))
        a1 = rnd.randrange(512) | (size << 14)
        if affine:
            a1 |= rnd.randrange(4) << 9
        else:
            a1 |= rnd.getrandbits(2) << 12
        a2 = rnd.randrange(1024) | (rnd.randrange(4) << 10) | (rnd.randrange(16) << 12)
        wr16(i*8, a0)
        wr16(i*8 + 2, a1)
        wr16(i*8 + 4, a2)
    for g in range(4):
        pa = rnd.choice([0x100, 0x80, 0x180, 0xB5])
        pb = rnd.choice([0, 0x40, -0x55 & 0xFFFF])
        wr16(g*32 + 6, pa)
        wr16(g*32 + 14, pb)
        wr16(g*32 + 22, (-sxt16(pb)) & 0xFFFF)
        wr16(g*32 + 30, pa)
    return oam

cases = []

# 0: mode 0 - four text BGs (4bpp x2, 8bpp x2), scrolls, sprites, no effects
c = dict(
    dispcnt=dispcnt(0, objextpal=0),
    bgs=[bgcfg(cntchar=1, cntscreen=0, scrollx=13, scrolly=200),
         bgcfg(cntchar=2, cntscreen=1, size=1, scrollx=300, scrolly=77),
         bgcfg(cntchar=8, cntscreen=2, hicolor=1, size=2, scrollx=45, scrolly=511),
         bgcfg(cntchar=9, cntscreen=3, hicolor=1, size=3, scrollx=137, scrolly=250)],
    merge=mergecfg(prios=[3, 2, 1, 0]))
cases.append(c)

# 1: mode 2 - affine BG2/BG3 with rotation + wrap, win0, text BG0/1
c = dict(
    dispcnt=dispcnt(2),
    bgs=[bgcfg(cntchar=1, cntscreen=0),
         bgcfg(cntchar=2, cntscreen=1, scrollx=100),
         bgcfg(cntchar=10, cntscreen=4, size=1, refx=(-40 << 8) & 0xFFFFFFF,
               refy=300 << 8, dx=0x0B5, dmx=-0x0B5 & 0xFFFF, dy=0x0B5, dmy=0x0B5),
         bgcfg(cntchar=12, cntscreen=5, size=2, slotwrap=1, refx=0x123456,
               refy=(-0x23456) & 0xFFFFFFF, dx=-0x180 & 0xFFFF, dmx=0x20,
               dy=0x100, dmy=0xE0)],
    merge=mergecfg(prios=[0, 1, 2, 3], win0_on=1, w0x1=30, w0x2=180, w0y1=20,
                   w0y2=150, en_win0=0x3F, en_winout=0x1D))
cases.append(c)

# 2: mode 5 - extended bitmaps (direct + 256c), ext palettes, blending, objwnd
c = dict(
    dispcnt=dispcnt(5, bgextpal=1, objextpal=1),
    bgs=[bgcfg(cntchar=1, cntscreen=0, slotwrap=1),
         bgcfg(cntchar=2, cntscreen=1, hicolor=1),
         bgcfg(cntchar=1, cntscreen=9, hicolor=1, size=1, slotwrap=1,
               refx=30 << 8, refy=200 << 8, dx=0xB3, dmx=0x41, dy=-0x41 & 0xFFFF, dmy=0xB3),
         bgcfg(cntchar=0, cntscreen=10, hicolor=1, size=2, slotwrap=1,
               refx=(-300 << 8) & 0xFFFFFFF, refy=777 << 8, dx=0x1C5, dmx=0,
               dy=-0x8B & 0xFFFF, dmy=0x100)],
    merge=mergecfg(prios=[1, 3, 0, 2], effect=1, first=(1 << 2), second=(1 << 3) | (1 << 5),
                   eva=9, evb=7, winobj_on=1, en_winobj=0x37, en_winout=0x3F))
cases.append(c)

# 3: mode 4 - affine BG2 + extended 8bpp-tile BG3 w/ ext pal, brightness, windows
c = dict(
    dispcnt=dispcnt(4, bgextpal=1, screenbase=0, charbase=0),
    bgs=[bgcfg(cntchar=3, cntscreen=6, extpal=1),
         bgcfg(cntchar=4, cntscreen=7, hicolor=1, size=1, slotwrap=1),
         bgcfg(cntchar=10, cntscreen=8, size=0, refx=5 << 8, refy=10 << 8,
               dx=0x100, dmx=0, dy=0, dmy=0x100),
         bgcfg(cntchar=13, cntscreen=12, size=1, slotwrap=1, refx=0x654321,
               refy=(-0x1234 << 4) & 0xFFFFFFF, dx=-0x1D3 & 0xFFFF, dmx=0x11,
               dy=0xE7, dmy=-0x30 & 0xFFFF)],
    merge=mergecfg(prios=[2, 2, 1, 1], effect=2, first=0x3F, bldy=6,
                   win0_on=1, win1_on=1, w0x1=10, w0x2=120, w0y1=0, w0y2=100,
                   w1x1=100, w1x2=40, w1y1=80, w1y2=190,
                   en_win0=0x2F, en_win1=0x35, en_winout=0x18))
cases.append(c)

# ---------------------------------------------------------------- emit

def whex(f, v):
    f.write(f"{v & 0xFFFFFFFF:08x}\n")

with open("gpu2d_banks.hex", "w") as f:
    for b in range(9):
        mem = BANKS[b]
        for a in range(0, len(mem), 4):
            whex(f, mem[a] | (mem[a+1] << 8) | (mem[a+2] << 16) | (mem[a+3] << 24))

with open("gpu2d_vectors.hex", "w") as f:
    whex(f, len(cases))
    for case in cases:
        resolve(case)
        palraw = make_pal()
        oam = make_oam(case["dispcnt"])
        palbg, palobj = palraw[0:512], palraw[512:1024]
        # golden render (extended BGs use mapbase_ext)
        for i in (2, 3):
            if BGTYPE[case["dispcnt"]["mode"]][i] == 3:
                case["bgs"][i] = dict(case["bgs"][i], mapbase=case["bgs"][i]["mapbase_ext"])
        fb = render_frame(case, palbg, palobj, oam)
        regs = pack_regs(case)
        whex(f, len(regs))
        for off, v in regs:
            whex(f, off)
            whex(f, v)
        for a in range(0, 1024, 4):
            whex(f, palraw[a] | (palraw[a+1] << 8) | (palraw[a+2] << 16) | (palraw[a+3] << 24))
        for a in range(0, 1024, 4):
            whex(f, oam[a] | (oam[a+1] << 8) | (oam[a+2] << 16) | (oam[a+3] << 24))
        for p in fb:
            whex(f, p)

print(f"{len(cases)} frame cases")
