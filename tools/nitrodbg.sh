#!/bin/sh
# nitrodbg - host side of the on-FPGA IS-NITRO-style debugger (rtl/nds_debug.vhd).
#
# Runs ON the MiSTer, in busybox ash. Talks to the ch4 DDR3 mailbox in NDS.sv:
#
#   command  @ 0x3FFF0000   {16'hDB90, seq[7:0], op[7:0], arg[31:0]}
#   response @ 0x3FFF0008   {16'hDB91, ack[7:0], 8'h00,   data[31:0]}
#
# Bump seq, spin until ack matches, read data. The FPGA polls the command beat
# every ~122us, so a command round-trips in well under a millisecond.
#
#   scp tools/nitrodbg.sh root@mister:/media/fat/
#   ssh root@mister /media/fat/nitrodbg.sh regs9
#
# Usage:
#   nitrodbg.sh halt9 | run9 | halt7 | run7
#   nitrodbg.sh step9 [cycles]        release for N clk1x cycles, then hold
#   nitrodbg.sh brk9 <hexaddr>        halt when the architectural PC matches
#   nitrodbg.sh brkclr9
#   nitrodbg.sh reg9 <0-16>           0..15 = r0..r15 in the current mode, 16 = CPSR
#   nitrodbg.sh regs9                 dump all 17
#   nitrodbg.sh peek9 <hexaddr>       read a word through the CPU's own bus
#   nitrodbg.sh dump9 <hexaddr> [n]   n consecutive words
#   nitrodbg.sh status
#   nitrodbg.sh where9                PC + CPSR + the word at the PC, decoded a little
#   nitrodbg.sh softreset             restart the boot FSM; both cores held at t=0
#   nitrodbg.sh probe                 decode the ARM9 memory path's FSMs (op 0x0A):
#                                     tells a wedged CPU apart from a merely slow one
#   nitrodbg.sh forcecart             claim the card image is already in DDR3 (op 0x0B),
#                                     so a freshly deployed core boots with no OSD
#   nitrodbg.sh irq                   IME/IE/IF for both CPUs (op 0x0C); peek cannot
#                                     read IO space, so this is the only way to see them
#   nitrodbg.sh reach9 <hex> [secs]   from t=0, is that PC ever executed? (bisect probe)
#   nitrodbg.sh reach7 <hex> [secs]
#
# PEEK reads through the CPU's memory port, which means a peek issued while a
# core is RUNNING can swallow that core's own bus completion and wedge it.
# Always halt9/halt7 first (reach9/where9 handle this themselves).
#
# The 7/9 suffix picks the CPU. BADACCE5 as a peek result means the bus never
# answered (unmapped address) - the timeout fired, nothing is wedged.
#
# Remember the ARM architectural PC offset: r15 reads as the instruction address
# + 8 in ARM state, + 4 in Thumb. `where9` already subtracts it.

# Both beats are split into their two 32-bit halves on purpose. A 64-bit devmem
# write may or may not become a single store on armv7, and if it becomes two the
# FPGA could sample the header (with its new seq) beside a stale arg. Writing arg
# first and the header second makes the command atomic *by ordering*, whatever
# devmem does underneath. The response needs no such care - the FPGA posts it as
# one ch4 beat with be=0xFF.
CMD_ARG=0x3FFF0000    # command beat [31:0]
CMD_HDR=0x3FFF0004    # command beat [63:32] = DB90 <seq> <op>
RSP_DAT=0x3FFF0008    # response beat [31:0]
RSP_HDR=0x3FFF000C    # response beat [63:32] = DB91 <ack> 00
SEQFILE=/tmp/.nitrodbg_seq

die() { echo "nitrodbg: $*" >&2; exit 1; }
command -v devmem >/dev/null 2>&1 || die "devmem not found"

# ---- transport ----------------------------------------------------------

next_seq() {
	s=0
	[ -f "$SEQFILE" ] && s=$(cat "$SEQFILE")
	s=$(( (s + 1) & 255 ))
	echo "$s" > "$SEQFILE"
	echo "$s"
}

