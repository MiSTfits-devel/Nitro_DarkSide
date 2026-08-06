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
# the original was untracked and went missing with the rest of scratchpad/.
#
# Guards, in order of how badly you would regret losing them:
#   1. No EXISTING remote .rbf is overwritten at all - the target name must be new.
#      Old test cores are evidence from past sessions; do not clobber them.
#   2. The upload is staged to a .tmp name and only moved into place after its
#      sha256 is verified ON THE DEVICE against the local file. A truncated scp
#      over a flaky link otherwise gives you a core that fails to configure and an
#      afternoon of debugging the wrong thing.
#
# There used to be a third guard here refusing to write NDS_20260719.rbf, described
# as "the known-good production core". It was not one - it does not work - so the
# rule protected nothing and only added a name that had to be kept in sync by hand.
# Removed 2026-08-05 at the owner's instruction. Guard 1 already stops any existing
# core, that one included, from being clobbered.
set -eu

HOST="${HOST:-192.168.1.243}"
CORE_DIR="${CORE_DIR:-/media/fat/_Console}"
SSH="ssh -o ConnectTimeout=25 -o StrictHostKeyChecking=accept-new"

[ $# -eq 2 ] || { echo "usage: $0 <local.rbf> <NewName>" >&2; exit 1; }
LOCAL="$1"
NAME="$(basename "$2" .rbf)"
REMOTE="$CORE_DIR/$NAME.rbf"

[ -f "$LOCAL" ] || { echo "no such file: $LOCAL" >&2; exit 1; }

# --- guard 1: never overwrite anything that already exists ---
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

if [ -n "${NOLOAD:-}" ]; then
   echo "== NOLOAD set, not loading"
   exit 0
fi

echo "== load_core $REMOTE"
$SSH "root@$HOST" "echo 'load_core $REMOTE' > /dev/MiSTer_cmd"
echo "== requested. NOTE: DDR3 loses the cart image on a POWER CYCLE - if the"
echo "   machine was powered off, load the ROM once through the OSD, then"
echo "   tools/nitrodbg.sh forcecart makes subsequent core reloads unattended."
