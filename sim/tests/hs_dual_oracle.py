#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Synthetic two-CPU DS image and independent expectations for the dual
fixture (hs_dual_boot9.S, hs_dual_boot7.S, hs_dual_arm9.S, hs_dual_arm7.S).

The image follows the cartridge header layout of hs_arm9_boot_oracle.py
with both binaries: ARM9 fields 0x020-0x02C (ROM 0x8000, RAM 0x02000400),
ARM7 fields 0x030-0x03C (ROM 0x8000 + the ARM9 size rounded up to 0x200,
RAM 0x02000900), header CRC16 at 0x15E. Expectations come from this
script's own model of the IPC registers (GBATEK "DS Inter Process
Communication": IPCSYNC, IPCFIFOCNT flags, error on full send / empty
receive with the FIFO enabled, sends dropped without error when disabled,
an empty receive returns the last received word or 0 after a clear, IF.17
on (CNT.2 and send empty) going 0 to 1, IF.18 on (CNT.10 and receive not
empty) going 0 to 1), replaying the guests' operations in the order their
IPCSYNC handshakes force, and from the data patterns the guests use. It
shares no code with the Clash model.

  hs_dual_oracle.py image   ARM9.bin ENTRY9 ARM7.bin ENTRY7 OUT.hex
  hs_dual_oracle.py boot9   LOADER9.bin ARM9.bin ENTRY9 ARM7.bin ENTRY7 OUT.hex
  hs_dual_oracle.py boot7   LOADER7.bin OUT.hex
  hs_dual_oracle.py expected 9|7 ARM9.bin ENTRY9 ARM7.bin ENTRY7

