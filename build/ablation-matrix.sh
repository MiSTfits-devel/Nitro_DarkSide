#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fit matrix for the dead-silicon ablations (savestate write-muxes + mosaic-Y
# counters). Four configurations, two pods at a time.
#
# Everything is anchored on SEED 23 except D, so build A is a DIRECT A/B against
# build/artifacts-audio-s23 (41,889 ALMs, 100%, fitter Failed) - same seed, same
# config, only the ablations differ. D uses SEED 3 to line up with
# build/cores-20260810 NDS_cart_hdmi_s3 (39,072 ALMs).
#
#   A  SOUND=1 DEBUG=0 HDMI=no   seed 23   does the ablation close the fit
#   B  SOUND=1 DEBUG=1 HDMI=no   seed 23   audio + nitrodbg at once (new)
#   C  SOUND=1 DEBUG=0 HDMI=yes  seed 23   the documented-impossible combo
#   D  SOUND=0 DEBUG=1 HDMI=yes  seed  3   shipping hdmi image, regression check
#
# DIRTY=1 streams the WORKING TREE, so the config for each build is edited in
# place and each launch must finish streaming before the next edit lands. The
# handshake is /work/src/.ready inside the pod, which remote-build.sh touches
# immediately after its tar completes - wait_streamed() blocks on it.
#
# The tree is restored to its original configuration on exit, including on
# failure or interrupt.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

NS="${NS:-default}"
WRAP=nds_port_wrap.vhd
QSF=NDS.qsf
SAVE=".ablation-matrix-save"

mkdir -p "$SAVE"
cp "$WRAP" "$SAVE/wrap.orig"
cp "$QSF"  "$SAVE/qsf.orig"

restore() {
   cp "$SAVE/wrap.orig" "$WRAP"
   cp "$SAVE/qsf.orig"  "$QSF"
   echo "== tree configuration restored"
}
trap restore EXIT

# set_config <sound> <debug> <hdmi:yes|no>
set_config() {
   local snd="$1" dbg="$2" hdmi="$3"

   # The generic map is a single known line; rewrite it wholesale rather than
   # patching fields, so a partial match cannot leave a half-applied config.
   python3 - "$WRAP" "$snd" "$dbg" <<'PY'
import re, sys
path, snd, dbg = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
new = f"   generic map ( GPU_FAST => 0, SOUND_ENABLE => {snd}, DEBUG_ENABLE => {dbg} )"
out, n = re.subn(r"^   generic map \( GPU_FAST => 0, SOUND_ENABLE => \d+, DEBUG_ENABLE => \d+ \)$",
                 new, src, count=1, flags=re.M)
if n != 1:
    sys.exit(f"generic map line not matched exactly once in {path} (n={n})")
open(path, "w").write(out)
PY

   python3 - "$QSF" "$hdmi" <<'PY'
import re, sys
path, hdmi = sys.argv[1], sys.argv[2]
src = open(path).read()
live = 'set_global_assignment -name VERILOG_MACRO "MISTER_DEBUG_NOHDMI=1"'
off  = '#set_global_assignment -name VERILOG_MACRO "MISTER_DEBUG_NOHDMI=1"'
# Normalise to the live form first so this is idempotent in both directions.
src = src.replace(off, live)
if hdmi == "yes":
    src, n = re.subn(re.escape(live), off, src, count=1)
    if n != 1:
        sys.exit("NOHDMI macro line not found")
open(path, "w").write(src)
PY

   echo "== config: SOUND=${snd} DEBUG=${dbg} HDMI=${hdmi}"
   grep -n "generic map ( GPU_FAST" "$WRAP"
   grep -n "MISTER_DEBUG_NOHDMI" "$QSF"
}

# launch <tag> <pod> <seed>
launch() {
   local tag="$1" pod="$2" seed="$3"
   echo "== launching ${tag} on ${pod} (seed ${seed})"
   DIRTY=1 POD="$pod" ARTIFACT_DIR="build/artifacts-abl-${tag}" \
      SEED_OVERRIDE="$seed" NS="$NS" \
      build/remote-build.sh > "build/abl-${tag}.log" 2>&1 &
   echo "$!" > "$SAVE/pid-${tag}"
}

# wait_streamed <pod> - block until remote-build.sh has finished its tar, so the
# working tree is free to be reconfigured for the next build
wait_streamed() {
   local pod="$1" waited=0
   echo "== waiting for ${pod} to finish streaming"
   while true; do
      if kubectl -n "$NS" exec "$pod" -- test -f /work/src/.ready >/dev/null 2>&1; then
         echo "== ${pod} streamed after ${waited}s"
         return 0
      fi
      sleep 10
      waited=$((waited + 10))
      if [ "$waited" -gt 1800 ]; then
         echo "!! ${pod} never streamed after ${waited}s" >&2
         return 1
      fi
   done
}

run_wave() {
   local t1="$1" s1="$2" d1="$3" h1="$4" sd1="$5"
   local t2="$6" s2="$7" d2="$8" h2="$9" sd2="${10}"

   set_config "$s1" "$d1" "$h1"
   launch "$t1" "nds-quartus-abl-$(echo "$t1" | tr 'A-Z' 'a-z')" "$sd1"
   wait_streamed "nds-quartus-abl-$(echo "$t1" | tr 'A-Z' 'a-z')"

   set_config "$s2" "$d2" "$h2"
   launch "$t2" "nds-quartus-abl-$(echo "$t2" | tr 'A-Z' 'a-z')" "$sd2"
   wait_streamed "nds-quartus-abl-$(echo "$t2" | tr 'A-Z' 'a-z')"

   echo "== both streamed; waiting on fits"
   wait "$(cat "$SAVE/pid-${t1}")" || echo "!! ${t1} exited nonzero"
   wait "$(cat "$SAVE/pid-${t2}")" || echo "!! ${t2} exited nonzero"
   echo "== wave done: ${t1} ${t2}"
}

run_wave A 1 0 no 23   B 1 1 no 23
run_wave C 1 0 yes 23  D 0 1 yes 3

echo "== all four fits complete"
for t in A B C D; do
   f="build/artifacts-abl-${t}/NDS.fit.summary"
   if [ -f "$f" ]; then
      echo "--- ${t} ---"
      grep -E "Fitter Status|Logic utilization|Total RAM Blocks|block memory" "$f" || true
   else
      echo "--- ${t} --- no fit summary fetched"
   fi
done