# cmd <op-hex-byte> <arg-hex-32>  ->  prints the 8-hex-digit response payload
cmd() {
	_op=$1
	_arg=$2
	_seq=$(next_seq)
	devmem $CMD_ARG 32 "$(printf '0x%08X' "0x$_arg")"
	devmem $CMD_HDR 32 "$(printf '0xDB90%02X%02X' "$_seq" "0x$_op")"

	# The FPGA polls every ~4096 clk_sys cycles; 400 spins is ~ a second of
	# slack even with the shell's own overhead dominating.
	_i=0
	while [ $_i -lt 400 ]; do
		_h=$(devmem $RSP_HDR 32)      # 0xDB91<ack>00
		case "$_h" in
			0xDB91*)
				_ack=$(printf '%d' "0x$(echo "$_h" | cut -c7-8)")
				if [ "$_ack" = "$_seq" ]; then
					devmem $RSP_DAT 32 | cut -c3-10
					return 0
				fi
				;;
		esac
		_i=$((_i + 1))
	done
	die "no response to op $_op (seq $_seq, last header '$_h') - is a debug-enabled core loaded?"
}

# op(7) selects the CPU: 0 = ARM9, 1 = ARM7
op_for() {  # op_for <base-op-hex> <cpu 9|7>
	if [ "$2" = "7" ]; then printf '%02X' $((0x$1 | 0x80)); else printf '%02X' "0x$1"; fi
}

# ---- commands ----------------------------------------------------------

do_halt()   { cmd "$(op_for 01 "$1")" 0 >/dev/null; echo "ARM$1 held"; }
do_run()    { cmd "$(op_for 02 "$1")" 0 >/dev/null; echo "ARM$1 running"; }
do_step()   { cmd "$(op_for 03 "$1")" "$(printf '%X' "${2:-1}")" >/dev/null
              echo "ARM$1 ran ${2:-1} cycle(s), held again"; }
do_brk()    { cmd "$(op_for 04 "$1")" "$2" >/dev/null; echo "ARM$1 breakpoint at 0x$2"; }
do_brkclr() { cmd "$(op_for 05 "$1")" 0 >/dev/null; echo "ARM$1 breakpoint cleared"; }
do_reg()    { cmd "$(op_for 06 "$1")" "$(printf '%X' "$2")"; }
do_peek()   { cmd "$(op_for 07 "$1")" "$2"; }

do_softreset() {
	cmd 09 0 >/dev/null
	echo "boot FSM restarted; both cores held at t=0"
}

# The OSD is the only thing that can raise cart_loaded normally, and it needs a
# human at the remote. DDR3 survives FPGA reconfiguration, so after deploying a
# new core the card image is usually still sitting at 0x30000000: op 0x0B just
# tells the core to believe it. Use `dd` from the .nds onto /dev/mem first if it
# is not (see COORDINATION.md).
do_forcecart() {
	cmd 0B 0 >/dev/null
	echo "cart_loaded forced; nds_on will rise and the loader will stage from DDR3"
}

# op 0x0C: the interrupt controllers. PEEK cannot reach 0x040001xx - it borrows
# the ARM9 main-RAM channel, so an IO address aliases into RAM and reads garbage.
# IF is the one that settles "does a VBlank ever actually fire": it latches the
# pulse until software acknowledges it.
do_irq() {
	_n=0
	for _f in IME9 IE9 IF9 IME7 IE7 IF7; do
		printf "  %-5s = 0x%s\n" "$_f" "$(cmd 0C "$_n")"
		_n=$((_n+1))
	done
}

