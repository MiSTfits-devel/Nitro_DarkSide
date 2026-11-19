# SPDX-License-Identifier: GPL-3.0-only
import struct
import unittest
from renderer_gate import acknowledged


class RendererGate(unittest.TestCase):
    def test_committed_pair_only(self):
        page = bytearray(4096)
        old, epoch = 0xffffffff, 1
        struct.pack_into('<4I', page, 0, 0x31443348, 0x00800001, epoch, 0)
        struct.pack_into('<4I', page, 0x20, 0, 0, 2, epoch)
        struct.pack_into('<4I', page, 0x70, epoch, 0, epoch, 0)
        for flags in (6, 7):
            for where in (0x300, 0x340):
                struct.pack_into('<8I', page, where, 0x31503348, 0x00200001, epoch, flags, epoch, 0, epoch, 0)
            self.assertEqual(acknowledged(page, old), epoch)
        self.assertIsNone(acknowledged(page, epoch))
        for off in (0, 4, 8, 12, 0x20, 0x24, 0x28, 0x2c, 0x70, 0x78, 0x300, 0x30c, 0x318, 0x344, 0x358):
            with self.subTest(offset=off):
                broken = bytearray(page)
                broken[off] ^= 1
                self.assertIsNone(acknowledged(broken, old))


if __name__ == '__main__':
    unittest.main()
