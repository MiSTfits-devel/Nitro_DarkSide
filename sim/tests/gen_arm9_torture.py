#!/usr/bin/env python3
"""Generate the armwrestler-style ARM9 ISA torture workload for the M3
differential trace (docs/TRACE_DIFF.md). Emits pseudo-random but fully
deterministic ARMv5TE assembly, linked at 0x02000000, that loops a body of
random chunks forever — correctness is established by lockstep comparison
against melonDS, so nothing is self-checking.

Generated code only ever touches main RAM (code, a scratch buffer at
0x02300000, stacks below 0x02100000) — no MMIO, no IRQs, no CP15 state the
two sides don't share. Officially UNPREDICTABLE encodings are avoided
(LDM/STM writeback with base in list, PC in store lists, SWP with Rn
overlap, LDRD/STRD unaligned, ...).

Usage: gen_arm9_torture.py [--seed N] [--chunks N] [--loops N] -o out.s
"""
import argparse
import random

# free registers the random ops may read/write; r8 = scratch base,
# r11 = loop counter, r13 = sp, r14 = lr are managed by the harness code
FREE = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r9", "r10", "r12"]
LOW = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7"]  # thumb chunks

SCRATCH = 0x02300000
SCRATCH_SIZE = 0x1000

ALU_2OP = ["and", "eor", "sub", "rsb", "add", "adc", "sbc", "rsc", "orr", "bic"]
ALU_MOV = ["mov", "mvn"]
ALU_CMP = ["cmp", "cmn", "tst", "teq"]
SHIFTS = ["lsl", "lsr", "asr", "ror"]
CONDS = ["eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le"]


