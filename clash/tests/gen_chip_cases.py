#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
"""Op scripts for the whole-chip gate (Nds.Gpu3D.Chip against a melonDS NDS
driven through ARM9 I/O, tools/gx3d_oracle/chip_oracle.cpp).

usage: gen_chip_cases.py KIND SEED SCRIPT_OUT VRAM_OUT

KIND is a directed kind (see DIRECTED), "random" (a multi-frame sequence of
realistic scenes with every feature drawn at random) or "fuzz" (random
command bytes, parameters, packed words and register writes).

A script is what a game does to the 3D engine, one op per line (the format
chip_oracle.cpp documents): ARM9 writes and reads (GX commands as packed
GXFIFO words or direct command-port writes, every register at 8/16/32-bit
widths), POWCNT1, BG0HOFS, VCOUNT and IF writes, and the display events
VBlank (V), render start (S), GetLine (L) and frame end (F).

Real-looking scenes: a perspective or orthographic projection, a camera,
lights and materials, textured and vertex-coloured models (cubes of quads,
spheres of triangle strips, quad-strip grids, triangle soups) placed with
the matrix stack, translucent models, shadow volumes, box/position/vector
tests, fog/edge/AA/toon/highlight/alpha-test/rear-plane frames, swaps with
every parameter.

The ARM9 bus stall is part of the input: the generator keeps the front end's
FIFO occupancy (PIPE, FIFO, stall queue, packer, the drain after every op,
swap pending) so it never issues an ARM9 op while the bus is held -- it lets
the display run (V S L F) until the engine has made room, as a halted ARM9
waits. chip_oracle.cpp aborts if that bookkeeping is ever wrong.
"""
import math
import random
import sys

NUM_PARAMS = {
    0x10: 1, 0x12: 1, 0x13: 1, 0x14: 1, 0x16: 16, 0x17: 12, 0x18: 16, 0x19: 12,
    0x1A: 9, 0x1B: 3, 0x1C: 3, 0x20: 1, 0x21: 1, 0x22: 1, 0x23: 2, 0x24: 1,
    0x25: 1, 0x26: 1, 0x27: 1, 0x28: 1, 0x29: 1, 0x2A: 1, 0x2B: 1, 0x30: 1,
    0x31: 1, 0x32: 1, 0x33: 1, 0x34: 32, 0x40: 1, 0x50: 1, 0x60: 1, 0x70: 3,
    0x71: 2, 0x72: 1,
}
VALID = [0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A,
         0x1B, 0x1C, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29,
         0x2A, 0x2B, 0x30, 0x31, 0x32, 0x33, 0x34, 0x40, 0x41, 0x50, 0x60, 0x70,
         0x71, 0x72]

DISP3DCNT = 0x04000060
GXSTAT = 0x04000600
RAM_COUNT = 0x04000604


def nparams(c):
    return NUM_PARAMS.get(c & 0xFF, 0)


def u32(v):
    return v & 0xFFFFFFFF


# --------------------------------------------------------------------------
# The script and the front end's FIFO occupancy


class Seq:
    """An op script plus exactly as much of the front end as decides when the
    ARM9 bus is held (cmdFifoWrite/cmdFifoRead/WriteToGXFIFO and the drain)."""

    def __init__(self, rng):
        self.rng = rng
        self.ops = []
        self.pipe, self.fifo, self.stall = [], [], []
        self.nc = self.cur = self.pc = self.tot = 0
        self.geom = self.rend = False
        self.flush = False
        self.cur_vtx = (0, 0, 0)
        self.in_burst = False     # ops get the '+' prefix: no drain after them
        self.last_burst = False   # the last op emitted was a burst op

    # ---- front-end bookkeeping
    def _entry(self, c):
        if not self.fifo and len(self.pipe) < 4:
            self.pipe.append(c)
        elif len(self.fifo) >= 256:
            self.stall.append(c)
        else:
            self.fifo.append(c)

    def _gxfifo(self, val):
        if self.nc == 0:
            self.nc, self.cur, self.pc, self.tot = 4, val, 0, nparams(val)
            run = self.tot == 0
        else:
            self.pc += 1
            run = True
        while run:
            emit = (self.cur & 0xFF) != 0 or (self.nc == 4 and self.cur == 0)
            if emit:
                self._entry(self.cur & 0xFF)
            if self.pc >= self.tot:
                self.cur >>= 8
                self.nc -= 1
                if self.nc == 0:
                    run = False
                else:
                    self.pc = 0
                    self.tot = nparams(self.cur)
                    run = self.tot == 0
            else:
                run = False

    def _read(self):
        e = self.pipe.pop(0)
        if len(self.pipe) <= 2:
            for _ in range(2):
                if self.fifo:
                    self.pipe.append(self.fifo.pop(0))
            while self.stall and len(self.fifo) < 256:
                self._entry(self.stall.pop(0))
        return e

    def _drain(self):
        while self.geom and not self.flush and self.pipe:
            if self._read() == 0x50:
                self.flush = True

    def held(self):
        return bool(self.stall)

    def queued(self):
        return len(self.pipe) + len(self.fifo)

    def _op(self, text):
        burst = self.in_burst
        self.ops.append(("+" if burst else "") + text)
        self.last_burst = burst
        if not burst:
            self._drain()

    def time(self):
        """No access: the geometry engine catches up."""
        self.ops.append("T")
        self.last_burst = False
        self._drain()

    def burst(self, fn):
        """Run fn with every op a burst op (an STM or DMA block: no geometry
        engine run between the accesses)."""
        was = self.in_burst
        self.in_burst = True
        try:
            fn()
        finally:
            self.in_burst = was

    def bus(self):
        """Wait until the ARM9 may access the bus again: time passes while
        the engine can drain, otherwise the display runs to the next VBlank."""
        guard = 0
        was = self.in_burst
        self.in_burst = False
        while self.held():
            assert self.geom, "stalled with geometry off"
            if not self.flush:
                self.time()
            else:
                self.frame_events(lines=self.rng.randrange(3) == 0)
            guard += 1
            assert guard < 300
        self.in_burst = was

    # ---- ARM9 ops
    def w(self, size, addr, val):
        self.bus()
        mask = {8: 0xFF, 16: 0xFFFF, 32: 0xFFFFFFFF}[size]
        val &= mask
        off = addr - 0x04000000
        if self.geom and size == 32 and 0x400 <= off < 0x440:
            self._gxfifo(val)
        elif self.geom and size == 32 and 0x440 <= off < 0x5CC:
            self._entry((off & 0x1FC) >> 2)
        self._op(f"W {size} {addr:x} {val:x}")

    def r(self, size, addr):
        self.bus()
        if 0x04000600 <= addr < 0x04000604:
            # A GXSTAT read runs the engine itself (at zero elapsed time), so
            # it only ever follows a caught-up engine.
            if self.last_burst:
                self.time()
            was = self.in_burst
            self.in_burst = False
            self._op(f"R {size} {addr:x}")
            self.in_burst = was
        else:
            self._op(f"R {size} {addr:x}")

    def power(self, geom, rend, extra=0x0203):
        self.bus()
        self.geom, self.rend = bool(geom), bool(rend)
        self._op(f"P {(extra | (8 if geom else 0) | (4 if rend else 0)) & 0x820F:x}")

    def xpos(self, size, addr, val):
        self.bus()
        self._op(f"X {size} {addr:x} {val & (0xFF if size == 8 else 0xFFFF):x}")

    def vcount(self, size, addr, val):
        self.bus()
        self._op(f"A {size} {addr:x} {val & (0xFF if size == 8 else 0xFFFF):x}")

    def irq_ack(self, val):
        self.bus()
        self._op(f"I {u32(val):x}")

    # ---- display events
    def vblank(self):
        if self.geom and self.flush:
            self.flush = False
        self._op("V")

    def render(self):
        self._op("S")

    def lines(self):
        self._op("L")

    def frame_end(self):
        self._op("F")

    def frame_events(self, lines=True):
        self.vblank()
        self.render()
        if lines:
            self.lines()
        self.frame_end()

    # ---- GX commands
    def send(self, items, mode=None):
        """Send a command list: ('c', cmd, params) entries, with ('op', fn)
        entries run in between. mode: 'direct', 'packed' or None (mixed)."""
        rng = self.rng
        i = 0
        while i < len(items):
            it = items[i]
            if it[0] == "op":
                it[1](self)
                i += 1
                continue
            m = mode or rng.choice(["packed", "packed", "direct"])
            if m == "direct":
                _, c, ps = it
                if not ps:
                    self.w(32, 0x04000400 + 4 * c, rng.choice([0, rng.getrandbits(32)]))
                for p in ps:
                    self.w(32, 0x04000400 + 4 * c, p)
                i += 1
                continue
            group = []
            while i < len(items) and items[i][0] == "c" and len(group) < 4:
                group.append(items[i])
                i += 1
                if rng.randrange(5) == 0:
                    break
            word = 0
            for k, (_, c, _) in enumerate(group):
                word |= c << (8 * k)
            port = lambda: 0x04000400 + 4 * rng.randrange(16)
            self.w(32, port(), word)
            for _, c, ps in group:
                for p in ps:
                    self.w(32, port(), p)


