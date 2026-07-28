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
| Timing | **CLOSES as of 2026-07-28** — 0 violated paths, worst setup **+1.537**, all holds positive, Fitter Successful. `build/artifacts-isl0`. Reached by removing the 67 MHz island (ARM9 now on clk1x), not by more RTL: the 2.32 ratio that justified the island does not exist, and the ISLAND=0 stall was a bench delta cycle. See the TIMING CLOSES section. |
| 67 MHz island | **REMOVED.** It failed at −2.535/−2.809 across five path families inside 0.37 ns, and a *slower* island is a dead end (cross-domain budget follows edge alignment: /16 gave −8.362). |
| Frame rate | **3.01x too slow, and it is NOT the CPUs** — `GPU_CE_DIV=3` with the render fabric on clk1x where the design intends clkMem. Fix that and the frame is 16.81 ms vs 16.74 real. This is now the top item. |
| Deployed on hardware | **Nothing.** An RBF exists at `build/artifacts-isl0/NDS.rbf` and no hardware result is claimed. |
| Area | **85% ALMs** / 85% M10K / 84% DSP (35,824 / 41,910), down from 90% — the island removal and the DTCM deferral both gave ALMs back |

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
0b11f58  DMA cacheability + BIOS9 onto clk2x
d6a2d55  p_vidregs: report on change
2b41fdb  ARM9 worst path: TCM compares and the ALU's second carry chain
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

## *** TIMING CLOSES 2026-07-28: build/artifacts-isl0, ARM9 at 1:1 ***

**The core meets timing for the first time.** `Report Timing: Found 50 setup paths
(0 violated). Worst case slack is 1.537`, Fitter Successful, Timing Models Final.

| domain | setup | TNS |
|---|---|---|
| clkMem 100.542 MHz | **+1.537** | 0.000 |
| clk1x 33.514 MHz (**now carries the ARM9**) | **+2.186** | 0.000 |
| video 67.028 MHz | +5.507 | 0.000 |
| h2f_user0 / FPGA_CLK2_50 | +5.795 / +13.348 | 0.000 |

Holds all positive, worst +0.248. Area **85% ALMs** (35,824 / 41,910), RAM 85%,
DSP 84% - the island's removal gave back ~1,400 ALMs on top of the DTCM change.

How: `NDS.sv` passes `clk_sys` as `.clk2x`, i.e. ISLAND=0. That is viable because
(a) Kirby's boot handshake imposes **no** ARM9:ARM7 ratio - both sides wait
unboundedly, and (b) the ISLAND=0 stall was a **bench delta cycle**, not RTL. Both
are documented below. A slower *island* is a dead end - see the /16 result.

Verified on the real workload: Kirby 25 ms at 1:1 gives ARM9 125,695 / ARM7 84,006
instructions with `itcm_hit 3152` / `dtcm_hit 4120` **identical to the 2:1 island
run**, so the same functional progress, and the IO chain fully matched. `bootreq`
passes at 1:1 with `pass=0x5A5BDE7F`.

**The cost is ARM9 clock: 33.514 MHz instead of 67.028.** Whether that is playable
depends on the GPU pacing item immediately below, which is the next piece of work
and is worth more than any further timing effort. NOTHING HAS BEEN DEPLOYED - the
RBF exists at `build/artifacts-isl0/NDS.rbf` but no hardware result is claimed.

## UPDATE 2026-07-28 (b): the 3x "too slow" is GPU_CE_DIV, not the CPUs

First run past the boot phase: 216 ms / 6 frames, untraced, `CYCLE_HIST=2000000`.
This is 12x further than any previous measurement and it changes the speed story.

**Frames dump every 50.42 ms, dead constant** (87.26 / 137.68 / 188.10 ms) against
16.74 ms for real NDS — exactly **3.01x**. That is not CPU slowness, it is
`GPU_CE_DIV`, and `nds_top.vhd:14-20` already documents it:

> the GPU dot cadence is ce-paced at 1-of-GPU_CE_DIV … the planned MiSTer topology
> (fabric 100.5 MHz, dots 33.5) **with clk1x standing in for the fabric clock** …
> Consequence: relative to the CPUs the frame is GPU_CE_DIV x longer than hardware

### The exact mechanism, and why it is not a misconfiguration

`nds_gpu_timing.vhd:80` is `constant LINE_CYCLES : integer := 355 * 6`, which
already encodes the real relationship: 355 dots x 6 clk1x cycles per dot, because
clk1x (33.514 MHz) is 6x the NDS dot clock (5.585 MHz). But the timing unit is
ce-gated 1-in-3, so a line costs 2,130 x 3 = 6,390 clk1x cycles:

| | clk1x cycles/frame | frame time |
|---|---|---|
| GPU_CE_DIV=3 (current) | 263 x 6,390 = 1,680,570 | **50.15 ms** (measured 50.42) |
| GPU_CE_DIV=1 | 263 x 2,130 = 560,190 | **16.72 ms** = real NDS |

