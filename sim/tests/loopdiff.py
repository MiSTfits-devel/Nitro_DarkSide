#!/usr/bin/env python3
"""Find the first genuine control-flow divergence between two CPU traces.

    sim/tests/loopdiff.py <rtl_trace> <melonds_trace> [max_instructions]

Both files are the shared trace format (docs/TRACE_DIFF.md):
`<pc> <opcode> <cpsr> <r0>..<r14>`, one line per retired instruction. The RTL
writes uppercase hex and melonDS lowercase, so everything here is folded to
lowercase first.

WHY THIS EXISTS, and why plain `diff` / instruction-indexed comparison is the
wrong tool for BIOS and firmware boot code:

Both CPUs spend most of the boot inside cross-CPU polling loops - the IPCSYNC
handshake at 0x04000180 is the big one. How many times a CPU spins in such a
loop depends entirely on how far the *other* CPU has progressed, and that
relative timing legitimately differs between the RTL and melonDS: they are not
cycle-equivalent and were never intended to be. So an instruction-indexed diff
"diverges" on the very first poll and every number it reports afterwards is
meaningless. Doing exactly that once cost this project a false root cause:
"the ARM7 reads IPCSYNC = 1 where melonDS reads 0" looked like a wiring bug in
nds_ipc, and was nothing but a different spin count.

What is actually comparable is the ORDER OF BASIC BLOCKS each CPU executes.
This collapses runs of a repeated PC, then squashes whole repeated loop bodies
(up to 25 blocks long), and reports the first block where the two orders differ
along with the shared path leading in and each side's continuation. That points
at a specific conditional branch, and from there the differing input value is
usually two or three loads back.

Real find, for calibration: RTC status1 powered up as 0x02 instead of 0x82
(bit 7, power-off detect, which the ARM7 BIOS branches on to pick cold boot vs
warm boot). Raw diff blamed IPCSYNC at ARM7 instruction 18459; this tool put it
at pc 0x2216, five instructions from the load that actually differed.
"""
import sys


def collapse(path, limit):
    """Trace -> list of (pc, first_instruction_index) with loops squashed."""
    seq = []
    prev = None
    for i, line in enumerate(open(path)):
        if i >= limit:
            break
        pc = line.split(None, 1)[0].lower()
        if pc == prev:
            continue          # same PC repeated back-to-back (stall/multi-cycle)
        prev = pc
        seq.append((pc, i + 1))
    out = []
    for item in seq:
        out.append(item)
        # if the last k blocks repeat the k before them, drop the repetition;
        # this turns any loop of period <= 25 into one pass through its body
        for k in range(1, 26):
            if len(out) >= 2 * k and \
               [p for p, _ in out[-k:]] == [p for p, _ in out[-2 * k:-k]]:
                del out[-k:]
                break
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 20_000_000
    a = collapse(sys.argv[1], limit)
    b = collapse(sys.argv[2], limit)
    print("collapsed: %s %d blocks, %s %d blocks"
          % (sys.argv[1], len(a), sys.argv[2], len(b)))
    for i in range(min(len(a), len(b))):
        if a[i][0] != b[i][0]:
            print("first CONTROL-FLOW divergence at collapsed block %d" % i)
            print("  A pc=%s (A instruction %d)" % a[i])
            print("  B pc=%s (B instruction %d)" % b[i])
            print("  common path in: ", " ".join(p for p, _ in a[max(0, i - 12):i]))
            print("  A continues:    ", " ".join(p for p, _ in a[i:i + 12]))
            print("  B continues:    ", " ".join(p for p, _ in b[i:i + 12]))
            print("\nNext step: dump both traces with registers around those "
                  "instruction indices and walk back from the branch to the "
                  "load whose value differs.")
            return 1
    print("no control-flow divergence in the common %d blocks"
          % min(len(a), len(b)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
