#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Fit the checked-in Clash flat-triangle RTL on the real device. No pins, no
# board image: this answers ALM/LAB cost and register-to-register Fmax.
set -euo pipefail

POD="${POD:-nds-quartus-flat}"
NS="${NS:-default}"
PARALLEL="${PARALLEL:-4}"
KEEP="${KEEP:-0}"
OUT="${OUT:-${TMPDIR:-/tmp}/nds-flat-fit}"

cd "$(dirname "$0")/../.."
mkdir -p "$OUT"

echo "== recreating ${POD} in ${NS}"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait
kubectl -n "$NS" apply -f clash/tests/quartus-flat-pod.yaml
kubectl -n "$NS" wait --for=condition=Ready "pod/${POD}" --timeout=20m

echo "== streaming flat RTL"
tar -C clash/tests/quartus-flat -c NDS_FLAT.qpf NDS_FLAT.qsf NDS_FLAT.sdc \
    -C ../../rtl nds_gpu3d_flat.v \
  | kubectl -n "$NS" exec -i "$POD" -- tar -x -C /work/src
kubectl -n "$NS" exec "$POD" -- bash -c "echo ${PARALLEL} > /work/src/.parallel && touch /work/src/.ready"

echo "== waiting for fit"
rc=""
while [ -z "$rc" ]; do
  sleep 10
  rc=$(kubectl -n "$NS" exec "$POD" -- sh -c 'cat /work/exitcode 2>/dev/null' 2>/dev/null || true)
done

kubectl -n "$NS" exec "$POD" -- cat /work/src/NDS_FLAT.fit.summary > "$OUT/fit.summary" 2>/dev/null || true
kubectl -n "$NS" exec "$POD" -- cat /work/src/NDS_FLAT.sta.summary > "$OUT/sta.summary" 2>/dev/null || true
kubectl -n "$NS" logs "$POD" > "$OUT/quartus.log" 2>/dev/null || true

echo "== fit summary"
cat "$OUT/fit.summary" 2>/dev/null || true
echo "== timing summary"
cat "$OUT/sta.summary" 2>/dev/null || true
echo "== Quartus exit code: ${rc}"

if [ "$KEEP" != 1 ]; then
  kubectl -n "$NS" delete pod "$POD" --wait=false
fi
exit "$rc"
