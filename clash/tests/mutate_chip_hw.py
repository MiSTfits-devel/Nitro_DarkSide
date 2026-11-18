#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
"""Mutation test for the chip hardware's gate ("clash/tests/run_chip_hw_check.sh").

Each mutant is one plausible single edit of ``clash/src/Nds/Gpu3D/ChipHw.hs`` (the
composition only: the four blocks are untouched). The mutant is applied to a private
copy of ``clash/src`` and the gate is run on the ``tiny`` case; the mutant is killed
when the gate fails, and a survivor is reported with its name.

    clash/tests/mutate_chip_hw.py [NAME...]
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "src")
TARGET = "Nds/Gpu3D/ChipHw.hs"

# (name, old text, new text). Each is one edit of the composition.
MUTANTS = [
    ("tag-fifo-owner",
     "    owner = C.head (atTags s) :: Maybe (Index n)",
     "    owner = (atTags s) C.!! (1 :: Index 32) :: Maybe (Index n)"),
    ("queue-full",
     "    readies = C.map (\\q -> qCnt q < 4) qs",
     "    readies = C.map (const True) qs"),
    ("tag-room",
     "    served = isJust outReq && memReady && (not isRead || room)",
     "    served = isJust outReq && memReady"),
    ("arbiter-base",
     "    fwd = addBase base <$> outReq",
     "    fwd = outReq"),
    ("poly-grant-queue",
     "    polyMemRdy = at4 (0 :: Index 4) memRdyV",
     "    polyMemRdy = at4 (1 :: Index 4) memRdyV"),
    ("drain-cmd-valid",
     "    drained = not (coGeomBusy o) && not (coCmdValid o) && coBusReady o",
     "    drained = not (coGeomBusy o)"),
    ("entries-count",
     ", dEntries = dEntries d + fromEnum (coCmdAccept o)",
     ", dEntries = dEntries d + fromEnum (coCmdValid o)"),
    ("table-swap-address",
     "    o = TOut aJ eJ fJ (if done then Just (regs, desc) else Nothing)",
     "    o = TOut eJ aJ fJ (if done then Just (regs, desc) else Nothing)"),
    ("table-copy-wait",
     "        | tiGo i && tiIdle i && tiOk i -> s { tsPh = TRead, tsJ = 0 }",
     "        | tiGo i && tiIdle i -> s { tsPh = TRead, tsJ = 0 }"),
    ("list-swap-pending",
     "    wantList = (\\g r s v -> g && r && s && v)",
     "    wantList = (\\g r s _ -> g && r && s)"),
    ("swap-pending-bit",
     "    geoStatus = (\\g w -> g { gsBusy = w }) <$> (goStatus <$> geoOut) <*> swapPend",
     "    geoStatus = (\\g w -> g { gsBusy = w }) <$> (goStatus <$> geoOut) <*> (poOverflow <$> po)"),
    ("power-off-list",
     "          _ -> if off then 0 else c)",
     "          _ -> c)"),
]


def copy_src(dest):
    shutil.copytree(SRC, dest)
    return dest


def apply(src, old, new):
    path = os.path.join(src, TARGET)
    with open(path) as f:
        text = f.read()
    if text.count(old) != 1:
        raise SystemExit("mutant text %r occurs %d times" % (old, text.count(old)))
    with open(path, "w") as f:
        f.write(text.replace(old, new))


def run(src, work):
    env = dict(os.environ)
    env["TMPDIR"] = work
    env["CSRC"] = src
    env["KINDS"] = "tiny"
    env["SEQS"] = "0"
    env["FUZZ"] = "0"
    env["REUSE"] = "0"
    return subprocess.run(
        [os.path.join(HERE, "run_chip_hw_check.sh")],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def main(argv):
    wanted = argv[1:]
    base = tempfile.mkdtemp(prefix="nds-chip-hw-mut-")
    clean = copy_src(os.path.join(base, "clean"))
    clean_work = os.path.join(base, "clean-work")
    res = run(clean, clean_work)
    if res.returncode != 0:
        print("the unmutated gate fails; run it first:")
        print(res.stdout.decode()[-2000:])
        return 1
    print("clean: gate passes")
    killed = 0
    for i, (name, old, new) in enumerate(MUTANTS):
        if wanted and name not in wanted:
            continue
        src = copy_src(os.path.join(base, name))
        apply(src, old, new)
        work = os.path.join(base, name + "-work")
        # Reuse the clean object directory so only this module recompiles.
        shutil.copytree(clean_work, work)
        res = run(src, work)
        dead = res.returncode != 0
        killed += 1 if dead else 0
        line = [l for l in res.stdout.decode().splitlines() if l]
        first = line[0] if line else "(no output)"
        print("%-2d %-20s %s  %s" % (i, name, "killed  " if dead else "SURVIVED", first))
    print("mutants: %d, killed %d, survived %d"
          % (len([m for m in MUTANTS if not wanted or m[0] in wanted]), killed,
             len([m for m in MUTANTS if not wanted or m[0] in wanted]) - killed))
    return 0 if killed == len([m for m in MUTANTS if not wanted or m[0] in wanted]) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
