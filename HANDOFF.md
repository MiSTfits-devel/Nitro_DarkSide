# NDS_MiSTfits — state of play, 2026-07-28

Goal: **run 2D NDS titles on the DE10-Nano**, Kirby: Squeak Squad as the test case.

Earlier revisions of this file were a running narrative and most of it was
superseded, wrong, or both — `git log HANDOFF.md` has the history. This is current
state only. **Treat every claim here as provisional and check it before spending a
build or a long run on it**: a large fraction of what the old version asserted as
rules turned out to be invented.

---

## Where the project is

| Thing | State |
|---|---|
| **Timing** | **CLOSES.** 0 violated paths, worst setup **+1.537 ns**, all holds positive, Fitter Successful. `build/artifacts-isl0`. |
| **Area** | 85% ALMs (35,824 / 41,910), 85% M10K, 84% DSP |
| **ARM9 island** | **Removed.** ARM9 runs on `clk1x` at 1:1. The 67 MHz island existed for a ratio requirement that does not exist. |
| **Kirby in sim** | Boots, runs, renders to VRAM. ~6 frames in 216 ms; display still off there, which is correct for that point. |
| **Frame rate** | 3.01x too slow, and it is **not** the CPUs — `GPU_CE_DIV`. See below. |
| **HDMI** | **Compiled out** (`MISTER_DEBUG_NOHDMI=1`). `ascal`/`pll_hdmi` absent, analog VGA only. Re-enabling costs ~2,178 ALMs against ~6,086 free. |
| **Hardware** | `NDS_isl0_20260728.rbf` deployed 2026-07-28 and **configures and runs** — the debug mailbox returns a coherent probe decode. Not yet exercised with a cart. |
| **Firmware boot** | **Built** (`FWBOOT=1`, sim only). Both retail BIOSes execute from their reset vectors; the ARM7 BIOS matches the melonDS oracle with **0 control-flow divergence over 323,826 basic blocks**. Cart launch not yet confirmed. |

---

## Timing closes — how, and what not to redo

The route was not RTL optimisation, it was disproving two blockers:

