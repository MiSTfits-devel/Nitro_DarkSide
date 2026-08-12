#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Headless Quartus build of the NDS core on the k8s cluster (GBA_MiSTer
# build/remote-build.sh pattern; single revision).
#
#   build/remote-build.sh [git-ref]     # default: HEAD
#   DIRTY=1 build/remote-build.sh       # working tree incl. uncommitted
#                                       # (same pattern as remote-sim.sh -
#                                       # measurement builds without a commit)
#
# Environment:
#   NS=default                    kubernetes namespace
#   PARALLEL=8                    NUM_PARALLEL_PROCESSORS override
#   POD=nds-quartus-build         isolated pod name
#   ARTIFACT_DIR=build/artifacts  local report/output directory
#   SEED_OVERRIDE=0               build-only fitter seed override
#
# The source is streamed into the pod with git archive - only committed files
# of the given ref are built, and the branch never has to be pushed anywhere.
# Artifacts land in build/artifacts/.
set -euo pipefail

REF="${1:-HEAD}"
NS="${NS:-default}"
PARALLEL="${PARALLEL:-8}"
DIRTY="${DIRTY:-0}"
POD="${POD:-nds-quartus-build}"
ARTIFACT_DIR="${ARTIFACT_DIR:-build/artifacts}"
SEED_OVERRIDE="${SEED_OVERRIDE:-}"
ARTIFACT_FILES=(
   NDS.rbf NDS.fit.summary NDS.map.summary NDS.sta.summary NDS.sta.rpt
   NDS.paths.rpt NDS.flow.rpt NDS.fit.rpt NDS.map.rpt
   # Hold failures need endpoint/path detail too; the default STA report only
   # carries the per-clock summary, which is not enough to fix one.
   NDS.paths_hold.rpt
   # every path that would violate at 67.028 MHz (14.92 ns). The -npaths 50
   # report only ever shows the worst ~31 ns family, which hid the whole
   # 15-26 ns population - i.e. most of the work needed to raise clk_sys.
   NDS.paths_67mhz.rpt
   # ARM9-hierarchy-only paths. The global report is ranked by slack and caps
   # out long before it reaches the CPU, so it cannot answer "would the ARM9
   # close at 67 MHz" - this one is scoped to icpu9/imembus9 and can.
   NDS.paths_cpu9.rpt
   # ...but paths_cpu9 is -detail summary: it names the endpoints and never says
   # where the nanoseconds went. Choosing a cut off endpoint names alone is how
   # a build got spent on logic that turned out not to be on the path. This is
   # the same four families with -detail full_path, two paths each.
   NDS.paths_fam.rpt
)

if [[ ! "$POD" =~ ^([a-z0-9]|[a-z0-9][-a-z0-9]{0,61}[a-z0-9])$ ]]; then
   echo "invalid POD (expected a DNS-1123 name): ${POD}" >&2
   exit 2
fi
if [[ ! "$NS" =~ ^([a-z0-9]|[a-z0-9][-a-z0-9]{0,61}[a-z0-9])$ ]]; then
   echo "invalid NS (expected a DNS-1123 name): ${NS}" >&2
   exit 2
fi
if [[ -n "$SEED_OVERRIDE" && ! "$SEED_OVERRIDE" =~ ^[0-9]+$ ]]; then
   echo "invalid SEED_OVERRIDE (expected an unsigned integer): ${SEED_OVERRIDE}" >&2
   exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
mkdir -p -- "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd -- "$ARTIFACT_DIR" && pwd -P)"
case "$ARTIFACT_DIR" in
   "$REPO_ROOT"/build/*) ;;
   *)
      echo "ARTIFACT_DIR must resolve below ${REPO_ROOT}/build: ${ARTIFACT_DIR}" >&2
      exit 2
      ;;
esac

echo "== recreating pod ${POD} in ${NS}"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait
sed "s/nds-quartus-build/${POD}/g" build/quartus-pod.yaml | kubectl -n "$NS" apply -f -
# first run pulls a multi-GB image, give it time
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=20m

echo "== streaming source (${REF}, dirty=${DIRTY})"
# clash/ carries the checked-in Clash-generated SV that NDS.qsf sources
if [ "$DIRTY" = "1" ]; then
   tar -c rtl sys clash NDS.qpf NDS.qsf NDS.sdc NDS.sv nds_port_wrap.vhd files.qip \
      | kubectl -n "$NS" exec -i "$POD" -- tar -x -C /work/src
else
   git archive "$REF" rtl sys clash NDS.qpf NDS.qsf NDS.sdc NDS.sv nds_port_wrap.vhd files.qip \
      | kubectl -n "$NS" exec -i "$POD" -- tar -x -C /work/src
fi
if [[ -n "$SEED_OVERRIDE" ]]; then
   kubectl -n "$NS" exec "$POD" -- sed -i \
      "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED ${SEED_OVERRIDE}/" \
      /work/src/NDS.qsf
fi
kubectl -n "$NS" exec "$POD" -- bash -c "echo ${PARALLEL} > /work/src/.parallel && touch /work/src/.ready"

echo "== compiling (this takes a while - fitter on Cyclone V is slow)"
kubectl -n "$NS" logs -f "$POD" &
LOGPID=$!
trap 'kill ${LOGPID} 2>/dev/null || true' EXIT

RC=""
while [ -z "$RC" ]; do
   sleep 20
   RC=$(kubectl -n "$NS" exec "$POD" -- sh -c 'cat /work/exitcode 2>/dev/null' 2>/dev/null || true)
done
kill "$LOGPID" 2>/dev/null || true

echo "== flow exit code: ${RC}"
# Clear only this driver's known generated outputs.  Otherwise a failed fit
# can leave an old local report beside newly fetched partial results.
for f in "${ARTIFACT_FILES[@]}"; do
   rm -f -- "${ARTIFACT_DIR}/${f}"
done
# kubectl cp doesn't propagate remote tar failures, so check existence first
for f in "${ARTIFACT_FILES[@]}"; do
   if kubectl -n "$NS" exec "$POD" -- test -f "/work/src/output_files/${f}" 2>/dev/null; then
      kubectl -n "$NS" cp "${POD}:/work/src/output_files/${f}" "${ARTIFACT_DIR}/${f}" \
         && echo "   fetched ${f}"
   else
      echo "   missing ${f}"
   fi
done

kubectl -n "$NS" delete pod "$POD" --wait=false
exit "$RC"
