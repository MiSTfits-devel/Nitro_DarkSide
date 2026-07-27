# NDS_MiSTfits handoff — 2026-07-26

Supersedes `HANDOFF-2026-07-20.md` (SWP-era; still accurate about the MiSTer
inventory and the SWP fix, stale about everything else).

Goal unchanged: **boot Kirby: Squeak Squad on the DE10-Nano.** Screen is still
white on hardware, but the reason is no longer a mystery and the remaining list is
short and specific.

---

## State at a glance

| Thing | State |
|---|---|
| ARM9 IO reads | **FIXED** this session. They returned `0x00000000` for every register. |
| Cross-CPU IPCSYNC | **WORKS** in sim (`bootreq` bit 15). This was the boot handshake blocker. |
| ARM9:ARM7 instruction ratio | 0.42 → **2.86** (island + speculative cache index) |
| Instruction fidelity vs melonDS | 1,293,260 ARM9 / 231,343 ARM7 exact on pc/opcode/r0..r12 |
| **DMA0** | **BROKEN** — the one real functional failure left. `bootreq` bit 14. |
| 67 MHz island timing | **FAILS.** `decode_RM_op2 → fetch_PC` = 20.9 ns in a 14.915 ns period. |
| Deployed on hardware | **Nothing from this session.** Do not deploy until timing closes. |
| Area | 88% ALMs / 86% M10K / 84% DSP — fits, not the constraint |

Commits since `663cb6c`:

```
8faa633  three island wiring bugs, cache speculative index, loader sim shortcut
ffaf373  preload main RAM so a boot-length run costs minutes, not an hour
540b1b1  Ledger: island works - ratio 0.42 -> 2.86
023b21c  measure where the ARM9's stall cycles go
d5f0e32  ROOT CAUSE: latch the ARM9 IO payload   <-- WRONG, see 8051589
8051589  Correction: the IO latch is NOT the root cause, and the timing verdict
487427c  purpose-built iotest ROM
4e93f3f  Fix ARM9 IO reads (W_IO_RESP) + bootreq subsystem suite
```

---

## The root cause of the white screen

**Every ARM9 IO read returned `0x00000000`.**

`nds_membus9` retired IO accesses in `FINISH`, one cycle after asserting
`io_bus.ena`. Before the ARM9 moved to its own clock the IO fabric shared `clk1x`
with the CPU, so `io_wired_done` was already valid in `FINISH` and that was
correct. Across the island bridge the round trip takes several island cycles, so
`FINISH` was always reached with `io_wired_done` still low — and the read mux
(`nds_membus9.vhd`, `din_unrot`) falls through to `x"00000000"` for an unclaimed
`T_IO`.

Consequences, all of which had been chased separately as if unrelated:

- the ARM9 wrote `Din=0` to IPCSYNC because it **read** 0 and faithfully echoed it
- DISPCNT/POWCNT were never usefully programmed → white screen
- the ARM7 read `0x0800` at its handshake instead of `0x0808`

Fix (`4e93f3f`): new `W_IO_RESP` state holds the access until the fabric answers,
plus a per-transaction completion pulse in `nds_top`. Three subtleties worth not
rediscovering:

1. `io_wired_done9` is a pure **address decode**, not an event. Edge-detecting it
   fires once and never again for back-to-back IO accesses. Hence a dedicated
   completion toggle (`cdc_io_cpl`).
2. That completion must fire for **unclaimed** addresses too, or membus9 hangs
   forever on an unmapped IO read. Data is still correct: `io_wired_out9` is a
   wired-OR that reads 0 when nothing claims the address.
3. `W_IO_RESP` must **not** have its own FSM branch. This bus accepts a new access
   in the cycle it completes one; a private branch that handles the completion
   without honouring `cpu_ena` drops the CPU's next request and it waits forever.
   That hung the ARM9 on its *second* IO access. `W_MAIN`/`W_VRAM` have no such
   branch for exactly this reason — `accept_now` alone is correct.

### Why this hid for three sessions

**An instruction-exact trace cannot detect a dropped or corrupted store, or a
read that returns a wrong value the code does not branch on.** TRACE_DIFF records
pc, opcode and r0..r14. A store that goes nowhere leaves all of them identical.
"1.29M instructions match melonDS" was true the whole time and never implied the
ARM9's IO accesses worked. Do not use trace agreement as a proxy for correctness
of anything that leaves the CPU.