1. **There is no ARM9:ARM7 ratio requirement.** Kirby's handshake cannot time out on
   either side. ARM9 at `0x0214FF00`: `mov r2,#1000` is a polling budget and on
   expiry `movle ip, r1` **restores the attempt counter** and retries — no failure
   path. (Its 8-instruction inner wait x 1000 = 8,000 is where the old "8,017
   instructions per iteration" mystery came from.) ARM7 at `0x0238FEA0`: sets its
   nibble then spins `ldrh / and #15 / cmp #1 / bne` **unbounded**, twice. The
   "2.32 target" that justified the island was never a requirement of this code.
2. **ISLAND=0 was never broken.** The bench tied the domains with `clk2x <= clk1x`,
   a concurrent copy of a signal itself driven from the `clkMem` process — one
   **delta cycle**, which inverts every clk1x->clk2x edge detector, so `i9_io_done`
   could never pulse and `membus9` parked in `W_IO_RESP`. On hardware they are one
   net. Fixed by driving `clk2x` off the same `clkMem` edge and index.

**Do not try to lower the island clock.** Cross-domain setup budget follows **edge
alignment, not period**: 2:1 coincident gives a full fast-clock period (14.919 ns),
3:2 gives half an island period (9.942 ns). A /16 island fit came out at -8.362
despite a 33% longer period (`build/artifacts-isl16`). Only integer ratios work and
there is no integer between 1 and 2 — hence 1:1.

Also landed: the **DTCM store deferred onto M10K port B** with a registered write
enable (`nds_membus9`, "DTCM deferred store"). Removed 2,009 of ~3,000 violating
paths and ~420 ALMs. Its store-forward merge is unexercised insurance — the hazard
needs two back-to-back *data* accesses in write-then-read order, but DTCM excludes
code fetches so a fetch always separates them, and no ARM instruction stores then
loads.

---

## The real playability item: `GPU_CE_DIV`

Frames take **50.42 ms** against 16.74 ms real — exactly 3.01x, and it is not the
CPUs.

`nds_gpu_timing.vhd:80` is `LINE_CYCLES := 355 * 6` (clk1x is 6x the 5.585 MHz dot
clock), and the timing unit is ce-gated 1-in-3, so a line costs 6,390 clk1x cycles
instead of 2,130. Measured at `GPUCEDIV=1`: **16.806 ms/frame, dead constant, 0.5%
off real.**

**`gpu_ce` gates ONLY `itiming`** (single consumer in `nds_top`). The renderer runs
at full clk1x throughout, so slowing the timing unit is what *buys* it 18 clk1x
cycles per dot instead of 6. This is a deliberate placeholder, not a
misconfiguration, and **the real deficiency is renderer throughput**.

### MEASURED: the renderer is compute-bound in gpu2d, NOT VRAM-bound

Measured 2026-07-29 with `sim/tests/nds_2dk.hex` (both engines rendering, mode 1,
`GPUCEDIV=1`, `VRAMOPS=1`), on clean steady-state frames of exactly 560,190 cycles:

| | value |
|---|---|
| dropped lines / frame | **126 of 192 visible — 66%** |
| per-engine drops | **A 361 / B 361 — exactly equal** |
| renderer VRAM ops / line | **271** (= 1.06 ops per dot) |
| renderer blocked on VRAM | ~~12% of the frame~~ **RETRACTED, bad metric** — see the clkMem section. From ops instead: 271 x ~4 cycles is ~a third of a line |

**The VRAM arbiter is not the bottleneck, and the cost is localised.** Directly
measured on the same clean frame, not derived:

| | value |
|---|---|
| lines rendered / drawlines | **66 of 192** (126 dropped) |
| **cycles per RENDERED line** | **5,829** against a **2,130** budget — **2.74x over** |
| **cycles per visible dot** | **22** against **8.3** available |
| of which VRAM waiting | **~9%** (509 cycles) |
| of which gpu2d compute | **~91%** (~5,320 cycles) |

The renderer waits on VRAM 9% of a line and overruns by 2.74x, so the arbiter has
~88% headroom and making it parallel buys almost nothing.

**This self-validates:** 5,829 fits inside `GPUCEDIV=3`'s 6,390-cycle budget with 9%
margin, and does not fit 2,130. That is exactly why `GPUCEDIV=3` renders every line
and `GPUCEDIV=1` drops 2 in 3, predicted with no fitting. 2.74x also matches the
3.01x frame stretch.

**Where the 5,829 go.** `nds_gpu2d`'s `linestate` is
`LIDLE -> LDRAW -> LMERGE -> LFLUSH` (`nds_gpu2d.vhd:1142`):

- `LMERGE` is a fixed **256 cycles** — `merge_x` advances one pixel per cycle. That
  is already optimal and there is nothing to win there.
- `LFLUSH` is **8** cycles draining the 5-stage merge pipeline.
- So **~5,565 of 5,829 cycles are `LDRAW`**, which waits on `any_bg_busy` and
  `obj_busy`. **The BG and OBJ drawers are the cost**, not the merge, and not VRAM.

**Split, measured:** of the 5,829 cycles, **`any_bg_busy` accounts for 5,563 (95%)**
and `obj_busy` for 1,051 (they overlap). Kirby's mode enables **BG3 only**, so a
*single* text BG drawer is spending **21.7 cycles per pixel** — and only ~2 of those
are VRAM waiting.

So the target is precise: **`nds_drawer_text.vhd`, ~21.7 cycles/pixel, needs to be
~8.** Its per-pixel path is `CALCADDR -> WAITREAD_TILE -> CALCCOLORADDR ->
WAITREAD_COLOR` (`nds_drawer_text.vhd:175-246`), i.e. at least four states and up to
two VRAM round trips per pixel, with a `VRAM_lastcolor_data` same-address cache that
is evidently working — total renderer traffic is only **1.06 ops/dot**, so it is not
refetching per pixel.

That leaves state-machine cycles, not memory, as the cost, which makes it
pipelineable in principle: one pixel per cycle steady-state instead of a four-state
walk. **Do not start the rewrite on that reasoning alone** — instrument per-state
cycle counts in the text drawer first. `t_state` is declared inside the architecture
so it is not aliasable from the bench (same obstacle as `nds_vram`'s `rstate` and
`nds_gpu2d`'s `linestate`); either add a debug output encoding the state, or count
`VRAM_Drawer_ena` assertions against total busy cycles to separate fetch from
compute.

Two remaining options, both about gpu2d throughput rather than memory:

1. **Move the render fabric to `clkMem`** — built as `rtl/nds_gpu2d_fast.vhd`
   (`GPU_FAST` generic, default 0 = inert pass-through; `nds_gpu2d` itself is not
   modified). **Working, and a 31% gain — but not enough on its own.** Measured on
   a clean steady-state frame, `nds_2dk.hex`, both engines, `GPUCEDIV=1`:

   | per rendered line | baseline | `GPU_FAST=1` | budget |
   |---|---|---|---|
   | clk1x cycles | 5,829 | **3,996** | 2,130 |
   | over budget | 174% | **88%** | |
   | lines rendered / 192 | 66 | **94** | |
   | renderer VRAM occupancy | see RETRACTION below | | |

   **RETRACTED: the "12% -> 84% blocked, the bottleneck inverted" claim.** That
   metric counted cycles with any `srv_*_req` asserted and called it VRAM-blocked
   time. It is not occupancy: `nds_gpu2d` drives req as a ONE-CYCLE PULSE, so it
   counted requests — 0.94 cycles per op in baseline, where an op takes ~4. And it
   was not comparable across configurations, because `nds_gpu2d_fast` HOLDS req
   until done (6.14 cycles per op). The whole "inversion" was an artifact of the
   two configs driving req differently. `nds_vram` now exposes **`dbg_rbusy`** (its
   own renderer FSM busy) and the bench reports **`rvram_busy%`** from it —
   comparable, and the figure to re-measure.

   Also retracted: "only ~9% VRAM-blocked" from the original sizing, same bad
   metric. From op counts instead: 271 ops/line x ~4 cycles is ~1,084 of an
   uncontended 3,255-cycle line, so memory is roughly **a third** of a line, not a
   tenth. Still a minority, so the compute-bound conclusion stands — but on
   ops/dot, not on that number.

   **What survives**, all `line_busy` occupancy and therefore valid and comparable:
   5,829 -> 3,996 cycles/line, 66 -> 94 lines rendered, BG = 95% of the cost.

   The gain is short of 3x for a reason that does hold: **only the compute scales.**
   `nds_vram` stays on clk1x, so its service costs the same wall-clock time however
   fast the renderer runs. (An earlier version claimed "5,829 fits 6,390 with 9%
   margin" by scaling the whole figure; that was wrong.)

   **OPEN QUESTION that changes the sizing: 5,829 is not the intrinsic per-line
   cost.** The same baseline renderer, same scene, measures **3,255 cycles/line at
   `GPUCEDIV=3`** (all 192 lines rendered, 4% blocked) versus **5,844 at
   `GPUCEDIV=1`** (66 rendered, 12% blocked) — 80% longer for identical work. So
   against the 2,130 budget the uncontended cost is **53% over, not 174%**, and the
   renderer may need only ~1.5x rather than ~2.7x.

   Most likely mechanism: CPU/renderer contention through the shared VRAM arbiter.
   A `GPUCEDIV=1` frame is 3x shorter in cycles, so the CPU issues 3x more VRAM
   accesses per frame, and blocked% triples (4% -> 12%). But tripling a 4% term
   does not account for an 80% increase, so **this is not explained** — do not
   quote either figure as "the" per-line cost until it is. Measuring the CPU's
   share of arbiter dispatches (`rdispatch` split by requester) would settle it.

   **TRANSPARENCY VERIFIED (2026-07-29).** `sim/tests/fbdiff.py` on a `GPUCEDIV=3`
   A/B, frames 3 and 4:

       4 full rows differ (1, 3, 5, 7), 0 PARTIAL rows, both frames

   Zero partial-row differences means every line both configurations rendered is
   byte-identical — the adapter alters no pixels. The four full rows are explained:
   baseline rendered **188/192**, `GPU_FAST=1` rendered **192/192**, so those are
   the lines the BASELINE dropped. It is not just transparent, it is strictly
   better:

   | at `GPUCEDIV=3` | baseline | `GPU_FAST=1` |
   |---|---|---|
   | lines rendered | 188/192 | **192/192** |
   | cycles per line | 3,498 | **2,899** (-17%) |
   | `rvram_busy%` | (old bad metric) | **31%** |

   That 31% is the first trustworthy renderer-VRAM occupancy figure and it agrees
   with the ~one-third estimate derived from op counts.

   Caveat for rigour: the two runs were launched sequentially so the baseline used
   a slightly older tree. All deltas are inert (debug output ports, the bench metric
   rename) and none touch rendering, but a same-tree baseline would be cleaner if
   this is ever challenged.

   **How to test correctness of this, because the obvious test is wrong.**
   Comparing framebuffers between `GPU_FAST=0` and `1` at `GPUCEDIV=1` proves
   nothing: both configurations DROP lines (126/192 and 98/192), and a dropped
   line is itself a visible artifact, so different lines get rendered and the
   pixels legitimately differ. Compare at **`GPUCEDIV=3`**, where the budget is
   6,390 and both 5,829 and 3,996 fit, so both render all 192 lines — then
   byte-identical output is a real transparency check.

   Two adaptation traps, both of which cost a run (details in the file header):
   `eProcReg_gba`'s write path is **combinational on `proc_bus.ena`**, so a clk1x
   pulse is three clkMem cycles wide and writes every register three times unless
   edge-detected. And **`nds_gpu2d` drives `srv_*_req` as a one-cycle PULSE**
   despite `nds_vram` documenting a held level — it is safe at clk1x only because
   `nds_vram` latches into `rpend`. Sampling that pulse at `clkMemIndex=2` misses
   it two times in three; it must be captured and held until done.

3. **Move `nds_vram`'s renderer read channels to clkMem too** — the measured next
   step. Makes the service rate scale AND removes every `srv_*` domain crossing,
   which deletes the whole class of handshake bug the adapter needed. Rough
   projection from the 84%: a line would land near ~1,760-1,880 cycles, under the
   2,130 budget — **an estimate, to be measured with `VRAMOPS=1`, not trusted.**
   Note `nds_vram` also serves the CPU on clk1x, so its BRAMs need
   independent-clock dual-port (M10K supports it).

2. **Make the drawer/merge chain 3x cheaper per dot.** Same number from the other
   side, no clock work, but a gpu2d rewrite — and now the measurement says that is
   where the time actually is.

Either way `itiming` ends at `ce = '1'`. Do **not** quote the ~3 drops/frame seen at
`GPUCEDIV=1` as evidence the renderer nearly keeps up — that was measured with the
display off, so it had nothing to draw. Once Kirby writes DISPCNT the same run
settles at a steady **+7 drops/frame** (7 of 192 visible lines, 3.6%), still with
display mode 0.

**The drop counter is now split per engine** (`dbg_line_drop_a` / `dbg_line_drop_b`,
2026-07-29). The combined `drawline and (line_busy or line_busy_b)` export remains
for callers that only want "a line was dropped at all", but it ORs both engines, so
every number predating the split — the bench's "~110 dropped lines/frame on an
affine scene" and the +7/frame above — is ambiguous about which engine is behind.
Engine B runs the simpler configuration in Kirby's mode (no ext palettes), so
attributing drops to the wrong engine sizes the renderer target wrong. The bench's
per-frame report now reads `drops so far N (A x / B y)`; **re-measure with a ROM
that actually renders before sizing the GPU work** — Kirby's direct boot never turns
its display on, so use `sim/tests/nds_2dk.hex`, which reaches
`DISPCNT_A=80211810 / DISPCNT_B=00211810` (both engines, mode 1).

One measurement to be careful with: across the 337-frame direct-boot run the drop
rate was dead constant at **6.93/frame with the display OFF**. A constant rate with
nothing to draw means that counter is measuring the line server losing races
regardless of content, so it is not by itself evidence of a content-dependent
renderer overload.

---

## The renderer is PIPELINED now (2026-07-29) — and "the arbiter is not the bottleneck" was wrong

Landed: the renderer memory path and the text drawer are pipelined. All measured
with `tb_gpu2d_timed` at `CE_DIV=3` (every line renders, so nothing is
confounded by drops), as `line_busy` occupancy per rendered line — the same
basis as the 5,829 / 3,255 figures above. Budget is **2,130**.

| bench case | before | after | server busy before | after |
|---|---|---|---|---|
| 0 — mode 0, **four text BGs** + sprites | 3,119 | **947** | 2,019 | 592 |
| 1 — mode 2, affine x2 + text x2 | 4,916 | 4,340 | 2,847 | 2,299 |
| 2 — mode 5, extended bitmaps | 4,794 | 2,794 | 2,983 | 1,717 |
| 3 — mode 4, affine + extended | 5,162 | 3,952 | 2,932 | 1,970 |

**Case 0 is the one that matters for Kirby** (mode 0, tiled BGs, sprites) and it
is now **947 against 2,130 — inside budget with 2.2x margin**, while rendering
*four* text BGs where Kirby enables one.

### RETRACTED: "the VRAM arbiter is not the bottleneck ... making it parallel buys almost nothing"

That claim (and "the arbiter sits ~88% idle") rested on the same
count-req-pulses metric this file already retracts for the clkMem section — it
was never withdrawn from the *conclusion*. Measured with `dbg_rbusy`, the
metric this file itself introduced as the correct one, the v1 line server was
busy **58-65% of every rendered line**. It served ONE request at a time through
a six-state FSM: five cycles for a plain BRAM hit, nothing overlapped.

It was a throughput wall, and it was also why the drawers looked compute-bound:
with one fetch outstanding a drawer has nothing to do but wait, so its cost
shows up as its own busy time rather than as memory pressure.

### What changed

- **`nds_vram` renderer server → pipelined.** One request accepted per cycle,
  several in flight, retired **in issue order** through a completion queue, so a
  channel may have several outstanding requests and needs no tags on the wire.
  BRAM hits answer in 2 cycles instead of 5. The A..D (`rsrv`) backing channel
  is pipelined the same way. New per-channel `accept` handshake: a request is
  taken on `accept`, not on `done`.
- **`nds_gpu2d` BG arbiter → pipelined**, with a FIFO of which BG owns each
  in-flight op. One trap here, and it is the kind that produces plausible
  output: `bgv_done` is registered a cycle after `srv_bg_done`, but
  `srv_bg_data` is only valid ON the done cycle. With one op in flight nothing
  could overwrite it in the gap; with several, the drawer read the NEXT
  request's word. It shows up as pixels wearing their neighbours' colours. The
  data is now captured with the done it belongs to.
- **Palette round robin deleted.** One shared copy served 4 BGs one cycle in
  four, and the drawers *park* until answered — an average 2.5-cycle stall on
  every pixel. Now: one 1 KB palette copy per BG (~3 extra M10K), and the 32 KB
  BG ext-pal split into **four 8 KB slot RAMs**. A BG can only read the slot its
  BGxCNT selects (BG0 → 0 or 2, BG1 → 1 or 3, BG2 → 2, BG3 → 3), so at most two
  BGs want any slot — exactly what a dual-port block gives. Static assignment,
  no arbitration, `valid` is unconditional.
- **`nds_drawer_text` → decoupled prefetch pipeline.** A tile queue whose
  entries walk map-fetch → char-fetch → ready, with fetches for several tiles in
  flight at once, feeding a two-stage pixel path that has no back-pressure.
- **`NDS.sv`**: the renderer feed on SDRAM ch1 serves one op at a time
  (`ch1_rq` is a single bit) and silently DROPPED any request arriving while
  busy. Now exports `vrsrv_ready` and the core throttles. Pipelining ch1 itself
  is a separate change and wants hardware to validate.

### The drawer, measured in isolation

`sim/run_drawer_text_equiv.sh` drives the new drawer and the old one from
identical stimulus with a 5-cycle memory latency:

| | cycles/line | per pixel |
|---|---|---|
| serial (v1) | 1,183 | 4.6 |
| pipelined (v2) | **274** | **1.07** |

256 is the floor (one pixel per cycle), so this is within 7% of it. Note 4.6
rather than 21.7 cycles/pixel for v1: that bench gives it a private palette
port, so it already excludes the round-robin stall.

### A coverage hole this found: the golden model has no mosaic

`gen_gpu2d_frame.py` states it and means it — "Mosaic stays off" — so **no
full-frame bench can check the BG mosaic path**, and the rewrite had to change
it (v1 decided each repeat from `pixeldata(15)`, which a pipelined pixel path
cannot read, because pixeldata is written a cycle later). That is exactly the
shape of change that ships broken.

`sim/tb_drawer_text_equiv.vhd` closes it by comparing against v1 directly
(kept verbatim as `sim/nds_drawer_text_ref.vhd`), which is a proven-correct
oracle. 64 configurations, 384 lines, identical line buffers: all 16 mosaic
sizes in both depths, all four screen sizes, both flips, ext-pal on and off, and
every sub-tile scroll alignment. **Run it after any text-drawer change** — the
frame benches will not catch a mosaic regression.

### Still to do, with the number attached

**The affine drawer is now the limiting one.** Cases 1 and 3 are affine-heavy
and still 2x and 1.9x over budget, and case 1 works out at roughly 17 cycles per
pixel — consistent with paying TWO dependent memory round trips per pixel with
nothing overlapped (map then char, and rotation defeats its word caches). The
fix is the same shape as the text drawer: pixel N+1's map fetch overlapped with
pixel N's char fetch, several pixels in flight. Affine has no 8-pixel locality
to exploit, so the ceiling is memory throughput — 2 ops/pixel, ~512 ops/line per
BG — not 1 pixel/cycle.

Also open: the OBJ drawer is untouched (this file measured `obj_busy` at 1,051
cycles/line in Kirby's mode), and `rsrv`/ch1 could return **two** words per op —
`NDS.sv` already fetches a 64-bit burst on ch1 and throws the upper half away,
which is a free halving of A..D renderer traffic.

### Verification state

`tb_gpu2d` / `tb_gpu2d_frame` / `tb_gpu2d_timed` (pixel-exact, 0 dropped lines
at CE_DIV=3) / `tb_vram_ls` (16 VRAMCNT configs incl. the 8-channel concurrent
arbiter exercise) / `tb_vram_torture` / `tb_drawer_text_equiv` all pass;
`run_analyze_all.sh` OK and `tb_top_frame` elaborates. **Not** run: a full
`tb_top_frame` frame run, and Quartus — so the M10K delta from the palette
copies and the slot-RAM split is unmeasured, and area/timing are unconfirmed.

---

## Kirby's real video mode (measured)

Kirby enables its display at melonDS **dump frame 51** — 3-4 s on real hardware.
`main_fbdump.cpp` has a `VIDLOG=1` hook reporting video registers on change:

```bash
VIDLOG=1 sim/melonds_tracer/build/melonds_fbdump --direct \
  "/Users/heni/Downloads/Kirby - Squeak Squad (USA)/Kirby - Squeak Squad (USA).nds" \
  /tmp/kfb.txt 300 2>&1 >/dev/null | grep VIDLOG
```

Steady-state target for a render-test ROM:

| field | engine A | engine B |
|---|---|---|
| DISPCNT | `80211810` | `00211810` |
| display mode | **1, graphics** | 1 |
| BG mode | **0, all tiled** | 0 |
| BGs enabled | **BG3 only** | BG3 only |
| OBJ | on, 1D mapping | on, 1D |
| ext palettes | yes | no |
| POWCNT1 | `820F` | — |

**Kirby never uses the 3D engine** — `BG0 enable` is 0 in every value logged, so the
BG0 2D/3D bit is moot. 2D-only scope is safe for this title.

Caveat: `FRAMEMAP`'s vblank counter (`0x02FFFF08`) reads constant garbage on this
ROM under direct boot, and `RunFrame` coalesces frames while the LCD is off, so
dump-frame index is the only usable time axis.

---

## Simulation cost — it is TRACING that is expensive

Measured untraced: **~52 ms simulated in ~4 min wall** (`PRELOAD=1`, no `TRACEFILE`).

| config | frame | to display-on (~200-240 frames) | wall clock |
|---|---|---|---|
| `GPUCEDIV=1` | 16.806 ms | 3.4-4.0 s sim | **~6.5 h** |
| `GPUCEDIV=3` | 50.42 ms | 10-12 s sim | **~17 h** |

`TRACEFILE` writes a line per retired instruction (212,592 lines / 34 MB for 25 ms)
and that I/O dominates by ~40x. **Long runs are cheap if you do not trace.**

Prefer `GPUCEDIV=1` for long runs: 3x cheaper in simulated time *and* it gives the
CPUs the realistic per-frame cycle budget (at 3 they get 3x too many). Its cost is
dropped render lines — pixel accuracy, not whether the display comes on.

**`PRELOAD=1` — do not run a boot-length sim without it.** `nds_loader` stages
443,230 words (~70 ms sim, ~1 h wall) before the CPUs are released; the bench writes
those sections into the SDRAM model directly, dropping loader busy to 2,084 cycles.

```bash
WORK=sim/nvc_work_x PRELOAD=1 HEXFILE=sim/tests/kirby_4mb.hex DIRECT=1 \
  TIMEOUT_MS=5000 FRAMES=290 GPUCEDIV=1 CYCLE_HIST=20000000 \
  sh sim/run_top_frame.sh
```

---

## Performance measurement — read before quoting a number

**Every CPI/stall figure taken before ~100 ms is meaningless.** `cp15_control` resets
to `0x00012078` (PU, I-cache and D-cache all **off**) and cacheability is gated on
bit 0 (`nds_cpu9.vhd`), so at 18 ms ~99% of ARM9 main-RAM traffic bypasses the
cache. Kirby writes CP15 CRn=1 **17** times (plus 11 region, 25 cache-op, 4 TCM) —
it enables them, later than anyone had simulated. `FILL_BEAT` is 3,352 at 18 ms and
28,312 at 200 ms.

Healthy stall split at 18 ms, for shape only: `BYPASS_WAIT` 70% mainram-working,
25% bridge idle, 5% awaiting arbitration — and **53% of the ARM9's stall is queueing
behind the ARM7**, which occupies main RAM 3.1x more because it is uncached. **That
contention is architecturally faithful**: `nds_mainram`'s tiebreak is
`arm7_priority` = EXMEMCNT bit 15, the game's own register. 4.2 cyc/op at clk1x is
~125 ns against ~134 ns real, so memory latency is roughly authentic.

`nds_mainram` latches `req9_*` in the accept cycle and **overwrites it
unconditionally** on the next `mem9_ena` — single-entry. A posted write must hold
the memory port or it destroys the pending one; the full win needs a second
in-flight slot there, not just a queue in `nds_cache9`.

---

## Tooling that works

**A/B recipe for a change that must not alter behaviour** — three tiers:

```bash
sh sim/run_shifter_equiv.sh                        # exhaustive, 0.3 s, 294,912 cases

SEED=1 CHUNKS=400 LOOPS=1000 sim/tests/build_arm9_torture.sh
MAXINSTR=400000 HEXFILE=sim/tests/arm9_torture.hex LOADADDR=33554432 \
  TIMEOUT_MS=800 sh sim/run_arm9_trace.sh          # then md5 the trace

DIRTY=1 POD=nds-sim-ab ARTIFACTS="isl9.txt isl7.txt" \
  ENV="WORK=sim/nvc_work_ab PRELOAD=1 HEXFILE=sim/tests/kirby_4mb.hex DIRECT=1 \
       TRACEFILE=isl9.txt TRACEFILE7=isl7.txt TRACE_START_FRAME=-1 \
       TRACE7_START_FRAME=-1 TIMEOUT_MS=25 FRAMES=2" \
  build/remote-sim.sh run_top_frame.sh
#   reference: ARM9 212,592 / ARM7 79,501 lines, md5
#   6be14b4d9fb41a01e02d377b9c19d098 / d6ea0d1d544fa34f25731bd22b22915a
```

The reference side must be a **worktree with `sim/tests` rsynced in**, not
`REF=HEAD` — the BIOS dumps and Kirby hexes are gitignored, so a `git archive` side
runs a different machine.

- **`TRACE_START_FRAME=-1` is required** to trace from instruction 0. The gate is
  `dump_frame_index >= TRACE_START_FRAME`, starting at -1; with the default 0 any
  short run writes an **empty trace**.
- **`WORK=`** lets a second run analyse into its own library.
- **`CYCLE_HIST=N`** prints joint `cache9`/`membus9` state counts, off-bus holds,
  boot stalls, the `BYPASS_WAIT` split and main-RAM occupancy per CPU.
- **`bootreq`** is the 15-subtest subsystem suite; `pass=0x5A5BDE7F prog=0x63` is the
  good answer, and the last trace line is the whole report (`r9` pass bitmap at
  `$13`, `r10` progress at `$14`).
  Subtests 16..25 (the IRQ-driven IPC FIFO block) report separately in **`r11`**
  at `$15`, tagged `0xFC000000` — the `0x5A5A` tag in `r9` has bits 17/19/20/22
  set, so it cannot carry them. RTL `r11=0xFC0001BF` vs melonDS `0xFC0003FF`:
  bits 22 and 25 are the multi-word RECV bug below. `r1` at `$5` is subtest 25's
  read-back sequence (`0x11223344` correct, `0x22334444` observed).
  Oracle baseline for this ROM is the **HLE (non-`--direct`) mode** of
  `melonds_fbdump` — `--direct` runs melonDS's secure-area decryption, which
  fails on an unencrypted ndstool image and overwrites the first 2 KB of the
  ARM9 binary with `0xE7FFDEFF`. Pass `BIOS9=`/`BIOS7=` retail dumps so the
  oracle executes the same BIOS the RTL serves.
- **First-divergence vs the oracle**: `sim/tests/compare_trace.py`, documented in
  `docs/TRACE_DIFF.md`. Against melonDS pass `--ignore cpsr,r13,r14`.
- **`sim/check_bios9_fetch.awk`** compares every BIOS fetch against the image —
  oracle-free. **In ARM state the trace pc column is the pipeline PC, +8**: the
  opcode on a line belongs to `pc-8`. Filter Thumb lines and ARM/Thumb transitions.

**Driver audit after any domain split.** `nvc` sees neither multiple drivers
(`std_logic` resolves silently) nor undriven signals (read as `'U'`); Quartus
catches them only after a 25-minute fit. For each crossing signal count
statement-level assignments and port-map bindings whose formal is `out` — zero or
two is a bug.

---

## Writing test ROMs

Purpose-built ROMs beat inference off a Kirby trace: you know the expected value, so
a mismatch is a fact. `sim/tests/iotest/` and `sim/tests/bootreq/` use the proven
`sdk2d` custom-crt0 pattern (no calico, no BIOS SWIs, no DMA) and boot in
microseconds. Establish the melonDS baseline first — if the oracle does not pass,
the test is wrong, not the RTL.

Traps that each cost an iteration:

- **The mailbox must live in an uncached mirror** (`0x02FFxxxx`, PU region 2), or the
  ARM9 serves reads from D-cache and cross-CPU tests silently pass.
- **Use high vectors** (control bit 13). With V=0 the vector table sits at `0x0`
  inside uninitialised ITCM.
- **To take an ARM9 exception you need two more things**, and without either one the
  vector itself aborts and melonDS prints `EXCEPTION REGION NOT EXECUTABLE` and
  stops the console: (1) a PU region covering `0xFFFF0000` — `bootreq`'s region 0
  was `0x2F`, a *16 MB* region, not the 4 GB its comment claimed, so nothing
  covered the BIOS window; (2) **SP_irq**, which is 0 out of reset while the BIOS
  dispatcher at `0xFFFF0274` does `push {r0-r3,ip,lr}` before calling the handler
  at `[DTCM_base+0x3FFC]`. Set SP_irq in the crt0, not from C inline asm: `r14` is
  banked, so GCC picking `lr` to carry the address makes `mov sp, lr` read
  `r14_irq` (0) and silently set SP_irq to 0.
- **The PU aborts on any address no region covers.** A 4 GB catch-all as region 0
  plus specific higher-numbered regions is the right shape.
- **A subtest that data-aborts discards everything after it.** Order risky ones last.
- **`register x asm("r10")` does not hold** across calls; park results with explicit
  inline asm at the end.
- **A `svc` ends melonDS's instruction trace**, so BIOS entry points need their own
  ROM (`sim/tests/hle_bios9`, `hle_bios7`).
- `bootreq` bit 9 (shared WRAM) fails on melonDS too — that subtest is wrong.
- **No ROM has ever driven an ARM9 SWP through the full system.** `tb_mainram` covers
  the lock *semantics* but not how `mem9_lock` is produced.

---

## Hardware

**The timing-clean core runs on real silicon** (2026-07-28). `tools/deploy-core.sh`
uploaded `build/artifacts-isl0/NDS.rbf` as `NDS_isl0_20260728.rbf`, sha256 verified
on the device, and `nitrodbg.sh probe` returns a coherent decode rather than
garbage — `cache9 IDLE / membus9 IDLE / mainram MR_IDLE / allow=1 / ld_busy=0`,
which is exactly right with no cart loaded. So the bitstream configures, the ARM9
memory path is alive, and the debug channel works at 1:1.

`tools/deploy-core.sh` is the replacement for the lost `scratchpad/deploy-probe.sh`
and is **tracked** — the original was lost because it was not. It refuses to write
`NDS_20260719.rbf`, refuses to overwrite any existing remote `.rbf`, and stages
through a `.tmp` verified by sha256 on the device before moving into place.

MiSTer IP **moves across reboots — ask, do not scan the subnet.** It was
`192.168.1.243`; unreachable as of 2026-07-28.

**DDR3 survives a core reload but NOT a power cycle.** After a power cycle the cart
image is gone and must be loaded once through the OSD (the MGL cannot fill the cart
slot). Mailbox op `0x0B` (`forcecart`) then makes the core believe it, so the cycle
is `scp` -> `load_core` -> `forcecart`, unattended from then on.

Mailbox `tools/nitrodbg.sh`: `probe` (0x0A), `forcecart` (0x0B), `irq` (0x0C),
halt/step/brk/regs/peek. **PEEK cannot read IO space** — it borrows the ARM9
main-RAM channel, so `0x040001xx` returns a plausible aliased RAM word. Only
`0x02xxxxxx` peeks are real; test ROMs must read IO themselves and report inward.

`scratchpad/deploy-probe.sh` (upload + SHA verify + **production-core guard** +
`load_core`) **no longer exists**. Rewrite it carefully before the next deploy — its
job included refusing to touch `NDS_20260719.rbf`, and a careless replacement loses
that protection silently.

---

## Firmware boot: BUILT, and the ARM7 BIOS now matches the oracle exactly

Every leftover-memory bug in this project is the same shape - *direct boot skips the
firmware, so something is not initialised*: main RAM (SWP cart-lock wedge, fixed),
VRAM/palette/OAM (stale screen, fixed), ARM7 WRAM (fixed). Booting the firmware
attacks the source rather than the symptoms. As of 2026-07-29 it exists:
**`FWBOOT=1`** in the bench, `fw_boot` through `nds_loader` -> `nds_top` ->
`nds_card`.

What it does: no HLE staging, no direct-boot env block, both retail BIOSes running
from their reset vectors, firmware left to boot the cart. Boot completes at ~16 ms
of DS time, all of it the VRAM/palette clear; direct boot with Kirby takes ~240 ms,
which is the **image staging plus the DIRECT=0 verify read-back** of a 4 MB image,
NOT the memory clear. `nds_loader`'s IDLE state skips the clear outright when
`is_simu = '1'` ("model RAM is already zero"), so in simulation those 1,064,960
writes never happen and **sim understates hardware boot time**. On hardware the
clear does run. Do not quote a sim boot time as a hardware boot time; this is the
same sim-zero-fill divergence that hid the uninitialised-main-RAM cart lock.

**Measured state:** both BIOSes execute for real - ARM9 from `0xFFFF0000`, ARM7 from
`0x00000000`, CPSR `0xD3` - and the ARM7 BIOS now follows melonDS with **zero
control-flow divergence across 323,826 collapsed basic blocks** (~1.1M
instructions). Before the RTC fix below it diverged at block 2096.

### The trap, and it cost a build

**You MUST preset the boot PCs.** Earlier revisions of this file said the opposite -
*"Do not preset the PCs. Let the ARM9 start at 0xFFFF0000"* - and that is exactly
wrong. This core **does not model the ARM reset exception at all**: both CPUs take
their initial `fetch_PC` from `SAVESTATE_PC_in`, written by the boot FSM in
`B_S9GAP`/`B_S7GAP`. Skipping the preset starts the ARM9 at `0x00000000` and
retires **zero instructions** (nvc reports it as an index of -1 in the barrel
rotator, from `'U'` propagating out of the fetch). `fw_boot` therefore keeps the
whole FSM and only swaps the *values*, via `arm9_entry_eff`/`arm7_entry_eff`.
`cp15_control` does reset with bit 13 set, so high vectors are already right.

### Two bugs it exposed

- **`nds_rtc` `status1` powered up `0x02`, must be `0x82`.** Bit 1 is 24-hour mode;
  bit 7 is power-off / reset detect, which a real RTC raises on first power-up and
  auto-clears when read (melonDS `RTC.cpp:43`). The ARM7 BIOS bit-bangs status1 out
  of `0x04000138`, stores it at `0x0380FEC8`, and branches on bits 7:6 at pc
  `0x2216` to pick cold boot vs warm boot. One bit; the whole boot took the
  warm-boot path.
- **`nds_card` had only B7/B8**, which is where *direct* boot hands the cart over.
  A firmware boot walks the sequence from power-up: raw `9F`/`00`/`90`/`3C`, then
  seven KEY1-encrypted commands, then B7/B8. Now implemented. KEY1 commands are
  decoded by block size + a counter (the Blowfish schedule lives in the ARM7 BIOS
  and this model does not decrypt), which is sound only because the BIOS issues one
  fixed sequence. **The four secure-area blocks are read OUT OF ORDER: 0x6000,
  0x7000, 0x5000, 0x4000** - assuming 0x4000 upward silently scrambles the secure
  area. KEY2 is deliberately absent: hardware applies and removes it, so it is
  transparent to software and melonDS ignores it too.

### The ARM7 fault at 1.588 s is WRONG MEMORY CONTENTS, not CPU state

Firmware boot reaches 1.588 s and the ARM7 dies on `unhandled opcode 1C0E1C05
thumb=0 pc=037FE28C lr=00002E10 cpsr=8000001F`. Two wrong diagnoses were
discarded on the way, both by measurement:

1. *"A decode case GBA titles never reach."* No — `0x1C0E1C05` is two Thumb
   `add rX,rY,#0`, and `thumb=0`, so it is Thumb code being run as ARM.
2. *"The ARM7 lost its T bit."* Also no. A new melonDS window probe
   (`ARM7PROBE_LO`/`ARM7PROBE_HI`, in `tracer.patch`) shows the oracle in **ARM**
   state there too, and holding **different bytes**:

   | at `0x037FE28C` | instruction |
   |---|---|
   | melonDS | `0xE25EF004` = ARM `subs pc, lr, #4` |
   | our RTL | `0x1C0E1C05` |

**So it is a data/loading bug.** And what melonDS holds is the clue:
`subs pc, lr, #4` is the canonical exception return, so `0x037FE28C` is inside the
firmware's **ARM7 exception handler** in ARM7 WRAM.

**That retro-implicates a divergence recorded below as benign.** `loopdiff` put the
first ARM7 control-flow difference at instruction 2,258,084, where our ARM7
branches to `pc=0x00000020` — the instruction at `0x18`, the **IRQ vector** — and
melonDS does not. That was attributed to IRQ delivery timing between two
non-cycle-equivalent models. Since the eventual fault lands in exception-handler
code, **treat that as suspect and re-examine it first.** Also unexplained: our
CPSR is `0x8000001F` (System) where melonDS at `0x037FE280` is `0x000000D3`
(Supervisor).

Next: find where the firmware's ARM7 handler is written in our RTL and diff the
written bytes against melonDS. Candidates — `nds_spi`'s firmware read
address/offset, the BIOS's decompression input, or WRAMCNT mapping the write
somewhere other than where the read lands. Note the firmware boot code is
**compressed** in the image, so grepping the raw firmware for expected instruction
words does not work (tried: 0 hits, inconclusive).

### The extra KEY1 command: benign, an IRQ timing difference

Under `FWBOOT=1` with Kirby the ARM7 issues **two** one-word KEY1 commands where the
oracle issues one. Ruled out as causes: the chip ID (ours computes `0x00003FC2`,
byte-identical to melonDS's) and KEY2 (melonDS defines `Key2_Encrypt` and never
calls it — it really is transparent hardware).

`loopdiff` on a 4M-instruction traced run against a 6M-line oracle trace found it:
first control-flow divergence at RTL instruction **2,258,084**, where the ARM7
branches to `pc=0x00000020`. Architectural PC is instruction+8 in ARM state, so that
is the instruction at **`0x18` — the ARM7 IRQ vector** — followed by a handler at
`0x2dcc`/`0x2ecc`. melonDS's ARM7 carries straight on at `0x1fe2`.

So the RTL takes an interrupt where melonDS has not yet. That is relative IRQ
delivery timing between two models that were never cycle-equivalent — the same
category as the IPCSYNC spin-count difference that already produced one false root
cause — and an IRQ landing mid-sequence plausibly costs one extra status read. The
boot completes the entire KEY1 sequence and enters main data mode, so it is treated
as benign.

**Caveat worth keeping:** `loopdiff` cannot tell "IRQ at a different time" from "IRQ
that should not fire at all". Confirming this properly means identifying which IRQ
source asserted.

### Corrections to what this file used to say

- *"`DIRECT=0` never releases the CPUs - 0 instructions retired across a full
  120 ms, strictly worse than `DIRECT=1`"*: half wrong, and the half that was right
  was right for the wrong reason. `DIRECT=0` **does** release the CPUs: it stages
  the image then verifies it by reading all of it back, so with Kirby they come out
  at **~240 ms** and the 120 ms window was simply too short (28,153 ARM9 IO accesses
  in the next 57 ms). The cost scales with image size - the 4 KB `nds_2dk.hex`
  finishes its loader in **167 us**.

  **But `DIRECT=0` is not a boot you should regression-test against.** It skips
  `ENV_SET`, so the direct-boot env block at `0x027FF800` is never written and Kirby
  never gets the chip ID and header copy it expects: measured over 12 frames at
  `GPUCEDIV=1` it issues **zero card commands**, where `DIRECT=1` reference runs
  issue 72. **`NDS.sv` hardwires `direct_boot(1'b1)`, so `DIRECT=1` is the shipping
  configuration** - use it for anything meant to reflect hardware. `DIRECT=0` exists
  for the verify pass, which is a loader self-check, not a boot mode.
- *"`firmware_retail.hex` and `firmware_dslite.hex` share only 1% of their words, so
  one may be synthetic"*: **wrong inference.** `firmware_retail.hex` is
  **byte-identical (65536/65536 words)** to the user's genuine retail non-Lite DS
  dump. DS and DS Lite firmware are different images for different consoles; low
  overlap is expected, not suspicious.
- `docs/ARCHITECTURE.md` still records *"Firmware boot menu = never"* and `NDS.sv`
  still hardwires `direct_boot(1'b1)`. `fw_boot` is a sim-side path today; wiring it
  to hardware is a separate decision, and boot-to-game gets much longer.

### Tooling this produced

- **`sim/melonds_tracer --fw`** - the firmware-boot oracle that did not exist.
  `BIOS9=/BIOS7=/FIRMWARE=` binaries, real reset-vector boot, no `SetupDirectBoot`.
  It boots Kirby **all the way**: display on at dump frame 128, POWCNT1 `0x820F`.
  Convert the RTL `.hex` images back to `.bin` so both sides run identical ROMs.
- **`sim/tests/loopdiff.py`** - compares the *order of basic blocks*, not
  instruction index. For BIOS boot an instruction-indexed diff is worthless: both
  CPUs sit in cross-CPU polling loops whose spin counts depend on the other CPU's
  progress and legitimately differ. That produced a **false root cause** first -
  "ARM7 reads IPCSYNC=1 where melonDS reads 0" at instruction 18459 looks exactly
  like an `nds_ipc` wiring bug and is only a spin count. `nds_ipc` is fine.
- **`HEARTBEAT_MS`** in `tb_top_frame` - both PCs and both retired-instruction
  counts on a slow tick. A firmware boot is tens of millions of instructions and
  `TRACEFILE` costs ~40x, so untraced runs otherwise cannot distinguish "grinding
  through a boot stage" from "wedged in a poll"; the IO counters rise either way.
- `tracer.patch` now carries the `NDS.cpp`/`NDSCart.cpp` logging (CARDCMD, KEY1DEC)
  it used to leave as untracked local edits.

## Next

1. **GPU pacing** — the whole of the remaining 3x. Two routes above.
2. **Render-test ROM in Kirby's real mode** (`80211810` / `00211810` / `820F`),
   diffed against melonDS on the same ROM. Reaches the interesting mode in
   microseconds and gives a real oracle, which Kirby never will.

   **DONE 2026-07-28** — `sim/tests/arm9_2dk.s` + `build_nds_2dk.sh`, both engines
   **pixel-exact vs melonDS** on every rendered line. Note the premise I set this
   task with was WRONG: **DISPCNT bit 30 is BG ext-pal, bit 31 is OBJ ext-pal**
   (`reg_nds_display.vhd:39-40`). Kirby's `80211810` therefore has BG ext-pal
   **OFF** and OBJ ext-pal **ON** — its BG3 is a 256-colour text BG on the
   *standard* palette with `palno` ignored, and its *sprites* use ext palettes.
   The ROM covers that fallback branch (no prior sample did: `arm9_2d.s`'s BG3 is
   affine, and 2dh/2dw only run it with ext-pal on), plus OBJ ext palettes at
   palno 5/11/0, BG mode 0, and engine B rendered at all for the first time.

   The old (wrong) framing follows for context: Kirby
   draws BG3 as a 256-colour *text* BG with **extended palettes** (DISPCNT bit 31)
   and 1D OBJ mapping. `nds_drawer_text.vhd` implements ext palettes properly —
   `slot*8K + palno*512 + color*2`, BG2/3 to slot 2/3 — but **grep finds zero
   mentions of `extpal` in `tb_gpu2d.vhd`, `tb_gpu2d_frame.vhd` or
   `tb_gpu2d_timed.vhd`, and no 1D-OBJ-mapping coverage either.** The existing
   `sim/tests/arm9_2d.s` is BG mode 1 (BG0 text + BG3 affine) and affine BGs
   explicitly do *not* use ext palettes. So the one colour-lookup path Kirby
   actually depends on has never been executed by any test in this repo.

   Start from `arm9_2d.s` (it already carries the melonDS-oracle compat rules: no
   4 GB PU catch-all, cover the DTCM window, POWCNT1 before any palette/OAM write)
   and change it to mode 0, BG3 text 256-colour, ext palettes on, OBJ 1D.
3. **Long untraced runs to display-on** — cheap now (~6.5 h at `GPUCEDIV=1`). The
   question is whether our RTL reaches the transition melonDS makes at frame 51.
4. Test ROMs `bootreq` had to exclude: TCM, BIOS SWIs, VBlank/IRQ dispatch, card
   reads, and an ARM9 SWP.
5. HDMI is a **product decision**, not a bug, and has nothing to do with making
   Kirby boot.

---

## Kirby on hardware: NOT a deadlock. Both CPUs are live and taking IRQs.

Measured 2026-07-28 on `NDS_vbl_20260728.rbf` with the cart in DDR3.

- **The ARM9 is taking interrupts continuously.** A breakpoint at the IRQ vector
  (`brk9 FFFF0020`) fires within 5 s in the steady state. It wakes, services, and
  returns to the NitroSDK idle thread at `0x0214FC10` (`bl sched / bl WFI / b`),
  parked on the WFI at `0x0214FC08`.
- **DISPSTAT's ARM9 VBlank IRQ enable IS set** — mailbox probe bit 18,
  `vbl ena9 : 1`. Kirby's DISPSTAT-writing code is reached (`reach9` on
  `0x02143A4C`, `0x02143AF0`) and the sim sees the write land
  (`VIDREG A +004 = 0000000B bEna=3`).
- The ARM7 is live too: its PC moves across `0x037FC490-0x037FC9FC`.

**So the white screen is NOT an interrupt-delivery failure.** A pinned PC at the
WFI plus a clear `IF9` is exactly what a *healthy* idle loop looks like when
sampled — do not read it as a hang, which is the mistake made here first.

**The live lead is IPC.** `IE9 = 0x00040001` = VBlank + **IPC-recv-not-empty**, and
`IF9` bit 18 **never sets**, while the ARM7's `IF7` bit 18 **does**
(`IF7 = 0x00040019`, `IE7 = 0x01040099`). So the ARM9's main thread is blocked
waiting on an IPC message the ARM7 never delivers — the **ARM7 -> ARM9 direction
of the IPC FIFO** (`0x184` CNT / `0x188` SEND / `0x100000` RECV in `nds_ipc.vhd`,
a different mechanism from IPCSYNC at `0x180`, which is known good — `bootreq`
passes it). That is the next thing to chase.

### THE LEAD: the ARM7 stops servicing IPC, leaving messages queued

Final `p_ipcfifo` state after 400 ms of Kirby (`GPUCEDIV=1`, ~24 frames):

```
en9=1 rirq9=1 en7=1 rirq7=1
cnt79(7->9)=0   cnt97(9->7)=3     <- THREE words queued to the ARM7, undrained
sends 7->9=2    9->7=5
```

Early in the run the ARM7 drains promptly (`cnt97` 1 -> 0, repeatedly). By the end
**the ARM9 has sent 5 messages, the ARM7 has drained only 2, and 3 are stuck.** So
the ARM7 stops servicing IPC partway through — *after* the initial handshake that
makes the mechanism look healthy.

That is consistent with everything else observed: the ARM9 is alive, takes
interrupts, and idles in the NitroSDK idle thread because its main thread is
blocked on a reply that a wedged ARM7 never sends. **The ARM7 is now the prime
suspect, not IPC.**

Constraints on investigating it, learned the hard way:
- **`peek7` aliases to main RAM** — it borrows the ARM9 channel, so ARM7 WRAM reads
  return plausible garbage. Hardware cannot inspect ARM7 state. Its *registers*
  (via `where7`/`regs7`) are real; its *memory* is not.
- **Do not trace-diff the ARM7 against melonDS** — see the cross-CPU handshake note
  below; relative timing legitimately differs.
- Sim is the place: `TRACEFILE7` / `TRACE7_START_FRAME` give the ARM7's own stream,
  and the freeze reproduces in sim.

Next step: trace the ARM7 across the window where `cnt97` stops draining and find
what it is spinning on. On hardware its PC moved across `0x037FC490-0x037FC9FC`,
which is ARM7 WRAM and therefore unreadable there — in sim it is fully visible.

### ELIMINATED: the IPC *mechanism* works. The FIFO, its enables and its IRQs are fine.

Measured 2026-07-29 with `p_ipcfifo` in `tb_top_frame` (reports IPCFIFOCNT enables,
queued counts and cumulative sends per direction, on change):

```
89.93 ms  en7 -> 1                    <- matches melonDS's frame 5 exactly
90.76 ms  cnt97=1  sends 9->7=1       ARM9 sends
90.77 ms  cnt97=0                     ARM7 drains it
90.80 ms  cnt79=1  sends 7->9=1       ARM7 sends back
90.81 ms  cnt79=0                     ARM9 drains it
```

Both FIFOs enable where the oracle enables them (melonDS `IPCCNT`: ARM9 at dump
frame 2, ARM7 at frame 5; ours at ~4.5 and ~5.35 frames), and messages flow **both
directions and are drained**. So `IF9` bit 18 does latch — the hardware reading of
`IF9 = 0x00080000` was a post-ack steady-state snapshot, and reading it as "never
latches" was wrong.

**The full list of things now eliminated for the Kirby freeze**, all measured:

| hypothesis | verdict |
|---|---|
| ARM9 never enables the GPU VBlank IRQ | **false** — probe bit 18 reads `vbl ena9 : 1` |
| Kirby never writes DISPSTAT | **false** — `reach9` REACHED, and the sim sees the write |
| Neither CPU takes interrupts | **false** — breakpoint at the IRQ vector fires within 5 s |
| The recv-IRQ edge logic is wrong | **false** — bootreq 17-25 match the oracle exactly |
| The ARM7 never enables its FIFO / never replies | **false** — see above |
| ARM9 RECV returned the wrong word | **TRUE, fixed** — but the freeze survives it |

So both CPUs are alive, both service interrupts, IPC is bidirectional, and the
vblank path is armed — and Kirby still never turns the display on inside 290
frames, where the oracle does it early. The next tool is a **first-divergence
trace diff against melonDS** (`sim/tests/compare_trace.py`, `docs/TRACE_DIFF.md`),
traced from a checkpoint on both sides to bound the file sizes
(`TRACE9STARTFRAME` in the tracer, `TRACE_START_FRAME` in the bench). That is the
technique that found the earlier BIOS/IO bugs and it has not been applied to this
phase of the boot.

### Trace diffing STOPS WORKING at cross-CPU handshakes — do not chase its output

Ran the documented first-divergence diff on the current RTL (matched retail BIOS on
both sides: convert `sim/tests/bios{9,7}_retail.hex` to raw `.bin` and pass
`BIOS9=`/`BIOS7=` to `melonds_fbdump`, or the two diverge inside BIOS code
immediately). Result:

```
DIVERGENCE at instruction 844073
  rtl: 0214FF64 E1D300B0 ... r0=00000008
  ref: 0214ff64 e1d300b0 ... r0=00000000
  field r0: rtl=00000008 ref=00000000
```

That is `ldrh r0,[r3]` with `r3 = 0x04000180`, i.e. **reading IPCSYNC inside the
ARM9's sync loop**, and the differing field is the ARM7's out-nibble.

**It is almost certainly benign, and it would be easy to misread as the bug.** What
happens next settles it:

| | next PCs | means |
|---|---|---|
| RTL | `FF70 FF74 FF28` — leaves the inner wait for the outer loop | saw the nibble CHANGE, advanced |
| oracle | `FF6C FF58 FF5C FF60 FF64` — tight inner loop | nibble unchanged, still waiting |

So **our ARM7 reached its next nibble value sooner than melonDS's**. The ARM9 then
did exactly what the protocol says: counted the change and advanced. Nothing is
wrong; the two runs simply have different ARM9:ARM7 relative timing, which this
handshake is built to tolerate (both sides wait unboundedly — see the timing
section).

**Methodological consequence, and the reason to write this down:** an
instruction-exact trace diff is only meaningful while execution is a pure function
of the instruction stream. Once two CPUs interact through a *polling* handshake,
relative timing legitimately differs from the oracle and the diff reports a
divergence on the first poll that lands differently. The repo's headline claim of
"1,293,260 ARM9 instructions exact" must therefore have been measured before this
point, and it cannot be extended past a cross-CPU poll no matter how long the run.
Use trace diffing for single-CPU correctness (it found the BIOS-fetch and IO-read
bugs); use event-level instrumentation like `p_ipcfifo` for anything cross-CPU.

### Superseded: the IPC recv IRQ hypothesis (kept for the reasoning)

`bootreq` subtest 16 ("IPC FIFO round trip") **passes** — bitmap `0x1DE7F`, bit 16
set — so the FIFO data path works. But look at what it actually does:

```c
REG16(IPCFIFOCNT) = 0x8008;      // bit15 FIFO enable + bit3 send clear
REG32(IPCFIFOSEND) = 0x1234ABCD; // ARM9 -> ARM7
if (wait_ne(&M_FIFO, 0, 50000) && M_FIFO == 0x1234ABCD) pass |= 1u << 16;
```

**Bit 10 — recv-not-empty IRQ enable — is never set**, the ARM7 stub is explicitly
"no BIOS SWIs, no IRQs", and only the **ARM9 -> ARM7** direction is driven. So:

| path | tested | hardware |
|---|---|---|
| ARM9 -> ARM7 FIFO, polled | yes, subtest 16 | works, `IF7` bit 18 sets |
| **ARM7 -> ARM9 FIFO** (`fifo79`) | **never** | — |
| **recv-not-empty IRQ** (`rirq9`, CNT bit 10 -> `irq9_recv`) | **never** | **`IF9` bit 18 never sets** |

What is proven working is exactly the direction that works on hardware; what has
never been exercised is exactly what fails. Same signature as every other bug
here: correct-looking code on a path nothing drives.

The logic to scrutinise is `nds_ipc.vhd:222-237` — `recvpend9 := '1'` requires
`v_cnt79 /= 0 AND rirq9 = '1'`, and `irq9_recv` fires only on its **rising edge**.
Note the edge is on the *conjunction*: if the ARM9 enables `rirq9` while the FIFO
is already non-empty, the conjunction still goes 0->1 and should fire — but if
`rirq9` is set and cleared around a drain, or the ARM7 refills without the
conjunction ever dropping, no new edge is generated and the IRQ is lost.

### DONE (2026-07-29): that edge hypothesis is DEAD. The bug is the RECV READ PORT.

`bootreq` subtests 17..25 now cover the IRQ-driven ARM7 -> ARM9 path. The ARM7 needs
no interrupt path of its own: for ARM7 -> ARM9 it only *sends*, and for the reverse
control it polls its own `IF7` with IRQs masked, so nothing on that side can fail
for an unrelated reason. Results, `r11` (`$15`) and `r1` (`$5`):

| bit | subtest | melonDS | RTL |
|---|---|---|---|
| 17 | ARM7 send raises `IF9` bit 18 (IME=0) | pass | **pass** |
| 18 | ARM9 reads its own RECV at `0x04100000` | pass | **pass** |
| 19 | arming CNT bit 10 while already non-empty fires | pass | **pass** |
| 20 | drain then refill fires a SECOND IRQ | pass | **pass** |
| 21 | refill *without* draining does NOT re-fire | pass | **pass** |
| 22 | two queued words read back in order + empty-read error flag | pass | **FAIL** |
| 23 | control: ARM9 -> ARM7, `IF7` bit 18 latches | pass | **pass** |
| 24 | ARM9 actually *takes* the IRQ, handler runs, word correct | pass | **pass** |
| 25 | four queued words read back in order | pass | **FAIL** |

So the recv IRQ, the rising-edge conjunction in `nds_ipc.vhd:222-237`, the drain/
refill re-arm and full BIOS-vector dispatch are all **correct**. Do not spend more
time there.

**What is broken: an ARM9 RECV read returns the FIFO entry AFTER the one it pops.**
Subtest 25 queues `11 22 33 44` and reads back **`22 33 44 44`** (`r1 =
0x22334444`). The mechanism is `nds_top.vhd:958-984`, which says so in its own
comment: `cdc_io_cpl` toggles on the `io9_ena` cycle and the island samples
`io_wired_out9` **one clk1x later**. That is right for every stateless register, but
`nds_ipc.vhd:103-107` drives `wired_out9 <= fifo79(rd79)` combinationally, and
`rd79`/`cnt79` advance on that same edge — so the island latches the *next* entry.
It is invisible whenever the FIFO holds exactly one word, because `cnt79` is then 0
and the mux falls through to `last9`, which does hold the correct just-popped word.
That is why subtests 16, 18, 20 and 24 all pass and why nothing ever caught it.

Not a double pop: the tb's own counters are 1:1 (`membus9.ena 20386 -> io9_ena
20386 -> i9_io_done 20386`), and a double pop would read back `22 44 44 44`.
`nds_card`'s `0x04100010` is safe by luck — `romdata` is a register that holds
past the pop.

Kirby consequence: NitroSDK PXI messages are multi-word and its handler drains in
a loop, so every burst after the first word is corrupt and one word per burst is
lost — a receiver that mis-parses a header and never signals the waiting thread.
Fixing it means registering the popped word for the transaction (or completing the
IO access in the `ena` cycle), not touching the IRQ logic.

### nitrodbg `reach`/`brk` take the ARCHITECTURAL PC, i.e. instruction + 8

This cost a completely wrong conclusion. `reach9 FFFF0018` for the IRQ vector
returns **not-reached**, because it breaks when r15 = 0xFFFF0018, i.e. while
*executing* 0xFFFF0010. The correct probe is `FFFF0020`, which is REACHED. Same
for the ARM7: `00000020`, not `00000018`. `where9` states the convention in its own
output (`r15=0x0214FC10 -> executing 0x0214FC08`).

Sanity check for the method: `reach9 FFFF0008` (the reset vector) is **not**
reached, and that is correct under direct boot — the loader presets the PC and the
BIOS reset path never runs.

## FIXED 2026-07-29: direct boot never cleared VRAM / palette / OAM

Reported from hardware 2026-07-28 by the user: loading a different ROM does not
reliably clear the screen — leftovers from the previous ROM persist.

`nds_loader.vhd` has a `CLR_WR` pass that zeroes all 4 MB of **main RAM**, and its
own comment says why: *"Real hardware gets this clearing from the firmware boot we
skip in direct boot."* That pass was added after uninitialised SDRAM made the SWP
cart-lock acquisition fail forever — both CPUs spinning, no IRQ ever enabled, white
screen — and **simulation hid it completely**, because the behavioural SDRAM model
powers up all-zero.

**VRAM, palette and OAM never got the same treatment.** grep finds no clear pass in
`nds_vram.vhd`, only port defaults. So they retain whatever the previous ROM left,
and on a MiSTer the FPGA is not reconfigured between ROM loads — only the loader
re-runs. The DDR3 framebuffer at `0x0FE00000` is not cleared either.

Consequences:

- Cosmetic: stale pixels until the new ROM overwrites them (what the user saw).
- **Not necessarily cosmetic**: a game that enables a BG or OBJ before writing all
  of its tiles/map/palette shows the *previous* ROM's data rather than the black or
  known-state a firmware boot would leave. Any game relying on zeroed VRAM
  misbehaves, and **simulation cannot see it** for exactly the reason the main-RAM
  bug was invisible — the sim starts every memory at zero and each run is fresh.
- This is a strong candidate for behaviour that differs between the first ROM load
  after a core reload and every subsequent one, which is a nasty class of
  non-reproducible bug.

**FIXED** (`nds_vram` sweeps E..I in parallel then walks A..D over `srv_*`;
`nds_gpu2d` zeroes both palettes and OAM; all three `clr_busy` gate the CPU
release in `nds_top`). The loader's own pass could NOT be extended — it has a
main-RAM write port only — so each module self-clears using the path it already
owns, and no new nds_top ports were needed.

**The CPU-release gate is load-bearing, not insurance.** Measured, against my own
assumption that VRAM's ~164K words would fit inside the loader's 1M-word pass:

```
palette/OAM clear done    7.685 us
loader done             132.6   us      <- nds_loader SKIPS CLR_WR when is_simu
VRAM clear done          16.220 ms      <- 122x longer than the loader
CPUs released            16.2209 ms
```

**Fitted** (`build/artifacts-vclr`, seed 0, 0 violated paths):

| build | worst slack | ALMs | M10K |
|---|---|---|---|
| `artifacts-isl0` (island removed) | +1.537 | 35,824 | 472 |
| `artifacts-ipcfix` (+ IPC RECV fix) | +1.534 | 35,830 | 471 |
| **`artifacts-vclr`** (+ this clear) | **+1.743** | **36,115** | **471** |

285 ALMs (0.7% of the device), no M10K, no timing regression — read the +0.21 ns as
"no cost", not a gain; it is inside the 1.53 ns seed spread.

**Made verifiable despite sim starting zeroed**, which is how the main-RAM version
of this bug hid: `tb_vram_torture` PRE-DIRTIES 32 probes per bank with `DEAD_xxxx`,
asserts the pattern landed, resets, and requires zero. Palette/OAM have no CPU read
path, so `tb_gpu2d_frame` renders a scene twice and asserts 49,152 non-zero pixels
before reset and 0 after. Efficacy checked in both directions — disabling each pass
produces its own specific failure.

**Still unverified**: that it cures the reported ROM-to-ROM symptom (only hardware
can show that — load two different ROMs back to back and confirm the second starts
clean), and the ~20 ms hardware cost of the A..D clear against NDS.sv's
`mainram_allow` borrow scheduler. Note also that the 2D display **register** file
resets off `gb_bus.rst` rather than `reset`, so register state is a separate
leftover class, and the ext-palette shadows are deliberately left uncleared since
they refill from VRAM each vblank.

## Open RTL bug: the ARM9's 8-bit writes to VRAM are performed, and must not be

Found 2026-07-28 by `sim/tests/arm9_2dk.s`. On the DS, **8-bit writes from the
ARM9 to VRAM / palette / OAM are dropped** (unlike the GBA, which duplicates the
byte). melonDS drops them; our RTL performs them.

Reproducer: `strb` two OBJ tile bytes at `0x06400200` and `0x064003FF`. melonDS
leaves those pixels at index 0 (transparent, background shows through); the RTL
writes them and renders the sprite pixel — 3 mismatching pixels on both engines:

```
A (48, 24) rtl=ff0859a2 mds=ff384949    <- spr2 tile-4 byte 0
A (112,24) rtl=ff080828 mds=ff384949    <- spr4 tile-4 byte 0
A ( 95,39) rtl=ff08ba30 mds=fffb3038    <- spr3 tile-6 byte 255
```

The RTL values decode exactly to the palette entries for index 1, confirming the
byte write landed. Look at the ARM9 store path / `nds_membus9` VRAM byte-enable
handling. **This is a plausible real-game hazard** — any game that byte-writes
VRAM gets corruption the hardware would not produce. `arm9_2dk.s` uses word
stores so the test is not contaminated by it; the bug is unfixed.

## Do not repeat

- **Trusting this document, or `COORDINATION.md`, as ground truth.** Their measured
  artifacts are usually good; their *rules and thresholds* have repeatedly been
  invented. Verify before spending a build.
- **Treating trace agreement as proof.** An instruction-exact trace cannot see a
  dropped store, an IO read of 0, or a stale BIOS word — three separate root causes
  hid behind "1.29M instructions match melonDS".
- **Diffing BIOS/firmware boot traces by instruction index.** Both CPUs sit in
  cross-CPU polling loops whose spin counts depend on the other CPU's progress and
  legitimately differ from melonDS. Every such diff "diverges" on the first poll.
  Use `sim/tests/loopdiff.py`, which compares the order of basic blocks. Doing it
  the naive way produced a confident false root cause in `nds_ipc`, which is fine.
- **Assuming a sequence covers a range in order.** The ARM7 BIOS reads the four
  4 KB secure-area blocks as 0x6000, 0x7000, 0x5000, 0x4000. "Four blocks spanning
  0x4000..0x7FFF" is true of the range and false of the order.
- **Trusting a cross-domain counter without reading how it samples.** `p_iocount`
  counted clk1x arrivals with a *level sample* correct only at exactly 2:1; at
  1.705:1 it reported 183 of 314 and looked exactly like a CDC dropping requests.
- **Running `sim/run_arm9_trace.sh` on a main-RAM-linked ROM without `LOADADDR`.**
  It defaults to 0 and both sides of an A/B then execute the same open-bus garbage
  and produce the same MD5. Check the pc column spans the ROM.
- **Believing a trace diff without checking the workload executes what you changed.**
- **Editing a running shell script**, or the source tree during a `remote-build` —
  it snapshots at launch, so edits are silently not in the RBF.
- **Naming artifacts `remote-sim.sh` does not write.** Framebuffers are
  `DUMPFILE`/`DUMPFILE_B`, default `top_frame_fb.txt` / `top_frame_fb_b.txt`.
- **Writing a carry-in as `A + B + C`** — Quartus builds two chained carry chains.
  Use the extra-LSB form; see `nds_cpu9.vhd` for the worked version.
- **Trusting a probe's address decode without the register map.** `io_bus9.Adr` is a
  **byte** offset into `0x0400_0000`: BG0CNT `0x008`, engine B the `0x1000` window,
  POWCNT1 `0x304`.
- **Comparing against `build/artifacts-*` from an earlier session** without checking
  the fitter timestamp against `git log`.