ENTRY9 / ENTRY7 are entry offsets inside each binary.
"""
import sys

SIZE = 0x10000
RAM9 = 0x02000400
RAM7 = 0x02000900
HANDOFF = 0xE00
M = 0xFFFFFFFF


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def put32(buf, off, v):
    buf[off:off + 4] = (v & M).to_bytes(4, "little")


def get32(buf, off):
    return int.from_bytes(buf[off:off + 4], "little")


def words_of(data):
    data = bytes(data) + bytes(-len(data) % 4)
    return [get32(data, k) for k in range(0, len(data), 4)]


def image(bin9, e9, bin7, e7):
    rom = bytearray(SIZE)
    for a in range(0x200, SIZE, 4):
        put32(rom, a, (a * 0x9E3779B1) ^ 0xD0A1D0A1)
    rom[0:0x200] = bytes(0x200)
    rom[0x000:0x00C] = b"HSNITRO DUAL"
    rom[0x00C:0x010] = b"HSND"
    rom[0x010:0x012] = b"00"
    size9 = (len(bin9) + 3) & ~3
    size7 = (len(bin7) + 3) & ~3
    off9 = 0x8000
    off7 = off9 + ((size9 + 0x1FF) & ~0x1FF)
    for o, v in ((0x20, off9), (0x24, RAM9 + e9), (0x28, RAM9), (0x2C, size9),
                 (0x30, off7), (0x34, RAM7 + e7), (0x38, RAM7), (0x3C, size7),
                 (0x80, off7 + size7), (0x84, 0x4000)):
        put32(rom, o, v)
    rom[0x15E:0x160] = crc16(rom[0:0x15E]).to_bytes(2, "little")
    rom[off9:off9 + len(bin9)] = bin9
    rom[off7:off7 + len(bin7)] = bin7
    for k in range(len(bin9), size9):
        rom[off9 + k] = 0
    for k in range(len(bin7), size7):
        rom[off7 + k] = 0
    return rom


def h33(words):
    h = 0
    for w in words:
        h = (h * 33 + w) & M
    return h


class Side:
    def __init__(self):
        self.out = 0
        self.ien = False
        self.sirq = False
        self.rirq = False
        self.err = False
        self.en = False
        self.last = 0
        self.fifo = []          # this side's send FIFO
        self.c17 = False
        self.c18 = False
        self.irqs = []          # IF bits raised, in order


class Ipc:
    """Register-level IPC model, one operation at a time."""

    def __init__(self):
        self.s = {9: Side(), 7: Side()}

    def other(self, c):
        return 7 if c == 9 else 9

    def edges(self):
        for c in (9, 7):
            me, them = self.s[c], self.s[self.other(c)]
            c17 = me.sirq and not me.fifo
            c18 = me.rirq and bool(them.fifo)
            if c17 and not me.c17:
                me.irqs.append(17)
            if c18 and not me.c18:
                me.irqs.append(18)
            me.c17, me.c18 = c17, c18

    def sync_write(self, c, v):
        me, them = self.s[c], self.s[self.other(c)]
        me.out = (v >> 8) & 0xF
        me.ien = bool(v & 0x4000)
        if v & 0x2000 and them.ien:
            them.irqs.append(16)
        self.edges()

    def sync_read(self, c):
        me, them = self.s[c], self.s[self.other(c)]
        return them.out | (me.out << 8) | (0x4000 if me.ien else 0)

    def cnt_write(self, c, v):
        me, them = self.s[c], self.s[self.other(c)]
        if v & 8:
            me.fifo = []
            them.last = 0
        me.sirq = bool(v & 4)
        me.rirq = bool(v & 0x400)
        me.en = bool(v & 0x8000)
        if v & 0x4000:
            me.err = False
        self.edges()

    def cnt_read(self, c):
        me, them = self.s[c], self.s[self.other(c)]
        v = (1 if not me.fifo else 0) | (2 if len(me.fifo) == 16 else 0) | (4 if me.sirq else 0)
        v |= (0x100 if not them.fifo else 0) | (0x200 if len(them.fifo) == 16 else 0)
        v |= (0x400 if me.rirq else 0) | (0x4000 if me.err else 0) | (0x8000 if me.en else 0)
        return v

    def send(self, c, w):
        me = self.s[c]
        if me.en:
            if len(me.fifo) == 16:
                me.err = True
            else:
                me.fifo.append(w & M)
        self.edges()

    def recv(self, c):
        me, them = self.s[c], self.s[self.other(c)]
        if not me.en:
            v = them.fifo[0] if them.fifo else me.last
        elif not them.fifo:
            me.err = True
            v = me.last
        else:
            v = them.fifo.pop(0)
            me.last = v
        self.edges()
        return v


class Cpu:
    """A guest's IRQ handler bookkeeping (hs_dual_arm9.S / hs_dual_arm7.S)."""

    def __init__(self, ipc, c):
        self.ipc, self.c = ipc, c
        self.syncs = self.sends = self.recvs = self.words = self.sum = 0
        self.syncin = 0
        self.ie = 0x70000

    def service(self):
        """Take every pending IRQ the handler would see (IE & IF)."""
        side = self.ipc.s[self.c]
        while side.irqs:
            bit = side.irqs.pop(0)
            if bit == 16:
                self.syncs += 1
                self.syncin = self.ipc.sync_read(self.c) & 0xF
            elif bit == 17:
                self.sends += 1
            elif bit == 18:
                self.recvs += 1
                while not self.ipc.cnt_read(self.c) & 0x100:
                    w = self.ipc.recv(self.c)
                    self.sum = (self.sum * 33 + w) & M
                    self.words += 1
            # The handler acknowledges what it saw; edges raised by its own
            # draining (the other side's) are serviced by the other CPU.