---

## Beliefs to discard (all were in the ledger or my own commits)

- ~~"ALMs are at 125%, area is the binding constraint"~~ — the production path is
  **86–88%**. The 125% figure was a debug-export measurement build, fixed by
  `cf59e21`.
- ~~"0 blocking paths in `icpu9`; the ARM9 core is not what blocks 67 MHz"~~ — came
  from a **truncated** report. The ARM9-scoped report says the opposite: the core
  *is* the blocker.
- ~~"An unsynchronised IO payload is the root cause" (`d5f0e32`)~~ — false. The
  latch is kept (harmless, defensible) but fixes nothing; the run was
  bit-identical to the femtosecond with and without it, which is the proof.
- ~~"membus9 in `W_MAIN` 78% while cache9 is busy 37%" anomaly~~ — an artifact of
  two independent histograms that never sampled the same cycle. Fixed; there is
  no anomaly.
- ~~"The required ARM9:ARM7 ratio is 2.32"~~ — see the open question below. The
  number rests on an incomplete model of the handshake.

---

## The one real functional failure: DMA0

`bootreq` bit 14. A one-word main-RAM→main-RAM DMA0 transfer completes on melonDS
and does not on our RTL. Kirby's boot uses DMA heavily. This is the next thing to
fix and there is a 33 KB reproducer that hits it in ~9 ms of simulated time.

```bash
cd /Users/heni/sources/NDS_MiSTfits
WORK=sim/nvc_work_bq PRELOAD=0 HEXFILE=sim/tests/nds_bootreq.hex DIRECT=1 \
  FRAMES=1 TIMEOUT_MS=15 TRACEFILE=bq9.txt TRACE_START_FRAME=-1 \
  sh sim/run_top_frame.sh
tail -1 bq9.txt | awk '{printf "pass=%s prog=%s\n",$13,$14}'
```

Expect `prog=0x63` (99 = ran to completion). Current: `pass=0x5A5B9E7F`, oracle
`0x5A5BDC7F`. Only bit 14 differs in the RTL's disfavour.

Start at `rtl/nds_dma9.vhd` and the `mbus_ena`/`dmab_ena_i9` bridge path in
`nds_top.vhd` — the DMA is on `clk1x` and masters a `clk2x` membus, which is
exactly the kind of crossing that produced three bugs already this session.

---

## The timing blocker (independent of everything above)

```
decode_RM_op2[*] -> fetch_PC[29]    data delay 20.9 ns, period 14.915, slack -6.7
general[1] (clk2x, 67 MHz island)  -7.643
general[2] (clk_sys, 33.5 MHz)     -7.020
Fitter: Successful, 88% ALMs
```

Every worst path in the design is that one — the barrel-shifter operand feeding
the fetch PC, i.e. operand → shifter → ALU → PC, the classic long path in a
non-pipelined ARM. Report: `build/artifacts-island/NDS.paths_cpu9.rpt` (scoped to
`icpu9`/`imembus9`; the global report ranks by slack and never reaches the CPU,
which is how the "0 blocking paths" myth started).

**Do not deploy the island to hardware until this closes.** A −7.6 ns core will
behave nondeterministically and generate evidence you then have to un-explain.

The fix is pipelining that path in `nds_cpu9`. This is the substantial remaining
engineering task.

---

## Open question: the handshake model is wrong

The ARM9's sync loop is **8,017 instructions per iteration** (measured off the
oracle, dead constant — `grep -n "^0214ff28" arm9_melon.log`). At the oracle's own
2.32 ratio that is ~3,455 ARM7 instructions, but the ARM7 steps its countdown
every 593. **So even melonDS cannot echo within one ARM7 step, yet its read at
ARM7 231,344 succeeds.** The protocol is therefore not "echo within one step,"
and every ratio requirement quoted in this repo's ledger inherits that bad model.

Read the ARM9 loop at `0x0214FF00..FF68` and the ARM7 sequence at `0x037FEB94`
properly before quoting a ratio target again. Now that IO reads work, it is also
possible this question is moot — re-measure before theorising.

---

## Methodology: write ROMs, do not infer from traces

