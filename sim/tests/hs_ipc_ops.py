#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Random IPC register-operation sequences for comparing
Nds.WholeCore.Ipc with the product nds_ipc.vhd (sim/run_clash_ipc_check.sh).

    hs_ipc_ops.py SEED COUNT OUT

One operation per line: CPU (9|7), KIND (W2 W4 R2 R4), byte address, data
(hex). Halfword and word accesses to IPCSYNC/IPCFIFOCNT, word sends and
receives. The generator tracks enough state to steer clear of the
behaviours where the product is documented to differ from GBATEK and this
Clash block (which follows GBATEK):

  * it never sends while the sender's FIFO is disabled (the product sets
    the error flag; GBATEK and melonDS do not);
  * it never reads an empty receive FIFO when the other CPU cleared it after
    this CPU's last successful receive (GBATEK returns 0; the product keeps
    the last word it popped);
  * it never has the ARM9 read a non-empty receive FIFO while the ARM9's
    FIFO is disabled (GBATEK returns the oldest word without popping; the
    product's ARM9 read path always presents the last popped word);
  * it never clears a non-empty send FIFO in the same IPCFIFOCNT write that
    turns the send-empty IRQ off while it was on (the product evaluates the
    IF.17 edge with the old enable and raises it; GBATEK's edge rule and
    melonDS do not).

Byte accesses (rejected by the Clash block) are not generated.
"""
import random
import sys

SYNC, CNT, SEND, RECV = 0x04000180, 0x04000184, 0x04000188, 0x04100000


def main():
    seed, count, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    rng = random.Random(seed)
    en = {9: False, 7: False}
    sirq = {9: False, 7: False}
    fifo = {9: 0, 7: 0}            # words in each CPU's send FIFO
    cleared = {9: False, 7: False}  # receive FIFO cleared since this CPU's last pop
    lines = []
    for _ in range(count):
        c = rng.choice([9, 7])
        o = 7 if c == 9 else 9
        k = rng.random()
        if k < 0.15:
            v = rng.choice([0, 0x0100, 0x0F00, 0x4000, 0x6000, 0x2000, 0x4500, 0x6A00]) | rng.choice([0, 0x0300])
            lines.append("%d %s %08x %08x" % (c, rng.choice(["W2", "W4"]), SYNC, v))
        elif k < 0.25:
            lines.append("%d %s %08x 00000000" % (c, rng.choice(["R2", "R4"]), SYNC))
        elif k < 0.40:
            v = 0
            if rng.random() < 0.8:
                v |= 0x8000
            if rng.random() < 0.5:
                v |= 0x0004
            if rng.random() < 0.5:
                v |= 0x0400
            if rng.random() < 0.3:
                v |= 0x4000
            if rng.random() < 0.15 and not (sirq[c] and not v & 0x0004 and fifo[c] > 0):
                v |= 0x0008
                fifo[c] = 0
                cleared[o] = True
            en[c] = bool(v & 0x8000)
            sirq[c] = bool(v & 0x0004)
            lines.append("%d %s %08x %08x" % (c, rng.choice(["W2", "W4"]), CNT, v))
        elif k < 0.55:
            lines.append("%d %s %08x 00000000" % (c, rng.choice(["R2", "R4"]), CNT))
        elif k < 0.80:
            if not en[c]:
                continue
            lines.append("%d W4 %08x %08x" % (c, SEND, rng.getrandbits(32)))
            fifo[c] = min(16, fifo[c] + 1)
        else:
            if fifo[o] == 0 and cleared[c]:
                continue
            if c == 9 and not en[9] and fifo[o] > 0:
                continue
            lines.append("%d R4 %08x 00000000" % (c, RECV))
            if en[c] and fifo[o] > 0:
                fifo[o] -= 1
                cleared[c] = False
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