def expected(rom):
    hdr = rom[0:0x200]
    crc, stored = crc16(hdr[0:0x15E]), get32(hdr, 0x15E) & 0xFFFF
    off9, size9, off7, size7 = (get32(hdr, o) for o in (0x20, 0x2C, 0x30, 0x3C))
    w9 = [get32(rom, off9 + 4 * k) for k in range(size9 // 4)]
    w7 = [get32(rom, off7 + 4 * k) for k in range(size7 // 4)]
    m9 = [(crc, "loader: CRC16 of the header, computed"), (stored, "loader: header CRC16 field"),
          (len(w9), "loader: ARM9 words copied"), (h33(w9), "loader: their checksum"),
          (len(w7), "loader: ARM7 words copied"), (h33(w7), "loader: their checksum")]
    m7 = []
    ipc = Ipc()
    a9, a7 = Cpu(ipc, 9), Cpu(ipc, 7)

    def both():
        a9.service()
        a7.service()

    # A: IPCSYNC IRQs both ways.
    ipc.sync_write(9, 0x4200); both()
    ipc.sync_write(7, 0x6300); both()
    m9.append((a9.syncin, "A: ARM9 IPCSYNC input in its IPCSYNC IRQ"))
    ipc.sync_write(9, 0x6400); both()
    m7.append((a7.syncin, "A: ARM7 IPCSYNC input in its IPCSYNC IRQ"))
    # B: ARM9 -> ARM7.
    ipc.send(7, 0x1234); both()
    m7.append((ipc.cnt_read(7), "B: ARM7 CNT after a send with its FIFO disabled (dropped, no error)"))
    ipc.cnt_write(7, 0xC000); ipc.sync_write(7, 0x4500); both()
    ipc.cnt_write(9, 0xC00C); both()
    m9.append((a9.sends, "B: ARM9 send-empty IRQs after enabling it on an empty FIFO"))
    d9 = [0x9000 + 0x11 * k for k in range(16)]
    for w in d9:
        ipc.send(9, w); both()
    m9.append((ipc.cnt_read(9), "B: ARM9 CNT with 16 words sent (full)"))
    ipc.send(9, 0xDEAD); both()
    m9.append((ipc.cnt_read(9), "B: ARM9 CNT after a 17th send (error)"))
    ipc.cnt_write(9, 0xC004); both()
    m9.append((ipc.cnt_read(9), "B: ARM9 CNT after acknowledging"))
    ipc.sync_write(9, 0x4600); both()
    m7.append((ipc.cnt_read(7), "B: ARM7 CNT with its receive FIFO full"))
    ipc.cnt_write(7, 0x8400); both()
    m7 += [(a7.recvs, "B: ARM7 receive IRQs"), (a7.words, "B: ARM7 words received"),
           (a7.sum, "B: their checksum")]
    assert a7.sum == h33(d9)
    ipc.recv(7); both()
    m7.append((ipc.cnt_read(7), "B: ARM7 CNT after an empty read (error)"))
    ipc.cnt_write(7, 0xC000); ipc.sync_write(7, 0x4700); both()
    m9.append((a9.sends, "B: ARM9 send-empty IRQs after the ARM7 drained the FIFO"))
    # C: ARM7 -> ARM9.
    ipc.cnt_write(9, 0x8004); ipc.sync_write(9, 0x4800); both()
    d7 = [0x7000 + 0x101 * k for k in range(8)]
    for w in d7:
        ipc.send(7, w); both()
    ipc.sync_write(7, 0x4900); both()
    m9.append((ipc.cnt_read(9), "C: ARM9 CNT with 8 words waiting"))
    ipc.cnt_write(9, 0x8404); both()
    m9 += [(a9.recvs, "C: ARM9 receive IRQs"), (a9.words, "C: ARM9 words received"),
           (a9.sum, "C: their checksum")]
    ipc.recv(9); both()
    m9.append((ipc.cnt_read(9), "C: ARM9 CNT after an empty read (error)"))
    ipc.cnt_write(9, 0xC004); ipc.sync_write(9, 0x4A00); both()
    for k in range(3):
        ipc.send(7, 0x3333 + k); both()
    ipc.cnt_write(7, 0x8008); both()
    m7.append((ipc.cnt_read(7), "C: ARM7 CNT after clearing its send FIFO"))
    ipc.sync_write(7, 0x4B00); both()
    m9.append((ipc.cnt_read(9), "C: ARM9 CNT after the ARM7's clear"))
    m9.append((ipc.recv(9), "C: ARM9 empty read after the clear returns 0"))
    m9.append((ipc.cnt_read(9), "C: ARM9 CNT after that read (error)"))
    ipc.cnt_write(9, 0xC004); both()
    # D: shared RAM.
    a = [((k * 0x01010101) ^ 0x5A5AA5A5) & M for k in range(32)]
    b = [(a[k] + k) & M for k in range(32)]
    m7.append((h33(a), "D: ARM7 checksum of buffer A"))
    m9.append((h33(b), "D: ARM9 checksum of buffer B = A + index"))
    region = [((k ^ 0x93) & 0xFF) | (((k ^ 0x71) & 0xFF) << 8) | (((k + 0x29) & 0xFF) << 16)
              | (((k + 0x37) & 0xFF) << 24) for k in range(32)]
    m9.append((h33(region), "D: ARM9 checksum of the words both CPUs stored bytes into"))
    m7.append((h33(region), "D: ARM7 checksum of the same words"))
    # E: stream ARM9 -> ARM7 with flow control, received under IRQ.
    ipc.cnt_write(9, 0x8000); both()
    a7.words = a7.sum = 0
    ipc.cnt_write(7, 0x8400); ipc.sync_write(7, 0x4100); both()
    s = [(k * 0x9E3779B1) & M for k in range(64)]
    for w in s:
        while ipc.cnt_read(9) & 2:
            both()
        ipc.send(9, w); both()
    ipc.sync_write(9, 0x4000); both()
    m7 += [(a7.words, "E: ARM7 streamed words received"), (a7.sum, "E: their checksum"),
           (a7.syncs, "ARM7 IPCSYNC IRQs")]
    ipc.sync_write(7, 0x4300); both()
    # F: per word, the ARM9 counted 100 in byte 0 and the ARM7 50 in byte 1.
    words_f = [100 | (50 << 8)] * 2
    m9.append((h33(words_f), "F: ARM9 checksum of the 2 words both CPUs counted bytes in at once"))
    m7.append((h33(words_f), "F: ARM7 checksum of the same words"))
    m7.append((0x700D7, "ARM7 done marker"))
    m9 += [(a9.sends, "ARM9 send-empty IRQs in total"), (a9.recvs, "ARM9 receive IRQs in total"),
           (a9.syncs, "ARM9 IPCSYNC IRQs"), (0x600D9, "ARM9 done marker")]
    return m9, m7


def write_hex(path, data, size):
    data = bytes(data) + bytes(size - len(data))
    with open(path, "w") as f:
        for k in range(0, size, 4):
            f.write("%08x\n" % get32(data, k))


def main():
    a = sys.argv[1:]
    try:
        cmd = a[0]
        if cmd == "image":
            rom = image(open(a[1], "rb").read(), int(a[2], 0), open(a[3], "rb").read(), int(a[4], 0))
            write_hex(a[5], rom, SIZE)
        elif cmd == "boot9":
            loader = open(a[1], "rb").read()
            rom = image(open(a[2], "rb").read(), int(a[3], 0), open(a[4], "rb").read(), int(a[5], 0))
            assert len(loader) <= HANDOFF, "loader overlaps the handoff header"
            boot = bytearray(0x1000)
            boot[0:len(loader)] = loader
            boot[HANDOFF:HANDOFF + 0x200] = rom[0:0x200]
            write_hex(a[6], boot, 0x1000)
        elif cmd == "boot7":
            loader = open(a[1], "rb").read()
            assert len(loader) <= 0x1000
            write_hex(a[2], loader, 0x1000)
        elif cmd == "expected":
            rom = image(open(a[2], "rb").read(), int(a[3], 0), open(a[4], "rb").read(), int(a[5], 0))
            m9, m7 = expected(rom)
            for k, (v, note) in enumerate(m9 if a[1] == "9" else m7):
                print("%08x  # %-2d %s" % (v & M, k, note))
        else:
            raise IndexError
    except (IndexError, ValueError):
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
