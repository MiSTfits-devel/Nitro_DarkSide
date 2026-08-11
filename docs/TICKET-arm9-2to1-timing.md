# ARM9 at 2:1 misses setup: it is a forwarding loop, not shifter depth (OPEN)

**Filed** 2026-08-11 · **Blocks** shipping the 2:1 ARM9 (67.028 MHz) · **Does not
block** the audio image fitting, which is now fixed

Read WHAT THE PATH ACTUALLY IS first. The short version of the trap: every
report that names endpoints says "barrel shifter", and that is the wrong cut.

---

## Status

Two problems were tangled together and are now separated by measurement:

| | was | now |
|---|---|---|
| **Area / fit** (audio config) | Failed, 41,889 ALMs / 4,232 LABs (101%) | **Successful, 41,388 / 4,189 (100%)** |
| **ARM9 2:1 setup** | −2.971 ns (earlier build) | **−2.259 ns, still open** |

The fit is closed. The 2:1 timing is not, and area work will not close it — see
THREE MEASUREMENTS below.

## What landed (branch `ablate-dead-silicon`, not pushed)

| commit | what |
|---|---|
| `01f37d4` | `cpu:` drop the savestate registers the boot preset never writes |
| `1e3ba8c` | `gpu2d:` mosaic Y as melonDS's counter, not a divider |
| `e77cb83` | `build:` fit matrix driver for A/B-ing configurations |

Combined MEASURED effect, seed 23, audio config, against
`build/artifacts-audio-s23`: **−501 ALMs, −43 LABs, Failed -> Successful.**

Note the estimate that motivated the work said ~920 ALMs. It was ~45% high,
because summing "ALMs needed" per hierarchy node over-counts: removing flops
does not free ALMs proportionally once register packing is involved. The LAB
estimate (~56 predicted, 43 actual, 41 needed) was the useful one. **Predict in
LABs, not ALMs, and do not trust either without a fit.**

### The savestate ablation

The savestate bus is not a savestate bus. It exists so `nds_top` can preset the
boot PC and the r13 banks before releasing CPU reset, and nothing reads it back
(`ss_wired_out`/`ss_wired_done` are `open` at all four instantiations; the
debugger uses `dbg_regsel`/`dbg_regval`). Only addresses 0, 13, 14, 15, 24, 34
and 37 are ever written — see `preset_adr` in `rtl/nds_top.vhd`. Every other
register on the bus sits at its `startVal` forever, but Quartus cannot prove it
because `proc_bus.Adr` is a runtime value, so it built all of them: a MEASURED
870 ALMs of flops that can never change value.

Behind `SS_PRESET_ONLY` (default `'1'`; `'0'` restores the full bus). **The trap:
`REG_SAVESTATE_CPUMIXED`'s `startVal` is 0xCC0, not zero** — bits 9:6 are
`cpu_mode = 3` (supervisor), bits 11:10 disable FIQ/IRQ. Tie it to zero and the
ARM9 boots in user mode with interrupts live. Everything ties off to `startVal`,
never to `(others => '0')`.

### The mosaic-Y counters

`ypos_mosaic_bg/obj` were `linecounter mod (size + 1)`. A variable divisor makes
Quartus emit a general divider, so both became `lpm_divide` instances — a
MEASURED 37.7 + 35.6 ALMs per 2D engine, 146 across both. They were the only two
non-power-of-two `mod` operators in `nds_gpu2d.vhd`.

This is also a divergence fix. melonDS: "Y mosaic uses incrementing 4-bit
counters" (`GPU2D.cpp UpdateMosaicCounters`), and `BGMosaicYMax` is re-latched
only when the counter wraps (`GPU2D_Soft.cpp`, end of `DrawScanline_BGOBJ`), so a
mid-frame MOSAIC write takes effect at the next block boundary. The divider
re-snapped against absolute `linecounter` instead. The counter is the accurate
one; that difference is deliberate and is NOT checked by the gate.

Gate: `sim/run_mosaic_equiv.sh` — 6,144 comparisons (every line x all 16 sizes x
BG and OBJ), counter against divider, 0 mismatches, self-contained, seconds.

**The sim earned its keep.** The first version drove
`ypos_mosaic_bg <= linecounter - mos_bgy` and `run_gpu2d` went Fatal with
`value -1 outside of INTEGER range`: `refpoint_update` for line L lands BEFORE
`drawline` sets `linecounter <= L`, so in that window the counter has advanced
and `linecounter` has not. Fixed by tracking the block BASE as a register. The
phase reasoning was right and the wiring was still wrong.