# --------------------------------------------------------------------------
# GX command builder


def fx(v):
    return int(round(v * 4096))


def clamp16(v):
    return max(-0x8000, min(0x7FFF, v))


def rgb(r, g, b):
    return (r & 31) | ((g & 31) << 5) | ((b & 31) << 10)


def pack10(x, y, z):
    q = lambda v: max(-512, min(511, int(round(v * 512)))) & 0x3FF
    return q(x) | (q(y) << 10) | (q(z) << 20)


def normalize(v):
    n = math.sqrt(sum(c * c for c in v)) or 1.0
    return [c / n for c in v]


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(len(b))) for j in range(len(b[0]))]
            for i in range(len(a))]


def rot(ax, ay, az):
    cx, sx, cy, sy, cz, sz = (math.cos(ax), math.sin(ax), math.cos(ay), math.sin(ay),
                              math.cos(az), math.sin(az))
    rx = [[1, 0, 0], [0, cx, sx], [0, -sx, cx]]
    ry = [[cy, 0, -sy], [0, 1, 0], [sy, 0, cy]]
    rz = [[cz, sz, 0], [-sz, cz, 0], [0, 0, 1]]
    return matmul(matmul(rx, ry), rz)


def perspective(fovy, near, far, aspect=256 / 192):
    f = 1 / math.tan(fovy / 2)
    return [[f / aspect, 0, 0, 0], [0, f, 0, 0],
            [0, 0, (far + near) / (near - far), -1], [0, 0, 2 * far * near / (near - far), 0]]


def ortho(w, h, near, far):
    return [[2 / w, 0, 0, 0], [0, 2 / h, 0, 0], [0, 0, -2 / (far - near), 0],
            [0, 0, -(far + near) / (far - near), 1]]


class Gx:
    """A command list with ARM9 ops in between."""

    def __init__(self, seq):
        self.seq = seq
        self.rng = seq.rng
        self.items = []

    def c(self, cmd, *ps):
        ps = [u32(p) for p in ps]
        assert len(ps) == nparams(cmd), hex(cmd)
        self.items.append(("c", cmd, ps))

    def op(self, fn):
        self.items.append(("op", fn))

    def read(self, size, addr):
        self.op(lambda s: s.r(size, addr))

    def write(self, size, addr, val):
        self.op(lambda s: s.w(size, addr, val))

    # matrices
    def mode(self, m): self.c(0x10, m)
    def push(self): self.c(0x11)
    def pop(self, n=1): self.c(0x12, n & 0x3F)
    def store(self, i): self.c(0x13, i)
    def restore(self, i): self.c(0x14, i)
    def identity(self): self.c(0x15)

    def load44(self, m):
        self.c(0x16, *[fx(m[r][c]) for r in range(4) for c in range(4)])

    def load43(self, m):
        self.c(0x17, *[fx(m[r][c]) for r in range(4) for c in range(3)])

    def mult44(self, m):
        self.c(0x18, *[fx(m[r][c]) for r in range(4) for c in range(4)])

    def mult43(self, m):
        self.c(0x19, *[fx(m[r][c]) for r in range(4) for c in range(3)])

    def mult33(self, m):
        self.c(0x1A, *[fx(m[r][c]) for r in range(3) for c in range(3)])

    def scale(self, x, y, z): self.c(0x1B, fx(x), fx(y), fx(z))
    def trans(self, x, y, z): self.c(0x1C, fx(x), fx(y), fx(z))

    def rotate(self, ax, ay, az):
        r = rot(ax, ay, az)
        if self.rng.randrange(3):
            self.mult33(r)
        else:
            self.mult43(r + [[0, 0, 0]])

    # vertex attributes
    def color(self, r, g, b): self.c(0x20, rgb(r, g, b))
    def normal(self, x, y, z): self.c(0x21, pack10(*normalize([x, y, z])))

    def texcoord(self, s, t):
        self.c(0x22, (int(s) & 0xFFFF) | ((int(t) & 0xFFFF) << 16))

    def vtx(self, x, y, z):
        """A vertex at model coordinates (floats), in the cheapest format the
        DS command set offers for it (as a game's exporter would pick)."""
        xi, yi, zi = clamp16(fx(x)), clamp16(fx(y)), clamp16(fx(z))
        px, py, pz = self.seq.cur_vtx
        rng = self.rng
        opts = [0x23]
        if zi == pz: opts.append(0x25)
        if yi == py: opts.append(0x26)
        if xi == px: opts.append(0x27)
        if all(v % 64 == 0 and -0x8000 <= v < 0x8000 for v in (xi, yi, zi)):
            opts.append(0x24)
        if all(-512 <= d <= 511 for d in (xi - px, yi - py, zi - pz)):
            opts.append(0x28)
        c = rng.choice(opts)
        if c == 0x23:
            self.c(0x23, (xi & 0xFFFF) | ((yi & 0xFFFF) << 16), zi & 0xFFFF)
        elif c == 0x24:
            q = lambda v: (v >> 6) & 0x3FF
            self.c(0x24, q(xi) | (q(yi) << 10) | (q(zi) << 20))
        elif c == 0x25:
            self.c(0x25, (xi & 0xFFFF) | ((yi & 0xFFFF) << 16))
        elif c == 0x26:
            self.c(0x26, (xi & 0xFFFF) | ((zi & 0xFFFF) << 16))
        elif c == 0x27:
            self.c(0x27, (yi & 0xFFFF) | ((zi & 0xFFFF) << 16))
        else:
            d = lambda v: v & 0x3FF
            self.c(0x28, d(xi - px) | (d(yi - py) << 10) | (d(zi - pz) << 20))
        self.seq.cur_vtx = (xi, yi, zi)

    def attr(self, lights=0, mode=0, back=True, front=True, xlu_depth=0, far=0,
             dot=0, equal=0, fog=0, alpha=31, pid=0):
        self.c(0x29, lights | (mode << 4) | (int(back) << 6) | (int(front) << 7)
               | (xlu_depth << 11) | (far << 12) | (dot << 13) | (equal << 14)
               | (fog << 15) | (alpha << 16) | (pid << 24))

    def teximage(self, offset, sw, sh, fmt, rs=1, rt=1, fs=0, ft=0, c0=0, gen=0):
        self.c(0x2A, (offset & 0xFFFF) | (rs << 16) | (rt << 17) | (fs << 18) | (ft << 19)
               | (sw << 20) | (sh << 23) | (fmt << 26) | (c0 << 29) | (gen << 30))

    def pltt(self, base): self.c(0x2B, base & 0x1FFF)

    def difamb(self, dif, amb, setcol=1):
        self.c(0x30, rgb(*dif) | (setcol << 15) | (rgb(*amb) << 16))

    def speemi(self, spe, emi, table=0):
        self.c(0x31, rgb(*spe) | (table << 15) | (rgb(*emi) << 16))

    def light_vector(self, i, x, y, z):
        self.c(0x32, pack10(*normalize([x, y, z])) | (i << 30))

    def light_color(self, i, col): self.c(0x33, rgb(*col) | (i << 30))

    def shininess(self, table):
        words = [table[k] | (table[k + 1] << 8) | (table[k + 2] << 16) | (table[k + 3] << 24)
                 for k in range(0, 128, 4)]
        self.c(0x34, *words)

    def begin(self, m): self.c(0x40, m)
    def end(self): self.c(0x41)
    def swap(self, p): self.c(0x50, p)

    def viewport(self, x0, y0, x1, y1):
        self.c(0x60, x0 | (y0 << 8) | (x1 << 16) | (y1 << 24))

    def box_test(self, x, y, z, w, h, d):
        f = lambda v: fx(v) & 0xFFFF
        self.c(0x70, f(x) | (f(y) << 16), f(z) | (f(w) << 16), f(h) | (f(d) << 16))

    def pos_test(self, x, y, z):
        xi, yi, zi = clamp16(fx(x)), clamp16(fx(y)), clamp16(fx(z))
        self.c(0x71, (xi & 0xFFFF) | ((yi & 0xFFFF) << 16), zi & 0xFFFF)
        self.seq.cur_vtx = (xi, yi, zi)

    def vec_test(self, x, y, z): self.c(0x72, pack10(*normalize([x, y, z])))


