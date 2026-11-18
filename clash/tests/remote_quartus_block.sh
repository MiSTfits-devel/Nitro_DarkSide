# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Standalone fit of one generated Clash 3D block. No pins, no board image:
# this answers ALM/LAB/register/DSP cost and register-to-register Fmax.
#
#   clash/tests/remote_quartus_block.sh flat|shade|gxfront|polygon|geometry|raster|chip
#
# Environment:
#   NS=default             kubernetes namespace
#   POD=nitro-fit-<block>   pod name (also the claim name is POD-work)
#   CLAIM=nitro-fit-work    reused working claim, wiped at pod startup
#   PARALLEL=4              NUM_PARALLEL_PROCESSORS override
#   KEEP=0                  keep the pod alive for inspection after the fit
#   OUT=<tmpdir>/nds-<block>-fit   local artifact directory
#   FIT_TIMEOUT=5400        seconds before the driver gives up waiting
#   KLOG=/tmp/nitro-fit-kubectl.log   every kubectl call and its output
#   DRY_RUN=0               print the resolved plan and exit
set -euo pipefail

BLOCK="${1:-flat}"
case "$BLOCK" in
  flat)
    REV=NDS_FLAT
    PROJ=clash/tests/quartus-flat
    RTL_FILES=(nds_gpu3d_flat.v)
    ;;
  shade)
    REV=NDS_SHADE
    PROJ=clash/tests/quartus-shade
    RTL_FILES=(nds_gpu3d_shade.v)
    ;;
  # every other block: generated Verilog only, project written by
  # clash/tests/gen_quartus_block_project.sh. A trailing "3x" fits the same
  # block constrained at clk1x (29.838 ns), which is the clock a 3D pipeline
  # that cannot close at 100.5 MHz has to run at.
  *3x)
    BASE="${BLOCK%3x}"
    REV="NDS_$(printf '%s' "$BASE" | tr '[:lower:]' '[:upper:]')3X"
    case "$BASE" in
      chip) TOP=nds_gpu3d RTL_FILES=(nds_gpu3d.v);;
      *)    TOP="nds_gpu3d_${BASE}" RTL_FILES=("nds_gpu3d_${BASE}.v");;
    esac
    PROJ="clash/tests/quartus-${BLOCK}"
    CLOCK_NS=29.838
    ;;
  gxfront|polygon|geometry|raster|chip)
    REV="NDS_$(printf '%s' "$BLOCK" | tr '[:lower:]' '[:upper:]')"
    case "$BLOCK" in
      chip) TOP=nds_gpu3d RTL_FILES=(nds_gpu3d.v);;
      *)    TOP="nds_gpu3d_${BLOCK}" RTL_FILES=("nds_gpu3d_${BLOCK}.v");;
    esac
    PROJ="clash/tests/quartus-${BLOCK}"
    ;;
  *)
    echo "unknown block: ${BLOCK}" >&2
    exit 2
    ;;
esac

# A block whose generated ROM is large enough gets it in a `.inc` beside the top
# (the flat and raster tops do). Quartus resolves the top's `include relative to
# the project directory, so the file has to be streamed beside it but must NOT be
# listed as a VERILOG_FILE: a `.inc` starts with a `` ` `` directive, which
# Quartus rejects when it compiles the file on its own.
EXTRA_FILES=()
for rtl in "${RTL_FILES[@]}"; do
  for inc in "clash/rtl/${rtl%.v}_enc_"*.inc; do
    [ -f "$inc" ] && EXTRA_FILES+=("$(basename "$inc")")
  done
done

if [ ! -f "$PROJ/${REV}.qsf" ]; then
  CLOCK_NS=${CLOCK_NS:-9.946} \
    clash/tests/gen_quartus_block_project.sh "$BLOCK" "$TOP" \
      $(printf '%s ' "${RTL_FILES[@]}") >/dev/null
fi

NS="${NS:-default}"
POD="${POD:-nitro-fit-${BLOCK}}"
CLAIM="${CLAIM:-nitro-fit-work}"
PARALLEL="${PARALLEL:-4}"
KEEP="${KEEP:-0}"
DRY_RUN="${DRY_RUN:-0}"
FIT_TIMEOUT="${FIT_TIMEOUT:-5400}"
OUT="${OUT:-${TMPDIR:-/tmp}/nds-${BLOCK}-fit}"
KLOG="${KLOG:-/tmp/nitro-fit-kubectl.log}"

if [[ ! "$POD" =~ ^([a-z0-9]|[a-z0-9][-a-z0-9]{0,61}[a-z0-9])$ ]]; then
  echo "invalid POD: ${POD}" >&2
  exit 2
fi
if [[ ! "$NS" =~ ^([a-z0-9]|[a-z0-9][-a-z0-9]{0,61}[a-z0-9])$ ]]; then
  echo "invalid NS: ${NS}" >&2
  exit 2
fi
if [[ ! "$CLAIM" =~ ^([a-z0-9]|[a-z0-9][-a-z0-9]{0,61}[a-z0-9])$ ]]; then
  echo "invalid CLAIM: ${CLAIM}" >&2
  exit 2
