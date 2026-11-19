#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Independent expectations for sim/tests/hs_arm9_card.S.

Builds the synthetic 64 KiB test cartridge (no commercial data: an ASCII
title and code, then arithmetic filler) and computes, from the NTR protocol
as melonDS implements it (NDSCart.cpp WriteROMCnt/ReadROMData,
NDSCart/CartCommon.cpp ROMCommandStart/ROMCommandReceive/ROMRead32), the
mailbox each build of the fixture must store and the ROM word addresses the
slot must fetch. It shares no code with the Clash model.

  hs_arm9_card_oracle.py image OUT.hex        cartridge words, little-endian
  hs_arm9_card_oracle.py expected raw|direct  mailbox, one word per line
  hs_arm9_card_oracle.py romlog raw|direct    fetched word addresses
"""
import sys

SIZE = 0x10000
MASK = SIZE - 1
CHIP_ID = 0x00001FC2

def image():
    rom = bytearray(SIZE)
    for i in range(0x200):
        rom[i] = (i * 37 + 11 + 0x55 * (i >> 8)) & 0xFF
    rom[0x000:0x00C] = b"HSNITRO CARD"
    rom[0x00C:0x010] = b"HSNT"
    rom[0x010:0x012] = b"00"
    for a in range(0x200, SIZE, 4):
        w = ((a * 0x01000193) ^ 0x5EED0000 ^ a) & 0xFFFFFFFF
        rom[a:a + 4] = w.to_bytes(4, "little")
    return rom

ROM = image()

def word(a):
    return int.from_bytes(ROM[a:a + 4], "little")

def size_words(size):
    return 0 if size == 0 else 1 if size == 7 else (0x100 << size) // 4

# Cart command semantics (melonDS CartCommon), per transfer.
class Cart:
    def __init__(self):
        self.log = []

    def header(self, addr, n):           # raw mode 00: ROMAddr &= 0xFFF, page 0
        lo = addr & 0xFFF
        out = []
        for _ in range(n):
            self.log.append(lo)
            out.append(word(lo))
            lo = (lo + 4) & 0xFFF
        return out

    def b7(self, addr, n):               # data mode B7
        a = addr & MASK
        if a < 0x8000:
            a = 0x8000 + (a & 0x1FF)
        hi, lo = a & MASK & ~0xFFF, a & 0xFFF
        out = []
        for _ in range(n):
            self.log.append(hi | lo)
            out.append(word(hi | lo))
            lo = (lo + 4) & 0xFFF
        return out

# The fixture's xfer routine: checksum h = h * 33 + w (mod 2^32), AND, first,
# last, the word at a capture index, and the number of words read.
def xfer(words, capture):
    h, a = 0, 0xFFFFFFFF
    for w in words:
        h = (h * 33 + w) & 0xFFFFFFFF
        a &= w
    cap = words[capture] if capture < len(words) else 0
    first = words[0] if words else 0
    last = words[-1] if words else 0
    return dict(h=h, a=a, first=first, last=last, cap=cap, n=len(words))

IF_CARD = 0x00080000

def raw():
    c = Cart()
    m = [(0xC000, "AUXSPICNT after writing C000"),
         (0x20000000, "ROMCTRL after releasing cart reset (bit 29)")]
    t1 = xfer([0xFFFFFFFF] * size_words(1), 0)
    m += [(t1["a"], "9F x 0x200 bytes: AND of all words"),
          (t1["n"], "9F words read"),
          (1, "IRQ handler entered once for the 9F transfer"),
          (IF_CARD, "handler's IF & IE: card transfer done")]
    m += [(IF_CARD, "size-0 9F transfer: IF bit 19 after busy clears")]
    t3 = xfer(c.header(0, size_words(1)), 3)
    m += [(t3["h"], "00 header at 0, 0x200 bytes: checksum"),
          (t3["first"], "header word 0: 'HSNI'"),
          (t3["cap"], "header word 3: game code 'HSNT'"),
          (t3["last"], "header word at 0x1FC")]
    m += [(0xA7800000, "90 chip ID: ROMCTRL busy, word ready, size 7, bit 29"),
          (CHIP_ID, "90 chip ID"),
          (IF_CARD, "IF bit 19 after the chip-ID transfer"),
          (0x27000000, "ROMCTRL after it: busy and ready clear")]
    product = len(m)
    t5 = xfer(c.header(0xF00, size_words(1)), 64)
    m += [(t5["h"], "00 header at F00: checksum (wraps inside 4 KiB)"),
          (t5["first"], "word at F00"),
          (t5["cap"], "word 64 wraps to 000"),
          (t5["last"], "last word at 0FC")]
    return m, product, c.log

def direct():
    c = Cart()
    m = [(0xC000, "AUXSPICNT after writing C000")]
    d1 = xfer(c.b7(0x8000, size_words(1)), 64)
    m += [(d1["h"], "B7 8000 x 0x200 bytes: checksum"),
          (d1["first"], "word at 8000"),
          (d1["cap"], "word 64 at 8100"),
          (d1["last"], "word at 81FC"),
          (1, "IRQ handler entered once for that transfer"),
          (IF_CARD, "handler's IF & IE: card transfer done")]
    for addr, note in [(0x00000200, "B7 200 redirects to 8000"),
                       (0x00001FFC, "B7 1FFC redirects to 81FC"),
                       (0x00010100, "B7 10100 mirrors to 100, redirects to 8100"),
                       (0x0001C000, "B7 1C000 mirrors to C000")]:
        m.append((c.b7(addr, 1)[0], note))
    d6 = xfer(c.b7(0xC000, size_words(2)), 0)
    m += [(d6["h"], "B7 C000 x 0x400 bytes: checksum"),
          (d6["last"], "word at C3FC")]
    m += [(0xA7800000, "B8 chip ID: ROMCTRL busy, word ready, size 7, bit 29"),
          (CHIP_ID, "B8 chip ID"),
          (IF_CARD, "IF bit 19 after the chip-ID transfer"),
          (0x27000000, "ROMCTRL after it: busy and ready clear")]
    product = len(m)
    m += [(0x8000, "AUXSPICNT at power-up after direct boot"),
          (0x20000000, "ROMCTRL at power-up after direct boot")]
    d8 = xfer(c.b7(0xAF00, size_words(1)), 64)
    m += [(d8["h"], "B7 AF00 x 0x200 bytes: checksum (wraps inside 4 KiB)"),
          (d8["cap"], "word 64 wraps to A000"),
          (d8["last"], "last word at A0FC")]
    return m, product, c.log

def main():
    if len(sys.argv) == 3 and sys.argv[1] == "image":
        with open(sys.argv[2], "w") as f:
            for a in range(0, SIZE, 4):
                f.write("%08x\n" % word(a))
        return
    if len(sys.argv) != 3 or sys.argv[2] not in ("raw", "direct"):
        sys.exit(__doc__)
    m, product, log = (raw if sys.argv[2] == "raw" else direct)()
    if sys.argv[1] == "expected":
        for k, (v, note) in enumerate(m):
            tag = "" if k < product else " [slice only]"
            print("%08x  # %-2d %s%s" % (v, k, note, tag))
    elif sys.argv[1] == "romlog":
        for a in log:
            print("%08x" % a)
    elif sys.argv[1] == "product-words":
        print(product)
    else:
        sys.exit(__doc__)

if __name__ == "__main__":
    main()