# --------------------------------------------------------------------------
# Models (model space, about +-1.5)


def texsize(rng):
    sw, sh = rng.choice([0, 1, 2, 3, 4]), rng.choice([0, 1, 2, 3, 4])
    return sw, sh, 8 << sw, 8 << sh


def material(gx, rng):
    gx.difamb([rng.randint(8, 31) for _ in range(3)], [rng.randint(0, 12) for _ in range(3)],
              setcol=rng.randrange(2))
    gx.speemi([rng.randint(0, 31) for _ in range(3)], [rng.randint(0, 8) for _ in range(3)],
              table=rng.randrange(3) == 0)


def texture(gx, rng, fmt=None, gen=0):
    sw, sh, w, h = texsize(rng)
    if fmt is None:
        fmt = rng.choice([1, 2, 3, 4, 5, 6, 7, 3, 4, 7])
    gx.teximage(rng.randrange(0, 0x10000, 8), sw, sh, fmt, rs=rng.randrange(2), rt=rng.randrange(2),
                fs=rng.randrange(2), ft=rng.randrange(2), c0=rng.randrange(2), gen=gen)
    gx.pltt(rng.randrange(0, 0x1800))
    return w, h


def no_texture(gx):
    gx.teximage(0, 0, 0, 0)


def cube(gx, rng, s, lit, tex, colour=None):
    """Six quads (BEGIN 1), normals or colours, texcoords."""
    faces = [((0, 0, 1), [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]),
             ((0, 0, -1), [(1, -1, -1), (-1, -1, -1), (-1, 1, -1), (1, 1, -1)]),
             ((1, 0, 0), [(1, -1, 1), (1, -1, -1), (1, 1, -1), (1, 1, 1)]),
             ((-1, 0, 0), [(-1, -1, -1), (-1, -1, 1), (-1, 1, 1), (-1, 1, -1)]),
             ((0, 1, 0), [(-1, 1, 1), (1, 1, 1), (1, 1, -1), (-1, 1, -1)]),
             ((0, -1, 0), [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1)])]
    gx.begin(1)
    w, h = tex if tex else (8, 8)
    uv = [(0, h * 16), (w * 16, h * 16), (w * 16, 0), (0, 0)]
    for n, quad in faces:
        if lit:
            gx.normal(*n)
        elif colour is None:
            gx.color(rng.randint(0, 31), rng.randint(0, 31), rng.randint(0, 31))
        for k, (x, y, z) in enumerate(quad):
            if tex:
                gx.texcoord(*uv[k])
            if colour is None and not lit and rng.randrange(3) == 0:
                gx.color(rng.randint(0, 31), rng.randint(0, 31), rng.randint(0, 31))
            gx.vtx(x * s, y * s, z * s)
    gx.end()


def sphere(gx, rng, r, stacks, slices, lit, tex):
    """Triangle strips, one per band (BEGIN 2)."""
    w, h = tex if tex else (8, 8)
    for i in range(stacks):
        gx.begin(2)
        for j in range(slices + 1):
            for k in (i, i + 1):
                th = math.pi * k / stacks
                ph = 2 * math.pi * j / slices
                n = (math.sin(th) * math.cos(ph), math.cos(th), math.sin(th) * math.sin(ph))
                if lit:
                    gx.normal(*n)
                else:
                    gx.color(int(15 + 15 * n[0]), int(15 + 15 * n[1]), int(15 + 15 * n[2]))
                if tex:
                    gx.texcoord(16 * w * j / slices, 16 * h * k / stacks)
                gx.vtx(r * n[0], r * n[1], r * n[2])
        if rng.randrange(4):
            gx.end()


def grid(gx, rng, size, rows, cols, lit, tex, height=0.3):
    """Quad strips, one per row (BEGIN 3)."""
    w, h = tex if tex else (8, 8)
    hgt = [[rng.uniform(-height, height) for _ in range(cols + 1)] for _ in range(rows + 1)]
    for i in range(rows):
        gx.begin(3)
        if lit:
            gx.normal(0, 1, 0)
        for j in range(cols + 1):
            for k in (i, i + 1):
                x = size * (j / cols - 0.5) * 2
                z = size * (k / rows - 0.5) * 2
                if not lit:
                    gx.color(rng.randint(0, 31), rng.randint(0, 31), rng.randint(0, 31))
                if tex:
                    gx.texcoord(16 * w * j / cols, 16 * h * k / rows)
                gx.vtx(x, hgt[k][j], z)
        gx.end()


def soup(gx, rng, n, spread, lit, tex):
    """Separate triangles (BEGIN 0)."""
    w, h = tex if tex else (8, 8)
    gx.begin(0)
    for _ in range(n):
        cx, cy, cz = (rng.uniform(-spread, spread) for _ in range(3))
        for _ in range(3):
            if lit:
                gx.normal(rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1))
            else:
                gx.color(rng.randint(0, 31), rng.randint(0, 31), rng.randint(0, 31))
            if tex:
                gx.texcoord(rng.randint(0, 16 * w), rng.randint(0, 16 * h))
            gx.vtx(cx + rng.uniform(-0.6, 0.6), cy + rng.uniform(-0.6, 0.6), cz + rng.uniform(-0.6, 0.6))
    gx.end()


def shadow_volume(gx, rng, ids, s):
    """A shadow volume: the mask (polygon ID 0, back faces), then the shadow
    (polygon ID != 0, front faces), both mode 3 and translucent."""
    no_texture(gx)
    a = rng.randint(1, 30)
    gx.attr(mode=3, back=True, front=False, alpha=a, pid=0)
    cube(gx, rng, s, False, None, colour=0)
    gx.color(rng.randint(0, 31), rng.randint(0, 31), rng.randint(0, 31))
    gx.attr(mode=3, back=False, front=True, alpha=a, pid=rng.choice(ids) or 1,
            fog=rng.randrange(2))
    cube(gx, rng, s, False, None, colour=0)


