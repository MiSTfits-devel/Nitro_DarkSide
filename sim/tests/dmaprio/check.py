#!/usr/bin/env python3
"""Decode rtl_state_banks.hex from a dmaprio run and apply the NITRO Tester's
own [04-02] verification algorithm to it.

The cart's checker (disassembled at 0x0201a1f8) is a three-state walk over the
LOW-priority channel's 2048-entry buffer:

  state 0: every entry must be exactly +2 on the last one. A 16-bit DMA unit is
           one read plus one write - two bus cycles - and the source is a
           counter ticking once per bus cycle. Where the sequence breaks, the
           HIGH-priority channel is presumed to have preempted: go to state 1.
  state 1: the 8 missing counter values must be the HIGH-priority channel's
           buffer, contiguous, +2 apart. Any mismatch prints NG STEP_1 and the
           test fails.
  state 2: the low-priority buffer resumes, still +2, to the end.

Reaching the end of the buffer in state 0 also passes (no preemption happened
inside the window), which is what a correct-cadence core without preemption
does. Both outcomes are reported separately below so they are not confused.
"""
import sys

BANKS = sys.argv[1] if len(sys.argv) > 1 else "rtl_state_banks.hex"
D0 = 3 * 32768          # bank D base, in 32-bit words, inside the dump
LOW_OFF = 0             # 0x06860000 - low-priority channel, 2048 units
HIGH_OFF = 0x1000 // 4  # 0x06861000 - high-priority channel, 8 units
MARK_OFF = 0x2000 // 4  # 0x06862000 - CPU markers

words = []
with open(BANKS) as f:
    for line in f:
        line = line.strip()
        if line:
            words.append(int(line, 16))

if len(words) < D0 + MARK_OFF + 4:
    sys.exit(f"{BANKS}: only {len(words)} words, expected at least {D0+MARK_OFF+4}")


def halfwords(off, n):
    out = []
    for i in range(n):
        w = words[D0 + off + i // 2]
        out.append(w & 0xFFFF if i % 2 == 0 else (w >> 16) & 0xFFFF)
    return out


mark = words[D0 + MARK_OFF:D0 + MARK_OFF + 8]
print(f"markers: ran={mark[0]:08X} (want DEADBEEF)  done={mark[1]:08X} (want C0DE0001)")
print(f"         TM3CNT_L at completion={mark[2]:08X}  poll iterations={mark[3]}")

# ---- cost decomposition: same source, cheaper destinations ----
vre = [mark[4] & 0xFFFF, mark[5] & 0xFFFF, mark[6] & 0xFFFF, mark[7] & 0xFFFF]
print(f"\nVRAM E destination (BRAM, no off-chip trip): "
      f"{' '.join(f'{v:04X}' for v in vre)}")
print(f"  per-unit cycles: {' '.join(str((vre[i+1]-vre[i]) & 0xFFFF) for i in range(3))}")

try:
    pal = []
    with open("rtl_state_pal.hex") as f:
        for line in f:
            line = line.strip()
            if line:
                pal.append(int(line, 16))
    ph = []
    for i in range(8):
        w = pal[i // 2]
        ph.append(w & 0xFFFF if i % 2 == 0 else (w >> 16) & 0xFFFF)
    print(f"\npalette destination (membus9 retires in FINISH - the fastest write "
          f"in the system):\n  {' '.join(f'{v:04X}' for v in ph)}")
    print(f"  per-unit cycles: {' '.join(str((ph[i+1]-ph[i]) & 0xFFFF) for i in range(7))}")
except FileNotFoundError:
    print("\n(rtl_state_pal.hex not found - run with DUMP_STATE=1)")

low = halfwords(LOW_OFF, 2048)
high = halfwords(HIGH_OFF, 8)

print(f"\nlow-priority buffer (0x06860000), first 16 of 2048:")
print("  " + " ".join(f"{v:04X}" for v in low[:16]))
d = [(low[i + 1] - low[i]) & 0xFFFF for i in range(15)]
print("  deltas: " + " ".join(str(x) for x in d) + "   (hardware: all 2)")

print(f"\nhigh-priority buffer (0x06861000), all 8:")
print("  " + " ".join(f"{v:04X}" for v in high))
print("  deltas: " + " ".join(str((high[i + 1] - high[i]) & 0xFFFF) for i in range(7)) +
      "   (hardware: all 2)")

uniq = sorted(set((low[i + 1] - low[i]) & 0xFFFF for i in range(2047)))
print(f"\ndistinct low-priority deltas over all 2047 steps: {uniq[:12]}"
      f"{' ...' if len(uniq) > 12 else ''}")

# ---- the cart's own state machine, verbatim ----
exp = low[0]
state = 0
hi_i = 0
verdict = None
for i in range(2048):
    if state == 0:
        if low[i] != exp:
            state = 1
        else:
            exp = (exp + 2) & 0xFFFF
            continue
    if state == 1:
        for k in range(8):
            if high[k] != exp:
                verdict = (f"FAIL  NG!:STEP_1 at low[{i}] - expected {exp:04X} in the "
                           f"high-priority buffer, found {high[k]:04X} at index {k} "
                           f"(printed AD would be {0x06861000 + k*2:08X})")
                break
            exp = (exp + 2) & 0xFFFF
        if verdict:
            break
        state = 2
    if state == 2:
        if low[i] != exp:
            verdict = (f"FAIL  NG!:STEP_2 at low[{i}] - expected {exp:04X}, "
                       f"found {low[i]:04X}")
            break
        exp = (exp + 2) & 0xFFFF

if verdict is None:
    if state == 0:
        verdict = ("PASS  the whole low-priority buffer is +2 throughout - correct "
                   "cadence, and no preemption happened inside the window")
    else:
        verdict = "PASS  cadence correct and the preemption gap matched exactly"

print("\n" + verdict)
print(f"\nfor reference, the failing board printed:  STEP_1  109449216 (=06861000) "
      f"AD: 00000001\n  i.e. it failed on the FIRST high-priority entry, index 0.")
