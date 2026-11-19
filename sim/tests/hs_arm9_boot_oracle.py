#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Synthetic DS boot image and independent expectations for hs_arm9_boot.S.

The image follows the NDS cartridge header layout (GBATEK "DS Cartridge
Header"; melonDS NDS_Header.h): title 0x000, game code 0x00C, maker 0x010,
ARM9 ROM offset / entry / RAM address / size at 0x020 / 0x024 / 0x028 /
0x02C, ARM7 fields 0x030-0x03F (left zero: no ARM7 binary), used ROM size
0x080, header size 0x084, header CRC16 (poly 0xA001, init 0xFFFF, over
0x000-0x15D) at 0x15E. The Nintendo logo area and its CRC are left zero, so
the image contains no commercial data. The ARM9 binary is the assembled
hs_arm9_boot_payload.S, placed at ROM offset 0x8000; filler is arithmetic.

From the image bytes alone this script derives what each build must store,
the card word addresses the slot must fetch, and the instructions the CPU
must retire from RAM: the binary's words from the entry up to its first
`b .` (0xEAFFFFFE), which then repeats. It shares no code with the Clash
model or the loader.

  boot_oracle.py image PAYLOAD.bin ENTRY_OFFSET VARIANT OUT.hex
  boot_oracle.py bootrom LOADER.bin PAYLOAD.bin ENTRY_OFFSET VARIANT OUT.hex
  boot_oracle.py expected direct|raw PAYLOAD.bin ENTRY_OFFSET VARIANT
  boot_oracle.py romlog PAYLOAD.bin ENTRY_OFFSET VARIANT
  boot_oracle.py trace PAYLOAD.bin ENTRY_OFFSET
VARIANT: good | badcrc (one title byte changed after the CRC was computed)
| badentry (entry one word past the binary, CRC recomputed).
"""
import sys

SIZE = 0x10000
ROM_OFFSET = 0x8000
RAM = 0x02000400
HANDOFF = 0xE00
B_SELF = 0xEAFFFFFE

def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc

def put32(buf, off, v):
    buf[off:off + 4] = (v & 0xFFFFFFFF).to_bytes(4, "little")

def get32(buf, off):
    return int.from_bytes(buf[off:off + 4], "little")

def image(payload, entry_off, variant):
    rom = bytearray(SIZE)
    for a in range(0x200, SIZE, 4):
        put32(rom, a, (a * 0x9E3779B1) ^ 0xB007B007)
    rom[0:0x200] = bytes(0x200)
    rom[0x000:0x00C] = b"HSNITRO BOOT"
    rom[0x00C:0x010] = b"HSNB"
    rom[0x010:0x012] = b"00"
    size = (len(payload) + 3) & ~3
    entry = RAM + entry_off + (size - entry_off if variant == "badentry" else 0)
    put32(rom, 0x020, ROM_OFFSET)
    put32(rom, 0x024, entry)
    put32(rom, 0x028, RAM)
    put32(rom, 0x02C, size)
    put32(rom, 0x080, ROM_OFFSET + size)
    put32(rom, 0x084, 0x4000)
    rom[0x15E:0x160] = crc16(rom[0:0x15E]).to_bytes(2, "little")
    if variant == "badcrc":
        rom[0x005] ^= 0x01
    rom[ROM_OFFSET:ROM_OFFSET + len(payload)] = payload
    return rom

def h33(words):
    h = 0
    for w in words:
        h = (h * 33 + w) & 0xFFFFFFFF
    return h

def expected(mode, rom):
    hdr = rom[0:0x200]
    crc, stored = crc16(hdr[0:0x15E]), get32(hdr, 0x15E) & 0xFFFF
    m = [(crc, "CRC16 of the header, computed"), (stored, "header CRC16 field (0x15E)")]
    if crc != stored:
        return m + [(0xE001, "rejected: header CRC")]
    off, entry, ram, size = (get32(hdr, o) for o in (0x20, 0x24, 0x28, 0x2C))
    m += [(off, "ARM9 ROM offset"), (entry, "ARM9 entry"), (ram, "ARM9 RAM address"),
          (size, "ARM9 size")]
    if mode == "raw":
        return m + [(get32(hdr, 0x0C), "game code 'HSNB'"),
                    (0, "words differing from the boot-ROM handoff copy")]
    if not (ram <= entry < ram + size):
        return m + [(0xE004, "rejected: entry outside the binary")]
    words = [get32(rom, off + 4 * k) for k in range(size // 4)]
    m += [(len(words), "words copied into RAM"), (h33(words), "their checksum (h * 33 + w)")]
    table = [get32(rom, off + 4 * k) for k in range(8)]
    total = sum(table) & 0xFFFFFFFF
    m += [(ram, "payload: RAM address handed over in r0"), (size, "payload: size in r1"),
          (crc, "payload: header CRC in r2"), (entry, "payload: ADR of its entry"),
          (0x600DCAFE, "payload: literal from its RAM pool"),
          (total, "payload: sum of the 8-word table it was loaded with"),
          (total ^ 0x600DCAFE, "payload: table word 0 rewritten and read back"),
          (0x5A, "payload: done marker")]
    return m

def romlog(rom):
    off, entry, ram, size = (get32(rom, o) for o in (0x20, 0x24, 0x28, 0x2C))
    if crc16(rom[0:0x15E]) != get32(rom, 0x15E) & 0xFFFF or not (ram <= entry < ram + size):
        return []
    blocks = (size + 0x1FF) // 0x200
    return [off + 0x200 * b + 4 * k for b in range(blocks) for k in range(128)]

def trace(rom):
    off, entry, ram = get32(rom, 0x20), get32(rom, 0x24), get32(rom, 0x28)
    out, pc = [], entry
    while True:
        w = get32(rom, off + pc - ram)
        out.append((pc, w))
        if w == B_SELF:
            return out
        pc += 4

def main():
    a = sys.argv[1:]
    try:
        cmd = a[0]
        if cmd == "bootrom":
            loader = open(a[1], "rb").read()
            rom = image(open(a[2], "rb").read(), int(a[3], 0), a[4])
            assert len(loader) <= HANDOFF, "loader overlaps the handoff header"
            boot = bytearray(0x1000)
            boot[0:len(loader)] = loader
            boot[HANDOFF:HANDOFF + 0x200] = rom[0:0x200]
            with open(a[5], "w") as f:
                for k in range(0, 0x1000, 4):
                    f.write("%08x\n" % get32(boot, k))
            return
        if cmd == "expected":
            rom = image(open(a[2], "rb").read(), int(a[3], 0), a[4])
            for k, (v, note) in enumerate(expected(a[1], rom)):
                print("%08x  # %-2d %s" % (v, k, note))
            return
        rom = image(open(a[1], "rb").read(), int(a[2], 0), a[3] if len(a) > 3 else "good")
        if cmd == "image":
            with open(a[4], "w") as f:
                for k in range(0, SIZE, 4):
                    f.write("%08x\n" % get32(rom, k))
        elif cmd == "romlog":
            for x in romlog(rom):
                print("%08x" % x)
        elif cmd == "trace":
            for pc, w in trace(rom):
                print("%08x %08x" % (pc, w))
        else:
            raise IndexError
    except (IndexError, ValueError):
        sys.exit(__doc__)

if __name__ == "__main__":
    main()