def random_attr(gx, rng, ids, lights, translucent=False):
    alpha = rng.randint(1, 30) if translucent else (0 if rng.randrange(12) == 0 else 31)
    gx.attr(lights=lights, mode=rng.choice([0, 0, 0, 1, 2]), back=rng.randrange(2) == 0 or translucent,
            front=True, xlu_depth=rng.randrange(2), far=rng.randrange(4) == 0,
            dot=rng.randrange(4) == 0, equal=rng.randrange(10) == 0, fog=rng.randrange(2),
            alpha=alpha, pid=rng.choice(ids))


def model(gx, rng, ids, lights, translucent=False, kind=None):
    gx.push()
    gx.trans(rng.uniform(-1.4, 1.4), rng.uniform(-1.0, 1.0), rng.uniform(-1.5, 1.0))
    gx.rotate(rng.uniform(0, 6.3), rng.uniform(0, 6.3), rng.uniform(0, 6.3))
    if rng.randrange(3) == 0:
        sc = rng.uniform(0.5, 1.5)
        gx.scale(sc, sc * rng.uniform(0.7, 1.3), sc)
    lit = lights != 0 and rng.randrange(3) != 0
    if lit:
        material(gx, rng)
    random_attr(gx, rng, ids, lights if lit else 0, translucent)
    tex = None
    if rng.randrange(3):
        tex = texture(gx, rng)
    else:
        no_texture(gx)
    if not lit:
        gx.color(rng.randint(0, 31), rng.randint(0, 31), rng.randint(0, 31))
    kind = kind or rng.choice(["cube", "cube", "sphere", "grid", "soup"])
    if kind == "cube":
        cube(gx, rng, rng.uniform(0.35, 0.8), lit, tex)
    elif kind == "sphere":
        sphere(gx, rng, rng.uniform(0.4, 0.9), rng.randint(3, 5), rng.randint(5, 8), lit, tex)
    elif kind == "grid":
        grid(gx, rng, rng.uniform(0.8, 1.6), rng.randint(2, 4), rng.randint(2, 5), lit, tex)
    else:
        soup(gx, rng, rng.randint(3, 10), 1.0, lit, tex)
    gx.pop(1)


def camera(gx, rng):
    gx.mode(0)
    r = rng.randrange(6)
    if r == 0:
        gx.load44(ortho(rng.uniform(3.5, 5), rng.uniform(2.6, 3.8), 0.5, 20))
    elif r == 1:
        gx.identity()
        gx.mult44(perspective(rng.uniform(0.7, 1.3), rng.uniform(0.3, 1.0), rng.uniform(10, 60)))
    else:
        gx.load44(perspective(rng.uniform(0.7, 1.3), rng.uniform(0.3, 1.0), rng.uniform(10, 60)))
    gx.mode(3)
    gx.identity()
    gx.mode(2)
    if rng.randrange(2):
        gx.identity()
        gx.trans(0, 0, -rng.uniform(3.5, 5.0))
    else:
        gx.load43([[1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 0, -rng.uniform(3.5, 5.0)]])
    gx.rotate(rng.uniform(-0.3, 0.3), rng.uniform(-0.6, 0.6), 0)
    if rng.randrange(5) == 0:
        gx.viewport(rng.randint(0, 40), rng.randint(0, 30), rng.randint(200, 255), rng.randint(150, 191))
    else:
        gx.viewport(0, 0, 255, 191)


def lights(gx, rng):
    mask = 0
    for i in range(4):
        if rng.randrange(2) or i == 0:
            gx.light_vector(i, rng.uniform(-1, 1), rng.uniform(-1, 0.2), rng.uniform(-1, 0.2))
            gx.light_color(i, [rng.randint(10, 31) for _ in range(3)])
            mask |= 1 << i
    if rng.randrange(2):
        gx.shininess(sorted(rng.randint(0, 255) for _ in range(128)))
    return mask


# --------------------------------------------------------------------------
# Register writes


def write_word(seq, addr, val, rng, widths=(8, 16, 32)):
    """Write a 32-bit register as one 32-bit, two 16-bit or four 8-bit
    accesses (registers that ignore some widths simply ignore them)."""
    size = rng.choice(widths)
    if size == 32:
        seq.w(32, addr, val)
    elif size == 16:
        seq.w(16, addr, val & 0xFFFF)
        seq.w(16, addr + 2, (val >> 16) & 0xFFFF)
    else:
        for k in range(4):
            seq.w(8, addr + k, (val >> (8 * k)) & 0xFF)


def write_table(seq, base, data, unit, rng):
    """A table of unit-byte entries, written as words, halfwords or bytes."""
    raw = b"".join(v.to_bytes(unit, "little") for v in data)
    size = rng.choice([8, 16, 32, 32])
    step = size // 8
    for off in range(0, len(raw), step):
        seq.w(size, base + off, int.from_bytes(raw[off:off + step], "little"))


def frame_regs(seq, rng, ids, features=None):
    """DISP3DCNT and the rendering registers for one frame."""
    f = features or {}
    disp = 0
    disp |= (f.get("tex", rng.randrange(5) != 0)) << 0
    disp |= (f.get("toon", rng.randrange(3) == 0)) << 1
    disp |= (f.get("alphatest", rng.randrange(3) == 0)) << 2
    disp |= (f.get("blend", rng.randrange(4) != 0)) << 3
    disp |= (f.get("aa", rng.randrange(3) == 0)) << 4
    disp |= (f.get("edge", rng.randrange(3) == 0)) << 5
    disp |= (f.get("fogalpha", rng.randrange(4) == 0)) << 6
    disp |= (f.get("fog", rng.randrange(3) == 0)) << 7
    disp |= rng.randint(0, 10) << 8
    disp |= (f.get("clearimage", rng.randrange(8) == 0)) << 14
    if rng.randrange(4) == 0:
        disp |= rng.choice([1 << 12, 1 << 13, 3 << 12])  # write-1-to-clear acks
    write_word(seq, DISP3DCNT, disp, rng, widths=(16, 32))
    if rng.randrange(2):
        seq.w(rng.choice([8, 16, 32]), 0x04000340, rng.randint(0, 31))
    clear_alpha = rng.choice([0, 31, 31, rng.randint(1, 30)])
    write_word(seq, 0x04000350, rng.randint(0, 0x7FFF) | (rng.randrange(2) << 15) | (clear_alpha << 16)
               | (rng.choice(ids + [0, 63]) << 24), rng, widths=(16, 32))
    write_word(seq, 0x04000354, rng.choice([0x7FFF, 0x7FFF, 0x7FFF, rng.randint(0x7000, 0x7FFF)])
               | (rng.randrange(2) << 15) | (rng.randint(0, 0xFFFF) << 16), rng, widths=(16, 32))
    if disp & (1 << 7) or rng.randrange(3) == 0:
        write_word(seq, 0x04000358, rng.getrandbits(32), rng, widths=(16, 32))
        seq.w(rng.choice([16, 32]), 0x0400035C, rng.choice([rng.randint(0, 0x7FFF), rng.randint(0x6000, 0x7FFF)]))
        table = sorted(rng.randint(0, 127) for _ in range(32))
        if rng.randrange(3) == 0:
            table = [rng.randint(0, 255) for _ in range(32)]
        write_table(seq, 0x04000360, table, 1, rng)
    if disp & (1 << 5) or rng.randrange(3) == 0:
        write_table(seq, 0x04000330, [rng.getrandbits(16) for _ in range(8)], 2, rng)
    if disp & (1 << 1) or rng.randrange(3) == 0:
        write_table(seq, 0x04000380, [rng.getrandbits(16) for _ in range(32)], 2, rng)
    if rng.randrange(3) == 0:
        seq.w(rng.choice([16, 32]), 0x04000610, rng.randint(0, 0x7FFF))
    return disp