## The fit matrix (`build/ablation-matrix.sh`, artifacts in `build/artifacts-abl-*`)

| build | SOUND | DEBUG | HDMI | seed | ALMs | LABs | RAM | Fitter | 2:1 setup |
|---|---|---|---|---|---|---|---|---|---|
| A | 1 | 0 | no | 23 | 41,388 (99%) | 4,189 (100%) | 482 (87%) | **Successful** | −2.259 |
| B | 1 | 1 | no | 23 | 42,002 (100%) | 4,235 (101%) | — | Failed | — |
| C | 1 | 0 | yes | 23 | 44,967 (107%) | 4,533 (108%) | — | Failed | — |
| D | 0 | 1 | yes | 3 | 39,625 (95%) | 4,176 (100%) | 529 (96%) | **Successful** | −2.970 |

Derived costs, previously guesswork:

* `DEBUG_ENABLE=1` costs **+614 ALMs / +46 LABs**. Audio + `nitrodbg` misses by
  ~44 LABs. It does not fit, and the ablation does not buy it.
* HDMI costs **+3,579 ALMs / +344 LABs**, confirming the ~3,500-4,000 already in
  `NDS.qsf`. Audio + HDMI is short **3,057 ALMs / 342 LABs**. The fixed-res SPG
  idea budgeted at ~2,200 cannot cover that, so the QSF's existing conclusion —
  it does NOT buy SOUND + HDMI together — holds, now measured.

**A fits by 2 LABs.** Any change that adds registers can reopen it.

## What the path actually is

From `build/artifacts-abl-A/NDS.paths_fam.rpt`, element by element:

```
icpu9|decode_immidiate[1]              (register, launch)
 -> shiftervalue[1]~32                 -+
 -> RotateRight1~16, ~18                | shifter, pass 1
 -> shiftresult[8]~28                   -+
 -> Add24~113 ... ~57                     ALU carry chain
 -> Selector77~3
 -> pcwrite_Addr[13]~188, ~189            PC-write address
 -> regs~363                              <- 1.602 ns, longest single hop
 -> regs[14][13]_NEW2930~_Duplicate       register-file next-state
 -> shiftervalue[13]~100, ~103, ~104   -+
 -> RotateRight1~44                      | shifter, pass 2
 -> RotateRight1~44_OTERM12347DUPLICATE -+ (register, latch)
```

**The cycle traverses the barrel shifter TWICE**, through a forwarding loop: the
ALU result becomes a PC-write address, is written back to the register file, and
is bypassed combinationally into the next instruction's shifter operand — all
inside one 14.915 ns cycle.

So a register inside the shifter breaks only ONE of the two passes. That is why
"pipeline the barrel shifter" is the wrong cut, even though every endpoint-name
report points at it. `NDS.qsf` already warns about exactly this: "choosing a cut
off endpoint names alone is how a build got spent on logic that turned out not to
be on the path."

Delay budget for this path:

| | count | delay | share |
|---|---|---|---|
| Data IC (routing) | 20 hops | 11.384 ns | **70%** |
| Data cell (logic) | 21 cells | 4.808 ns | 30% |
| Logic levels | 14 | | |
| Clock skew | | −0.483 ns | against us |

**70% is interconnect.** Reducing logic levels alone attacks the 30%; the fix has
to shorten the physical span too. Data delay 16.192 ns against 14.915 ns.
Fmax 58.23 MHz.

## Three measurements: area and 2:1 timing are separate problems

1. Merging the affine/extended BG drawers freed 2,159 ALMs / 86 LABs; 2:1 slack
   moved only −3.389 -> −2.971 ns.
2. These ablations freed 501 ALMs / 43 LABs, closed the fit, and 2:1 stayed at
   −2.259 ns.
3. Build D has MORE free area than A (95% vs 99% ALM, 4,176 vs 4,189 LABs) and
   WORSE timing (−2.970 vs −2.259).

Stop spending builds on ALMs for timing.

## Not established — do not assume

* **This is one of four path families.** The −2.259 ns worst path ends at
  `imembus9|target~40`; the family above ends inside `icpu9`. Whether they share
  the forwarding loop is unknown. One fix may not close all four. Characterising
  the other three costs nothing — the reports are already in
  `build/artifacts-abl-A/`.
* **Seed spread is 1.5-4 ns on unchanged netlists** (`NDS.qsf`). A single build
  cannot establish that a small slack improvement is real. Five seeds on the
  audio build gave 4,210-4,232 LABs and never reached 4,191.