The single biggest win of this session. Three sessions of inference off NitroSDK
traces produced two wrong root causes. A purpose-built ROM found the real one in
one run, because it inverts the epistemics: **you know the expected value, so a
mismatch is a fact rather than a theory.**

- `sim/tests/iotest/` — minimal IO probe (5 subtests)
- `sim/tests/bootreq/` — 15-subtest subsystem suite, the main instrument

Both use the proven `sdk2d` custom-crt0 pattern (no calico kernel, no BIOS SWIs,
no DMA) so they cannot fail for a reason unrelated to what is measured. Both boot
in **microseconds** — Kirby needs ~75 ms of simulated time just to reach its first
IO access, which is why three earlier IO measurements were accidentally taken
before the thing being measured existed.

Readout needs no testbench support: results are parked in fixed registers before a
`b .`, so **the last line of the trace is the whole report** (`r9` = `0x5A5A0000 |`
pass bitmap, `r10` = progress index, `r4..r8` = raw values). `r10` matters as much
as `r9`: if a subtest hangs, it names which one.

Establish the melonDS baseline first. If the oracle does not pass, the test is
wrong, not the RTL:

```bash
TRACE9=/tmp/or9.txt TRACE9MAX=900000 sim/melonds_tracer/build/melonds_fbdump \
  sim/tests/bootreq/nds_bootreq.nds --direct 3
tail -1 /tmp/or9.txt | awk '{printf "pass=%s prog=%s\n",$13,$14}'
```

### Traps that cost an iteration each — read before writing the next ROM

- **The mailbox must live in an uncached mirror** (`0x02FFxxxx`, PU region 2). At a
  cacheable address the ARM9 serves its read from D-cache and every cross-CPU test
  silently fails.
- **Use high vectors** (control bit 13). With V=0 the vector table sits at `0x0`
  *inside ITCM*, uninitialised, so any `svc` or abort jumps into garbage — and an
  ITCM test at offset 0 overwrites the reset vector.
- **The PU aborts on any address no region covers**, including the ITCM window. A
  4 GB catch-all as region 0 with specific higher-numbered regions for
  cacheability is the right shape for a test ROM.
- **A subtest that data-aborts discards everything after it.** Order risky ones
  last or leave them out.
- **`register x asm("r10")` does not hold** across calls; GCC ignores it. Park
  results with explicit inline asm at the end.
- **A `svc` ends melonDS's instruction trace**, so no oracle baseline is possible
  for BIOS entry points in a traced ROM. They need their own ROM
  (`sim/tests/hle_bios9`, `hle_bios7` exist).
- Excluded from `bootreq` for the above reasons: TCM (7, 8), VBlank IF (13 — needs
  a full frame, ~800k instructions). Known-bad: bit 9 (shared WRAM) fails on
  melonDS too, so that subtest is wrong.

---

## Tooling that works

**`PRELOAD=1` — do not run a boot-length sim without it.** `nds_loader` stages
443,230 words (~70 ms of simulated time, ~1 hour of wall clock) before the CPUs
are released. The bench writes those sections into the SDRAM model directly and
`nds_top`'s `skip_copy` generic skips the copy passes. Loader busy drops from 4.7M
cycles to **2,084**; boot completes at ~31 µs. Steady-state memory timing is
untouched, so CPI/ratio numbers stay comparable.

```bash
WORK=sim/nvc_work_x PRELOAD=1 HEXFILE=sim/tests/kirby_4mb.hex DIRECT=1 \
  TRACEFILE=isl9.txt TRACEFILE7=isl7.txt TRACE_START_FRAME=-1 TRACE7_START_FRAME=-1 \
  TIMEOUT_MS=90 CYCLE_HIST=4000000 sh sim/run_top_frame.sh
```

- **`TRACE_START_FRAME=-1` is required** to trace from instruction 0. The gate is
  `dump_frame_index >= TRACE_START_FRAME` and that starts at −1, only reaching 0
  after the first vblank (~17 ms). With the default 0, any shorter run writes an
  **empty trace** and looks like a broken trace writer.
- **`WORK=`** lets a second run analyse into its own library instead of
  overwriting the one a long run is still executing from.