def status_reads(seq, rng, k=None):
    for _ in range(k if k is not None else rng.randint(1, 3)):
        r = rng.randrange(10)
        if r < 4:
            seq.r(32, GXSTAT)
        elif r == 4:
            seq.r(rng.choice([8, 16]), GXSTAT + rng.randrange(4) if r == 4 else GXSTAT)
        elif r == 5:
            seq.r(32, RAM_COUNT)
        elif r == 6:
            seq.r(16, rng.choice([RAM_COUNT, RAM_COUNT + 2]))
        elif r == 7:
            seq.r(rng.choice([16, 32]), DISP3DCNT)
        elif r == 8:
            seq.r(16, rng.choice([0x04000600, 0x04000602]))
        else:
            seq.r(rng.choice([16, 32]), 0x04000320)


def result_reads(seq, rng):
    for _ in range(rng.randint(1, 4)):
        r = rng.randrange(4)
        if r == 0:
            seq.r(32, 0x04000620 + 4 * rng.randrange(4))
        elif r == 1:
            seq.r(16, 0x04000630 + 2 * rng.randrange(3))
        elif r == 2:
            seq.r(32, 0x04000640 + 4 * rng.randrange(16))
        else:
            seq.r(32, 0x04000680 + 4 * rng.randrange(9))


# --------------------------------------------------------------------------
# Frames


def scene(seq, rng, ids, nobj, translucent=0, shadows=0, tests=True, swap=None):
    """One frame's command list for a scene, ending with SWAP_BUFFERS."""
    gx = Gx(seq)
    camera(gx, rng)
    lmask = lights(gx, rng)
    if rng.randrange(2):
        gx.read(32, GXSTAT)
    objs = ["opaque"] * nobj + ["xlu"] * translucent + ["shadow"] * shadows
    rng.shuffle(objs)
    for o in objs:
        if o == "shadow":
            gx.push()
            gx.trans(rng.uniform(-1, 1), rng.uniform(-1, 0.5), rng.uniform(-1, 0.5))
            shadow_volume(gx, rng, ids, rng.uniform(0.3, 0.8))
            gx.pop(1)
        else:
            model(gx, rng, ids, lmask, translucent=(o == "xlu"))
        if rng.randrange(4) == 0:
            gx.op(lambda s: status_reads(s, rng))
        if tests and rng.randrange(6) == 0:
            t = rng.randrange(3)
            if t == 0:
                gx.box_test(*(rng.uniform(-1.5, 1.0) for _ in range(3)), *(rng.uniform(0.1, 2.0) for _ in range(3)))
                gx.read(rng.choice([8, 32]), GXSTAT)
            elif t == 1:
                gx.pos_test(*(rng.uniform(-1.5, 1.5) for _ in range(3)))
            else:
                gx.vec_test(rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1))
            gx.op(lambda s: result_reads(s, rng))
    gx.swap(rng.randint(0, 3) if swap is None else swap)
    return gx


def show(seq, rng, lines=True, between=None):
    """Display one frame: VBlank, what the game does in its VBlank handler
    (status reads, an X scroll, `between`), render start, the lines, frame
    end."""
    seq.vblank()
    if rng.randrange(3) == 0:
        status_reads(seq, rng)
    if rng.randrange(6) == 0:
        seq.xpos(rng.choice([8, 16]), 0x04000010, rng.choice([0, 0, rng.randint(1, 511)]))
    if between:
        between()
    seq.render()
    if lines:
        if rng.randrange(8) == 0:
            seq.xpos(16, 0x04000010, rng.randint(0, 511))   # scroll after render start
        seq.lines()
    seq.frame_end()


def power_on(seq, rng):
    seq.power(1, 1)
    if rng.randrange(2):
        seq.w(32, GXSTAT, rng.choice([0, 0x40000000, 0x80000000]))


def send_maybe_burst(seq, rng, items, p=0.3):
    """Send a command list, as a burst (STM / DMA blocks) with probability p."""
    if rng.random() < p:
        seq.burst(lambda: seq.send(items))
    else:
        seq.send(items)


def realistic_sequence(seq, rng, frames, pipelined=0.3):
    ids = [rng.randint(1, 63) for _ in range(rng.randint(2, 6))]
    power_on(seq, rng)
    rest = None          # commands of this frame left over from the last VBlank handler
    for f in range(frames):
        if rest is None:
            frame_regs(seq, rng, ids)
            gx = scene(seq, rng, ids, rng.randint(3, 8), translucent=rng.randint(0, 3),
                       shadows=rng.randrange(3) == 0)
            rest = gx.items
        send_maybe_burst(seq, rng, rest)
        rest = None
        status_reads(seq, rng)
        if rng.random() < pipelined and f + 1 < frames:
            # The next frame's commands go out before the VBlank: the FIFO
            # fills behind the pending swap (and may stall the ARM9).
            seq.r(32, GXSTAT)
            extra = Gx(seq)
            for _ in range(rng.randint(1, 3)):
                model(extra, rng, ids, 0)
            extra.read(32, GXSTAT)
            send_maybe_burst(seq, rng, extra.items)
        between = None
        if rng.random() < 0.4 and f + 1 < frames:
            # The VBlank handler sets up the next frame (registers and the
            # first part of its commands) before rendering starts.
            def between():
                nonlocal rest
                frame_regs(seq, rng, ids)
                gx = scene(seq, rng, ids, rng.randint(3, 8), translucent=rng.randint(0, 3),
                           shadows=rng.randrange(3) == 0)
                k = rng.randint(0, len(gx.items))
                send_maybe_burst(seq, rng, gx.items[:k])
                rest = gx.items[k:]
        show(seq, rng, between=between)
        if rng.randrange(8) == 0:
            seq.vcount(16, 0x04000006, rng.randint(0, 262))
            seq.lines()
            seq.frame_end()
        if rng.randrange(8) == 0:
            seq.irq_ack(rng.choice([1 << 21, 0xFFFFFFFF, 0]))

# --------------------------------------------------------------------------
# Directed sequences


def directed_basic(seq, rng):
    ids = [1, 2, 3, 4]
    power_on(seq, rng)
    for f in range(3):
        frame_regs(seq, rng, ids, {"tex": 1, "fog": 0, "clearimage": 0})
        gx = Gx(seq)
        camera(gx, rng)
        lmask = lights(gx, rng)
        for kind in ("cube", "sphere", "grid", "soup"):
            model(gx, rng, ids, lmask, kind=kind)
            gx.read(32, RAM_COUNT)
        gx.op(lambda s: result_reads(s, rng))
        gx.swap(f & 3)
        seq.send(gx.items, mode=["packed", "direct", None][f])
        seq.r(32, GXSTAT)
        show(seq, rng)


def directed_strips(seq, rng):
    """Strips and quad strips, and a strip continued across two swaps without
    BEGIN_VTXS: frame 2's first polygon shares frame 1's vertices in the other
    bank, which frame 3's vertices (sent between VBlank and render start)
    overwrite before frame 2 is rendered."""
    ids = [5, 6]
    power_on(seq, rng)
    frame_regs(seq, rng, ids, {"tex": 0, "fog": 0, "aa": 0, "edge": 0, "clearimage": 0})
    for kind_mode in (2, 3):
        gx = Gx(seq)
        camera(gx, rng)
        no_texture(gx)
        gx.attr(alpha=31, pid=5)
        gx.begin(kind_mode)
        for k in range(12):
            gx.color(k * 2, 31 - k * 2, 16)
            gx.vtx(-1.5 + 0.25 * k, 0.6 if k % 2 else -0.6, -0.5)
        gx.swap(0)                                 # no END_VTXS: the strip goes on
        seq.send(gx.items)
        show(seq, rng)
        gx = Gx(seq)
        for k in range(6):
            gx.color(31, k * 5, 0)
            gx.vtx(1.5 + 0.2 * k, 0.6 if k % 2 else -0.6, -0.5)
        gx.swap(0)
        seq.send(gx.items)
        seq.vblank()
        gx = Gx(seq)                               # frame 3 before frame 2 renders
        for k in range(16):                        # writes bank indices 0..15
            gx.color(0, 0, 31)
            gx.vtx(-1.0 + 0.1 * k, -0.9 if k % 2 else 0.9, -0.2)
        gx.end()
        seq.send(gx.items)
        seq.render()
        seq.lines()
        seq.frame_end()
        gx = Gx(seq)
        gx.swap(0)
        seq.send(gx.items)
        show(seq, rng)
    for f in range(2):
        gx = scene(seq, rng, ids, 0)
        g2 = Gx(seq)
        sphere(g2, rng, 0.8, 5, 8, False, None)
        grid(g2, rng, 1.2, 4, 5, False, None)
        seq.send(g2.items + gx.items)
        show(seq, rng)


