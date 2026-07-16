#!/usr/bin/env python3
"""Compare two ARM9 instruction traces (RTL sim vs melonDS) line by line.

Each line: <pc> <opcode> <cpsr> <r0> .. <r14>  (hex, space-separated).
Reports the first divergence with surrounding context and exits nonzero.

Usage: compare_trace.py rtl_trace.log melonds_trace.log [--context 5]
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
    args = ap.parse_args()

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
            if a != b:
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
