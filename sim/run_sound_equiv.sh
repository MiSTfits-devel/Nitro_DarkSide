#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Equivalence gate for the nds_sound area refactor: the working RTL against
# sim/nds_sound_ref.vhd, a verbatim copy of the version before it.
#
# This is the check that has to stay clean while the sample engine is
# restructured. tb_sound (sim/run_sound.sh) is a liveness smoke test with 27
# samples and no oracle - useful, but it cannot tell you a channel format
# regressed. See the testbench header.
#
# Regenerate the reference ONLY from a known-good commit:  sim/regen_sound_ref.sh
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-200}"
WORK=sim/nvc_work_snd_eq
mkdir -p "$WORK"

nvc --work="$WORK/altera_mf" -a --relaxed sim/altera_mf_stub.vhd

nvc -L "$WORK" --work="$WORK/mem" -a --relaxed \
   rtl/SyncRamDualByteEnable.vhd

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/nds_sound.vhd \
   sim/nds_sound_ref.vhd \
   sim/tb_sound_equiv.vhd

nvc -H 2g -L "$WORK" --work="$WORK/work" -e tb_sound_equiv -gTIMEOUT_MS="$TIMEOUT_MS"
nvc -H 2g -L "$WORK" --work="$WORK/work" -r tb_sound_equiv \
   --ieee-warnings=off --exit-severity=failure