- **`CYCLE_HIST=N`** prints joint `cache9`/`membus9` state counts (same edge —
  independent histograms are what produced the bogus `W_MAIN` anomaly), plus
  off-bus holds (`resetCpu`/`dbg_hold9`/`dma_bus_on`/`cpu9_ena`), boot stalls
  (`nds_on`/`ld_busy`/`ld_done`/`ld_error`), the `BYPASS_WAIT` split and main-RAM
  occupancy per CPU.
- **Read `ld_busy`/`ld_done` before concluding anything from an all-IDLE
  histogram.** A 100%-IDLE cache with `resetCpu` high for a whole 60 ms run means
  *the loader is still copying* — what a healthy design does — not a dead CPU. I
  called a working island dead on exactly that evidence.

**First-divergence vs the oracle** — `scratchpad/firstdiv.awk`. Fold case (the RTL
writes uppercase hex, melonDS lowercase, or every line "diverges" on line 1) and
exclude cpsr, r13, r14 (melonDS pre-sets SP/LR).

**Driver audit after any domain split.** Three island bugs were multiple-driver or
undriven signals, and `nvc` sees neither (`std_logic` resolves multiple drivers
silently; undriven reads as `'U'`). Quartus catches them — after a 25-minute fit.
For each crossing signal, count statement-level assignments and port-map bindings
*whose formal is `out`*. Zero drivers or two is a bug. The three shapes seen:
half-renamed port map, swapped ends (`cpu9_done`/`cpu9_done_1x`), and record field
vs standalone signal (`i9_io_ena` should have been `i9_io_bus.ena`).

Oracle traces (regenerable, ~10 min): `melonds_fbdump` + `kirby.nds`. The stale
ones live under an old session scratchpad and should be regenerated rather than
trusted.

---

## Hardware

MiSTer at **192.168.1.243** (was `.244`; it moves across reboots — ask, do not
scan the subnet). Kirby is staged in DDR3: `devmem 0x30000000 32` → `0x4252494B`
("KIRB").

**DDR3 survives a core reload but NOT a power cycle.** After a power cycle the
cart image is gone and must be loaded once through the OSD — the MGL cannot fill
the cart slot (FS3 direct-to-memory). Mailbox op `0x0B` (`forcecart`) then makes
the core believe it, so the cycle is `scp` → `load_core` → `forcecart`, unattended
from then on.

`scratchpad/deploy-probe.sh <rbf> <name>` does upload + SHA verify +
production-core guard + `load_core`. Production core `NDS_20260719.rbf` must stay
untouched (the script refuses if its checksum changed).

Mailbox `tools/nitrodbg.sh`: `probe` (0x0A), `forcecart` (0x0B), `irq` (0x0C),
halt/step/brk/regs/peek. **PEEK cannot read IO space** — it borrows the ARM9
main-RAM channel, so `0x040001xx` returns a plausible aliased RAM word. Only
`0x02xxxxxx` peeks are real. That is why the test ROMs read IO themselves and
report inward to `0x02FFFF00`.

---

## Next steps, in order

1. **Fix DMA0** (`bootreq` bit 14). Fast reproducer exists. Suspect the
   `clk1x` DMA mastering a `clk2x` membus.
2. **Re-run `bootreq` and Kirby** with IO reads fixed. The handshake may now
   simply work; re-measure before theorising about ratios.
3. **Pipeline `decode_RM_op2 → fetch_PC`** in `nds_cpu9`. Until this closes,
   nothing from this session is deployable.
4. Then build and deploy, and judge the screen only after ~600 frames (white at
   frame 0 is normal — melonDS reports `DISPCNT=0` there too).
5. Write the ROMs `bootreq` had to exclude: TCM, BIOS SWIs, VBlank/IRQ dispatch,
   card reads.

## Do not repeat

- Inferring subsystem state from a Kirby boot trace. Write a ROM.
- Treating trace agreement as proof that stores or IO accesses work.
- Taking an IO measurement before instruction ~536,610 (~57 ms) and reading
  meaning into it. Kirby does almost no IO before then.
- Gating the ARM7's `ce` to fake the ratio. Measured twice wrong; kills the ARM7
  (`gb_bus_done` is consumed in ce-gated processes while `membus7`'s `cpu_done` is
  a state level), and desynchronises it from its own timers.
- Editing a running shell script (`bash` reads incrementally — it will die
  mid-build) or a source tree during a `remote-build` (it snapshots at launch).
- Deploying a core that misses timing.
