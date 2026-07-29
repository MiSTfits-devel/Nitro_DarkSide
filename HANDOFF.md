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

Two alternatives, not steps:

1. **Move the render fabric to `clkMem`** (the documented intent: fabric 100.5 MHz,
   dots 33.5). At 3x clk1x it gets the 18 cycles/dot it needs while `itiming` runs
   at full rate. clkMem is an exact 3x, phase-locked, `clkMemIndex` already plumbed
   — an **integer-ratio related clock**, the friendly case. Work is CDC to the
   clk1x IO/VRAM/framebuffer interfaces.
2. **Make the line server 3x cheaper per dot.** Same number from the other side, no
   clock work, but a gpu2d rewrite.

Either way `itiming` ends at `ce = '1'`. Do **not** quote the ~3 drops/frame seen at
`GPUCEDIV=1` as evidence the renderer nearly keeps up — that was measured with the
display off, so it had nothing to draw. Once Kirby writes DISPCNT the same run
settles at a steady **+7 drops/frame** (7 of 192 visible lines, 3.6%), still with
display mode 0.

**The drop counter cannot tell you WHICH engine is behind, and that wants fixing
before the GPU work.** `nds_top.vhd:1810` is

```vhdl
dbg_line_drop <= drawline and (line_busy or line_busy_b);
```

— it ORs engine A and engine B, so a drop is counted when *either* is still busy.
Both the bench's "~110 dropped lines/frame on an affine scene" and the +7/frame
above inherit that ambiguity. Engine B is the simpler configuration in Kirby's mode
(no ext palettes), so if the drops are actually engine A the renderer target is
different from what a combined number implies. Split it into two exports before
sizing the work — it is a debug-only signal, so the change is behaviourally inert.

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

### nitrodbg `reach`/`brk` take the ARCHITECTURAL PC, i.e. instruction + 8

This cost a completely wrong conclusion. `reach9 FFFF0018` for the IRQ vector
returns **not-reached**, because it breaks when r15 = 0xFFFF0018, i.e. while
*executing* 0xFFFF0010. The correct probe is `FFFF0020`, which is REACHED. Same
for the ARM7: `00000020`, not `00000018`. `where9` states the convention in its own
output (`r15=0x0214FC10 -> executing 0x0214FC08`).

Sanity check for the method: `reach9 FFFF0008` (the reset vector) is **not**
reached, and that is correct under direct boot — the loader presets the PC and the
BIOS reset path never runs.

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