* The 67.028 MHz domain was **+5.630 ns** when it carried only video scanout
  (`NDS.qsf`). The uncommitted 2:1 work moved the ARM9 onto it. Whatever image is
  currently giving 60 FPS is running a domain that does not close timing.

## Candidate cuts, and what each costs

| cut | breaks | CPI cost |
|---|---|---|
| Register the write-back forwarding (`Selector77` -> `pcwrite_Addr` -> `regs~363`) | removes shifter pass 2 from the cycle | +1 cycle on ALU-writes-PC (uncommon) |
| Register the cpu9 -> membus9 address crossing | the long wire directly, at the module boundary | +1 cycle on EVERY load/store |
| Register inside the shifter | one of two passes only | +1 on shift-ops, likely insufficient |

Note `adr_early` (`rtl/nds_cpu9.vhd:952`) is already register-derived and crosses
one LUT — the address mux is not the problem, the forwarding into it is.

Good news for verification: these are latency changes, not architectural ones,
so `sim/run_arm9_trace.sh` against the melonDS oracle should stay identical
instruction-for-instruction while cycle counts move.

## Reproducing

```sh
sim/run_mosaic_equiv.sh          # 6,144 comparisons, seconds
sim/run_analyze_all.sh
sim/run_top_frame.sh             # then diff top_frame_fb{,_b}.txt
build/ablation-matrix.sh         # 4 fits, 2 pods at a time, ~45 min
```

`ablation-matrix.sh` edits `nds_port_wrap.vhd` and `NDS.qsf` in place because
`DIRTY=1` streams the working tree; it waits on `/work/src/.ready` per pod before
reconfiguring, and restores the tree on exit including on failure. There is no
local Quartus on this machine — fits run on the k8s pods.

## Known-clean and known-broken elsewhere

* `run_dual_boot` (TIMEOUT, `arm9=00000000 arm7=00000000`) and `run_arm7_island`
  (`magic=BADBAD00`) fail identically before and after this work. Pre-existing in
  the uncommitted tree. `run_dual_boot` failing means it gave NO coverage of the
  boot preset — `run_top_frame` carried that.
* **`nds_sound` is a dead end for area.** MEASURED 5,945-6,016 ALMs across 12
  builds (`artifacts-snd{A,C,D,E,G,H,I}`, `-cut-snd`, `-cut2-snd`, `-spec-audio`,
  `-spec-snd`, `-audio-s23`) — 71 ALMs of spread. Serializing the 16-way unrolled
  decode loop requires dynamic-index muxes over the per-channel flop array, and
  `rtl/nds_sound.vhd` records three measured attempts that each made the design
  BIGGER (16 registered read ports: 10,060 -> 17,478 ALUTs). Do not start this
  without a fit in the loop.
* `docs/TICKET-arm7-firmware-wedge.md` is titled FIXED 2026-08-05, but
  `NDS.sv:1349` still documents the same 1.588 s / lost-T-bit wedge as a KNOWN
  LIMIT on an OSD-selectable mode. One of the two is stale.
* `NDS.qsf` and `nds_port_wrap.vhd` both cite `FITTING.md`, which is not in this
  tree — it only exists under `.claude/worktrees/`.

## Direct boot needs no external images

Asked in passing, recorded so it is not re-derived. `nds_loader` with
`direct='1'` synthesizes the whole firmware-provided memory image (melonDS
`SetupDirectBoot`): header copy at 0x02FFFE00, chip ID x2, secure-area CRC16,
boot flags, and a 0x70-byte default user-settings block at 0x02FFFC80.
`nds_bios9`/`nds_bios7` fall back to built-in HLE images and the hex probe is
elaboration-time, so in synthesis they ALWAYS reduce to HLE — and per
`nds_top.vhd`, "the ARM9 needs no BIOS (calico ds9 installs its own vectors)".

Soft spot: `nds_spi` device 1 still answers 03/05/04/06 out of the DDR3 region at
0x0FF00000 regardless. A game reading user settings over SPI rather than from the
RAM mirror gets whatever DDR3 holds — garbage rather than a clean failure. Mostly
theoretical while touch/mic are unwired. Also note `fw_download` triggers on
`ioctl_index == 0` (`NDS.sv:430`), the `boot0.rom` auto-load, so firmware may be
staged on every boot without anyone asking for it.

Not an ablation target: the image was already evicted from M10K into DDR3, so
support costs address space and a handshake, not block RAM.
