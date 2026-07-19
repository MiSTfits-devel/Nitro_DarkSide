#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Convert retail NDS BIOS/firmware dumps into the hex overrides the sim
# picks up when present (sim/tests/bios7_retail.hex / bios9_retail.hex /
# firmware_retail.hex). The outputs are gitignored — retail images are
# copyrighted, never commit them; without the hex files the sim falls back
# to the built-in HLE BIOS and the synthesized firmware image.
#
#   sim/tests/make_retail_bios.sh <bios7.bin> <bios9.bin> [firmware.bin]
#
# bios7.bin:    16 KB,  md5 df692a80a5b1bc90728bc3dfc76cd948
# bios9.bin:     4 KB,  md5 a392174eb3e572fed6447e956bde4b25
# firmware.bin: 256 KB, e.g. md5 903360c1bed6b40452b1fa3e5a4f1b66 (2005-12-07 world)
set -eu

B7="${1:?usage: make_retail_bios.sh <bios7.bin> <bios9.bin> [firmware.bin]}"
B9="${2:?usage: make_retail_bios.sh <bios7.bin> <bios9.bin> [firmware.bin]}"
FW="${3:-}"
OUT="$(cd "$(dirname "$0")" && pwd)"

python3 - "$B7" "$B9" "$OUT" "$FW" <<'EOF'
import struct, sys

def conv(src, dst, expect):
    with open(src, "rb") as f:
        data = f.read()
    if len(data) != expect:
        sys.exit("%s: expected %d bytes, got %d" % (src, expect, len(data)))
    with open(dst, "w") as f:
        for i in range(0, len(data), 4):
            f.write("%08X\n" % struct.unpack_from("<I", data, i)[0])
    print("wrote %s - %d words" % (dst, len(data) // 4))

out = sys.argv[3]
conv(sys.argv[1], out + "/bios7_retail.hex", 16384)
conv(sys.argv[2], out + "/bios9_retail.hex", 4096)
if sys.argv[4]:
    conv(sys.argv[4], out + "/firmware_retail.hex", 262144)
EOF