And **`gpu_ce` gates ONLY `itiming`** (`nds_top.vhd:1685` is its single consumer -
grep it). The renderer runs at full `clk1x` the whole time. So slowing the timing
unit stretches each dot from 6 clk1x cycles to 18, and *that* is what lets the
renderer keep up.

So this is not a wrong clock assignment, it is a deliberate placeholder, and the
real deficiency is **renderer throughput: the v1 line server needs ~18 clk1x
cycles per dot where a real-time dot clock affords 6.** That is exactly why
`GPU_CE_DIV=1` drops ~110 lines/frame and why `tb_gpu2d_timed` says 3.

### Measured at GPUCEDIV=1 (confirms the arithmetic exactly)

```
frames at 29.13 / 45.94 / 62.74 / 79.55 / 96.36 / 113.16 ms
deltas   16.806 ms x5, dead constant     ratio to GPUCEDIV=3's 50.42 ms = 3.000
```

**16.806 ms against real NDS 16.716 ms - 0.5% off real-time**, and exactly 3.000x
the current config. That half is content-independent (pure timing-unit arithmetic)
and is now confirmed empirically as well as from `LINE_CYCLES`.

**The line-drop cost is NOT yet measured, and do not repeat this mistake.** The
same run reports only **3 dropped lines/frame** (cumulative 7/10/13/16/19/22),
which looks like the renderer nearly keeping up - but the framebuffer is
**100% white across all 294,912 pixels**, i.e. `DISPCNT=0`, display off, so the
renderer had nothing to draw. That number is worthless as a throughput measure.
The header's ~110 drops/frame on an affine scene stands as the relevant figure for
real content, and renderer throughput remains the open problem.

### ANSWERED: Kirby's real video mode, and the ~600-frame rule was invented

**Delete the "judge only after ~600 frames" rule wherever it appears in this
document.** Kirby enables its display at **dump frame 51**, and on real hardware /
melonDS within 3-4 seconds. `main_fbdump.cpp` now has a `VIDLOG=1` hook that reports
the video-mode registers on change:

```
VIDLOG frame=0   DISPCNT_A=00000000  DISPLAY OFF
VIDLOG frame=10  DISPCNT_A=80200018  off, BG config being written
VIDLOG frame=51  DISPCNT_A=80211218  mode 1 - DISPLAY ON (BG1+OBJ)
VIDLOG frame=109 DISPCNT_A=80211810  mode 1, settled (BG3+OBJ)
VIDLOG frame=120 DISPCNT_B=00211810  engine B follows
```

Steady-state target, which is what a render-test ROM should program:

| field | engine A | engine B |
|---|---|---|
| DISPCNT | `80211810` | `00211810` |
| display mode (16-17) | **1, graphics** | 1 |
| BG mode (0-2) | **0, all tiled** | 0 |
| BGs enabled | **BG3 only** | BG3 only |
| OBJ | **on, 1D mapping** | on, 1D |
| ext palettes (b31) | **yes** | no |
| POWCNT1 | `820F` | — |

**Kirby never uses the 3D engine.** `BG0 enable` (bit 8) is 0 in *every* value
logged, so the BG0 2D/3D bit is moot even in the frames where it is set. The
2D-only scope is safe for this title.

Run it:
```bash
VIDLOG=1 sim/melonds_tracer/build/melonds_fbdump --direct \
  "/Users/heni/Downloads/Kirby - Squeak Squad (USA)/Kirby - Squeak Squad (USA).nds" \
  /tmp/kfb.txt 300 2>&1 >/dev/null | grep VIDLOG
```
Caveat: `FRAMEMAP`'s vblank counter (`0x02FFFF08`) reads a constant garbage value on
this ROM under direct boot, so dump-frame index is the only usable time axis, and
`RunFrame` coalesces frames while the LCD is off.

Renderer load under real content still cannot be measured in RTL sim (216 ms only
reaches 6 frames), but it no longer needs to be inferred - the mode above can be
programmed directly by a test ROM and driven at full rate.

**Two routes, and they are alternatives not steps:**

