#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Convert retail NDS BIOS dumps into the hex overrides nds_bios7/nds_bios9
# serve when present (sim/tests/bios7_retail.hex / bios9_retail.hex).
# The outputs are gitignored — retail images are copyrighted, never commit
# them; without the hex files the ROMs fall back to the built-in HLE BIOS.
#
#   sim/tests/make_retail_bios.sh <bios7.bin> <bios9.bin>
#
# bios7.bin: 16 KB, md5 df692a80a5b1bc90728bc3dfc76cd948
# bios9.bin:  4 KB, md5 a392174eb3e572fed6447e956bde4b25
set -eu

B7="${1:?usage: make_retail_bios.sh <bios7.bin> <bios9.bin>}"
B9="${2:?usage: make_retail_bios.sh <bios7.bin> <bios9.bin>}"
OUT="$(cd "$(dirname "$0")" && pwd)"

python3 - "$B7" "$B9" "$OUT" <<'EOF'
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
EOF
