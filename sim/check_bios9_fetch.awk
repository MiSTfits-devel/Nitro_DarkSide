# SPDX-License-Identifier: GPL-2.0-or-later
#
# Assert that every ARM9 BIOS fetch in a trace really delivered the word the
# BIOS image holds at that address. Oracle-free: the expected value is known
# exactly, so a mismatch is a fact, not a theory.
#
#   awk -f sim/check_bios9_fetch.awk sim/tests/bios9_retail.hex isl9.txt
#   ARM7=1 awk -v arm7=1 -f sim/check_bios9_fetch.awk sim/tests/bios7_retail.hex isl7.txt
#
# Exits 1 on any mismatch.
#
# Why this exists: ibios9 was clocked on clk1x while the ARM9 island runs on
# clk2x, and T_BROM has no done handshake (nds_membus9.vhd:191 drives the
# address combinationally from cpu_adr, :508 consumes the data combinationally
# in FINISH). The ROM therefore sampled the address on only every OTHER island
# cycle and every second BIOS9 fetch returned the previous word - 15 of Kirby's
# first 28 BIOS fetches. The first one, the swi 0x0B vector fetch at 0xFFFF0008,
# returned word 0 (the reset vector) instead of the SWI vector, which branched
# the ARM9 into the middle of the BIOS CRC16 helper and from there into ITCM
# garbage. An instruction-exact trace diff cannot see any of this: it is a
# wrong value the trace faithfully records.
#
# TRACE PC CONVENTION - calibrated against the ARM7, which shares its CPU's
# clock and is the known-good control. In ARM state the pc column is the
# PIPELINE pc, i.e. instruction address + 8, so the opcode on a line belongs to
# address pc-8. Measured on the ARM7's 9,759 ARM-state BIOS fetches: 0 match at
# pc, 9,272 at pc-8. Do not "fix" this by comparing at pc.
#
# Thumb lines are skipped: the trace prints a zero-extended 16-bit halfword and
# steps pc by 2, so a word compare is meaningless. The ARM7 BIOS is mostly
# Thumb (251,520 of its lines); the ARM9's BIOS entry path is all ARM.
#
# Lines whose opcode has a zero high halfword are also skipped, and this is not
# cosmetic: on an ARM/Thumb transition the cpsr column already carries the new
# (T-clear) flag while the opcode is still the Thumb halfword. Those were all
# 487 residual "mismatches" on the ARM7 control - with them excluded the ARM7 is
# 9,272 of 9,272, which is what makes a nonzero count on the ARM9 meaningful.
# A returned 0x00000000 is exempted from that exclusion: an all-zero read is the
# signature of a fetch that no one answered, i.e. the thing being hunted.

function h(s,   i, c, n) {
   n = 0
   for (i = 1; i <= length(s); i++) {
      c = index("0123456789ABCDEF", toupper(substr(s, i, 1))) - 1
      n = n * 16 + c
   }
   return n
}

BEGIN { pat = arm7 ? "^0000[0-3][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$" \
                   : "^FFFF0[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$" }

# first file: one 32-bit word per line, word k at byte offset k*4
NR == FNR { bios[(FNR - 1) * 4] = toupper($1); next }

# trace lines: pc opcode cpsr r0 r1 ...
$1 ~ pat {
   # cpsr bit 5 is the T flag: bit 1 of the second-lowest hex digit
   if (int(h(substr($3, 7, 1)) / 2) % 2 == 1) { thumb++; next }
   # zero high halfword: a Thumb opcode on a transition line, unless it is an
   # all-zero word, which means nobody answered the fetch
   if (substr($2, 1, 4) == "0000" && toupper($2) != "00000000") { thumbx++; next }
   addr = h(substr($1, 5)) - 8
   if (!(addr in bios)) { outside++; next }
   total++
   if (toupper($2) == bios[addr]) ok++
   else {
      bad++
      stale = (toupper($2) == bios[addr - 4])
      if (stale) staleprev++
      if (bad <= 20)
         printf "MISMATCH pc=%s addr=%04X got=%s want=%s%s\n",
                $1, addr, $2, bios[addr], stale ? "   <- is the PREVIOUS word" : ""
   }
}

END {
   printf "\nBIOS fetches: %d  match: %d  mismatch: %d (%d were the previous word)\n",
          total, ok, bad, staleprev
   printf "skipped: %d thumb, %d thumb-transition, %d outside the image\n",
          thumb, thumbx, outside
   if (total == 0) { print "NO BIOS FETCHES - the trace never entered the BIOS"; exit 1 }
   if (bad > 0) exit 1
   print "OK - every BIOS fetch delivered the right word"
}