1. **Move the render fabric to `clkMem`** (the documented intent: "fabric
   100.5 MHz, dots 33.5"). At 3x clk1x the renderer gets 18 clkMem cycles per dot -
   precisely its measured need - while `itiming` runs at full clk1x for real-time
   frames. clkMem is an exact 3x, phase-locked, and `clkMemIndex` is already
   plumbed, so unlike the ARM9 island this is an **integer-ratio related clock**,
   which is the friendly case. The work is CDC between the clkMem fabric and the
   clk1x IO/VRAM/framebuffer interfaces.
2. **Make the line server 3x cheaper per dot.** Attacks the same number from the
   other side and needs no clock work, but it is a gpu2d rewrite.

Either way, `itiming` must end up with `ce = '1'`. This is the "M9 pacing" item the
header defers and it is the whole of the remaining 3x - it is worth more than any
further timing effort.

Supporting numbers from the same run:

- **The caches are working by 200 ms**: `FILL_BEAT` 28,312 (vs 3,352 at 18 ms),
  `FILL_WAIT` 333,323, `WB_WAIT` 28,487. Every CPI figure in this repo predates
  cache enable — see the boot-phase warning in COORDINATION.md.
- **Kirby is really rendering**: `membus9 state 3` (W_VRAM) is 21% of cycles, 0 at
  18 ms.
- **The ARM9 has headroom**: `cpu9_ena 2,159,850 of 14,000,000` = it wants the bus
  only **15.4%** of cycles, and after frame 2 its accept counter freezes for
  ~3 ms+ with no error, consistent with finishing frame work and idle-waiting for
  vblank. Rough estimate off that idle window: at a real 16.74 ms frame budget the
  ARM9 would be **~1.4x short**, not 3-9x. Treat that as an estimate, not a
  measurement — it is inferred from a frozen counter over a thin sample, and the
  clean way to settle it is per-frame ARM9 busy cycles.
- **Screen still white** (294,912 px, all 0x3FFFF) at 6 frames. Expected:
  `DISPCNT=0` is display-off and this document's own rule is to judge after ~600
  frames (~10 s simulated, out of reach). The screen question still needs the
  melonDS video-register log, not RTL sim.

## UPDATE 2026-07-28: read this before acting on the timing section below

Two measurements change what the timing problem *is*. The section below is
accurate about slack numbers and about what has been tried; its **strategy
advice ("go after area", "close the remaining 2.5 ns") is superseded.**

1. **67 MHz is inherited from the video clock, not required by the ARM9.**
   `NDS.sv:206` is `assign CLK_VIDEO = clk_video_67;` — the island shares the
   video pixel clock. This number was never an ARM9 requirement.

2. **clk2x fails on a broad front, not a path.** Census of *all* violating paths
   in `artifacts-t5/NDS.paths_67mhz.rpt` — the `-npaths 50` report shows only the
   worst family, which is what made this look like a single-path problem:

   | family | paths | worst |
   |---|---|---|
   | DTCM `porta_we` | 2,009 | −2.535 |
   | store data → `pal/vram/oam/wsh_din` | 514 | −2.491 |
   | `creq_*` | 351 | −2.254 |
   | `io_bus` | 78 | −2.278 |
   | other | ~50 | −2.170 |

   Five families inside **0.37 ns** — and more hidden behind them.

   **This was then tested, and the result is the strongest evidence in this
   document.** The DTCM port-B deferral (`build/artifacts-dtcm`, seed 0, directly
   comparable to `artifacts-t5`) eliminated the entire 2,009-path DTCM family —
   `idtcm|*porta_we_reg` appears **zero** times in the new violating set, so the
   fix did exactly what it was designed to do. Result:

   | | t5 | dtcm | delta |
   |---|---|---|---|
   | clk2x WNS | −2.535 | **−2.809** | −0.274 (worse) |
   | clk2x TNS | −1415 | −1551 | worse |
   | violating paths | ~3,000 | ~3,000 | **unchanged** |
   | ALMs | 37,652 | 37,232 | −420 (better) |

   Removing **67% of all violating paths bought nothing on WNS.** The new worst is
   `shiftervalue → fetch_PC` at −2.809, i.e. the PC-update datapath loop that the
   section below already calls unamenable to restructuring, with 2,021 paths that
   were queued invisibly behind DTCM. The −0.274 ns is inside the 1.53 ns seed
   spread so it is not attributable, but that is the point: **the front is deep as
   well as broad, and per-family RTL work cannot close this.** Do not spend more
   builds on one family at a time — the DTCM change is worth keeping for its 420
   ALMs, not for its slack.

3. **A slower island is nearly free, and the CDCs survive a non-integer ratio.**
   `ISLAND_HALF_PS` (new bench generic, 7500 = current 2:1) at 8750 = 57.1 MHz,
   ratio 1.705:1: `bootreq` **pass=0x5A5BDE7F prog=0x63 identical to control**;
   IO bridge **314 requests issued / 314 arrived, 19/19 writes**; Kirby 25 ms
   ends in the **same 3-instruction copy loop**, ratio 2.674 → **2.632 (−1.6%
   for a −14.4% clock)** because the ARM9 is memory-bound. Required period is
   17.45 ns = **57.3 MHz**, so ~57 MHz closes clk2x with the ratio still clear of
   the 2.32 target. Remaining work is a 4th PLL output + SDC — *not* done, and
   not yet fitted.

   The "the handshakes were written against a 2:1 ratio" worry below **does not
   hold**: the request toggle sits stable until the transaction completes
   (`nds_top.vhd:774-780`), the `*_done` paths are edge detectors and a 1-clk1x
   pulse is still 1.705 island cycles, and the one ratio-sensitive structure
   (`cpu9_done` toggle+XOR, `:924-937`) is *safer* slower. ISLAND=0 breaking at
   1:1 is a real but separate defect — 1:1 is the degenerate case, 1.705:1 works.

4. **DO NOT PICK /16. The ratio collapses on a 3:2 harmonic.** Ratio measured on
   Kirby 25 ms at each available divisor (all four runs end in the *same* copy loop
   at 0x020008A8/AC/B0, so these are same-phase comparisons):

   | MHz | div | ARM9 | ARM7 | ratio | vs 2.32 |
   |---|---|---|---|---|---|
   | 67.028 | /12 | 212,592 | 79,501 | 2.674 | +0.354 |
   | 57.453 | /14 | 203,207 | 77,215 | 2.632 | +0.312 |
   | 53.622 | /15 | 198,545 | 75,865 | 2.617 | +0.297 |
   | 50.271 | /16 | 174,616 | 78,939 | **2.212** | **−0.108 BELOW** |

   /16 is exactly **3:2** against clk1x (24/16 = 1.5) and the ARM9 loses 12% of its
   instructions while the ARM7 *gains* — it looks like a systematic main-RAM
   arbitration slot lost to the harmonic alignment. /15 is 8:5 and /14 is 12:7.
   **The only divisor that both closes timing and holds the ratio is /15
   (53.6 MHz), and its +1.20 ns is inside the 1.53 ns seed spread**, so expect a
   seed sweep. Do not extrapolate a trend across divisors — measure each one.

5. **TIMING CLOSURE IS NECESSARY BUT NOT SUFFICIENT, and the clock change trades
   away speed the core does not have.** Instantaneous rate from the `T9`/`T7`
   checkpoints of a Kirby 25 ms run at the current 67 MHz:

   | CPU | MIPS | CPI | trend |
   |---|---|---|---|
   | ARM9 @ 67.028 | **8.02** | **8.4** | flat over 23 ms |
   | ARM7 @ 33.514 | **3.04** | **11.0** | flat |

   Real hardware is roughly CPI 1.2–2 (ARM9, caches on) and ~3–5 (ARM7 from main
   RAM), i.e. **the core is ~4–7x too slow** — the same order as the "~9x slower"
   note in the ledger. The window is the boot copy loop, so it is the memory-bound
   worst case and does *not* measure gameplay locality; but the rate is flat, so
   nothing is warming up.

   **Consequence for ordering: fix CPI before touching the clock.** The known
   mechanism is already diagnosed — `BYPASS_WAIT` at ~35% of ARM9 cycles because a
   cacheable write miss goes write-no-allocate (`nds_cache9.vhd:624`, correct for
   ARM946E-S) but stalls the CPU for the whole ~11.5-cycle round trip, where real
   hardware posts it through a write buffer (`cp15_pu_wbuf` = 0x02 enables
   buffering on main RAM). A posted-write FIFO is worth roughly **4x** (8 → ~30
   MIPS); the /15 clock cut costs **20%**. Doing the clock first spends speed the
   core cannot spare; doing the write buffer first makes the clock cut painless.

6. **`tb_top_frame`'s `IO9 path:` counter lied, and the handoff told you to trust
   it.** `p_iocount` counted clk1x arrivals with `if (clk1x = '1' and
   a_io9.ena = '1')` — a level sample correct only by accident of 2:1 coincident
   edges. At 1.705:1 it reported 183 of 314 and looked exactly like the CDC
   dropping 131 requests. Now a rising-edge detector. **Never trust a
   cross-domain counter without reading how it samples.**

---

## The timing blocker (independent of everything above)

### First: `NDS.sta.summary` names PLL outputs, not clocks

Earlier revisions of this document read that summary wrong, and the error changed
what the problem looked like. The mapping is in `NDS.sv:213-215`:

| STA name | PLL output | clock | period |
|---|---|---|---|
| `general[0]` | `outclk_0` | clkMem | 9.95 ns |
| **`general[1]`** | `outclk_1` | **clk2x — the ARM9 island, 67.028 MHz** | 14.915 ns |
| **`general[2]`** | `outclk_2` | **clk1x — everything else, 33.514 MHz** | 29.83 ns |

and **Quartus groups setup by the *latch* clock.** So the headline "−4.622 ns"
was the *clk1x* domain, reached by a clk2x → clk1x **crossing**, while the
island's own worst was −4.196 with 29× the total negative slack (−3838 vs −133).
Reading it as "the ARM9 core misses by 4.6 ns" sends you into the datapath;
reading it correctly sends you to a CDC, which is where it was. Always check
which of the two failing domains a number belongs to before acting on it.

### Where it is now

**Two of the three clock domains now pass.** Only the island is left.

```
build/artifacts-t5/  (seed 0, the shipping settings)
  clk2x (island):  -2.535   TNS -1415.1    <- the only thing left
  clk1x:           +1.584   TNS     0.0    PASSES (was -4.622)
  clkMem:          +1.372   TNS     0.0
Fitter: Successful, 90% ALMs
```

`clk1x` closing is the `io9_lat` re-registration: it was the last combinational
clk2x -> clk1x crossing, and every peripheral's address decode sat inside it.
There is no longer a cross-domain path anywhere in the failing set.

Progression, every step trace-identical against the previous HEAD:

| build | change | clk2x | clk1x | ALMs |
|---|---|---|---|---|
| `artifacts-alu2` | baseline | −4.196 (TNS −3838) | −4.622 | 91% |
| `artifacts-t1` | lock CDC, shift width, address mux, PU width | −3.400 (−2465) | −1.668 | 89% |
| `artifacts-t2` | + five shifters → one rotator | **−2.499 (−790)** | −1.959 | 91% |
| `artifacts-t3` | + TCM selects, mux merge, **fitter knobs** | −4.104 (−3356) | −2.212 | 91% |
| `artifacts-t4` | t3 with the knobs reverted | −2.622 (−1244) | −2.099 | 91% |
| `artifacts-t5` | t4 minus the `adr_is_pcw` expansion, plus the clk1x IO payload latch | −2.535 (−1415) | **+1.584** | 90% |
| `artifacts-t5s3` | same netlist, seed 3 | −4.065 (−3940) | +1.535 | 90% |
| `artifacts-t5s7` | same netlist, seed 7 | −3.046 (−1612) | **+1.981** | 90% |

### Read that table with the seed spread in mind, or you will fool yourself

The last three rows are **the same netlist**. Seeds 0 / 3 / 7 give **−2.535 /
−4.065 / −3.046** with TNS **−1415 / −3940 / −1612**. That is a **1.53 ns spread
and 2.8x on TNS from placement alone**, on a design at 90% utilisation where two
thirds of the worst path is interconnect.

Consequences, all of which bite:

- **A single build cannot resolve a change smaller than ~1.5 ns.** Sweep at least
  three seeds before believing any per-change number, including the ones above.
- The overall clk2x result, −4.622 → −2.535, is 2.09 ns — above the spread, but
  not by much. **The unambiguous win is clk1x**: −4.622 / TNS −133 → +1.584 /
  TNS 0, and it holds on all three seeds.
- **The `t3` attribution is weaker than it looks.** t3 (knobs, −4.104) vs t4 (no
  knobs, −2.622) is 1.48 ns, i.e. *inside* the spread, from one sample each. What
  can honestly be said: raising `PLACEMENT_EFFORT_MULTIPLIER` did not help, cost
  build time, and moved the worst endpoints into DSP logic (`dblsat`, `dsp_rb`)
  that no source change had been near. It is not established as systematically
  harmful. Do not spend builds re-litigating it.
- **The two RTL edits in t3 were a wash** — t2 −2.499 / 37,971 ALMs vs t4 −2.622
  / 38,306, a 0.12 ns difference that means nothing. The `adr_is_pcw` expansion
  was reverted on the ALM count, which is the one number in that comparison that
  is not noise; the TCM select simplification is strictly less logic and stayed.

### What is left, and the two shapes it comes in

**(a) The datapath loop** — `fetch_PC/regs → op2 mux → rotator → keep/fill → ALU
adder → writedata mux → pcwrite_Addr → +2/+4 → fetch_PC`, 16.672 ns off
`artifacts-t2/NDS.paths_fam.rpt`:

| segment | ns |
|---|---|
| op2 register-file mux, **split either side of the loop by retiming** | 5.67 (4.9 interconnect) |
| `fetch_PC` `+2/+4` adder | 3.17 |
| rotator + keep/fill mux | 2.42 |
| ALU adder | 2.08 |
| `pcwrite_Addr` / `bus_AddrFetch_eff` | 2.54 |
| `execute_writedata` mux | 0.85 |

**(b) The DTCM store's write enable**, which is the worst endpoint in `t5` at
17.629 ns over 11 levels (`fetch_PC[1] → … → idtcm|ram_block1a0~porta_we_reg`).
The address now arrives 2.6 ns earlier than in `t1`, but the tail is unforgiving:

| segment | ns |
|---|---|
| bus address → `imembus9` (one routing hop across the port) | 1.99 |
| `itcm_hit` → `dtcm_we` | 2.75 |
| **routing into the M10K + its write-enable setup** | **3.46** |

That last row is 20% of the whole path and no amount of logic work touches it.
The way out is to stop presenting the TCM write in the accept cycle: port B of
`SyncRamDualByteEnable` is unused (`ce_b => '0'` in both `iitcm` and `idtcm`), so
the write could move there with a registered address/data/we, giving it a full
extra cycle. **The catch is a read-after-write hazard** — port A reads
combinationally off the live `cpu_adr`, `membus9` accepts a new request in the
same cycle it retires one, and mixed-port read-during-write on Cyclone V returns
old data — so it needs a store-forward bypass (compare the pending write address,
merge per byte-enable into the read data). That is a real piece of work, not a
tweak, but it is now the largest single identifiable item after the register file.

Which of (a) and (b) reports as *the* worst path moves with the seed; they are
within a few hundred ps of each other and both are ~65% interconnect. **That is
the real finding: what is left is placement, not logic.** The register-file mux
in (a) is a 16:1 32-bit mux read three times (op1/op2/opDest) across 512 source
flops; the RAM tail in (b) is fixed silicon. Neither yields to restructuring.

So **area is the next lever, not further rewriting**: `nds_sound` is 6,538 ALMs,
larger than `nds_cpu9` at 5,676 and larger than either `nds_gpu2d`, and
`FITTING.md`'s RESOLUTION section documents the async-read-array pattern its
16-channel state looks like. The four separate families of the previous session
have collapsed into these two; there is no cheap structural target left inside
`nds_cpu9`.

### Ideas that are wrong, recorded so they are not tried again

- **Moving the PU cacheability compare onto the registered `creq_addr`.** It looks
  free — `creq_cacheable` is consumed the cycle *after* accept, so the value would
  be identical. It is not: `nds_cache9` uses `req_cacheable` to gate the early-hit
  `resp_done` (`nds_cache9.vhd:535`), and `resp_done` feeds `accept_now` →
  `cpu_done` → the CPU's whole execute stage, so a 4-level cone in front of it
  adds ~4.3 ns to the `cpu_done` family. One failing family traded for a worse
  one. The compare stays on the live address; only its width came down (bits
  31:12, which is melonDS's own `PU_Map[addr >> 12]` granularity).
- **Leaving a redundant copy of a term you have bypassed.** Static timing does not
  know two conditions are mutually exclusive, so the long path is still reported
  and still routed. The PC-write term had to come *out* of `execute_branchPC`, not
  merely be duplicated onto the final address mux.
- **Raising `PLACEMENT_EFFORT_MULTIPLIER`.** See `t3` above.

### CORRECTION 2026-07-28: the ISLAND=0 stall below is a TESTBENCH ARTIFACT

The section that follows concludes "closing clk2x timing is the only route to a
deployable core" and warns that "anyone who assumes there is [a fallback] will
lose a day discovering this." **That conclusion rests on one line of the bench.**

`sim/tb_top_frame.vhd` tied the domains with `clk2x <= clk1x`. But `clk1x` is
itself a *signal* driven from the `clkMem` process, so a concurrent copy puts
`clk2x` **one delta cycle** behind it — and that delta inverts every
clk1x→clk2x edge detector in `nds_top`:

```
delta 1: clk1x rises; the clk1x process schedules the new cdc_io_cpl
delta 2: cdc_io_cpl becomes new AND clk2x rises, so the clk2x process
         samples the ALREADY-UPDATED value
```

`cdc_io_cpl_d` therefore tracks `cdc_io_cpl` exactly, `i9_io_done` can never
pulse, and `membus9` parks in `W_IO_RESP` on its first IO access. That is
precisely the reported signature: Kirby retires **1** ARM9 instruction with 5
accepts, bootreq reaches 90 accepts and `pass=0x0`, and the bench's own IO chain
reads `cdc_io_cpl tgl 1 -> i9_io_done 0`.

On hardware, `clk2x` tied to `clk1x` is **one net**: both flops see the same
edge and the detector works. The fix is to drive `clk2x` from the same `clkMem`
edge and the same `clkMemIndex` as `clk1x` so both land in the same delta, which
is what a shared net does — done, see the `gnoisland` comment in the bench.

Two things follow. **(a) The "5 memory accesses in 30 ms" evidence proves nothing
about the RTL.** **(b) The suspicion recorded below — "those handshakes were
written against a 2:1 ratio and at least one of them does not survive 1:1" — is
unsupported.** The request path is a toggle held until the transaction completes
and the done paths are `V(t) xor V(t-1)` edge detectors, both correct at any
ratio; and the 1.5:1 and 1.705:1 runs pass `bootreq` with the IO chain fully
matched (267 issued / 267 arrived / 267 done at 1.5:1).

Note this does *not* make ISLAND=0 desirable — it drops the ARM9 to 33.5 MHz,
and absolute speed is the thing the core can least afford. It removes the *fear*
that there is no fallback, and it retires a bogus 1:1 CDC bug hunt.

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

The consequence for planning: **closing clk2x timing is the only route to a
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
- **Missing from `bootreq`, and it is now load-bearing: an ARM9 SWP.** Measured on
  the 25 ms Kirby trace, the ARM9 executes **zero** SWP/SWPB, and `bootreq` has no
  subtest for one, so no ROM has ever driven `nds_mainram`'s lock pair through the
  full system. `sim/tb_mainram.vhd` covers the lock *semantics* (it drives
  `mem9_lock` directly, 10,000 concurrent pairs) but not how `mem9_lock` is
  produced — which changed on 2026-07-27 when `nds_top` started sourcing it from
  the island latch `mr9_lock` instead of live combinational logic. That rewrite is
  equivalent by construction (the CPU is stalled with the address held while the
  access is in flight) and it is the single biggest timing win in the design, but
  it has never been executed. Note that a single-threaded SWP would not
  distinguish a working lock from a missing one either — the bench needs to count
  `imainram|lock_pair` assertions.

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

**The A/B recipe for an RTL change that must not alter behaviour.** Three tiers,
each catching what the one before it cannot; run all three before a build:

```bash
# 1. exhaustive, 0.3 s - algebraic identities (currently just the shifter)
sh sim/run_shifter_equiv.sh                        # 294,912 cases

# 2. targeted, ~80 s local - the ISA features you touched
SEED=1 CHUNKS=400 LOOPS=1000 sim/tests/build_arm9_torture.sh
MAXINSTR=400000 HEXFILE=sim/tests/arm9_torture.hex LOADADDR=33554432 \
  TIMEOUT_MS=800 sh sim/run_arm9_trace.sh          # then md5 arm9_trace.log
#    CACHES=1 on the build line turns the PU and both caches on - a different
#    machine, and the only variant that exercises bus_cacheable_*

# 3. integration, ~15 min on a pod - a real boot, both CPUs
DIRTY=1 POD=nds-sim-new ARTIFACTS="isl9.txt isl7.txt" \
  ENV="WORK=sim/nvc_work_ab PRELOAD=1 HEXFILE=sim/tests/kirby_4mb.hex DIRECT=1 \
       TRACEFILE=isl9.txt TRACEFILE7=isl7.txt TRACE_START_FRAME=-1 \
       TRACE7_START_FRAME=-1 TIMEOUT_MS=25 FRAMES=2" \
  build/remote-sim.sh run_top_frame.sh
#    reference numbers: ARM9 212,592 / ARM7 79,501 lines, and for the tree at
#    the time of writing md5 6be14b4d9fb41a01e02d377b9c19d098 / d6ea0d1d5...
```

The reference side must be a **worktree with `sim/tests` rsynced in**, not
`REF=HEAD` — the BIOS dumps and Kirby hexes are gitignored, so a `git archive`
side runs a different machine. Anything touching the IO bridge also wants
`bootreq` (`pass=0x5A5BDE7F`, and the bench's own `IO9 path:` line, which counts
island requests against clk1x arrivals and will show a dropped one).

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

**First-divergence vs the oracle** — `sim/tests/compare_trace.py`, which already
does this and is documented in `docs/TRACE_DIFF.md`; earlier revisions of this
document sent you to a `scratchpad/firstdiv.awk` that no longer exists and never
needed to. It folds case on its own (the RTL writes uppercase hex and melonDS
lowercase, or every line "diverges" on line 1). **Against melonDS pass
`--ignore cpsr,r13,r14`** — it pre-sets SP/LR, so those columns differ from
instruction 1 and hide everything real behind them. Comparing two RTL traces,
ignore nothing.

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

0. **NEW ORDER OF WORK, per the 2026-07-28 measurements above.** (a) Posted-write
   FIFO for the ARM9's cacheable write misses — worth ~4x on CPI, and the core is
   4–7x too slow, so this is the actual gate on *playable*. (b) Then give the island
   its own PLL output at **/15 = 53.6 MHz** (not /16 — the ratio collapses on its
   3:2 harmonic), expecting a seed sweep because +1.20 ns is inside the seed
   spread. (c) Then fit, `bootreq`, Kirby A/B, and only then deploy. Item 1 below
   is the old plan; its measurements hold, its strategy does not.

1. **Close the remaining ~2.5 ns on clk2x** — still the only thing between here and
   a core that can run on hardware. **But do it by giving the ARM9 island its own
   PLL output at ~53.6 MHz, not by more RTL: see "UPDATE 2026-07-28" above.** The
   failing set is five families inside 0.37 ns, so fixing families one at a time
   cannot close it; a clock change gives all ~3,000 paths +2.6 ns at once, and it
   was measured to cost 1.6% of the ARM9:ARM7 ratio. Concrete remaining work:
   add a 4th output to `rtl/pll` (the island stops sharing `clk_video_67`), update
   the SDC/`NDS.sv` wiring, then fit and re-run `bootreq` + a Kirby A/B. The rest
   of this item is the *old* plan, kept because its measurements are still valid:
   **do not start by restructuring `nds_cpu9` logic.** The four
   families of the previous session have collapsed into one loop whose largest
   single item is the register-file mux, and 4.9 of its 5.67 ns is interconnect.
   Read the budget table in the timing section, then go after **area**:
   * `nds_sound` is 6,538 ALMs — bigger than `nds_cpu9` at 5,676 and bigger than
     either `nds_gpu2d`. Its 16-channel state is an array of records indexed at
     runtime, which is the flops-plus-16:1-mux pattern `FITTING.md`'s RESOLUTION
     section already had to fix elsewhere. The unit is time-multiplexed over
     channels, so the state is a natural fit for an MLAB.
   * `MISTER_DISABLE_YC` is still commented out in `NDS.qsf`. Turning it on drops
     the composite/S-video encoder. That is a product decision, not a free win —
     ask before taking it.
   * Before spending a build on an inference, check it against the *previous*
     build's `NDS.paths_fam.rpt` rather than reasoning from the VHDL. That report
     now exists precisely because endpoint names are not enough: the path that
     replaced `req9_lock` ran `cache9|resp_done → cpu_done → execute_writeback →
     execute_writereg → pcwrite_fetch → gb_bus_Adr → dtcm_hit → dtcm_we → M10K`,
     and 3.32 ns of it was the M10K's own write-enable routing and setup.
   * Keep changing one thing per build. Bundling two fitter knobs with two RTL
     edits cost a build and 1.6 ns of confusion (`artifacts-t3`).
2. ~~**Verify the screen in sim before building.**~~ **The "~600 frames" rule in
   this item was invented and is deleted** — Kirby enables its display at melonDS
   dump frame **51** (3-4 s on real hardware), see the ANSWERED section above. RTL
   sim still only reaches ~6 frames in 216 ms, so the screen is not judgeable
   there, but the answer no longer has to be waited for: it is a `VIDLOG` run.
3. **Write a render-test ROM in Kirby's modes — they are now known** (the "Kirby
   has not picked any" premise below was a consequence of only ever looking at the
   first ~95 ms). Target `DISPCNT_A=80211810` / `DISPCNT_B=00211810` /
   `POWCNT1=820F`: display mode 1, BG mode 0, BG3 + OBJ, 1D OBJ mapping, engine-A
   extended palettes, and **no 3D** (BG0 is never enabled). Original note follows,
   still accurate about the early-init burst: Measured with `p_vidregs`: in a 95 ms run Kirby touches video
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
- **Running `sim/run_arm9_trace.sh` on a main-RAM-linked ROM without
  `LOADADDR`.** It defaults to 0, which means "HEXFILE is the boot ROM at
  0xFFFF0000". `arm9_torture.hex` is linked at 0x02000000, so without
  `LOADADDR=33554432` the run executes open-bus garbage at `0x0000xxxx` for every
  one of its instructions — and **both sides of an A/B produce the same garbage
  and the same MD5**, so it reads as a clean pass. Check the trace's pc column
  spans the ROM before believing a diff.
- **Believing a trace diff without checking the workload executes what you
  changed.** Correctly loaded, the torture ROM as it stood retired **2**
  register-specified shifts and **zero** PC writes in 400,000 instructions; it
  could not see either of the two `nds_cpu9` changes it was being used to
  validate. `gen_arm9_torture.py` now has `chunk_pcwrite`; count the opcodes you
  care about in the trace rather than assuming.
- **Reading a slack number out of `NDS.sta.summary` without resolving which
  clock it belongs to.** The names are PLL outputs, `general[1]` is clk2x and
  `general[2]` is clk1x, and the grouping is by *latch* clock. See the timing
  section.
- **Bundling fitter settings with RTL changes in one build.** `artifacts-t3` did
  and came out 1.6 ns worse; it took another whole build to establish that the
  settings, not the code, were responsible.
- Taking an IO measurement before instruction ~536,610 (~57 ms) and reading
  meaning into it. Kirby does almost no IO before then.
- Gating the ARM7's `ce` to fake the ratio. Measured twice wrong; kills the ARM7
  (`gb_bus_done` is consumed in ce-gated processes while `membus7`'s `cpu_done` is
  a state level), and desynchronises it from its own timers.
- Editing a running shell script (`bash` reads incrementally — it will die
  mid-build) or a source tree during a `remote-build` (it snapshots at launch).
- Deploying a core that misses timing.
- Writing a carry-in as `A + B + C`. Quartus infers a ternary adder and builds
  two chained carry chains — the same structure the `if C then A+B+1` form
  produces. Costs a build to discover, and simulation cannot catch it because it
  is functionally identical. Use the extra-LSB form, `(A & '1') + (notB & C)`
  with bits `[n:1]` taken; see `nds_cpu9.vhd:2105` for the worked version.
- Comparing a build against `build/artifacts-*` from an earlier session without
  checking the fitter timestamp against `git log`. `artifacts-island` predates
  `0b11f58`, which moved BIOS9 onto clk2x, so a diff against it silently mixes
  that commit into your result (+528 registers that no combinational edit can
  explain was the tell).
- A/B'ing a sim with `REF=HEAD` on one side and `DIRTY=1` on the other. The
  retail BIOS dumps and the Kirby hex images are gitignored, so the `git archive`
  side runs a different machine. Use a worktree with `sim/tests` rsynced in.
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

- ~~`scratchpad/firstdiv.awk`~~ — **not missing and never was.**
  `sim/tests/compare_trace.py` does the job, is documented in
  `docs/TRACE_DIFF.md`, and now takes `--ignore cpsr,r13,r14` for the melonDS
  case. Nothing to rewrite.
- `scratchpad/deploy-probe.sh` — upload + SHA verify + **production-core guard** +
  `load_core`. Rewrite this one carefully before the next deploy: its job included
  refusing to touch `NDS_20260719.rbf`, and a careless replacement loses that
  protection silently.
