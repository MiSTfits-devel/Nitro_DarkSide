#!/usr/bin/env bash
# Compile the current dirty tree in a dedicated Quartus pod. This is separate
# from build/remote-build.sh because that driver intentionally archives only a
# committed revision; Clash migration work needs to validate new, uncommitted
# HDL before asking the user to commit it.
set -euo pipefail

POD="${POD:-nds-quartus-clash-9}"
NS="${NS:-default}"
PARALLEL="${PARALLEL:-4}"
KEEP="${KEEP:-0}"

cd "$(dirname "$0")/../.."

echo "== recreating ${POD} in ${NS}"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait
sed "s/nds-quartus-build/${POD}/g" build/quartus-pod.yaml | kubectl -n "$NS" apply -f -
kubectl -n "$NS" wait --for=condition=Ready "pod/${POD}" --timeout=20m

echo "== streaming dirty tree (including Clash build inputs)"
tar -c NDS.qpf NDS.qsf NDS.sdc NDS.sv nds_port_wrap.vhd files.qip rtl sys clash \
  | kubectl -n "$NS" exec -i "$POD" -- tar -x -C /work/src
kubectl -n "$NS" exec "$POD" -- bash -c "echo ${PARALLEL} > /work/src/.parallel && touch /work/src/.ready"

kubectl -n "$NS" logs -f "$POD" &
log_pid=$!
trap 'kill "$log_pid" 2>/dev/null || true' EXIT

rc=""
while [ -z "$rc" ]; do
  sleep 10
  rc=$(kubectl -n "$NS" exec "$POD" -- sh -c 'cat /work/exitcode 2>/dev/null' 2>/dev/null || true)
done
kill "$log_pid" 2>/dev/null || true

echo "== Quartus integration exit code: ${rc}"
if [ "$KEEP" != 1 ]; then
  kubectl -n "$NS" delete pod "$POD" --wait=false
fi
exit "$rc"
