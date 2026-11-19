#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare ordered ABI2 transactions and committed mailbox words, not clocks."""
import re
import sys
from pathlib import Path

ACCESS = re.compile(r'ARM9 -> Haskell cycle=\d+ ([RW])(\d+) ([0-9a-fA-F]{8}) ([0-9a-fA-F]{8})')
MAIL = re.compile(r'ARM9 RAM\[\s*(\d+)\]=([0-9a-fA-F]{8})')


def parse(path):
    text = Path(path).read_text()
    accesses = [(d, int(w), int(a, 16), int(v, 16)) for d, w, a, v in ACCESS.findall(text)]
    mailbox = [(int(a), int(v, 16)) for a, v in MAIL.findall(text)]
    if len(accesses) != 10 or len(mailbox) != 6:
        raise SystemExit(f'{path}: expected 10 GPU accesses and 6 mailbox stores, got {len(accesses)} and {len(mailbox)}')
    if [a for a, _ in mailbox] != list(range(0, 24, 4)):
        raise SystemExit(f'{path}: mailbox addresses/order invalid: {mailbox}')
    return accesses, mailbox


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: compare_hs_arm9_witness.py PRODUCT_LOG CLASH_LOG')
    product, clash = (parse(p) for p in sys.argv[1:])
    for label, left, right in zip(('GPU access', 'mailbox store'), product, clash):
        for i, (a, b) in enumerate(zip(left, right)):
            if a != b:
                raise SystemExit(f'{label} {i} mismatch: product={a}, Clash={b}')
    print('PASS: 10 ordered GPU ABI2 accesses and 6 mailbox stores match product (cycles ignored)')


if __name__ == '__main__':
    main()