def directed_translucent(seq, rng):
    ids = [7, 8, 9, 10]
    power_on(seq, rng)
    for f in range(4):
        frame_regs(seq, rng, ids, {"blend": 1, "alphatest": f & 1, "aa": f >= 2, "edge": f == 3})
        gx = scene(seq, rng, ids, 2, translucent=4, shadows=2, swap=f)
        seq.send(gx.items)
        show(seq, rng)


def directed_effects(seq, rng):
    ids = [11, 12, 13, 14, 15]
    power_on(seq, rng)
    combos = [{"fog": 1, "fogalpha": 0}, {"fog": 1, "fogalpha": 1}, {"edge": 1, "aa": 0},
              {"edge": 1, "aa": 1}, {"aa": 1, "edge": 0}, {"toon": 1}, {"toon": 0, "alphatest": 1}]
    for f, c in enumerate(combos):
        frame_regs(seq, rng, ids, dict(c, clearimage=0))
        gx = scene(seq, rng, ids, 3, translucent=1, swap=rng.randint(0, 3))
        seq.send(gx.items)
        show(seq, rng)


def directed_clear(seq, rng):
    ids = [20, 21]
    power_on(seq, rng)
    for f in range(3):
        frame_regs(seq, rng, ids, {"clearimage": 1, "fog": f == 1, "edge": f == 2, "aa": f == 2})
        seq.w(32, 0x04000354, rng.randint(0, 0x7FFF) | (rng.randint(0, 255) << 16) | (rng.randint(0, 255) << 24))
        gx = scene(seq, rng, ids, 2)
        seq.send(gx.items)
        show(seq, rng)


def directed_stall(seq, rng):
    """The FIFO fills behind a pending swap: GXSTAT shows the level and the
    half-empty/empty bits, the IRQ modes fire, a write overflows the FIFO and
    holds the ARM9 until the VBlank lets the engine drain it -- including a
    stall whose next queued entry is another swap (one entry per VBlank)."""
    ids = [30, 31]
    power_on(seq, rng)
    frame_regs(seq, rng, ids)
    for mode in (0x40000000, 0x80000000, 0xC0000000, 0):
        seq.w(32, GXSTAT, mode)
        gx = scene(seq, rng, ids, 1, tests=False)
        seq.send(gx.items)
        seq.r(32, GXSTAT)
        # 300 single-entry COLOR writes behind the swap: 4 PIPE + 256 FIFO,
        # then the bus stalls.
        for k in range(300):
            seq.w(32, 0x04000480, k)
            if k % 37 == 0 and not seq.held():
                seq.r(32, GXSTAT)
                seq.r(8, GXSTAT + 3)
                # IF acknowledge: CheckFIFOIRQ re-evaluates the request now
                # that the FIFO level has moved without a PIPE refill.
                seq.irq_ack(rng.choice([1 << 21, 0, 0xFFFFFFFF]))
        seq.r(32, GXSTAT)
        show(seq, rng)
    # A packed word of four parameterless commands overflowing at once, and
    # swaps queued back to back.
    gx = scene(seq, rng, ids, 1, tests=False)
    seq.send(gx.items)
    for k in range(64):
        seq.w(32, 0x04000400, 0x15111515)          # IDENTITY, IDENTITY, PUSH, IDENTITY
        seq.w(32, 0x04000400, 0x12)                # POP
        seq.w(32, 0x04000400, 1)
    for k in range(6):
        seq.w(32, 0x04000540, k & 3)               # SWAP_BUFFERS
    seq.r(32, GXSTAT)
    for k in range(4):
        show(seq, rng)
        seq.r(32, GXSTAT)
    seq.irq_ack(0xFFFFFFFF)


def directed_power(seq, rng):
    """POWCNT1 gating: writes ignored while disabled, VBlank with geometry
    disabled keeps the swap pending, rendering disabled resets the latched
    state (blank frame) and empties the render list."""
    ids = [40, 41]
    power_on(seq, rng)
    frame_regs(seq, rng, ids)
    gx = scene(seq, rng, ids, 3)
    seq.send(gx.items)
    show(seq, rng)
    for geom, rend in ((0, 1), (1, 0), (0, 0), (1, 1), (1, 0), (1, 1)):
        seq.power(geom, rend)
        frame_regs(seq, rng, ids)              # ignored where gated
        gx = scene(seq, rng, ids, 2)
        seq.send(gx.items)
        status_reads(seq, rng, 3)
        if geom and rng.randrange(2):
            seq.power(0, rend)                     # swap pending, geometry off
            show(seq, rng)
            seq.power(1, rend)
        show(seq, rng)
        seq.xpos(16, 0x04000010, rng.randint(0, 511))
        show(seq, rng)


def directed_overflow(seq, rng):
    """More than 2048 polygons and more than 6144 vertices in one frame:
    DISP3DCNT bit 13, RAM_COUNT, and the write-1-to-clear acknowledge."""
    ids = [50]
    power_on(seq, rng)
    seq.w(32, DISP3DCNT, 0)
    for frame in range(2):
        gx = Gx(seq)
        camera(gx, rng)
        no_texture(gx)
        gx.attr(alpha=31, pid=50)
        if frame == 0:
            # Triangle strips of tiny triangles: the polygon limit first.
            for band in range(24):
                gx.begin(2)
                for k in range(92):
                    gx.color(k & 31, band, 31 - (k & 31))
                    gx.vtx(-1.6 + 0.035 * k, -1.2 + 0.1 * band + (0.03 if k % 2 else 0), -0.5)
                gx.end()
                if band % 6 == 5:
                    gx.read(32, RAM_COUNT)
                    gx.read(16, DISP3DCNT)
        else:
            # Separate triangles: the vertex limit first.
            gx.begin(0)
            for k in range(2100):
                x, y = -1.6 + 0.0015 * k, -1.0 + 0.0009 * k
                gx.vtx(x, y, -0.5)
                gx.vtx(x + 0.03, y, -0.5)
                gx.vtx(x, y + 0.03, -0.5)
            gx.end()
            gx.read(32, RAM_COUNT)
        gx.read(32, DISP3DCNT)
        gx.write(16, DISP3DCNT, 0x2000)
        gx.read(32, DISP3DCNT)
        gx.c(0x23, 0, 0)                           # one more polygon after the ack
        gx.c(0x23, 0, 0)
        gx.c(0x23, 0, 0)
        gx.read(32, DISP3DCNT)
        gx.swap(0)
        seq.send(gx.items, mode="packed")
        seq.r(32, RAM_COUNT)
        show(seq, rng)
        seq.r(32, RAM_COUNT)
    seq.w(32, DISP3DCNT, 0x3000)
    seq.r(32, DISP3DCNT)
    # A frame that fits: the acknowledged flag stays clear.
    gx = scene(seq, rng, ids, 2, tests=False)
    seq.send(gx.items)
    seq.r(32, DISP3DCNT)
    show(seq, rng)
    seq.r(32, DISP3DCNT)


