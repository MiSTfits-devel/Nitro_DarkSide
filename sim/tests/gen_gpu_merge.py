#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Golden-model generator for the NDS merge-stage tests (tb_gpu_merge).
#
# Emits gpu_merge_vectors.hex (generated, not checked in): a case-count
# word, then per case 16 header words + 256 words per plane in order
# bg0, bg1, bg2, bg3 (16 bit, bit15 transparent), obj (24 bit: [15:0]
# color/transparent, [17:16] prio, [18] semi, [19] bitmap, [23:20] bitmap
# alpha), objwnd (1 bit), expected (15 bit).
#
# The golden merge implements the donor's hardware-verified GBA semantics
# (window select, priority incl. OBJ-wins-ties, first/second target
# resolution, forced blending for semi-transparent OBJs, the
# effect>1-on-OBJ cancel rule, saturating blend math) plus the NDS deltas:
# bitmap sprites force blending with EVA=alpha+1 / EVB=16-EVA.

import random

rnd = random.Random(0x3E26E)

BG0, BG1, BG2, BG3, OBJ, BD = range(6)

def in_range(v, a, b):
    return (a <= b and a <= v < b) or (a > b and (v >= a or v < b))

def pick_top(ena, objprio, prios):
    cand = list(ena)  # bits BG0..BG3, OBJ, BD(always)
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

