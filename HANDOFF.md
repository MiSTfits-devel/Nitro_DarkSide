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
| **DMA0** | **FIXED.** `bootreq` 0x5A5B9E7F → **0x5A5BDE7F**, a strict superset of the melonDS oracle (0x5A5BDC7F). |
| **BIOS9 fetches** | **FIXED.** 15 of Kirby's first 28 were stale words. Now 650/650. |
| Kirby in sim | Runs the full 90 ms, takes its first vblank IRQ, fills VRAM. No longer derails into ITCM. |
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

## DMA0 — FIXED. A DMA access is never cacheable.

`bootreq` bit 14. Reproducer (~9 ms of simulated time):

```bash
cd /Users/heni/sources/NDS_MiSTfits
WORK=sim/nvc_work_bq PRELOAD=0 HEXFILE=sim/tests/nds_bootreq.hex DIRECT=1 \
  FRAMES=1 TIMEOUT_MS=15 TRACEFILE=bq9.txt TRACE_START_FRAME=-1 \
  sh sim/run_top_frame.sh
tail -1 bq9.txt | awk '{printf "pass=%s prog=%s\n",$13,$14}'
```

Was `pass=0x5A5B9E7F`, now `0x5A5BDE7F` against the oracle's `0x5A5BDC7F` — a
strict superset (bit 9, shared WRAM, is the known-bad subtest that fails on
melonDS too; we happen to pass it).

`nds_membus9` applied `bus_cacheable_d` to DMA accesses. That signal is decoded
in `nds_cpu9` from `gb_bus_Adr`, the **CPU's own** address register — not the
muxed bus — so while the DMA owns the bus it describes whatever address the CPU
last presented. Kirby's DMA paused the CPU mid instruction-fetch from main RAM,
inside the one region marked cacheable, so `bus_cacheable_d` read `'1'` for the
whole transfer: the DMA's read allocated a cache line, its write hit that same
line and stopped there dirty, and the CPU's read-back through the uncached
mirror saw 0. **On the bus the transfer looked perfect** — right address, right
data, right handshake — which is why it survived a probe of the DMA path itself.

The fix is one branch (`dma_bus = '1'` → `creq_cacheable <= '0'`), and it is also
just correct hardware: the ARM9 DMA is a separate master that does not see the
CPU's caches, which is why NitroSDK brackets every DMA with `DC_FlushRange` /
`DC_InvalidateRange`.

---

## The white screen after that: BIOS9 was clocked on the wrong clock

**`ibios9` was instantiated on `clk1x` while the ARM9 island runs on `clk2x`.**
15 of Kirby's first 28 BIOS fetches returned the wrong word.

`nds_bios9` is a *synchronous* RAM. Its read address is driven combinationally
from the island's `cpu_adr` (`nds_membus9.vhd:191`) and its data is consumed
combinationally in the island's `FINISH` state (`nds_membus9.vhd:508`) — **there
is no done handshake on `T_BROM` at all.** On `clk1x` the ROM therefore sampled
the address on only every *other* island cycle, so every second BIOS9 fetch
returned the previous word, and the first fetch after reset returned whatever
was latched (word 0).

The failure chain, which had looked like three unrelated mysteries:

1. Kirby's `blx` at `0x0213FEAC` enters Thumb and hits `swi 0x0B` (CpuSet) at
   `0x020002BE`. The CPU vectors correctly to `0xFFFF0008`.
2. The fetch there delivers **word 0** — `EA000042`, the *reset* vector — instead
   of `EA0000A2`, the SWI vector.
3. So it branches to `0xFFFF0120`, the middle of the BIOS CRC16 helper, and
   executes onward with every other word stale until `ldr pc,[r0,#-4]` at
   `0xFFFF0294` throws it into ITCM at `0x00000008`.
4. It then spins in ITCM garbage forever — ~500,000 instructions of it, in User
   mode, at PCs like `0x000000BC`, which is what "the ARM9 ran off into garbage"
   was.

`clk1x` → `clk2x` on `ibios9` is the whole fix. ITCM and DTCM were already on
`clk2x` (`nds_top.vhd:1141,1170`); `ibios9` was the lone outlier, and `T_BROM`
was the last unhandshaked target left on that bus after `W_IO_RESP` closed the
IO one.

### Why the ARM7 is the control, and use it

The ARM7's BIOS shares its CPU's clock, so it is the known-good reference for
anything on a BIOS path. In the same broken run, all 488 of its SWI entries
fetched the right vector and landed in the right handler; 9,272 of 9,272 of its
ARM-state BIOS fetches were correct. When an ARM9 memory path looks wrong, check
whether the ARM7's equivalent is right before theorising.

### The assertion, and the trace PC convention it rests on

`sim/check_bios9_fetch.awk` compares every BIOS fetch in a trace against the BIOS
image. Oracle-free — the expected value is known exactly, so a mismatch is a fact:

```bash
awk -f sim/check_bios9_fetch.awk sim/tests/bios9_retail.hex simout/<pod>/isl9.txt
awk -v arm7=1 -f sim/check_bios9_fetch.awk sim/tests/bios7_retail.hex .../isl7.txt
```

**In ARM state the trace's pc column is the pipeline PC — the instruction address
plus 8.** The opcode on a line belongs to `pc-8`. Calibrated on the ARM7's 9,759
ARM-state BIOS fetches: 0 match at `pc`, 9,272 at `pc-8`. Do not "fix" this by
comparing at `pc`. Two further filters are needed or the check cries wolf: Thumb
lines (the trace prints a zero-extended halfword and steps pc by 2), and
ARM/Thumb transition lines, where the cpsr column already carries the new T-clear
flag while the opcode is still the Thumb halfword — those were all 487 residual
"mismatches" on the ARM7 control.