# do_probe: op 0x0A returns a snapshot of the ARM9 memory path's FSMs.
# A CPU whose PC has stopped moving is either parked in one of these waits
# (a lost request or a lost done) or is not waiting on memory at all - and
# nothing else visible from the host tells those two apart.
do_probe() {
	_v=$(cmd 0A 0); _n=$(printf '%d' "0x$_v")
	_cs=$((_n & 15)); _cbeat=$(((_n >> 4) & 7)); _ccode=$(((_n >> 7) & 1))
	_ms=$(((_n >> 8) & 7)); _mrdone=$(((_n >> 12) & 1))
	_cresp=$(((_n >> 13) & 1)); _acc=$(((_n >> 14) & 1)); _cena=$(((_n >> 15) & 1))
	_rs=$(((_n >> 16) & 3)); _r9=$(((_n >> 19) & 1)); _r7=$(((_n >> 20) & 1))
	_srv7=$(((_n >> 21) & 1)); _lp=$(((_n >> 22) & 1)); _allow=$(((_n >> 23) & 1))
	_c9ena=$(((_n >> 24) & 1)); _mr9done=$(((_n >> 25) & 1))
	_mr9ena=$(((_n >> 26) & 1)); _m9ena=$(((_n >> 27) & 1))
	_vbl9=$(((_n >> 18) & 1))    # ARM9 DISPSTAT bit 3, VBlank IRQ enable
	_m9done=$(((_n >> 28) & 1)); _pksel=$(((_n >> 29) & 1))
	_ldb=$(((_n >> 30) & 1)); _dma=$(((_n >> 31) & 1))

	case $_cs in
	0) _csn=IDLE ;; 1) _csn=REQ_LOOKUP ;; 2) _csn=OP_LOOKUP ;; 3) _csn=HIT_RESP ;;
	4) _csn=BYPASS_ISSUE ;; 5) _csn=BYPASS_WAIT ;; 6) _csn=WB_PREP ;; 7) _csn=WB_BEAT ;;
	8) _csn=WB_WAIT ;; 9) _csn=FILL_BEAT ;; 10) _csn=FILL_WAIT ;; 11) _csn=OP_FINISH ;;
	*) _csn="?$_cs" ;; esac
	case $_ms in
	0) _msn=IDLE ;; 1) _msn=FINISH ;; 2) _msn=W_WRAMSH ;; 3) _msn=W_VRAM ;;
	4) _msn=W_MAIN ;; 5) _msn=W_IO_ALIGN ;; *) _msn="?$_ms" ;; esac
	case $_rs in
	0) _rsn=MR_IDLE ;; 1) _rsn=MR_LOCKWAIT ;; 2) _rsn=MR_WAIT ;; 3) _rsn=MR_DONE ;;
	*) _rsn="?$_rs" ;; esac

	echo "probe 0x$_v"
	echo "  cache9   : $_csn  beat=$_cbeat code=$_ccode"
	echo "  membus9  : $_msn  cpu_ena=$_cena accept=$_acc cresp_done=$_cresp mr_done=$_mrdone"
	echo "  mainram  : $_rsn  req9=$_r9 req7=$_r7 serving7=$_srv7 lock_pair=$_lp allow=$_allow"
	echo "  vbl ena9 : $_vbl9   <- ARM9 DISPSTAT bit 3. 0 here means the GPU never"
	echo "             raises the ARM9 VBlank IRQ, so it sleeps in WFI forever."
	echo "  top mux  : cpu9_ena=$_c9ena mr9_ena=$_mr9ena mr9_done=$_mr9done"
	echo "             mem9_ena=$_m9ena mem9_done=$_m9done pk_sel=$_pksel ld_busy=$_ldb dma_bus_on=$_dma"
}

# do_reach <cpu> <hexaddr> [seconds]
# From a real t=0: restart boot, arm the breakpoint BEFORE the first
# instruction retires, release both cores (ARM9 cannot progress without ARM7),
# then report whether that PC is ever executed. This is the primitive for
# bisecting the sim's golden trace against the hardware.
do_reach() {
	_cpu=$1; _addr=$2; _secs=${3:-3}
	cmd 09 0 >/dev/null                          # SOFTRESET -> both held
	cmd "$(op_for 04 "$_cpu")" "$_addr" >/dev/null   # BRKSET while still held
	cmd 02 0 >/dev/null                          # RUN ARM9
	cmd 82 0 >/dev/null                          # RUN ARM7
	sleep "$_secs"
	_v=$(cmd 08 0); _n=$(printf '%d' "0x$_v")
	if [ "$_cpu" = "7" ]; then _hit=$(((_n >> 3) & 1)); else _hit=$(((_n >> 2) & 1)); fi
	if [ "$_hit" = "1" ]; then echo "REACHED     0x$_addr"; else echo "not-reached 0x$_addr"; fi
	cmd "$(op_for 05 "$_cpu")" 0 >/dev/null      # BRKCLR
}

do_status() {
	v=$(cmd 08 0)
	n=$(printf '%d' "0x$v")
	echo "status 0x$v:"
	echo "  ARM9 held  : $(( n       & 1))"
	echo "  ARM7 held  : $(((n >> 1) & 1))"
	echo "  ARM9 bp hit: $(((n >> 2) & 1))"
	echo "  ARM7 bp hit: $(((n >> 3) & 1))"
}

