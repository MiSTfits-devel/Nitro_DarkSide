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

## Firmware boot: the right idea, but there is NO firmware-boot path to switch on

Every leftover-memory bug in this project is the same shape - *direct boot skips the
firmware, so something is not initialised*: main RAM (SWP cart-lock wedge, fixed),
VRAM/palette/OAM (stale screen, fixed), ARM7 WRAM (fixed). The loader says it
outright: *"Real hardware gets this clearing from the firmware boot we skip in
direct boot."* Each fix re-implements one thing the firmware does correctly, and
there is no reason to believe the last one has been found. So booting the firmware
attacks the source rather than the symptoms, and is strategically the right move.

**But it is a feature to build, not a flag to flip.** Two facts, measured:

1. **The boot FSM has no firmware path.** `nds_top` runs
   `B_LDWAIT -> B_S9RST..B_S9POST -> B_S7RST..B_S7POST -> B_RUN` unconditionally,
   presetting *both* CPU PCs from the cart header via the savestate bus. Nothing
   lets the CPUs start at their BIOS reset vectors instead. Consistent with
   `reach9 FFFF0008` being **not**-reached: the ARM9 reset vector never executes.
2. **`DIRECT=0` is NOT firmware boot** - the name misleads. In `nds_loader` it only
   skips `ENV_SET` (the direct-boot env block) and enters a verify pass where, per
   its own comment, *"busy stays high"*; `ld_done` therefore never asserts,
   `B_LDWAIT` never exits, and the CPUs are never released. Tried with Kirby and the
   retail firmware: **0 instructions retired on both CPUs, 0 membus accepts, across
   a full 120 ms.** `DIRECT=0` is "direct boot minus the env block" - strictly worse
   than `DIRECT=1`, not better.

What real firmware boot would require:
- **Do not preset the PCs.** Let the ARM9 start at `0xFFFF0000` and the ARM7 at
  `0x00000000` so the retail BIOSes run.
- The ARM7 BIOS then pulls the firmware over SPI, validates and decompresses its
  boot code, and jumps into it. `nds_spi` already serves a firmware image and
  `FWFILE` exists, so the plumbing is partly there.
- Firmware needs valid user settings with auto-start, or it waits at the menu for a
  touch that never comes in sim. **Both firmware images here have valid settings**
  (version 5 in both copies at 0x3FE00/0x3FF00).
- Assets: `sim/tests/bios{9,7}_retail.hex` (4 KB / 16 KB) plus
  `firmware_retail.hex` and `firmware_dslite.hex` (a real DS Lite dump). Those two
  share only **1%** of their words, so one may be synthetic - establish which before
  trusting either.
- `docs/ARCHITECTURE.md` records **"Firmware boot menu = never"** as a deliberate
  decision and `NDS.sv` hardwires `direct_boot(1'b1)`, so this reverses a design
  choice rather than fixing an oversight. Boot-to-game also gets much longer.

Verdict: the highest-leverage architectural change available, and the only one that
retires the whole leftover-initialisation class instead of one member at a time. A
project, not a patch.

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
