#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Convert an NDS cartridge dump into the .hex image the sim's card model reads
# (sim/run_top_frame.sh HEXFILE=...). The outputs are gitignored - cartridge
# dumps are copyrighted, never commit them.
#
#   sim/tests/make_test_cart.sh <cart.nds> [outname] [words]
#
# The NITRO Tester ("Nitro EVA") self-checker cart, gamecode AAAA, is the one
# this was written for: it is a 58-test hardware validation suite that runs
# WITHOUT any button input and halts on the first failure, printing the failing
# test id and PROGRESS[nnn/058] on screen. That makes "which test id does the
# screen stop at" a single-number regression signal for the whole 2D + DMA +
# timer path. See docs/NTR_EVA_TESTER.md.
#
#   sim/tests/make_test_cart.sh ~/dumps/__AAAA01_00.nds ntr_eva
#     -> sim/tests/ntr_eva.hex
#
# 'words' truncates the image (default 1048576 = 4 MB, matching the default
# CARD_WORDS in run_top_frame.sh). Truncation is only safe above the header's
# "total used ROM size"; the script refuses to cut below it, because a card
# model that returns zeroes inside the used area fails in ways that look like
# core bugs rather than a truncated image.
set -eu

SRC="${1:?usage: make_test_cart.sh <cart.nds> [outname] [words]}"
NAME="${2:-$(basename "$SRC" .nds)}"
WORDS="${3:-1048576}"
OUT="$(cd "$(dirname "$0")" && pwd)"

python3 - "$SRC" "$OUT/$NAME.hex" "$WORDS" <<'EOF'
import struct, sys

src, dst, words = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(src, "rb") as f:
    img = f.read()
if len(img) < 0x200:
    sys.exit("%s: too small to be an NDS image (%d bytes)" % (src, len(img)))

title = img[0x00:0x0C].rstrip(b"\0").decode("ascii", "replace")
code = img[0x0C:0x10].decode("ascii", "replace")
unit = img[0x12]
cap = 128 * 1024 << img[0x14]
a9off, a9entry, a9load, a9size = struct.unpack_from("<4I", img, 0x20)
a7off, a7entry, a7load, a7size = struct.unpack_from("<4I", img, 0x30)
used, = struct.unpack_from("<I", img, 0x80)

print("title      : %r  gamecode %s  unit %02X" % (title, code, unit))
print("arm9       : off=%08X entry=%08X load=%08X size=%u" % (a9off, a9entry, a9load, a9size))
print("arm7       : off=%08X entry=%08X load=%08X size=%u" % (a7off, a7entry, a7load, a7size))
print("used / file: %u / %u bytes  (header capacity %u)" % (used, len(img), cap))

# The card model is word-addressed; a truncation that lands inside the used
# area silently turns cart reads into zeroes.
if words * 4 < used:
    sys.exit("refusing to truncate: %d words (%d bytes) is below the header's "
             "used ROM size of %d bytes - pass a larger 'words'"
             % (words, words * 4, used))
for off, size, who in ((a9off, a9size, "arm9"), (a7off, a7size, "arm7")):
    if off + size > len(img):
        sys.exit("%s section (off=%08X size=%u) runs past end of file" % (who, off, size))

data = img[:words * 4]
if len(data) % 4:
    data += b"\0" * (4 - len(data) % 4)
with open(dst, "w") as f:
    for i in range(0, len(data), 4):
        f.write("%08x\n" % struct.unpack_from("<I", data, i)[0])
print("wrote %s - %d words (%d bytes)" % (dst, len(data) // 4, len(data)))
EOF
