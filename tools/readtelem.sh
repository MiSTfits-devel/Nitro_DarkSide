#!/bin/sh
# readtelem - pull the NDS core's live telemetry out of DDR3 on the MiSTer.
#
# WHY THIS IS NOT JUST SIX devmem CALLS
#
# The telemetry burst in rtl/nds_fb_ddr3.sv targets framebuffer line 191 of
# screen 0 (`dy <= 8'd191`), and the *normal* video writer targets whatever line
# it just rendered (`dy <= job_y_a`, i.e. 0..191) - so every frame overwrites the
# telemetry with pixel data. Telemetry refreshes every ~125 ms (22-bit counter at
# 33.5 MHz) and line 191 re-renders every 16.7 ms, so a genuine sample is visible
# roughly 13% of the time. On the white screen the clobbered value is
# 0x0003FFFF0003FFFF - BGR666 all-ones, twice - which is exactly what a blind
# read returns most of the time.
#
# The validity marker: lane dbg3 is hardwired to 18'd0 (NDS.sv), and it sits in
# the HIGH half of the beat at +0x08. So a beat at +0x08 whose top 32 bits are
# zero was written by the telemetry job, not by the pixel path. All six beats
# come from one burst, so when that marker holds the whole set is consistent -
# this reads them together and re-checks the marker afterwards to reject a set
# torn by a render landing mid-read.
#
# Lane map (each beat = two 18-bit lanes, low half first):
#   +0x00  dbg0 = PC9[17:0]        dbg1 = PC9[31:18]
#   +0x08  dbg2 = vfy mismatches   dbg3 = 0            <- validity marker
#   +0x10  dbg4 = vfy addr[17:0]   dbg5 = vfy addr[31:18]
#   +0x18  dbg6 = CPSR9            dbg7 = PC7[17:0]
#   +0x20  dbg8 = PC7[31:18]       dbg9 = vfy mismatches (mirror)
#   +0x28  dbg10 = core status     dbg11 = shell status
#
# Usage: readtelem.sh [tries]     (default 300, ~a few seconds)

B=0x3FE2FC
TRIES=${1:-300}

lo() { printf '%d' "0x$(echo "$1" | cut -c11-18)"; }   # beat[31:0]
hi() { printf '%d' "0x$(echo "$1" | cut -c3-10)";  }   # beat[63:32]

i=0
while [ "$i" -lt "$TRIES" ]; do
	b1=$(devmem ${B}08 64)
	if [ "$(hi "$b1")" = "0" ]; then
		b0=$(devmem ${B}00 64)
		b2=$(devmem ${B}10 64)
		b3=$(devmem ${B}18 64)
		b4=$(devmem ${B}20 64)
		b5=$(devmem ${B}28 64)
		# re-check: if a render landed while we were reading, discard the set
		if [ "$(hi "$(devmem ${B}08 64)")" != "0" ]; then i=$((i + 1)); continue; fi

		pc9=$(( $(hi "$b0") << 18 | $(lo "$b0") ))
		pc7=$(( $(hi "$b4") << 18 | $(lo "$b3") ))
		bad=$(lo "$b1")
		bad2=$(hi "$b4")
		vad=$(( $(hi "$b2") << 18 | $(lo "$b2") ))
		cpsr=$(lo "$b3")
		hw=$(lo "$b5")
		sh=$(hi "$b5")

		echo "caught a live telemetry beat after $i discarded read(s)"
		echo
		printf 'MAIN-RAM VERIFY  mismatches = %d   (mirror lane = %d)\n' "$bad" "$bad2"
		if [ "$bad" -eq 0 ]; then
			echo "                 -> SDRAM main RAM read back every word the loader wrote"
		else
			printf '                 -> first bad address 0x%08X\n' "$vad"
		fi
		echo
		printf 'ARM9  r15=0x%08X  CPSR=0x%05X  mode=%02X I=%d F=%d T=%d\n' \
			"$pc9" "$cpsr" "$((cpsr & 0x1F))" "$(((cpsr >> 7) & 1))" \
			"$(((cpsr >> 6) & 1))" "$(((cpsr >> 5) & 1))"
		printf 'ARM7  r15=0x%08X\n' "$pc7"
		printf 'core status 0x%05X   shell status 0x%05X\n' "$hw" "$sh"
		echo
		echo "(r15 is the architectural PC: subtract 8 in ARM state, 4 in Thumb)"
		exit 0
	fi
	i=$((i + 1))
done

echo "no valid telemetry beat in $TRIES tries." >&2
echo "Every read looked like pixel data. Either the core running is not a" >&2
echo "telemetry build, or nothing is driving the framebuffer at all." >&2
echo "Last beat at ${B}08: $b1" >&2
exit 1