This is the third bug in a row that an instruction-exact trace diff could not
see, and for the same reason each time: **it is a wrong value the trace records
faithfully.** A dropped store, an IO read of 0, a stale BIOS word — all leave
pc/opcode/registers agreeing right up to the moment the wrong value changes a
branch.

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

### There is no timing-clean fallback: ISLAND=0 does not work

`nds_top.vhd:67` says "Tie to clk1x to disable the island". **That comment is
stale.** `sim/run_top_frame.sh` now takes `ISLAND=0`, which ties `clk2x` to
`clk1x` in the bench, and in that configuration the ARM9 makes **5 memory
accesses in 30 ms and stops** — a hard stall almost immediately, not the slow-but-
working behaviour the comment implies (the island run has 116,003 accepts by
6 ms). The ARM7 keeps running and reaches 100,000 instructions, so it is the
ARM9 side specifically.

Not chased to a proven root cause, but the shape points at the toggle-based CDC
added since that comment was written: `cdc_req_io` toggles on `clk2x` and
`clk1x` edge-detects it via `cdc_req_io_d` (`nds_top.vhd:787,800,806`), with the
completion toggling back on `clk1x` (`:901`). Those handshakes were written
against a 2:1 ratio and at least one of them does not survive 1:1.

The consequence for planning: **pipelining `decode_RM_op2` is the only route to a
deployable core.** There is no "ship the 1x build meanwhile" option to fall back
on, and anyone who assumes there is one will lose a day discovering this. If a 1x
build is ever wanted as an escape hatch, it is its own project — auditing every
CDC handshake for ratio independence — not a generic flip.

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

1. **Pipeline the worst path in `nds_cpu9`.** This is now the *only* thing between
   here and a core that can run on hardware — see the ISLAND=0 note above for why
   there is no fallback. Note the real ranking: `decode_RM_op2 → vram_din` at
   −7.643 is the worst, `decode_RM_op2 → fetch_PC` at −6.705 is only third, and
   there is a second independent family rooted at `io_bus.Adr`. Pipelining only
   the path this document used to name would leave ≈ −7.1 on the table.
2. **Verify the screen in sim before building.** Kirby now runs the full 90 ms and
   takes its first vblank IRQ, but 90 ms is ~5 frames and the handoff's own rule
   is to judge only after ~600 (white at frame 0 is normal — melonDS reports
   `DISPCNT=0` there too). Reaching 600 frames is ~10 s of simulated time, which
   is out of reach for a full-trace run; use `p_vidregs` and the framebuffer
   dumps instead of a trace.
3. **Write a render-test ROM — but not "in Kirby's modes", because Kirby has not
   picked any.** Measured with `p_vidregs`: in a 95 ms run Kirby touches video
   registers exactly 42 times, all in a 100 µs burst at ~83.7 ms, and it is all
   initialisation — POWCNT1 = `0x820F`, then every engine-A register `+000..+03C`
   zeroed, then every engine-B register, then identity affine matrices
   (`0x00000100` / `0x01000100` = 1.0 in 8.8) for BG2 and BG3 on both engines.
   **`DISPCNT` is still 0.**

   So the white screen at this point is the hardware being *correct*, not
   failing: display mode 0 is display-off, and both framebuffers come out
   uniformly `0x3FFFF` (white) across all 49,152 pixels, which is what they
   should be. Do not read a rendering bug into a white frame here.

   Kirby's real modes are therefore not obtainable from RTL sim — it does not
   choose them inside reachable simulated time. That is a melonDS question, where
   hundreds of frames are trivial: extend `sim/melonds_tracer/main_fbdump.cpp` to
   log video-register writes. Meanwhile a render ROM does not need to match Kirby
   to be worth writing — one that programs a *known* mode and is diffed against
   melonDS running the same ROM gives a real oracle, which Kirby never will. The
   `sdk2d` custom-crt0 pattern and `sim/tests/nds_2d*` are the starting points.
4. Write the ROMs `bootreq` had to exclude: TCM, BIOS SWIs, VBlank/IRQ dispatch,
   card reads. A BIOS SWI ROM would have caught the BIOS9 clock bug directly.

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
- Naming artifacts in `remote-sim.sh` that the bench does not write. The
  framebuffer files are `DUMPFILE`/`DUMPFILE_B`, default `top_frame_fb.txt` and
  `top_frame_fb_b.txt` — asking for `kirby_fb.txt` without setting `DUMPFILE`
  fetches nothing, the pod is deleted, and a 15-minute run has to be repeated.
- Trusting a probe's address decode without checking the register map.
  `io_bus9.Adr` is a **byte** offset into `0x0400_0000`: BG0CNT is `0x008`
  (`reg_nds_display.vhd:58`), engine B is the `0x1000` window
  (`nds_top.vhd:1663`), POWCNT1 is `0x304`.

## Missing tooling — this document references files that do not exist

`scratchpad/` was never tracked in git and is gone. Two tools this document tells
you to use no longer exist and need rewriting when next needed:

- `scratchpad/firstdiv.awk` — first divergence vs the oracle. Rebuildable from the
  description above (fold case; exclude cpsr, r13, r14).
- `scratchpad/deploy-probe.sh` — upload + SHA verify + **production-core guard** +
  `load_core`. Rewrite this one carefully before the next deploy: its job included
  refusing to touch `NDS_20260719.rbf`, and a careless replacement loses that
  protection silently.
