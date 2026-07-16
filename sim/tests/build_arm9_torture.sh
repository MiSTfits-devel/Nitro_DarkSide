#!/bin/sh
# Generate + assemble the ARM9 ISA torture workload (M3 differential trace).
# The .s/.bin/.hex are NOT checked in (deterministic from the generator);
# rerun this before streaming a DIRTY tree to the sim pod.
#   SEED=1 CHUNKS=400 LOOPS=1000 sim/tests/build_arm9_torture.sh
set -eu
cd "$(dirname "$0")"

SEED="${SEED:-1}"
CHUNKS="${CHUNKS:-400}"
LOOPS="${LOOPS:-1000}"
CACHES="${CACHES:-0}"

CACHEFLAG=""
[ "$CACHES" = "1" ] && CACHEFLAG="--caches"
python3 gen_arm9_torture.py --seed "$SEED" --chunks "$CHUNKS" --loops "$LOOPS" $CACHEFLAG -o arm9_torture.s

arm-none-eabi-as -march=armv5te -o arm9_torture.o arm9_torture.s
arm-none-eabi-ld -Ttext=0x02000000 -o arm9_torture.elf arm9_torture.o
arm-none-eabi-objcopy -O binary arm9_torture.elf arm9_torture.bin

python3 - <<'EOF'
data = open("arm9_torture.bin", "rb").read()
data += b"\0" * ((4 - len(data) % 4) % 4)
with open("arm9_torture.hex", "w") as f:
    for i in range(0, len(data), 4):
        w = int.from_bytes(data[i:i+4], "little")
        f.write(f"{w:08x}\n")
print(f"arm9_torture.hex: {len(data)//4} words")
EOF

rm -f arm9_torture.o arm9_torture.elf