def directed_abort(seq, rng):
    """VCOUNT writes abort the frame (GetLine returns zeros until the frame
    ends); BG0HOFS scrolls the output at 8- and 16-bit widths."""
    ids = [60, 61]
    power_on(seq, rng)
    frame_regs(seq, rng, ids, {"clearimage": 0})
    gx = scene(seq, rng, ids, 4)
    seq.send(gx.items)
    show(seq, rng)
    seq.vcount(16, 0x04000006, 0)                  # unchanged: no abort
    seq.lines()
    seq.vcount(16, 0x04000006, 100)                # abort
    seq.lines()
    seq.frame_end()
    seq.lines()
    seq.vcount(8, 0x04000006, 100)                 # unchanged low byte
    seq.lines()
    seq.vcount(8, 0x04000007, 1)                   # 356
    seq.lines()
    seq.render()
    seq.lines()
    seq.frame_end()
    for size, addr, val in ((16, 0x04000010, 1), (16, 0x04000010, 255), (16, 0x04000010, 256),
                            (16, 0x04000010, 257), (8, 0x04000010, 0x80), (8, 0x04000011, 1),
                            (8, 0x04000011, 0xFE), (16, 0x04000010, 0xFFFF), (16, 0x04000010, 0)):
        seq.xpos(size, addr, val)
        seq.lines()
    seq.power(1, 0)                                # SetRenderXPos ignored while rendering is off
    seq.xpos(16, 0x04000010, 77)
    seq.power(1, 1)
    seq.lines()


def directed_stack(seq, rng):
    """Matrix stack overflow/underflow (GXSTAT bit 15, stack levels), the
    acknowledge at every width, the tests and every result register."""
    power_on(seq, rng)
    gx = Gx(seq)
    camera(gx, rng)
    for k in range(33):
        gx.push()
        if k % 8 == 0:
            gx.read(32, GXSTAT)
    gx.read(32, GXSTAT)
    gx.write(8, GXSTAT + 1, 0x80)
    gx.read(16, GXSTAT)
    gx.mode(0)
    gx.push()
    gx.push()
    gx.read(32, GXSTAT)
    gx.write(16, GXSTAT, 0x8000)
    gx.read(32, GXSTAT)
    gx.pop(1)
    gx.pop(1)
    gx.read(32, GXSTAT)
    gx.write(32, GXSTAT, 0x8000)
    gx.mode(3)
    gx.pop(1)
    gx.mode(2)
    gx.pop(40)
    gx.store(31)
    gx.restore(5)
    gx.read(8, GXSTAT + 1)
    gx.write(32, GXSTAT, 0x00008000)
    gx.mode(1)
    gx.pop(1)
    gx.box_test(-0.5, -0.5, -0.5, 1, 1, 1)
    gx.read(32, GXSTAT)
    gx.box_test(20, 20, 20, 1, 1, 1)
    gx.read(8, GXSTAT)
    gx.pos_test(0.3, -0.2, 0.1)
    gx.vec_test(0.2, 0.9, -0.3)
    for a in range(0x04000620, 0x040006A4, 4):
        gx.read(32, a)
    for a in range(0x04000630, 0x04000636, 2):
        gx.read(16, a)
    gx.read(8, 0x04000620)
    gx.swap(0)
    seq.send(gx.items)
    show(seq, rng)


def directed_noswap(seq, rng):
    """A VBlank without a swap latches the registers and re-renders the same
    list; a swap of an empty bank; W-buffer and manual sort swap bits."""
    ids = [33, 34]
    power_on(seq, rng)
    frame_regs(seq, rng, ids)
    gx = scene(seq, rng, ids, 3, translucent=2, swap=3)
    seq.send(gx.items)
    show(seq, rng)
    for _ in range(2):
        frame_regs(seq, rng, ids)
        show(seq, rng)
    gx = Gx(seq)
    gx.swap(2)
    seq.send(gx.items)
    show(seq, rng)
    gx = scene(seq, rng, ids, 2, translucent=2, swap=1)
    seq.send(gx.items)
    show(seq, rng)


