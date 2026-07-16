#!/bin/sh
# M5: VRAM line-server tests — renderer BG/OBJ/ext-palette channels of
# nds_vram against the gen_vram_ls.py golden model (independent GBATEK
# mapping semantics) plus CPU-port differential for BG/OBJ. Vectors are
# generated, not checked in - run `python3 sim/tests/gen_vram_ls.py`
# (from sim/tests/) first.
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-20}"
WORK=sim/nvc_work
mkdir -p "$WORK"

[ -f sim/tests/vram_ls_vectors.hex ] || { echo "vectors missing: python3 sim/tests/gen_vram_ls.py"; exit 1; }

nvc --work="$WORK/altera_mf" -a --relaxed sim/altera_mf_stub.vhd
nvc -L "$WORK" --work="$WORK/mem" -a --relaxed rtl/SyncRamDualByteEnable.vhd
nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/nds_vram_map.vhd \
   rtl/nds_vram.vhd \
   sim/tb_vram_ls.vhd

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_vram_ls -gTIMEOUT_MS="$TIMEOUT_MS"
nvc -H 1g -L "$WORK" --work="$WORK/work" -r tb_vram_ls --ieee-warnings=off --exit-severity=failure
