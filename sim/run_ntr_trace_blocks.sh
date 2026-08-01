#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Trace-bisect helper: run tb_top_frame, reduce the ARM9 trace to one MD5 per
# BLOCK instructions, and report the first block that disagrees with a melonDS
# reference - then leave just that block behind for fetching.
#
# WHY. A from-boot trace long enough to reach the NITRO Tester's display-on
# write is ~11M instructions / ~1.6 GB. Moving that off the sim pod, or pushing
# the melonDS side onto it, is not worth doing for a single divergence point.
# Hashing both sides in fixed blocks turns each into a ~107-line file; only the
# one disagreeing block (~15 MB) has to travel.
#
# The RTL writes uppercase hex and melonDS lowercase. Lowercasing the RTL side
# makes the two byte-identical - verified on a 300k trace, same MD5 - so plain
# block MD5s are a valid comparison. Do NOT skip the tr.
#
# Reference file is generated locally; see docs/NTR_EVA_TESTER.md.
# All other env passes straight through to run_top_frame.sh, so set
# HEXFILE/DIRECT/PRELOAD/MAXINSTR/TRACEFILE/TRACE_START_FRAME there as usual.
#
#   REF=sim/tests/ntr_eva_mds_blocks.md5   BLOCK=100000
#   ARTIFACTS="trace_blocks.txt firstbad.txt" build/remote-sim.sh run_ntr_trace_blocks.sh
set -eu
cd "$(dirname "$0")/.."

TRACE="${TRACEFILE:-isl9.txt}"
REF="${REF:-sim/tests/ntr_eva_mds_blocks.md5}"
BLOCK="${BLOCK:-100000}"

sh sim/run_top_frame.sh

[ -s "$TRACE" ] || { echo "TRACE $TRACE is empty - with PRELOAD=1 you need TRACE_START_FRAME=-1"; exit 1; }
echo "== trace: $(wc -l < "$TRACE") instructions"

WORKDIR=./_blk
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
tr 'A-Z' 'a-z' < "$TRACE" > "$WORKDIR/lc.txt"
( cd "$WORKDIR" && split -l "$BLOCK" -d -a 4 lc.txt x )

: > trace_blocks.txt
i=0
for f in "$WORKDIR"/x*; do
   printf '%d %s\n' "$i" "$(md5sum < "$f" | cut -d' ' -f1)" >> trace_blocks.txt
   i=$((i + 1))
done
echo "== hashed $i blocks of $BLOCK"

if [ ! -f "$REF" ]; then
   echo "== no reference at $REF - hashes only"
   exit 0
fi

# Compare FULL blocks on BOTH sides. Neither trace is guaranteed to stop on a
# block boundary: the reference marks its own short tail partial=, and the RTL's
# last block is short whenever MAXINSTR/TIMEOUT_MS cut it off mid-block. Compare
# either one and you get a guaranteed mismatch that means nothing at all - it
# reads exactly like a real divergence at the far end of the run, which is the
# most expensive place to be wrong.
RTLFULL=$(($(wc -l < "$WORKDIR/lc.txt") / BLOCK))
echo "== comparing $RTLFULL full RTL blocks (short tail excluded)"
FIRSTBAD=-1
while read -r idx refmd5 rest; do
   case "$rest" in partial=*) continue ;; esac
   [ "$idx" -lt "$RTLFULL" ] || { echo "== RTL trace ends at block $idx (ref has more) - ran out of run, not a divergence"; break; }
   rtlmd5=$(awk -v n="$idx" '$1==n {print $2}' trace_blocks.txt)
   if [ "$rtlmd5" != "$refmd5" ]; then FIRSTBAD="$idx"; break; fi
done < "$REF"

if [ "$FIRSTBAD" -lt 0 ]; then
   echo "== MATCH: every full block agrees with $REF"
   : > firstbad.txt
else
   S=$((FIRSTBAD * BLOCK))
   echo "== FIRST DIVERGING BLOCK: $FIRSTBAD  (instructions $S .. $((S + BLOCK - 1)))"
   printf '%04d' "$FIRSTBAD" > /dev/null
   cp "$WORKDIR/$(cd "$WORKDIR" && ls x* | sed -n "$((FIRSTBAD + 1))p")" firstbad.txt
   echo "== firstbad.txt = RTL block $FIRSTBAD ($(wc -l < firstbad.txt) instructions)"
fi
