#!/usr/bin/env python3
"""Compare two ARM9 instruction traces (RTL sim vs melonDS) line by line.

Each line: <pc> <opcode> <cpsr> <r0> .. <r14>  (hex, space-separated).
Reports the first divergence with surrounding context and exits nonzero.
Case is folded: the RTL writes uppercase hex and melonDS lowercase, so without
that every comparison "diverges" on line 1.

    compare_trace.py rtl_trace.log melonds_trace.log [--context 5]
    compare_trace.py rtl.log melon.log --ignore cpsr,r13,r14

**Direct boot now compares with NOTHING ignored - do not reach for --ignore.**
That used to read "against a melonDS trace you almost always want
`--ignore cpsr,r13,r14`", because melonDS preset SP and LR at boot while the
RTL started from reset values, so those columns differed from instruction 1.
nds_top's boot FSM presets r12/r13/r14 and the banked stacks to match
SetupDirectBoot, and a direct-boot trace is now column-for-column identical
from instruction 1 - verified at 300k instructions on the NITRO Tester cart
(docs/NTR_EVA_TESTER.md). So if a direct-boot comparison only passes with those
ignores, that is a REAL divergence, not a boot-state artefact; the ignores hide
exactly the class of bug this script exists to find.

Firmware boot (FWBOOT=1) is the exception: it deliberately presets only the PC,
because there the ARM7/ARM9 BIOS sets up its own stacks. Those traces can still
differ in r13 until the BIOS stack setup has run.

Two RTL traces should always be compared with nothing ignored.
"""
import argparse
import itertools
import sys

FIELDS = ["pc", "opcode", "cpsr"] + [f"r{i}" for i in range(15)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rtl")
    ap.add_argument("ref")
    ap.add_argument("--context", type=int, default=5)
    ap.add_argument("--ignore", default="",
                    help="comma-separated field names to skip, e.g. cpsr,r13,r14")
    args = ap.parse_args()

    ignore = [f.strip() for f in args.ignore.split(",") if f.strip()]
    unknown = [f for f in ignore if f not in FIELDS]
    if unknown:
        print(f"unknown field(s) in --ignore: {', '.join(unknown)}")
        print(f"known fields: {', '.join(FIELDS)}")
        return 2
    keep = [i for i, f in enumerate(FIELDS) if f not in ignore]
    if ignore:
        print(f"ignoring {', '.join(ignore)}", file=sys.stderr)

    history = []
    n = 0
    with open(args.rtl) as fa, open(args.ref) as fb:
        for la, lb in itertools.zip_longest(fa, fb):
            n += 1
            if la is None or lb is None:
                short = args.rtl if la is None else args.ref
                print(f"trace length mismatch at line {n}: {short} ended first")
                return 1
            a, b = la.lower().split(), lb.lower().split()
            # `keep` indexes FIELDS, so a short line (fewer columns than
            # FIELDS) simply contributes nothing for the missing ones rather
            # than raising - a truncated final line is common on a killed run.
            if [a[i] for i in keep if i < len(a)] != [b[i] for i in keep if i < len(b)]:
                print(f"DIVERGENCE at instruction {n}")
                for h in history[-args.context:]:
                    print(f"  ... {h.rstrip()}")
                print(f"  rtl: {la.rstrip()}")
                print(f"  ref: {lb.rstrip()}")
                for f, va, vb in zip(FIELDS, a, b):
                    if va != vb:
                        print(f"  field {f}: rtl={va} ref={vb}")
                return 1
            history.append(la)
            if len(history) > args.context:
                history.pop(0)
            if n % 1000000 == 0:
                print(f"  {n} instructions identical...", file=sys.stderr)
    print(f"OK: {n} instructions, zero divergence")
    return 0


if __name__ == "__main__":
    sys.exit(main())