do_regs() {
	i=0
	while [ $i -le 15 ]; do
		printf 'r%-3d %s' "$i" "$(do_reg "$1" $i)"
		# r13/r14/r15 on their own line for readability; three columns otherwise
		if [ $(((i + 1) % 4)) -eq 0 ]; then echo; else printf '   '; fi
		i=$((i + 1))
	done
	echo
	echo "CPSR $(do_reg "$1" 16)"
}

do_dump() {
	_cpu=$1; _a=$(printf '%d' "0x$2"); _n=${3:-8}; _i=0
	while [ $_i -lt "$_n" ]; do
		printf '%08X: %s\n' "$_a" "$(do_peek "$_cpu" "$(printf '%X' $_a)")"
		_a=$((_a + 4)); _i=$((_i + 1))
	done
}

do_where() {
	_cpu=$1
	_pc=$(do_reg "$_cpu" 15)
	_cpsr=$(do_reg "$_cpu" 16)
	_t=$(( $(printf '%d' "0x$_cpsr") >> 5 & 1 ))   # CPSR bit 5 = Thumb
	if [ "$_t" = "1" ]; then _off=4; _st=Thumb; else _off=8; _st=ARM; fi
	_at=$(( $(printf '%d' "0x$_pc") - _off ))
	echo "ARM$_cpu  $_st  r15=0x$_pc  ->  executing 0x$(printf '%08X' $_at)"
	echo "CPSR=0x$_cpsr  mode=$(printf '%02X' $(( $(printf '%d' "0x$_cpsr") & 0x1F )))" \
	     " I=$(( $(printf '%d' "0x$_cpsr") >> 7 & 1 )) F=$(( $(printf '%d' "0x$_cpsr") >> 6 & 1 ))"
	echo "opcode at PC: $(do_peek "$_cpu" "$(printf '%X' $_at)")"
	echo "r13(sp)=$(do_reg "$_cpu" 13)  r14(lr)=$(do_reg "$_cpu" 14)"
}

# ---- dispatch ----------------------------------------------------------

# Every read path above runs cmd inside $(...), where `die` exits only the
# subshell - the caller then decodes an empty string and reports a bogus
# status plus "printf: 0x: invalid hex number". Probe once here, in this
# shell, where exiting actually works, so a core without the debug unit in
# it produces exactly one honest error.
case "$1" in
	""|help|-h|--help) ;;
	*) cmd 08 0 >/dev/null ;;
esac

case "$1" in
	halt9)   do_halt 9 ;;
	halt7)   do_halt 7 ;;
	run9)    do_run 9 ;;
	run7)    do_run 7 ;;
	step9)   do_step 9 "$2" ;;
	step7)   do_step 7 "$2" ;;
	brk9)    [ -n "$2" ] || die "brk9 needs a hex address"; do_brk 9 "$2" ;;
	brk7)    [ -n "$2" ] || die "brk7 needs a hex address"; do_brk 7 "$2" ;;
	brkclr9) do_brkclr 9 ;;
	brkclr7) do_brkclr 7 ;;
	reg9)    [ -n "$2" ] || die "reg9 needs a register number 0-16"; do_reg 9 "$2" ;;
	reg7)    [ -n "$2" ] || die "reg7 needs a register number 0-16"; do_reg 7 "$2" ;;
	regs9)   do_regs 9 ;;
	regs7)   do_regs 7 ;;
	peek9)   [ -n "$2" ] || die "peek9 needs a hex address"; do_peek 9 "$2" ;;
	peek7)   [ -n "$2" ] || die "peek7 needs a hex address"; do_peek 7 "$2" ;;
	dump9)   [ -n "$2" ] || die "dump9 needs a hex address"; do_dump 9 "$2" "$3" ;;
	dump7)   [ -n "$2" ] || die "dump7 needs a hex address"; do_dump 7 "$2" "$3" ;;
	softreset) do_softreset ;;
	reach9)  [ -n "$2" ] || die "reach9 needs a hex address"; do_reach 9 "$2" "$3" ;;
	reach7)  [ -n "$2" ] || die "reach7 needs a hex address"; do_reach 7 "$2" "$3" ;;
	status)  do_status ;;
	probe)     do_probe ;;
	forcecart) do_forcecart ;;
	irq)       do_irq ;;
	where9)  do_where 9 ;;
	where7)  do_where 7 ;;
	raw)     [ -n "$3" ] || die "raw needs <op-hex> <arg-hex>"; cmd "$2" "$3" ;;
	*)       sed -n '4,40p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
