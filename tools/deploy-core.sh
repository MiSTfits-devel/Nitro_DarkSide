#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Upload an NDS core to the MiSTer and load it, without ever endangering the
# production core or any existing test core.
#
#   tools/deploy-core.sh <local.rbf> <NewName>            # upload + verify + load
#   HOST=192.168.1.243 tools/deploy-core.sh build/artifacts-isl0/NDS.rbf NDS_isl0_20260728
#   NOLOAD=1 ...                                          # upload + verify, do not load
#
# This replaces the lost scratchpad/deploy-probe.sh. It lives in tools/ ON PURPOSE:
# the original was untracked, went missing with the rest of scratchpad/, and its
# production-core guard went with it.
#
# Guards, in order of how badly you would regret losing them:
#   1. PROTECTED never gets written, whatever you pass.
#   2. No EXISTING remote .rbf is overwritten at all - the target name must be new.
#      Old test cores are evidence from past sessions; do not clobber them.
#   3. The upload is staged to a .tmp name and only moved into place after its
#      sha256 is verified ON THE DEVICE against the local file. A truncated scp
#      over a flaky link otherwise gives you a core that fails to configure and an
#      afternoon of debugging the wrong thing.
set -eu

PROTECTED="NDS_20260719.rbf"       # the known-good production core. Never touch.
HOST="${HOST:-192.168.1.243}"
CORE_DIR="${CORE_DIR:-/media/fat/_Console}"
SSH="ssh -o ConnectTimeout=25 -o StrictHostKeyChecking=accept-new"

[ $# -eq 2 ] || { echo "usage: $0 <local.rbf> <NewName>" >&2; exit 1; }
LOCAL="$1"
NAME="$(basename "$2" .rbf)"
REMOTE="$CORE_DIR/$NAME.rbf"

[ -f "$LOCAL" ] || { echo "no such file: $LOCAL" >&2; exit 1; }

# --- guard 1: the production core, by name, case-insensitively ---
case "$(echo "$NAME.rbf" | tr 'A-Z' 'a-z')" in
   "$(echo "$PROTECTED" | tr 'A-Z' 'a-z')")
      echo "REFUSING: $PROTECTED is the production core and is never a deploy target." >&2
      exit 2 ;;
esac

# --- guard 2: never overwrite anything that already exists ---
if $SSH "root@$HOST" "[ -e '$REMOTE' ]" 2>/dev/null; then
   echo "REFUSING: $REMOTE already exists. Pick a new name - existing cores are" >&2
   echo "          evidence from earlier sessions and are not overwritten here." >&2
   exit 3
fi

LSUM=$(shasum -a 256 "$LOCAL" | cut -d' ' -f1)
SIZE=$(wc -c < "$LOCAL" | tr -d ' ')
echo "== $LOCAL ($SIZE bytes, sha256 ${LSUM%${LSUM#????????}}...)"
echo "== -> root@$HOST:$REMOTE"

echo "== uploading to $REMOTE.tmp"
scp -o ConnectTimeout=25 -o StrictHostKeyChecking=accept-new "$LOCAL" "root@$HOST:$REMOTE.tmp"

echo "== verifying sha256 on the device"
RSUM=$($SSH "root@$HOST" "sha256sum '$REMOTE.tmp' | cut -d' ' -f1" | tr -d '\r')
if [ "$LSUM" != "$RSUM" ]; then
   echo "SHA MISMATCH - local $LSUM remote $RSUM" >&2
   $SSH "root@$HOST" "rm -f '$REMOTE.tmp'" || true
   exit 4
fi
echo "== sha256 OK"

$SSH "root@$HOST" "mv '$REMOTE.tmp' '$REMOTE'"
echo "== in place: $REMOTE"

# re-assert guard 1 after the fact: if the protected core's checksum ever changes,
# something in this flow was wrong and you want to know immediately, not later.
$SSH "root@$HOST" "[ -e '$CORE_DIR/$PROTECTED' ] && sha256sum '$CORE_DIR/$PROTECTED'" \
   | sed 's/^/== production core still: /' || echo "== (production core not present?)"

if [ -n "${NOLOAD:-}" ]; then
   echo "== NOLOAD set, not loading"
   exit 0
fi

echo "== load_core $REMOTE"
$SSH "root@$HOST" "echo 'load_core $REMOTE' > /dev/MiSTer_cmd"
echo "== requested. NOTE: DDR3 loses the cart image on a POWER CYCLE - if the"
echo "   machine was powered off, load the ROM once through the OSD, then"
echo "   tools/nitrodbg.sh forcecart makes subsequent core reloads unattended."
