#!/bin/sh
# Build the stock-toolchain console test with the devkitPro example
# Makefile (calico + libnds + default ARM7), then emit the sim hex.
set -eu
cd "$(dirname "$0")"

export DEVKITPRO=/opt/devkitpro
export DEVKITARM=/opt/devkitpro/devkitARM
make clean >/dev/null
make

python3 - <<'PYEOF'
img = open("hello2d.nds", "rb").read()
img += b"\0" * ((4 - len(img) % 4) % 4)
with open("../nds_hello2d.hex", "w") as f:
    for i in range(0, len(img), 4):
        f.write(f"{int.from_bytes(img[i:i+4], 'little'):08x}\n")
print(f"nds_hello2d.hex: {len(img)//4} words")
PYEOF
