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
MAXINSTR=10000000 HEXFILE=sim/tests/<workload>.hex sim/run_arm9_trace.sh
```

Run it on the cluster (`DIRTY=1 build/remote-sim.sh run_arm9_trace.sh`,
`ENV="MAXINSTR=..."`); fetch `arm9_trace.log` from the pod before it is
deleted, or use `KEEP=1`.

## melonDS side (to do)

Patch points in melonDS (checked against 0.9.5-era sources; re-verify):

- `src/ARM.cpp`, `ARMv5::Execute()` main interpreter loop (the non-JIT
  template): after each instruction commits, emit
  `R[15]`, the fetched instruction word (`CurInstr`), reconstructed CPSR,
  and `R[0..14]` to a trace file. Gate on an env var
  (`MELONDS_TRACE9=path`) so normal builds are unaffected.
- Build headless (`cmake -DBUILD_QT_SDL=OFF` frontend-less core, or use the
  existing `melonDS-cli` style harness) — the cluster pod can run it.
- Match the initial state: melonDS must start the ARM9 at 0xFFFF0000 with
  the same memory image. Easiest path: package the workload as a minimal
  .nds ROM whose ARM9 entry is the test payload (arm9 load address
  0x02000000), and have BOTH sides run the loader-shaped start: for the RTL
  island that means staging the image into main RAM and setting the boot PC,
  which `tb_arm9_trace`'s savestate-bus preload already models.
- Alignment quirk to watch: melonDS traces the instruction *after* fetch,
  the RTL exports at retire — skipped (condition-failed) instructions ARE
  exported by the RTL (`export` fires on every `execute_done`), and melonDS
  also steps them, so counts line up. IRQ entry produces no trace line on
  either side (it is not an instruction).

## Comparison

```
python3 sim/tests/compare_trace.py arm9_trace.log melonds_trace.log
```

Streams both files, prints the first divergence with context and the
offending fields, exits nonzero on mismatch.

## Workloads (in order)

1. `arm9_island.hex` — smoke (≈2k instructions, already green in sim).
2. armwrestler-style CPU test ROM (ARM9 build) — dense ISA edge cases.
3. An SDK sample's ARM9 image (crt0 + OS_Init path) — the M4 rehearsal.