class Gen:
    def __init__(self, seed, chunks, loops, caches=False):
        self.rng = random.Random(seed)
        self.chunks = chunks
        self.loops = loops
        self.caches = caches
        self.out = []
        self.label_n = 0
        self.thumb_subs = []
        self.instr_per_loop = 0  # rough count of emitted instructions

    def emit(self, line, n=1):
        self.out.append("   " + line)
        self.instr_per_loop += n

    def label(self):
        self.label_n += 1
        return f"L{self.label_n}"

    def imm(self):
        # valid data-processing immediate: imm8 ror (2*n)
        v = self.rng.getrandbits(8)
        r = self.rng.randrange(16)
        return (v >> (2 * r) | v << (32 - 2 * r)) & 0xFFFFFFFF

    def reg(self):
        return self.rng.choice(FREE)

    def op2(self):
        r = self.rng.random()
        if r < 0.35:
            return f"#{self.imm()}"
        if r < 0.55:
            return self.reg()
        if r < 0.80:
            return f"{self.reg()}, {self.rng.choice(SHIFTS)} #{self.rng.randrange(1, 32)}"
        if r < 0.90:
            return f"{self.reg()}, {self.rng.choice(SHIFTS)} {self.reg()}"
        return f"{self.reg()}, rrx"

    def chunk_const(self):
        for r in self.rng.sample(FREE, self.rng.randrange(2, 7)):
            self.emit(f"ldr  {r}, ={self.rng.getrandbits(32)}")

    def chunk_alu(self):
        for _ in range(self.rng.randrange(4, 16)):
            k = self.rng.random()
            s = "s" if self.rng.random() < 0.4 else ""
            if k < 0.70:
                self.emit(f"{self.rng.choice(ALU_2OP)}{s} {self.reg()}, {self.reg()}, {self.op2()}")
            elif k < 0.85:
                self.emit(f"{self.rng.choice(ALU_MOV)}{s} {self.reg()}, {self.op2()}")
            else:
                self.emit(f"{self.rng.choice(ALU_CMP)} {self.reg()}, {self.op2()}")

    def chunk_mul(self):
        for _ in range(self.rng.randrange(2, 8)):
            k = self.rng.random()
            s = "s" if self.rng.random() < 0.3 else ""
            d, n, m, a = self.rng.sample(FREE, 4)
            if k < 0.15:
                self.emit(f"mul{s} {d}, {n}, {m}")
            elif k < 0.25:
                self.emit(f"mla{s} {d}, {n}, {m}, {a}")
            elif k < 0.45:
                op = self.rng.choice(["umull", "umlal", "smull", "smlal"])
                lo, hi, m2 = self.rng.sample(FREE, 3)
                self.emit(f"{op}{s} {lo}, {hi}, {m2}, {n}")
            elif k < 0.65:
                x, y = self.rng.choice("bt"), self.rng.choice("bt")
                op = self.rng.choice([f"smul{x}{y}", f"smulw{y}"])
                self.emit(f"{op} {d}, {n}, {m}")
            elif k < 0.80:
                x, y = self.rng.choice("bt"), self.rng.choice("bt")
                if self.rng.random() < 0.5:
                    self.emit(f"smla{x}{y} {d}, {n}, {m}, {a}")
                else:
                    self.emit(f"smlaw{y} {d}, {n}, {m}, {a}")
            elif k < 0.90:
                x, y = self.rng.choice("bt"), self.rng.choice("bt")
                lo, hi, m2 = self.rng.sample(FREE, 3)
                self.emit(f"smlal{x}{y} {lo}, {hi}, {m2}, {n}")
            else:
                op = self.rng.choice(["qadd", "qsub", "qdadd", "qdsub"])
                if self.rng.random() < 0.3:
                    self.emit(f"clz {d}, {n}")
                else:
                    self.emit(f"{op} {d}, {n}, {m}")

    def chunk_mem(self):
        # r9 = fresh copy of the scratch base so writeback can't escape
        self.emit(f"mov  r9, r8")
        for _ in range(self.rng.randrange(3, 10)):
            k = self.rng.random()
            d = self.rng.choice([r for r in FREE if r != "r9"])
            off = self.rng.randrange(0, SCRATCH_SIZE - 8)
            if k < 0.34:  # word, incl. rotated unaligned loads
                if self.rng.random() < 0.25:
                    self.emit(f"ldr  {d}, [r9, #{(off & ~3) | self.rng.randrange(4)}]")
                elif self.rng.random() < 0.5:
                    self.emit(f"str  {d}, [r9, #{off & ~3}]")
                else:
                    self.emit(f"ldr  {d}, [r9, #{off & ~3}]")
            elif k < 0.55:  # byte (ldrsb is addr-mode-3: imm8 offset max 255)
                op = self.rng.choice(["ldrb", "strb", "ldrsb"])
                boff = off if op != "ldrsb" else off & 0xFF
                self.emit(f"{op} {d}, [r9, #{boff}]")
            elif k < 0.75:  # halfword (addr mode 3: imm8 offset max 255)
                op = self.rng.choice(["ldrh", "strh", "ldrsh"])
                self.emit(f"{op} {d}, [r9, #{(off & 0xFF) & ~1}]")
            elif k < 0.85:  # pre/post index with writeback on the copy
                mode = self.rng.random()
                so = self.rng.randrange(4, 64) & ~3
                if mode < 0.5:
                    self.emit(f"ldr  {d}, [r9, #{so}]!")
                else:
                    self.emit(f"str  {d}, [r9], #{so}")
                self.emit("mov  r9, r8")
            elif k < 0.95:  # LDRD/STRD: addr mode 3 (imm8), 8-aligned, even pairs
                pair = self.rng.choice(["r0", "r2", "r4", "r6"])
                p2 = f"r{int(pair[1:]) + 1}"
                doff = (off & 0xFF) & ~7
                if self.rng.random() < 0.5:
                    self.emit(f"strd {pair}, {p2}, [r9, #{doff}]")
                else:
                    self.emit(f"ldrd {pair}, {p2}, [r9, #{doff}]")
            else:  # swp
                d2 = self.rng.choice([r for r in FREE if r not in (d, "r9")])
                op = self.rng.choice(["swp", "swpb"])
                self.emit(f"{op} {d}, {d2}, [r9]")

    def chunk_ldmstm(self):
        base = SCRATCH + (self.rng.randrange(0, SCRATCH_SIZE - 64) & ~3)
        self.emit(f"ldr  r9, ={base}")
        subset = sorted(self.rng.sample(LOW, self.rng.randrange(1, 8)),
                        key=lambda r: int(r[1:]))
        lst = ", ".join(subset)
        wb = "!" if self.rng.random() < 0.5 else ""
        mode = self.rng.choice(["ia", "ib", "da", "db"])
        self.emit(f"stm{mode} r9{wb}, {{{lst}}}")
        if wb:
            self.emit(f"ldr  r9, ={base}")
        subset2 = sorted(self.rng.sample(LOW, self.rng.randrange(1, 8)),
                         key=lambda r: int(r[1:]))
        self.emit(f"ldm{mode} r9, {{{', '.join(subset2)}}}")

    def chunk_cond(self):
        self.emit(f"cmp  {self.reg()}, #{self.imm()}")
        for _ in range(self.rng.randrange(2, 6)):
            c = self.rng.choice(CONDS)
            if self.rng.random() < 0.7:
                self.emit(f"{self.rng.choice(ALU_2OP)}{c} {self.reg()}, {self.reg()}, {self.op2()}")
            else:
                self.emit(f"{self.rng.choice(ALU_MOV)}{c} {self.reg()}, {self.op2()}")
        # short forward conditional branch over a couple of ops
        l = self.label()
        self.emit(f"b{self.rng.choice(CONDS)} {l}")
        for _ in range(self.rng.randrange(1, 4)):
            self.emit(f"add  {self.reg()}, {self.reg()}, {self.op2()}")
        self.out.append(f"{l}:")

    def chunk_msr(self):
        v = self.rng.randrange(32) << 27  # NZCVQ
        self.emit(f"msr  cpsr_f, #{v}")
        for _ in range(self.rng.randrange(1, 4)):
            self.emit(f"adc{'s' if self.rng.random() < 0.5 else ''} {self.reg()}, {self.reg()}, {self.op2()}")

    def chunk_thumb(self):
        name = f"tsub{len(self.thumb_subs)}"
        body = []
        # divided-syntax thumb: flag-setting is implicit, no 's' suffixes
        for _ in range(self.rng.randrange(4, 14)):
            k = self.rng.random()
            d, m = self.rng.choice(LOW), self.rng.choice(LOW)
            if k < 0.25:
                body.append(f"   mov  {d}, #{self.rng.getrandbits(8)}")
            elif k < 0.40:
                body.append(f"   {self.rng.choice(['add', 'sub'])} {d}, #{self.rng.getrandbits(8)}")
            elif k < 0.55:
                body.append(f"   {self.rng.choice(['lsl', 'lsr', 'asr'])} {d}, {m}, #{self.rng.randrange(1, 32)}")
            elif k < 0.85:
                op = self.rng.choice(["and", "eor", "adc", "sbc", "ror",
                                      "orr", "bic", "mvn", "neg"])
                body.append(f"   {op}  {d}, {m}")
            elif k < 0.95:
                body.append(f"   {self.rng.choice(['cmp', 'cmn', 'tst'])} {d}, {m}")
            else:
                n = self.rng.choice(LOW)
                body.append(f"   {self.rng.choice(['add', 'sub'])} {d}, {m}, {n}")
        body.append("   bx   lr")
        self.thumb_subs.append((name, body))
        self.emit(f"blx  {name}", n=len(body) + 1)

    def chunk_cachemaint(self):
        # trace-transparent maintenance only: clean / clean+invalidate by MVA
        # (never invalidate-without-clean on D: that drops dirty data, which
        # melonDS - cacheless - would not see). Plus inv-I-all and drain.
        for _ in range(self.rng.randrange(1, 4)):
            k = self.rng.random()
            off = self.rng.randrange(0, SCRATCH_SIZE) & ~31
            self.emit(f"add  r9, r8, #{off}")
            if k < 0.4:
                self.emit("mcr  p15, 0, r9, c7, c10, 1")   # clean D MVA
            elif k < 0.75:
                self.emit("mcr  p15, 0, r9, c7, c14, 1")   # clean+inv D MVA
            elif k < 0.9:
                self.emit("mcr  p15, 0, r9, c7, c5, 0")    # invalidate I all
            else:
                self.emit("mcr  p15, 0, r9, c7, c10, 4")   # drain write buffer

    def chunk_callret(self):
        # bl + ldm-to-pc return (v5 interworking path)
        name = self.label()
        skip = self.label()
        self.emit(f"b    {skip}")
        self.out.append(f"{name}:")
        self.emit("stmdb sp!, {r4, r5, lr}")
        for _ in range(self.rng.randrange(1, 4)):
            self.emit(f"eor  {self.reg()}, {self.reg()}, {self.op2()}")
        self.emit("ldmia sp!, {r4, r5, pc}")
        self.out.append(f"{skip}:")
        self.emit(f"bl   {name}")

    def pool(self):
        l = self.label()
        self.out.append(f"   b    {l}")
        self.out.append("   .ltorg")
        self.out.append(f"{l}:")

    def generate(self):
        o = self.out
        o.append("@ GENERATED by gen_arm9_torture.py — do not edit.")
        o.append(f"@ seed/chunks/loops on the build line in build_arm9_torture.sh")
        o.append("   .arch armv5te")
        o.append("   .arm")
        o.append("   .section .text")
        o.append("   .global _start")
        o.append("_start:")
        o.append("   msr  cpsr_c, #0xDF          @ system mode, I+F set")
        o.append("   ldr  sp, =0x02100E00")
        if self.caches:
            # PU: region0 4GB uncachable base, region1 main RAM 4MB I+D
            # cachable; then PU + both caches on. melonDS ignores cachability,
            # so the whole run doubles as a cache-transparency proof.
            o.append("   ldr  r0, =0x0000003F        @ region 0: 4GB")
            o.append("   mcr  p15, 0, r0, c6, c0, 0")
            o.append("   ldr  r0, =0x0200002B        @ region 1: main RAM 4MB")
            o.append("   mcr  p15, 0, r0, c6, c1, 0")
            o.append("   mov  r0, #0x02")
            o.append("   mcr  p15, 0, r0, c2, c0, 0  @ D cachable: region 1")
            o.append("   mcr  p15, 0, r0, c2, c0, 1  @ I cachable: region 1")
            o.append("   mcr  p15, 0, r0, c3, c0, 0  @ D bufferable")
            o.append("   ldr  r0, =0x33333333        @ full access")
            o.append("   mcr  p15, 0, r0, c5, c0, 2")
            o.append("   mcr  p15, 0, r0, c5, c0, 3")
            o.append("   ldr  r0, =0x0000117D        @ PU + I/D caches on")
            o.append("   mcr  p15, 0, r0, c1, c0, 0")
        o.append(f"   ldr  r8, ={SCRATCH}")
        o.append(f"   ldr  r11, ={self.loops}")
        o.append("   mov  r0, #0")
        o.append("   mov  r1, #0")
        o.append("   mov  r2, #0")
        o.append("outer:")
        chunks = [self.chunk_const, self.chunk_alu, self.chunk_mul,
                  self.chunk_mem, self.chunk_ldmstm, self.chunk_cond,
                  self.chunk_msr, self.chunk_thumb, self.chunk_callret]
        weights = [15, 25, 15, 15, 8, 10, 5, 5, 2]
        if self.caches:
            chunks.append(self.chunk_cachemaint)
            weights.append(4)
        since_pool = 0
        for _ in range(self.chunks):
            self.rng.choices(chunks, weights)[0]()
            since_pool += 1
            if since_pool >= 12:
                self.pool()
                since_pool = 0
        o.append("   subs r11, r11, #1")
        o.append("   bne  outer")
        o.append("hang:")
        o.append("   b    hang")
        o.append("   .ltorg")
        o.append("")
        o.append("   .thumb")
        for name, body in self.thumb_subs:
            o.append("   .thumb_func")
            o.append(f"{name}:")
            o.extend(body)
        o.append("")
        return "\n".join(o) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--chunks", type=int, default=400)
    ap.add_argument("--loops", type=int, default=1000)
    ap.add_argument("--caches", action="store_true",
                    help="enable PU + I/D caches and sprinkle maintenance ops")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    g = Gen(args.seed, args.chunks, args.loops, args.caches)
    text = g.generate()
    with open(args.output, "w") as f:
        f.write(text)
    print(f"{args.output}: ~{g.instr_per_loop} instructions/loop x {args.loops} loops "
          f"~= {g.instr_per_loop * args.loops / 1e6:.1f}M retired")


if __name__ == "__main__":
    main()
