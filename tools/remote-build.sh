#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Headless Quartus build of the grafted NDS4MiSTer core on the k8s cluster.
# Ported from Nitro_DarkSide build/remote-build.sh (single revision).
#
#   tools/remote-build.sh [git-ref]     # default: HEAD
#   DIRTY=1 tools/remote-build.sh       # working tree incl. uncommitted
#
# Environment:
#   NS=default                        kubernetes namespace
#   PARALLEL=8                        NUM_PARALLEL_PROCESSORS override
#   POD=nds4mister-quartus-build      isolated pod name
#   ARTIFACT_DIR=artifacts/remote     local report/output directory
#   SEED_OVERRIDE=                    build-only fitter seed override
#
# The source is streamed into the pod with git archive - only committed files
# of the given ref are built, and the branch never has to be pushed anywhere.
# Unlike the Nitro_DarkSide original, the project is not at the repo root: it
# is fpga/mister_nitro_console_island, and its files.qip reaches up into
# ../../rtl and ../../third_party. So whole repo prefixes are streamed with
# their paths intact rather than a flat list of project files.
set -euo pipefail

REF="${1:-HEAD}"
NS="${NS:-default}"
PARALLEL="${PARALLEL:-8}"
DIRTY="${DIRTY:-0}"
POD="${POD:-nds4mister-quartus-build}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts/remote}"
SEED_OVERRIDE="${SEED_OVERRIDE:-}"
PROJECT_DIR="fpga/mister_nitro_console_island"
SOURCE_PREFIXES=(fpga rtl third_party)
ARTIFACT_FILES=(
   NDS4MiSTer.rbf NDS4MiSTer.fit.summary NDS4MiSTer.map.summary
   NDS4MiSTer.sta.summary NDS4MiSTer.sta.rpt NDS4MiSTer.flow.rpt
   NDS4MiSTer.fit.rpt NDS4MiSTer.map.rpt
   # Worst 50 setup and hold paths, full detail. A hold failure cannot be
   # fixed from the per-clock summary the default sta.rpt carries.
   NDS4MiSTer.paths.rpt
   NDS4MiSTer.paths_hold.rpt
   # Every violating setup path: did this build close, and if not, what.
   NDS4MiSTer.paths_violated.rpt
   # The worst 3000 by slack. Its Data Delay column is cadence-independent:
   # a path blocks the native cadence when that delay exceeds clk2x's native
   # 14.92 ns period, whatever this build was constrained at.
   NDS4MiSTer.paths_delay.rpt
   # ARM9-hierarchy-only paths. The global report is ranked by slack and caps
   # out long before it reaches the CPU, so it cannot answer "would the ARM9
   # close" - this one is scoped to icpu9/imembus9 and can.
   NDS4MiSTer.paths_cpu9.rpt
   # ...but paths_cpu9 is -detail summary: it names endpoints and never says
   # where the nanoseconds went. Same four families, full_path, two paths each.
   NDS4MiSTer.paths_fam.rpt
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
# build/ is gitignored in this repo (it is the CMake build directory), so the
# driver and its reports live under tools/ and artifacts/ instead.
case "$ARTIFACT_DIR" in
   "$REPO_ROOT"/artifacts/*) ;;
   *)
      echo "ARTIFACT_DIR must resolve below ${REPO_ROOT}/artifacts: ${ARTIFACT_DIR}" >&2
      exit 2
      ;;
esac

echo "== recreating pod ${POD} in ${NS}"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait
sed "s/nds4mister-quartus-build/${POD}/g" tools/quartus-pod.yaml | kubectl -n "$NS" apply -f -
# first run pulls a multi-GB image, give it time
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=20m

echo "== streaming source (${REF}, dirty=${DIRTY})"
if [ "$DIRTY" = "1" ]; then
   tar -c "${SOURCE_PREFIXES[@]}" \
      | kubectl -n "$NS" exec -i "$POD" -- tar -x -C /work/src
else
   git archive "$REF" "${SOURCE_PREFIXES[@]}" \
      | kubectl -n "$NS" exec -i "$POD" -- tar -x -C /work/src
fi
if [[ -n "$SEED_OVERRIDE" ]]; then
   kubectl -n "$NS" exec "$POD" -- sed -i \
      "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED ${SEED_OVERRIDE}/" \
      "/work/src/${PROJECT_DIR}/NDS4MiSTer.qsf"
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
# Clear only this driver's known generated outputs. Otherwise a failed fit can
# leave an old local report beside newly fetched partial results.
for f in "${ARTIFACT_FILES[@]}"; do
   rm -f -- "${ARTIFACT_DIR}/${f}"
done
# kubectl cp doesn't propagate remote tar failures, so check existence first
for f in "${ARTIFACT_FILES[@]}"; do
   if kubectl -n "$NS" exec "$POD" -- test -f "/work/src/${PROJECT_DIR}/output_files/${f}" 2>/dev/null; then
      kubectl -n "$NS" cp "${POD}:/work/src/${PROJECT_DIR}/output_files/${f}" "${ARTIFACT_DIR}/${f}" \
         && echo "   fetched ${f}"
   else
      echo "   missing ${f}"
   fi
done

kubectl -n "$NS" delete pod "$POD" --wait=false
exit "$RC"
