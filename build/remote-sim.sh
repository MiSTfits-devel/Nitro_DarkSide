#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run an nvc sim script on the k8s cluster (same pattern as GBA remote-build.sh).
#
#   build/remote-sim.sh run_vram_map_tb.sh              # committed tree (HEAD)
#   REF=mybranch build/remote-sim.sh run_x.sh           # any committed ref
#   DIRTY=1 build/remote-sim.sh run_x.sh                # working tree incl. uncommitted
#   ENV="OPCOUNT=200000 SEED=7" build/remote-sim.sh run_vram_torture_tb.sh
#   KEEP=1 ...                                          # leave the pod running after
#   POD=nds-nvc-sim-2 ...                               # separate pod: parallel sims
#                                                       # (artifacts -> simout/<pod>/)
#
# Long benches: the pod survives this script's terminal - rerun with the same
# script to reuse a warm pod, or watch with: kubectl logs -f <pod name>
set -euo pipefail

SCRIPT="${1:?usage: build/remote-sim.sh <run_script.sh>}"
REF="${REF:-HEAD}"
NS="${NS:-default}"
DIRTY="${DIRTY:-0}"
ENVVARS="${ENV:-}"
KEEP="${KEEP:-0}"
# POD=nds-nvc-sim-2 (any name) runs on a separate pod so sims can run in
# parallel; default keeps the historical single-pod behavior
POD="${POD:-nds-nvc-sim}"

cd "$(dirname "$0")/.."

[ -f "sim/${SCRIPT}" ] || { echo "no such script: sim/${SCRIPT}"; exit 1; }

echo "== recreating pod ${POD} in ${NS}"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait
sed "s/nds-nvc-sim/${POD}/g" build/sim-pod.yaml | kubectl -n "$NS" apply -f -
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=10m

echo "== streaming source (${REF}, dirty=${DIRTY})"
# NDS.sv/nds_port_wrap.vhd/files.qip live at repo root (M9 wrapper) and are
# needed by sim/run_analyze_all.sh, which mirrors Quartus's file list.
# The stream is gzipped on purpose. sim/tests carries very large ASCII hex
# images (kirby_full.hex alone is 151 MB), and pushing that raw through the
# kubectl exec websocket reliably kills it partway with "connection reset by
# peer" + "tar: Write error" - a transfer failure that looks exactly like a
# build failure. Hex text compresses several-fold, which shrinks the window
# enough to be dependable. The pod image has gzip and tar -z.
if [ "$DIRTY" = "1" ]; then
   tar -cz rtl sim NDS.sv nds_port_wrap.vhd files.qip | kubectl -n "$NS" exec -i "$POD" -- tar -xz -C /work/src
else
   git archive "$REF" rtl sim NDS.sv nds_port_wrap.vhd files.qip | gzip | kubectl -n "$NS" exec -i "$POD" -- tar -xz -C /work/src
fi
# env overrides are baked into a wrapper so the pod's sh picks them up
kubectl -n "$NS" exec -i "$POD" -- sh -c "cat > /work/src/sim/_wrapped.sh" <<EOF
#!/bin/sh
set -e
export ${ENVVARS:-_NOOP=1}
exec sh "sim/${SCRIPT}"
EOF
kubectl -n "$NS" exec "$POD" -- sh -c "echo _wrapped.sh > /work/src/.script && touch /work/src/.ready"

echo "== running sim/${SCRIPT} ${ENVVARS:+(${ENVVARS})}"
kubectl -n "$NS" logs -f "$POD" &
LOGPID=$!
trap 'kill ${LOGPID} 2>/dev/null || true' EXIT

RC=""
while [ -z "$RC" ]; do
   sleep 5
   RC=$(kubectl -n "$NS" exec "$POD" -- sh -c 'cat /work/exitcode 2>/dev/null' 2>/dev/null || true)
done
kill "$LOGPID" 2>/dev/null || true

echo "== sim exit code: ${RC}"
# ARTIFACTS="a.txt b.txt" copies files (relative to the repo root in the pod)
# into simout/ (or simout/<pod>/ for non-default PODs, so parallel runs
# don't clobber each other) before the pod is deleted
if [ -n "${ARTIFACTS:-}" ]; then
   OUTDIR="simout"
   [ "$POD" != "nds-nvc-sim" ] && OUTDIR="simout/${POD}"
   mkdir -p "$OUTDIR"
   for f in $ARTIFACTS; do
      echo "== fetching $f -> ${OUTDIR}/"
      kubectl -n "$NS" cp "${POD}:/work/src/${f}" "${OUTDIR}/$(basename "$f")" ||
         echo "   (missing: $f)"
   done
fi
if [ "$KEEP" != "1" ]; then
   kubectl -n "$NS" delete pod "$POD" --wait=false
fi
exit "$RC"