def merge_line(cfg, bg, obj, objwnd):
    y = cfg["ypos"]
    out = []
    prios = cfg["prios"]
    eva = min(cfg["eva"], 16)
    evb = min(cfg["evb"], 16)
    bldy = min(cfg["bldy"], 16)
    anywin = cfg["win0_on"] or cfg["win1_on"] or cfg["winobj_on"]
    for x in range(256):
        colors = [bg[i][x] & 0x7FFF for i in range(4)]
        transp = [(bg[i][x] >> 15) & 1 for i in range(4)]
        o = obj[x]
        ocol, otr = o & 0x7FFF, (o >> 15) & 1
        oprio, osemi, obmp, obalpha = (o >> 16) & 3, (o >> 18) & 1, (o >> 19) & 1, (o >> 20) & 0xF

        special_en = 1
        mask = 0x1F
        if anywin:
            if cfg["win0_on"] and in_range(y, cfg["w0y1"], cfg["w0y2"]) and in_range(x, cfg["w0x1"], cfg["w0x2"]):
                sel = cfg["en_win0"]
            elif cfg["win1_on"] and in_range(y, cfg["w1y1"], cfg["w1y2"]) and in_range(x, cfg["w1x1"], cfg["w1x2"]):
                sel = cfg["en_win1"]
            elif cfg["winobj_on"] and objwnd[x]:
                sel = cfg["en_winobj"]
            else:
                sel = cfg["en_winout"]
            special_en = (sel >> 5) & 1
            mask = sel & 0x1F

        ena = [0] * 6
        for i in range(4):
            ena[i] = cfg["ena"][i] and not transp[i] and ((mask >> i) & 1)
        ena[OBJ] = cfg["ena"][4] and not otr and ((mask >> 4) & 1)
        ena[BD] = 1

        top = pick_top(ena, oprio, prios)

        force = (top == OBJ) and (osemi or obmp)
        first = top if (((cfg["first"] >> top) & 1) or force) else None

        sec_ena = list(ena)
        if first is not None:
            sec_ena[first] = 0
        sec = pick_top(sec_ena, oprio, prios)
        sec_masked = sec if ((cfg["second"] >> sec) & 1) else None

        def layercolor(lay):
            if lay == OBJ:
                return ocol
            if lay == BD:
                return cfg["backdrop"] & 0x7FFF
            return colors[lay]

        firstpixel = layercolor(first) if first is not None else cfg["backdrop"] & 0x7FFF
        secondpixel = layercolor(sec_masked) if sec_masked is not None else cfg["backdrop"] & 0x7FFF

        eff = cfg["effect"]
        apply = 0
        if special_en and eff > 0 and first is not None:
            apply = 1 if (eff != 1 or sec_masked is not None) else 0
        if (osemi or obmp) and first == OBJ and sec_masked is not None:
            eff = 1
            apply = 1
        if eff > 1 and first == OBJ and not ((cfg["first"] >> OBJ) & 1):
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
                    c = ch(firstpixel, sh)
                    res |= min(31, c + ((31 - c) * bldy) // 16) << sh
            else:
                for sh in (0, 5, 10):
                    c = ch(firstpixel, sh)
                    res |= max(0, c - (c * bldy) // 16) << sh
            out.append(res)
        else:
            out.append(layercolor(top))
    return out

def rnd_layer(p_transp=0.4):
    return [(rnd.getrandbits(15) | 0x8000) if rnd.random() < p_transp else rnd.getrandbits(15)
            for _ in range(256)]

def rnd_obj(p_transp=0.4, p_semi=0.0, p_bmp=0.0):
    o = []
    for _ in range(256):
        v = rnd.getrandbits(15)
        if rnd.random() < p_transp:
            v |= 0x8000
        v |= rnd.getrandbits(2) << 16
        r = rnd.random()
        if r < p_semi:
            v |= 1 << 18
        elif r < p_semi + p_bmp:
            v |= 1 << 19
            v |= rnd.randrange(16) << 20
        o.append(v)
    return o

def case(**kw):
    c = dict(ypos=rnd.randrange(192),
             win0_on=0, win1_on=0, winobj_on=0,
             w0x1=0, w0x2=0, w0y1=0, w0y2=0,
             w1x1=0, w1x2=0, w1y1=0, w1y2=0,
             en_win0=0x3F, en_win1=0x3F, en_winobj=0x3F, en_winout=0x3F,
             effect=0, first=0, second=0,
             prios=[rnd.randrange(4) for _ in range(4)],
             eva=rnd.randrange(0, 21), evb=rnd.randrange(0, 21), bldy=rnd.randrange(0, 21),
             ena=[1, 1, 1, 1, 1],
             backdrop=rnd.getrandbits(15))
    c.update(kw)
    return c

cases = []
# 0: plain priorities, incl. ties (obj wins ties vs BG, lower BG index wins)
cases.append(case(prios=[1, 1, 2, 2]))
# 1: alpha blend, BG1 first over BG2 second
cases.append(case(effect=1, first=1 << BG1, second=1 << BG2, prios=[3, 0, 1, 2]))
# 2: alpha with random target masks (second sometimes missing)
cases.append(case(effect=1, first=rnd.getrandbits(6), second=rnd.getrandbits(6)))
# 3: brighten; OBJ not a 1st target -> cancel rule when OBJ on top
cases.append(case(effect=2, first=(1 << BG0) | (1 << BG2) | (1 << BD), bldy=7))
# 4: darken everything
cases.append(case(effect=3, first=0x3F, bldy=12))
# 5: semi-transparent OBJs force blending
cases.append(case(second=(1 << BG1) | (1 << BG3) | (1 << BD), prios=[2, 3, 1, 3]))
# 6: bitmap OBJs blend with their own alpha
cases.append(case(second=0x0F, prios=[0, 1, 2, 3]))
# 7: WIN0 rectangle, effects disabled inside, some layers masked
cases.append(case(effect=2, first=0x3F, win0_on=1,
                  w0x1=40, w0x2=180, w0y1=10, w0y2=150, ypos=100,
                  en_win0=0x15, en_winout=0x3F, bldy=9))
# 8: WIN0+WIN1 overlap with X wraparound on WIN1
cases.append(case(win0_on=1, win1_on=1,
                  w0x1=100, w0x2=60, w0y1=0, w0y2=192,        # wraps
                  w1x1=30, w1x2=220, w1y1=50, w1y2=160, ypos=90,
                  en_win0=0x27, en_win1=0x1A, en_winout=0x0D))
# 9: OBJ window
cases.append(case(winobj_on=1, en_winobj=0x13, en_winout=0x2F,
                  effect=1, first=1 << BG0, second=(1 << BG1) | (1 << BD), prios=[0, 1, 2, 3]))
# 10: chaos - all windows + random masks + alpha + semis + bitmaps
cases.append(case(win0_on=1, win1_on=1, winobj_on=1,
                  w0x1=rnd.randrange(256), w0x2=rnd.randrange(256),
                  w0y1=rnd.randrange(200), w0y2=rnd.randrange(200),
                  w1x1=rnd.randrange(256), w1x2=rnd.randrange(256),
                  w1y1=rnd.randrange(200), w1y2=rnd.randrange(200),
                  en_win0=rnd.getrandbits(6), en_win1=rnd.getrandbits(6),
                  en_winobj=rnd.getrandbits(6), en_winout=rnd.getrandbits(6),
                  effect=1, first=rnd.getrandbits(6), second=rnd.getrandbits(6)))
# 11: BD as blend second target, one layer only
cases.append(case(effect=1, first=1 << BG2, second=1 << BD,
                  ena=[0, 0, 1, 0, 0], prios=[0, 0, 3, 0]))
# 12: layers disabled via DISPCNT
cases.append(case(ena=[1, 0, 1, 0, 1], prios=[2, 0, 1, 3]))

def whex(f, v):
    f.write(f"{v & 0xFFFFFFFF:08x}\n")

with open("gpu_merge_vectors.hex", "w") as f:
    whex(f, len(cases))
    for cfg in cases:
        semi = 0.15 if cfg in cases[5:7] or cfg is cases[10] else 0.0
        bmp  = 0.25 if cfg is cases[6] or cfg is cases[10] else 0.0
        bgp  = [rnd_layer() for _ in range(4)]
        objp = rnd_obj(p_semi=semi, p_bmp=bmp)
        wndp = [rnd.random() < 0.3 for _ in range(256)]
        exp  = merge_line(cfg, bgp, objp, wndp)

        hdr = [cfg["ypos"],
               cfg["win0_on"] | (cfg["win1_on"] << 1) | (cfg["winobj_on"] << 2),
               cfg["w0x1"] | (cfg["w0x2"] << 8) | (cfg["w0y1"] << 16) | (cfg["w0y2"] << 24),
               cfg["w1x1"] | (cfg["w1x2"] << 8) | (cfg["w1y1"] << 16) | (cfg["w1y2"] << 24),
               cfg["en_win0"] | (cfg["en_win1"] << 6) | (cfg["en_winobj"] << 12) | (cfg["en_winout"] << 18),
               cfg["effect"] | (cfg["first"] << 2) | (cfg["second"] << 8),
               sum(cfg["prios"][i] << (2 * i) for i in range(4)),
               cfg["eva"] | (cfg["evb"] << 5) | (cfg["bldy"] << 10),
               sum(cfg["ena"][i] << i for i in range(5)),
               cfg["backdrop"],
               0, 0, 0, 0, 0, 0]
        for w in hdr:
            whex(f, w)
        for plane in bgp:
            for v in plane:
                whex(f, v)
        for v in objp:
            whex(f, v)
        for v in wndp:
            whex(f, int(v))
        for v in exp:
            whex(f, v)

print(f"{len(cases)} cases")
