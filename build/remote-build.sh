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
#   NS=default     kubernetes namespace
#   PARALLEL=8     NUM_PARALLEL_PROCESSORS override for the remote copy
#
# The source is streamed into the pod with git archive - only committed files
# of the given ref are built, and the branch never has to be pushed anywhere.
# Artifacts land in build/artifacts/.
set -euo pipefail

REF="${1:-HEAD}"
NS="${NS:-default}"
PARALLEL="${PARALLEL:-8}"
DIRTY="${DIRTY:-0}"
POD="nds-quartus-build"

cd "$(git rev-parse --show-toplevel)"

echo "== recreating pod ${POD} in ${NS}"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait
kubectl -n "$NS" apply -f build/quartus-pod.yaml
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
mkdir -p build/artifacts
# kubectl cp doesn't propagate remote tar failures, so check existence first
for f in NDS.rbf NDS.fit.summary NDS.map.summary NDS.sta.summary NDS.sta.rpt NDS.paths.rpt NDS.flow.rpt NDS.fit.rpt NDS.map.rpt; do
   if kubectl -n "$NS" exec "$POD" -- test -f "/work/src/output_files/${f}" 2>/dev/null; then
      kubectl -n "$NS" cp "${POD}:/work/src/output_files/${f}" "build/artifacts/${f}" \
         && echo "   fetched ${f}"
   else
      echo "   missing ${f}"
   fi
done

kubectl -n "$NS" delete pod "$POD" --wait=false
exit "$RC"