fi
if [[ ! "$PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
  echo "invalid PARALLEL: ${PARALLEL}" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# every kubectl call goes through here, so the log is complete
klog_cmd() { printf '\n$ kubectl %s\n' "$*" >>"$KLOG"; }
klog_run() { klog_cmd "$@"; kubectl "$@" 2>&1 | tee -a "$KLOG"; return "${PIPESTATUS[0]}"; }

for f in "$PROJ/${REV}.qpf" "$PROJ/${REV}.qsf" "$PROJ/${REV}.sdc" \
         $(printf 'clash/rtl/%s ' "${RTL_FILES[@]}" "${EXTRA_FILES[@]}"); do
  if [ ! -f "$f" ]; then
    echo "missing source: ${f}" >&2
    exit 2
  fi
done

if [ "$DRY_RUN" = "1" ]; then
  echo "block=${BLOCK} rev=${REV} proj=${PROJ}"
  echo "pod=${POD} claim=${CLAIM} ns=${NS} parallel=${PARALLEL}"
  echo "out=${OUT} rtl=${RTL_FILES[*]}"
  exit 0
fi

mkdir -p "$OUT"
MANIFEST="$(mktemp "${TMPDIR:-/tmp}/nds-fit-pod.XXXXXX.yaml")"
trap 'rm -f "$MANIFEST"' EXIT
sed -e "s/__POD__/${POD}/g" -e "s/__REV__/${REV}/g" -e "s/__CLAIM__/${CLAIM}/g" \
  clash/tests/quartus-block-pod.yaml > "$MANIFEST"

echo "== recreating ${POD} in ${NS} (claim ${CLAIM})"
klog_run -n "$NS" delete pod "$POD" --ignore-not-found --wait
klog_run -n "$NS" apply -f "$MANIFEST"
if ! klog_run -n "$NS" wait --for=condition=Ready "pod/${POD}" --timeout=20m; then
  echo "pod did not become ready; logs:" >&2
  kubectl -n "$NS" describe pod "$POD" >&2 || true
  exit 3
fi

# condition=Ready is set when the container starts, which is BEFORE its own
# `rm -rf /work/src` runs. Stream after that wipe, not before it: wait for the
# cleanup's log line. (The 2026-11-06 fit hit exactly this: the source and the
# .ready handshake were wiped by the pod's startup cleanup, and the pod sat in its
# wait loop with the tree apparently complete.)
waited=0
while ! kubectl -n "$NS" logs "$POD" 2>/dev/null | grep -q "waiting for source"; do
  if [ "$waited" -ge 300 ]; then
    echo "pod never reached its source wait; logs:" >&2
    kubectl -n "$NS" logs "$POD" >&2 || true
    exit 3
  fi
  sleep 5
  waited=$((waited + 5))
done
klog_cmd -n "$NS" logs "$POD" --tail=20

echo "== streaming ${REV} project and RTL"
klog_cmd -n "$NS" exec -i "$POD" -- tar -x -C /work/src
tar -C "$PROJ" -cf - "${REV}.qpf" "${REV}.qsf" "${REV}.sdc" \
    -C ../../rtl "${RTL_FILES[@]}" "${EXTRA_FILES[@]}" \
  | kubectl -n "$NS" exec -i "$POD" -- tar -xf - -C /work/src
echo "== hand ${REV} over to the pod"
klog_cmd -n "$NS" exec "$POD" -- bash -c "echo ${PARALLEL} > /work/src/.parallel; touch /work/src/.ready"
# The pod's startup rm can land after condition=Ready, so a single handshake
# is not reliable. Rewrite it until the pod logs that the flow started.
started=0
for _ in $(seq 1 60); do
  if kubectl -n "$NS" logs "$POD" 2>/dev/null > "${OUT}/pod.log"; then
    if grep -q "=== quartus_sh --flow compile" "${OUT}/pod.log"; then
      started=1
      break
    fi
  fi
  sleep 2
  kubectl -n "$NS" exec "$POD" -- bash -c "echo ${PARALLEL} > /work/src/.parallel; touch /work/src/.ready" >/dev/null 2>&1 || true
done
if [ "$started" != 1 ]; then
  echo "pod never started the flow; logs:" >&2
  kubectl -n "$NS" logs "$POD" >&2 || true
  exit 3
fi

echo "== waiting for fit (timeout ${FIT_TIMEOUT}s)"
rc=""
waited=0
while [ -z "$rc" ]; do
  sleep 15
  waited=$((waited + 15))
  rc=$(kubectl -n "$NS" exec "$POD" -- sh -c 'cat /work/exitcode 2>/dev/null' 2>/dev/null || true)
  if [ -z "$rc" ] && [ "$waited" -ge "$FIT_TIMEOUT" ]; then
    echo "== timeout after ${waited}s, fetching what exists" >&2
    rc=timeout
    break
  fi
  if [ -z "$rc" ] && ! kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1; then
    echo "== pod disappeared before writing /work/exitcode" >&2
    rc=lost
    break
  fi
done
klog_cmd -n "$NS" get pod "$POD" -o wide

fetch() {
  kubectl -n "$NS" exec "$POD" -- cat "$2" > "${OUT}/$1" 2>/dev/null || rm -f "${OUT}/$1"
}
for f in fit.summary sta.summary clocks.rpt paths.rpt paths_hold.rpt; do
  klog_cmd -n "$NS" exec "$POD" -- cat "/work/out/${REV}.${f}"
  fetch "$f" "/work/out/${REV}.${f}"
done
klog_run -n "$NS" logs "$POD" > "${OUT}/quartus.log" 2>/dev/null || true

echo "== fit summary"
cat "${OUT}/fit.summary" 2>/dev/null || true
echo "== timing summary"
cat "${OUT}/sta.summary" 2>/dev/null || true
echo "== clocks"
cat "${OUT}/clocks.rpt" 2>/dev/null || true
echo "== Quartus exit code: ${rc}"

if [ "$KEEP" != 1 ]; then
  klog_run -n "$NS" delete pod "$POD" --wait=false
else
  echo "== KEEP=1: pod ${POD} left running, claim ${CLAIM} mounted at /work"
fi

if [ "$rc" = "timeout" ] || [ "$rc" = "lost" ]; then
  exit 3
fi
exit "$rc"
