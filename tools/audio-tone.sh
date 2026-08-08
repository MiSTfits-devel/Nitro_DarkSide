#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Milestone-0 exit test for the HPS audio pipe: play a tone out of the core with
# no daemon, no ARM toolchain and no rebuild.
#
#   tools/audio-tone.sh on          # generate, stage into DDR3, enable LOOP
#   tools/audio-tone.sh off         # clear ENABLE (core falls back to the SPU)
#   tools/audio-tone.sh status      # is the FPGA consuming, and is it starving
#   HOST=192.168.1.243 tools/audio-tone.sh on
#
# Needs a core built with NDS_HPS_AUDIO (see NDS.qsf) already loaded. DDR3
# survives FPGA reconfiguration, so the image can be staged before or after the
# core is loaded - but ENABLE must be re-asserted after a core reset, because
# the FPGA resyncs to ring frame 0 and republishes rd_ptr from zero.
#
# WRITE ORDER IS LOAD-BEARING. devmem does 32-bit accesses (tools/nitrodbg.sh
# says why), so the two halves of the 64-bit control beat land separately and
# the FPGA can poll between them. Enabling therefore writes wr_ptr FIRST and the
# magic+flags word LAST: a poll caught in the middle sees the old flags, which
# read as disabled, and simply tries again. Disabling writes the flags word
# first for the same reason. In steady state a daemon only ever moves wr_ptr, so
# the beat cannot tear at all.
set -eu

HOST="${HOST:-192.168.1.243}"
SSH="ssh -o ConnectTimeout=25 -o StrictHostKeyChecking=accept-new"

# HPS view of the FPGA's DDR3: FPGA byte 0x0FFD0000 == HPS 0x3FFD0000
BASE=0x3FFD0000
WRPTR=0x3FFD0000
CTRL=0x3FFD0004        # {magic 0xAD10, flags}: bit0 ENABLE, bit1 LOOP
RDPTR=0x3FFD0008
STAT=0x3FFD000C        # {magic 0xAD11, underruns}
PAGE=4096
IMG=/tmp/nds_audio_ring.bin

usage() { echo "usage: $0 {on|off|status}" >&2; exit 1; }
[ $# -ge 1 ] || usage

case "$1" in
on)
	shift
	GEN=$(python3 "$(dirname "$0")/mkaudioring.py" "$IMG" "$@")
	echo "$GEN" | grep -v '^VERIFY '
	SIZE=$(wc -c < "$IMG" | tr -d ' ')
	[ $((SIZE % PAGE)) -eq 0 ] || { echo "image is not page-aligned: $SIZE" >&2; exit 2; }

	$SSH "root@$HOST" "command -v devmem >/dev/null" \
		|| { echo "devmem not found on $HOST" >&2; exit 2; }

	echo "== staging $SIZE bytes to HPS $BASE"
	# straight down the pipe: no room on /tmp is not worth assuming
	$SSH "root@$HOST" \
		"dd of=/dev/mem bs=$PAGE seek=$((BASE / PAGE)) count=$((SIZE / PAGE)) conv=notrunc 2>&1 | tail -1" \
		< "$IMG"

	# Read two ring words back before enabling. dd to /dev/mem is far less
	# travelled here than devmem is, and a write that silently went nowhere
	# leaves a ring full of whatever was there before - which plays as noise, or
	# as nothing, and looks exactly like a broken core rather than a failed copy.
	# The generator picks the readback points by sample magnitude: a zero word
	# would match whatever stale content was already at that address and so
	# verify nothing.
	echo "== verifying the copy landed"
	echo "$GEN" | grep '^VERIFY ' | while read -r _ OFF WANT; do
		GOT=$($SSH "root@$HOST" "devmem $((BASE + OFF)) 32")
		GOT=$(printf '%08x' "$GOT")
		if [ "$GOT" != "$WANT" ]; then
			echo "STAGING FAILED at +$OFF: want $WANT got $GOT" >&2
			echo "  DDR3 was NOT updated. Not enabling, so the core stays as it was." >&2
			exit 4
		fi
	done || exit 4

	echo "== enabling (ENABLE | LOOP)"
	$SSH "root@$HOST" "devmem $WRPTR 32 0x00000000; devmem $CTRL 32 0xAD100003"
	echo "== playing. 'status' to check, 'off' to stop."
	;;

off)
	# flags first, so a poll between the two writes can only ever see it OFF
	$SSH "root@$HOST" "devmem $CTRL 32 0xAD100000; devmem $WRPTR 32 0x00000000"
	echo "== disabled"
	;;

status)
	# rd_ptr sampled twice: the FPGA republishes it every ~61us, so a pair that
	# does not move means it is not consuming, which is the whole question here.
	OUT=$($SSH "root@$HOST" "devmem $CTRL 32; devmem $RDPTR 32; devmem $STAT 32; sleep 1; devmem $RDPTR 32")
	set -- $OUT
	echo "  control  $1   (magic AD10 + flags: bit0 ENABLE, bit1 LOOP)"
	echo "  rd_ptr   $2 -> $4"
	echo "  status   $3   (magic AD11 + underrun count)"
	D=$(( $4 - $2 ))
	echo "  consumed $D frames in ~1 s (expect ~32729; 0 means the FPGA is not reading)"
	;;

*) usage ;;
esac
