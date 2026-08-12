# ARM9 differential trace vs melonDS (M3 exit test)

Goal: ≥10M retired instructions with **zero divergence** between `nds_cpu9`
in sim and melonDS's interpreter running the same binary from the same
initial state.

## Trace format

One line per retired instruction, lowercase hex, space-separated:

```
<pc> <opcode> <cpsr> <r0> <r1> ... <r14>
```

`pc` is the pipeline value (instruction address + 8 in ARM state, + 4 in
Thumb) — both sides expose it that way naturally. `cpsr` includes NZCVQ,
I/F, T and mode bits.

## RTL side

`sim/run_arm9_trace.sh` elaborates `tb_arm9_trace` (the ARM9 island with
`is_simu='1'`) and writes `arm9_trace.log`:

```
MAXINSTR=10000000 HEXFILE=sim/tests/<workload>.hex \
   LOADADDR=$((0x02000000)) sim/run_arm9_trace.sh
```

`LOADADDR` is not optional for a differential run and this line used to omit
it. The melonDS side boots the raw binary in main RAM at `0x02000000`; with
`LOADADDR` unset the RTL side instead loads the same hex as the boot ROM at
`0xFFFF0000`, so the two sides run different memory maps and diverge on
instruction 1 for a reason that has nothing to do with the CPU.

Run it on the cluster (`DIRTY=1 build/remote-sim.sh run_arm9_trace.sh`,
`ENV="MAXINSTR=..."`); fetch `arm9_trace.log` from the pod before it is
deleted, or use `KEEP=1`.

## melonDS side (done — sim/melonds_tracer/)

`sim/melonds_tracer/build.sh` clones melonDS **1.1** (pinned) into
`$MELONDS_DIR` (default `~/sources/melonDS`), applies `tracer.patch`,
and builds the headless `melonds_tracer` binary (no Qt/SDL, no JIT, stub
Platform):

```
melonds_tracer <arm9.bin> <trace.log> <maxinstr> [entry-hex=02000000]
```

It boots the raw binary in main RAM with the RTL-matching initial state
(regs zero, CPSR 0xD3, CP15 reset, no BIOS/firmware boot) and drives the
ARM9 alone — no scheduler, no ARM7, no IRQs. Trace emission is patched
into `ARMv5::Execute()`: pc captured after the prefetch advance (addr+8
ARM / +4 Thumb, matching the RTL's `regs(15)` at export), opcode masked
to 16 bit in Thumb, CPSR/r0-r14 post-execute. Condition-failed
instructions are traced on both sides; IRQ entry traces on neither.

`tracer.patch` also fixes one genuine melonDS interpreter bug the
differential itself flagged (RTL was right, verified against the ARM
ARM) that is still present upstream as of 1.1:

- `ARM_InstrTable.h`: the EORS row maps icode 0xA to
  `A_EOR_REG_ROR_IMM_S` — so `EORS ..., LSR #odd` executed as ROR.

History: the tracer originally pinned melonDS 0.9.5, where the patch
carried more fixes the differential found. Upstream 1.1 already has the
ADC/SBC/RSC V-flag fix (found here first, fixed differently upstream),
the LDM^-with-pc writeback-before-mode-switch ordering, CP15 c13 Trace
Process ID, and byte-wide IPCSYNC access — all of which the 0.9.5 patch
had to carry for calico/libnds-2.x ROMs.

Initial-state gotchas encoded in the workloads: CP15 control resets to
0x78 (RTL) vs 0x2078 (melonDS) — write control with an immediate before
ever reading it; SPSR resets differ — write before read.

## Comparison

```
python3 sim/tests/compare_trace.py arm9_trace.log melonds_trace.log
```

Streams both files, prints the first divergence with context and the
offending fields, exits nonzero on mismatch.

## Workloads

1. `arm9_diff.s` — the island tests 1-10 ported to 0x02000000, CPU+memory
   only (no MMIO/IRQ/WFI). Green at 3k instructions.
2. `gen_arm9_torture.py` (via `build_arm9_torture.sh`) — the
   armwrestler-style workload: seeded pseudo-random v5TE chunks (ALU with
   every shifter form, S-suffix multiplies/long multiplies, DSP
   multiplies + saturating ops, loads/stores incl. unaligned-rotate
   LDR/LDRD/STRD/SWP, LDM/STM, conditional blocks, MSR flag writes, Thumb
   round-trips via BLX, LDM-to-PC returns). `CACHES=1` prepends a PU
   setup that enables the I/D caches and mixes in trace-transparent
   maintenance ops (clean / clean+invalidate by MVA, invalidate-I-all,
   drain) — melonDS models no caches, so a clean diff doubles as a cache
   transparency proof. Generated files are not checked in; rerun the
   build script before streaming a DIRTY tree to the pod.
3. An SDK sample's ARM9 image (crt0 + OS_Init path) — the M4 rehearsal
   (still to do).

## Status (M3 exit test)

**PASSED 2026-07-16**: 10,000,000 retired instructions (seed 42,
2500 chunks x 600 loops), RTL on the cluster vs melonDS locally, zero
divergence. ~20 local seeds at 30k instructions each also green, caches
off and on. Divergences found and fixed along the way: RTL
ROR-by-register with a multiple-of-32 amount (C flag), plus the two
melonDS bugs above.