def directed_regs(seq, rng):
    """Every register at every width, with the reads that return them."""
    power_on(seq, rng)
    for size in (8, 16, 32):
        for a in list(range(0x04000060, 0x04000064)) + list(range(0x04000320, 0x040003C0)) \
                + [0x04000600, 0x04000601, 0x04000602, 0x04000603, 0x04000604, 0x04000606, 0x04000610]:
            if a % (size // 8):
                continue
            seq.w(size, a, rng.getrandbits(size) & ~(0x1000 if a == DISP3DCNT else 0))
        for a in range(0x04000060, 0x04000064):
            seq.r(size, a)
        for a in [0x04000320, 0x04000600, 0x04000601, 0x04000602, 0x04000603, 0x04000604,
                  0x04000606, 0x04000610]:
            if a % (size // 8) == 0:
                seq.r(size, a)
        frame_regs(seq, rng, [1, 2])
        gx = scene(seq, rng, [1, 2], 2)
        seq.send(gx.items)
        show(seq, rng)
    seq.w(32, GXSTAT, 0)


def screen_vtx(gx, sx, sy, z):
    """A vertex at screen pixel (sx, sy) under identity projection and
    position matrices and the full-screen viewport (sy a multiple of 3, so
    the 4.12 coordinate is exact)."""
    gx.vtx(sx / 128 - 1, 1 - sy / 96, z)


def screen_quad(gx, x0, y0, x1, y1, z):
    gx.begin(1)
    for sx, sy in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
        screen_vtx(gx, sx, sy, z)
    gx.end()


def screen_setup(gx):
    gx.mode(0)
    gx.identity()
    gx.mode(3)
    gx.identity()
    gx.mode(2)
    gx.identity()
    gx.viewport(0, 0, 255, 191)
    no_texture(gx)


def directed_carry(seq, rng):
    """Renderer state carried from one frame to the next through real GX
    commands (render_oracle's 'carry' case): a frame whose last polygon drawn
    is a full-width shadow mask failing its depth test down to line 191,
    then a frame whose first polygon drawn is a mask (so it keeps the stale
    stencil line) followed by a full-width shadow over the same lines."""
    power_on(seq, rng)
    seq.w(32, DISP3DCNT, 0x08)
    seq.w(32, 0x04000350, 0x001F0000 | rng.randint(0, 0x7FFF))
    seq.w(32, 0x04000354, 0x7FFF)
    for rep in range(2):
        gx = Gx(seq)
        screen_setup(gx)
        gx.color(rng.randint(0, 31), rng.randint(0, 31), rng.randint(0, 31))
        gx.attr(alpha=31, pid=5)
        screen_quad(gx, 0, 99, 256, 192, -0.5)          # floor, in front
        gx.attr(mode=3, alpha=20, pid=0)
        screen_quad(gx, 0, 120, 256, 192, 0.5)          # mask behind it: fails everywhere
        gx.swap(0)
        seq.send(gx.items)
        show(seq, rng)
        gx = Gx(seq)
        screen_setup(gx)
        gx.attr(mode=3, alpha=20, pid=0)
        screen_quad(gx, 9, 0, 42, 12, -0.8)             # small mask in front: sets nothing
        gx.color(31, 0, rng.randint(0, 31))
        gx.attr(mode=3, alpha=16, pid=9)
        screen_quad(gx, 0, 0, 256, 12, -0.5)            # full-width shadow
        gx.swap(1)                                      # manual sort: mask first
        seq.send(gx.items)
        show(seq, rng)
        show(seq, rng)                                  # the same list again (no swap)


def directed_dot(seq, rng):
    """1-dot polygons (every vertex on one pixel) against DISP_1DOT_DEPTH
    written at every width, with W from 0.5 to 4.0."""
    power_on(seq, rng)
    frame_regs(seq, rng, [1, 2], {"clearimage": 0})
    for w in (0.5, 1.0, 2.0, 4.0):
        gx = Gx(seq)
        screen_setup(gx)
        gx.mode(0)
        gx.load44([[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, w]])
        gx.mode(2)
        wi = int(w * 4096)
        for v in (wi // 512 - 1, wi // 512, wi // 512 + 1, 0, 0x7FFF, 3, 0x7FFF):
            width = rng.choice([16, 32, 8])
            gx.write(width, 0x04000610, v)
            gx.write(8, 0x04000611, v >> 8)             # ignored by melonDS
            for attr13 in (0, 1):
                gx.color(rng.randint(0, 31), 31, rng.randint(0, 31))
                gx.attr(alpha=31, pid=3, dot=attr13)
                gx.begin(0)
                x, y = rng.uniform(-0.9, 0.9), rng.uniform(-0.9, 0.9)
                for _ in range(3):
                    gx.vtx(x, y, -0.3)
                gx.end()
                gx.read(32, RAM_COUNT)
        gx.swap(0)
        seq.send(gx.items)
        show(seq, rng)


def directed_burst(seq, rng):
    """Bursts (STM / DMA blocks to GXFIFO: no engine run between accesses):
    a whole frame in one burst (the FIFO fills, DMA triggers on refills);
    a burst ending with geometry switched off (entries stay queued through
    GXSTAT reads, an IF acknowledge and a VBlank); a VBlank inside a burst
    whose SWAP_BUFFERS is still queued; a burst that overflows the FIFO."""
    ids = [44, 45, 46]
    power_on(seq, rng)
    for mode in (0x40000000, 0x80000000):
        seq.w(32, GXSTAT, mode)
        frame_regs(seq, rng, ids)
        gx = scene(seq, rng, ids, 3, tests=False)
        seq.burst(lambda: seq.send(gx.items, mode="packed"))
        seq.r(32, RAM_COUNT)                       # before the engine has run
        status_reads(seq, rng, 2)
        show(seq, rng)
        # Geometry off at the end of a burst.
        gx = scene(seq, rng, ids, 2, tests=False)
        k = len(gx.items) // 2
        seq.burst(lambda: (seq.send(gx.items[:k]), seq.power(0, 1)))
        seq.r(32, GXSTAT)
        seq.irq_ack(1 << 21)
        seq.r(16, GXSTAT + 2)
        show(seq, rng)                             # geometry off: nothing swaps
        seq.power(1, 1)
        seq.r(32, GXSTAT)
        seq.send(gx.items[k:])
        seq.r(32, GXSTAT)
        show(seq, rng)
        # VBlank in the middle of a burst, before its swap ran.
        gx = scene(seq, rng, ids, 2, tests=False)
        seq.burst(lambda: (seq.send(gx.items), seq.vblank(), seq.render(), seq.lines(),
                           seq.frame_end()))
        seq.r(32, GXSTAT)
        show(seq, rng)
        # A burst of 300 single-entry writes: the FIFO overflows and the ARM9
        # waits for the engine (no VBlank needed).
        gx = scene(seq, rng, ids, 1, tests=False)
        items = gx.items[:-1] + [("c", 0x20, [k]) for k in range(300)] + gx.items[-1:]
        seq.burst(lambda: seq.send(items, mode="direct"))
        seq.r(32, GXSTAT)
        show(seq, rng)



def directed_tiny(seq, rng):
    """The smallest whole-chip frame: one 3-vertex polygon, one SWAP_BUFFERS,
    one VBlank and one render, so every stage runs once end to end."""
    ids = [7]
    power_on(seq, rng)
    frame_regs(seq, rng, ids)
    gx = Gx(seq)
    camera(gx, rng)
    gx.attr(alpha=31, pid=7)
    gx.begin(0)
    for x, y in ((-0.5, -0.5), (0.5, -0.5), (0.0, 0.5)):
        gx.vtx(x, y, -0.5)
    gx.end()
    gx.swap(0)
    seq.send(gx.items)
    show(seq, rng)


DIRECTED = {
    "tiny": directed_tiny,
    "basic": directed_basic,
    "strips": directed_strips,
    "translucent": directed_translucent,
    "effects": directed_effects,
    "clear": directed_clear,
    "stall": directed_stall,
    "power": directed_power,
    "overflow": directed_overflow,
    "abort": directed_abort,
    "stack": directed_stack,
    "noswap": directed_noswap,
    "regs": directed_regs,
    "carry": directed_carry,
    "dot": directed_dot,
    "burst": directed_burst,
}


# --------------------------------------------------------------------------
# Fuzz


def fuzz_param(rng):
    r = rng.randrange(4)
    if r == 0:
        return rng.getrandbits(32)
    if r == 1:
        return rng.randint(-0x2000, 0x2000) & 0xFFFFFFFF
    if r == 2:
        return (rng.randint(-0x3000, 0x3000) & 0xFFFF) | ((rng.randint(-0x3000, 0x3000) & 0xFFFF) << 16)
    return rng.choice([0, 1, 0x1000, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF])


def fuzz_sequence(seq, rng, frames):
    power_on(seq, rng)
    ids = [rng.randint(0, 63) for _ in range(4)]
    for f in range(frames):
        if rng.randrange(2):
            frame_regs(seq, rng, ids)
        gx = Gx(seq)
        camera(gx, rng)                            # a sane start, then noise
        for _ in range(rng.randint(80, 400)):
            r = rng.randrange(20)
            if r < 12:
                c = rng.choice(VALID) if rng.randrange(6) else rng.randrange(256)
                if c in (0x50,) and rng.randrange(3):
                    continue
                gx.items.append(("c", c, [fuzz_param(rng) for _ in range(nparams(c))]))
            elif r < 15:
                gx.items.append(("c", 0x23, [fuzz_param(rng), fuzz_param(rng)]))
            elif r == 15:
                gx.write(32, 0x04000400 + 4 * rng.randrange(16), rng.getrandbits(32))
            elif r == 16:
                a = rng.choice([0x04000060, rng.randrange(0x04000320, 0x040006A4)])
                size = rng.choice([8, 16, 32])
                a -= a % (size // 8)
                if not (0x04000400 <= a < 0x040005CC):
                    gx.write(size, a, rng.getrandbits(size))
            elif r == 17:
                a = rng.choice([0x04000060, rng.randrange(0x04000320, 0x040006A4)])
                size = rng.choice([8, 16, 32])
                gx.read(size, a - a % (size // 8))
            elif r == 18:
                gx.items.append(("c", rng.choice([0x40, 0x41]), [rng.randrange(8)] if True else []))
            else:
                gx.op(lambda s: status_reads(s, rng))
        gx.items = [it if it[0] == "op" else ("c", it[1], it[2][:nparams(it[1])]) for it in gx.items]
        gx.swap(rng.getrandbits(32))
        seq.send(gx.items)
        if rng.randrange(4) == 0:
            seq.power(1, rng.randrange(2))
            seq.power(1, 1)
        if rng.randrange(5) == 0:
            seq.irq_ack(rng.getrandbits(32))
        show(seq, rng)


def main():
    kind, seed, script_out, vram_out = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    rng = random.Random(f"chip:{kind}:{seed}")
    texture = rng.randbytes(512 * 1024)
    palette = rng.randbytes(96 * 1024) + bytes(32 * 1024)
    with open(vram_out, "wb") as f:
        f.write(texture + palette)
    seq = Seq(rng)
    if kind == "random":
        realistic_sequence(seq, rng, rng.randint(3, 6))
    elif kind == "fuzz":
        fuzz_sequence(seq, rng, rng.randint(2, 4))
    else:
        DIRECTED[kind](seq, rng)
    with open(script_out, "w") as f:
        f.write("\n".join(seq.ops) + "\n")


if __name__ == "__main__":
    main()
