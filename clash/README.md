# Clash migration boundary

This directory is a source-owned replacement for the small part of the MiSTer
framework that the NDS core instantiates directly. None of the checked-in RTL
carries a GPL license; it is written fresh to the interface and timing
contracts the framework's consumers rely on.

| NDS use | Current owner | Migration status |
| --- | --- | --- |
| `hps_io` | `nds_hps_io.sv` + `nds_hps_io_boundary.sv` | Replaced. `nds_hps_io` decodes the uio/fp command subset the core uses (config, joystick, status, gamma, analog, file transfer); SD and unused commands are answered with protocol-legal values instead of implemented. Differential-fuzzed against the framework reference by `clash/tests/run_hps_io_diff.sh`. |
| `video_mixer` | `Mister.VideoMixer` | Replaced in `NDS.sv`. The checked-in Clash-aligned core implements the NDS-active path: no scandoubler/HQ2x and `HDMI_FREEZE=0`. `gamma_corr` remains a deliberately tiny SystemVerilog island because it is a dual-clock RAM. |
| `video_freak` | `nds_clash_video_freak.sv` | Replaced in `NDS.sv`. Source-owned port of the integer aspect/scaling calculator (crop path present but inert, since NDS ties CROP_SIZE=0). Differential-fuzzed against a fresh reference by `clash/tests/run_video_freak_diff.sh`. |

The checked-in RTL in `rtl/` is the build input, so a Quartus build never
depends on a local Haskell installation. It mirrors the Clash source and is
kept beside it to make the exact hardware reviewable. Regenerate it with Clash
and check in the reviewed result whenever the Haskell changes.

To regenerate after installing Clash (the command may vary slightly by
Clash release):

```sh
cd clash
clash --verilog -isrc --outputdir rtl src/Mister/VideoMixer.hs
```

`nds-mister-clash.cabal` pins the source dependency range; `cabal build` is a
quick type-check before emitting HDL.

Run the smoke test from the repository root with
`sim/run_clash_video_mixer_tb.sh`. It exercises the checked-in core's CE
recovery and one-cycle output pipeline. (The stock framework relies on a
Quartus-accepted declaration order in `gamma_corr.sv` that Icarus rejects, so
the direct stock-vs-generated comparison belongs in the Quartus build.)

Differential fuzzers (deterministic, `SEED`-driven):

- `clash/tests/run_video_mixer_diff.sh` — mixer core vs the NDS-selected
  video_mixer branch. `CYCLES=250000 SEED=0xc001d00d` for a long run.
- `clash/tests/run_video_freak_diff.sh` — `nds_clash_video_freak` vs a fresh
  reference of the aspect/scale calculator.
- `clash/tests/run_hps_io_diff.sh` — `nds_hps_io` vs the framework hps_io
  reference over the core's command set.

The isolated dirty-tree Quartus integration build is
`clash/tests/remote_quartus_integration.sh` (default pod: `nds-quartus-clash-9`).

## 3D inversion

The 3D path is moving into Clash and the 2D path is moving to the ARM; see
[the inversion plan](../docs/GPU3D_CLASH.md). Since 2026-11-16 this tree is the
single canonical `Nds.Gpu3D` source: the complete model, oracles and gates were
imported from `Nitro_DarkSide-clean` commit `20dca93` (see the plan's canonical
source and hash sections). The first block is the exact
melonDS edge walk in `src/Nds/Gpu3D/Slope.hs`, gated on the host by
`tests/run_slope_check.sh`. The flat triangle fill is `src/Nds/Gpu3D/Raster.hs`,
gated by `tests/run_raster_check.sh`. The streaming top is
`src/Nds/Gpu3D/Flat.hs`, gated under Clash simulation by
`tests/run_flat_check.sh`, with the exhaustive row-union gate in
`tests/run_flat_property.sh` and the reciprocal-table gate in
`tests/run_recip_check.sh`. The depth interpolator is `src/Nds/Gpu3D/Depth.hs`,
gated by `tests/run_depth_check.sh` against the production `Interpolator` and
`Slope` classes. `Nds.Gpu3D.Flat` carries FinalZ and the raw depth-interpolator
endpoints on every span; its gate compares every expanded pixel against
`rasterTriFinalDepth`. `Nds.Gpu3D.Frame` is the depth-tested frame model;
`tests/run_frame_check.sh` renders directed and seeded random frames through the
production `RenderFrame` and compares all 49,152 pixels on colour and final
depth. `Nds.Gpu3D.DepthPipe` is the streaming depth engine (Clash top
`nds_gpu3d_depth`); `tests/run_depth_pipe_check.sh` runs it against a
behavioural memory and compares the framebuffer and every depth word.
`tests/run_pixel_gate.sh` type-checks every module, runs the 2D checks first,
then the cheap 3D checks and the melonDS oracle gates last. Run it with the
local vendored fork explicit:

```sh
MELONDS_DIR=$PWD/third_party/melonDS clash/tests/run_pixel_gate.sh
```

No Quartus build is attempted until those gates are green.

The native toolchain is `stack` with `stack.yaml` (GHC 9.6.6, Clash 1.8.4). The
gate needs no Clash install: the pure model is base-only. Synthesis uses
`stack exec clash -- --verilog -fclash-no-escaped-identifiers ...`; without that
flag Clash emits names Quartus rejects as illegal. This M3 import carries only
`rtl/nds_gpu3d_geometry.v`, which the geometry co-simulation gate replays under
iverilog; the remaining generated Verilog (`nds_gpu3d_slope.v`,
`nds_gpu3d_flat.v` and its `_enc_` include, `nds_gpu3d_shade.v`,
`nds_gpu3d_gxfront.v`, `nds_gpu3d_polygon.v`, `nds_gpu3d_raster.v` and the
composed `nds_gpu3d.v`) stays in the sibling workstream until a fit is run.

The whole 3D engine is in Clash, block by block, each block a pure model gated
against melonDS plus a Clash entity gated against that model:

| block | model | gate |
| --- | --- | --- |
| GX registers and FIFO, GXSTAT, IRQ, DMA | `Nds.Gpu3D.GxFront` | `run_gxfront_check.sh` |
| geometry commands, matrix stacks, lighting, box/pos/vec tests | `Nds.Gpu3D.Geometry` | `run_geometry_check.sh` |
| primitive assembly, culling, clipping, RAM, VBlank sort | `Nds.Gpu3D.Polygon` | `run_polygon_check.sh` |
| the whole render path, every frame feature | `Nds.Gpu3D.Render` | `run_render_check.sh` |
| all of the above composed, ARM9 MMIO to output lines | `Nds.Gpu3D.Chip` | `run_chip_check.sh` |

Each block's hardware entity is gated against its model in Clash simulation
(`run_gxfront_check.sh`, `run_polygon_hw_check.sh`, `run_geometry_hw_check.sh`,
`run_raster_hw_check.sh`), and the block-level Quartus fits are
`tests/remote_quartus_block.sh <block>`.

`Nds.Gpu3D.Render` replaced `Nds.Gpu3D.Scene`, which modelled only the top
layer of triangles with no anti-aliasing, edge marking or fog. Gouraud, textured
and translucent frames still gate through `tests/run_scene_check.sh`, with unit gates
`tests/run_attr_check.sh`, `tests/run_texel_check.sh` and
`tests/run_shade_check.sh`.

`tools/gx3d_oracle` is the headless melonDS raster oracle. It constructs
polygons directly, calls the production `SoftRenderer3D::RenderFrame`, and writes
the 256x192 RGBA buffer, so the Clash rasteriser can be compared against the
same code the hybrid core runs. `tools/gx3d_oracle/gen_main.py` generates the
oracle from the vendored headers so layout constants cannot be retyped wrong.

## 2D trace checkpoint

Milestone status (M0-M5 evidence, M6/M7 remaining work) is tracked in
[`docs/MILESTONES.md`](../docs/MILESTONES.md).

`Nds.Gpu2D.Trace` replays ordered NSD2 input snapshots and memory deltas;
framebuffer and engine oracle records are delivered on a separate callback and
are never renderer inputs. The production trace format remains v9 by default.
The opt-in v10 stream adds sprite-phase input snapshots, display/capture/FIFO
state and oracle-only engine lines. Opt-in v11 additionally brackets display
capture and reports oracle-only changed VRAM chunks and lifecycle flags.
Normal CPU/DMA deltas update both replay shadows; Haskell capture writes update
only the renderer shadow, and oracle capture deltas update only the expected
shadow. The trace renderer carries each sprite buffer between its preparation
and composition phases. Existing live HGS receivers remain v9-only and reject
newer versions rather than discarding their phase information.

The following commands were run on the NTR EVA cartridge with the local
vendored melonDS and its default uncached software renderer:

```sh
sim/melonds_tracer/build-fbdump-vendored.sh
mkdir -p /tmp/nds-v11-capture
sim/melonds_tracer/build-vendored/melonds_fbdump --direct \
  --trace2d /tmp/nds-v11-capture/ntr-v11.nsd2 --trace2d-provenance \
  <path to your NTR test cart>.nds \
  /tmp/nds-v11-capture/top.txt 124 /tmp/nds-v11-capture/bottom.txt \
  2>&1 | tee /tmp/nds-v11-capture/run.log
runghc -iclash/src clash/test/TraceCheck.hs
ghc -O2 -outputdir /tmp/nds-trace-ghc -iclash/src \
  clash/test/TraceCompare.hs -o /tmp/nds-trace-compare
/tmp/nds-trace-compare /tmp/nds-v11-capture/ntr-v11.nsd2 \
  /tmp/nds-v11-capture/haskell 34 71 84 87 90 97 108 116 120 123
for f in 34 71 84 87 90 97 108 116 120 123; do
  for screen in top bottom; do
    python3 sim/tests/compare_fb.py \
      "/tmp/nds-v11-capture/haskell/frame-$f-$screen.txt" \
      "/tmp/nds-v11-capture/$screen.txt" --rtl-frame 0 --mds-frame "$f"
  done
done
```

Observed: all ten selected frames reported 192 lines, zero mismatching
pixels and zero unsupported lines against trace framebuffer records; all 20
independent direct-dump comparisons printed `PASS: pixel-perfect (256x192)`.
The v11 trace is 162,915,000 bytes and contains ordered register/memory and
capture provenance records. The Haskell replay compared 192 capture lines,
49,152 independently generated VRAM writes and two lifecycle events without a
capture mismatch; the replay including rendering took 22.54 seconds in the
observed run. The directed replay regression also rejects missing, extra and
wrong capture writes and checks CPU-delta ordering and same-bank feedback.
The changed-chunk oracle checks observable resulting bytes, not individual bus
write events: it cannot distinguish an extra no-op write or a missing write of
an unchanged value. Write-sensitive dirty-state or capture effects therefore
need separate event-level coverage; no bus write-event parity is claimed.
Artifacts are under `/tmp/nds-v11-capture`.

This is the M1 cartridge checkpoint, **not** exhaustive DS feature proof.
Frame 120 in this v11 check uses recorded melonDS 3D scanline input; the
separate v12 M4 check below replaces it with independently generated Haskell
3D. M2 additionally has both-engine BG/sprite/composition and capture oracles,
including combined multi-line state; these remain finite directed/seeded
coverage, not all possible register histories. Video mode 7 fails explicitly.

The chip-hardware narrow regression was also run after fixing response-tag
ordering, render-table start pulses, testbench memory timing, byte enables and
statistics aggregation:

```sh
KINDS=tiny SEQS=0 FUZZ=0 STOP_ON_FAIL=1 clash/tests/run_chip_hw_check.sh
```

It reported 84 operations, one frame, 49,152 pixels compared, zero
mismatches and `1 cases, 0 failures`. The directed arbiter/table check reports
`chip arbiter response tags and render-table pulse: passed`. These are narrow
checks, not a claim that the complete chip or pixel gate passes.

### Post-import chip-hardware corrections

The initial full pixel gate's composed-chip failure is historical evidence
(`/tmp/nds-m3-pixel-gate.log`), not the imported model's acceptance result.
Repairs made after import include lossless arbiter response-tag ordering,
one-shot render-table start, correct checker memory timing/byte enables,
read-lane/address alignment, VCOUNT abort tracking, statistics accumulation
and IF acknowledgement against live FIFO state. No C++ renderer is used as
the Haskell implementation.

The final directed failures had three distinct causes:

- `RasterHw/Front.hs`: a 2,048-polygon count wrapped to zero when narrowed
  to 11 bits before calculating scanner words. The addition now widens to
  13 bits before `(count + 3) >> 2`.
- `RasterHw/Setup.hs`: backwards-Y edges need signed offsets, reciprocal,
  interpolation products/divisions and coverage. The shared unsigned DSP
  now takes magnitudes and restores signs at the signed consumers. The
  perspective denominator retains production's Word32 wrapping and the
  setup divider supports all 32 divisor bits.
- `ChipHwCheck.hs`: a stalled pending write can finish its comparison
  before a following display event, but a current VBlank/render/frame-end
  must still drain normally. Releasing every stalled op prematurely skipped
  five VBlank drains and caused ten status/DMA mismatches; restricting the
  exception to `OWrite` preserves the actual order, without tolerances.

Observed narrow checks with those fixes: stall first 442 operations,
6,240 cycles, 0 mismatches; strips first 198 operations, two frames,
98,304 pixels, 0 mismatches. An earlier full overflow rerun with the scanner
fix compared 17,861 operations, three frames and 147,456 pixels with
0 mismatches. The final default chip-only acceptance is recorded below;
no unrelated full pixel suite was rerun. Import-time versus corrected-source
hashes and the historical generated-RTL/board limits are recorded in
[`docs/GPU3D_CLASH.md`](../docs/GPU3D_CLASH.md).

### Free-running burst reference contract

The first post-raster-fix default run (`/tmp/nds-chip-final.log`) passed the
15 non-burst directed cases, then failed burst/random status/DMA assertions.
Its first burst divergence was op 98: synthetic per-op entries `0x31` versus
`0x7`, DMA `0x1a` versus `0x5`. That reference froze geometry between `+`
accesses while the actual hardware kept running, and the checker omitted
command/DMA pulses outside its drain phase. It was not a valid burst clock
schedule; the stopped run is not acceptance evidence.

`ChipHwReference` now advances independent FIFO, geometry and polygon models
on the actual transaction schedule. Every accepted command **and parameter**
must match the independently queued head; every offered/transferred geometry
event is compared before the expected event reaches the polygon model.
Accepted-input/consumed/residual conservation is checked, including packed
NOP/zero iterations and deferred FIFO-full writes. IRQ/check/DMA pulses and
physical FIFO levels are independently scheduled over all phases; the
dedicated `FIFO_LT_HALF` level is checked every clock. IF samples that
physical timeline, with IF acknowledgement taking priority over a coincident
refill check. Terminal processing drains commands, events, reads, render work
and delayed pulses, except an independently established swap/power block.

Defined in-flight MMIO and display events retain their schedule. Only
documented undefined-busy geometry result ports are fenced. An overlapping
`RAM_COUNT` read must linearize monotonically to independently computed
old/new event-prefix states, including pending VBlank; stable values must
match exactly. Geometry test/stack status and results follow independently
predicted commands and verified control/event progress with bounded
liveness. This is **transaction-level geometry coherence, not an independent
proof of exact geometry microcycle latency**; no DUT status bit supplies its
own expected value.

Observed focused checks: the final geometry-schedule standalone check passed;
the terminal-burst prefix (97 ops), first RAM-count prefix (425 ops), and
packed-overflow/trailing-zero case (266 ops) each reported 0 mismatches.
With `IF_EVERY_CYCLE=1`, real input acknowledgements exercise every refill
clock: mode 1 at FIFO 128 and mode 2 at 1→0, including check-pulse coincidence.
The two cases report 151 operations, 141 GX entries, 73 DMA triggers,
1,988 cycles, 0 mismatches. Their fixtures are `/tmp/nds-if-mode{1,2}.txt`;
the packed case is `/tmp/nds-packed-zero.txt`.

Full directed burst with the final checker: **3,889 operations, 3,288 burst
operations, 3,289 GX entries, 1,951 DMA triggers, 12 frames, 589,824 pixels,
4,132,157 cycles, 0 mismatches**. Log: `/tmp/nds-burst-final.log`.

The affected 15 non-burst directed cases were then rerun once with that same
final checker: `tiny basic strips translucent effects clear stall power
overflow abort stack noswap regs carry dot`. They report **42,233 operations,
32,093 GX entries, 31,111 DMA triggers, 78 rendered frames, 4,423,680
compared pixel words, 28,920,400 cycles, 0 mismatches**. Together with the
disjoint burst case, all 16 default directed cases pass. The final directed
log is `/tmp/nds-chip-directed-final.log`; no earlier-checker result is
substituted for this affected-contract rerun.

The remaining-default batch initially passed all 16 random and seven fuzz
cases, then found two real `CLIPMTX_RESULT` reads returning zero in `fuzz8`
(ops 2,090 and 2,376). `GeometryHw.geoResultOut` had gated result RAM with
architectural GXSTAT busy, which includes a quiescent SWAP wait. The final
fix gates only unfinished control/tag/event work through
`geoTransactionIdle`; completed matrix results remain readable during swap
wait. A nonzero-matrix regression (26 ops / 708 cycles) gives exactly two
mismatches with the old binary and zero with the fix, preserving `0x4444`
and `0xbbbb` across SWAP. Logs: `/tmp/nds-swap-result-{before,after}.log`;
original fuzz failure: `/tmp/nds-fuzz8-before-resultgate.log`.

### Final M3 chip-only acceptance

**All 40 default cases pass: 16 directed, 16 seeded random and 8 fuzz;
0 mismatches.** They were observed in disjoint batches with the final
transaction checker, not by rerunning the entire pixel suite. The last fuzz
case was rerun after the localized completed-result/SWAP-wait fix; the other
39 accepted cases were preserved.

```text
144401 operations (141200 writes, 2011 reads)
116556 GX entries; 98634 DMA triggers; 23838 burst operations
215 rendered frames; 10665984 compared pixel words
24 aborted; 37 operations ending stalled; 33440 IRQ observations
8119 bus-wait cycles; 87463785 total cycles; 82991029 render cycles
40 cases, 0 mismatches
```

Evidence: `/tmp/nds-chip-directed-final.log` (15),
`/tmp/nds-burst-final.log` (1), and the first 23 passing cases in
`/tmp/nds-chip-remaining.log`, followed by
`/tmp/nds-fuzz8-result-final.log` (the corrected final case: 2,487 ops,
7 frames, 245,760 pixel words, 0 mismatches).
`/tmp/nds-chip-acceptance-summary.txt` aggregates those exact 40 records.
The remaining-batch log deliberately retains its original two fuzz8 failures;
it is not presented as a wholly green run.

The remaining default batch used
`KINDS=' ' REUSE=1 SEQS=16 FUZZ=8 STOP_ON_FAIL=1
clash/tests/run_chip_hw_check.sh`; the 15 named directed cases and burst
were run separately through the same checker. A fresh complete reproduction
is `clash/tests/run_chip_hw_check.sh`. No further check, Quartus/board run,
full pixel-suite rerun or generated composed-HDL update followed acceptance.

## v12 raw 3D replay and composition

v12 is opt-in (`--trace2d-raw3d` / `SetTrace2DRaw3DInputs(true)`); the v9
default and v11 records are unchanged. It adds ordered GPU3D power, RenderXPos,
VCount abort, VBlank, frame-end, render-start snapshots (VRAMCNT plus texture
and texture-palette mappings, preceded by changed memory deltas, with an
initial snapshot that never renders) and raw accepted GX bus writes (type 26).
The Haskell decoder delivers all of these in stream order with their 64-bit
timestamps and exact memory snapshot; `renderTraceDisplays` accepts an explicit
3D line and never reads the recorded oracle line itself.

Observed with the independent gate:

```sh
MELONDS_DIR=$PWD/third_party/melonDS clash/tests/run_m4_check.sh /tmp/nds-v12c/ntr-v12.nsd2
```

reported `type3 768 lines, 0 3D mismatches; screen 23808 lines, 0 screen
mismatches`. The production-C++ re-render of the same raw stream reported
`768 recorded lines compared, 0 mismatched, 0 skipped`. The directed/seeded
3D scene composition gate reported 6,720/6,720 3D lines and 6,720/6,720 screen
lines exact. The expanded 2D composition oracle reported 1,897 valid lines,
0 failures, plus 3 explicit mode-7 rejections (1,900 oracle lines total);
the BG oracle reported 177 cases, 0 mismatches, and capture 220 cases,
0 mismatches. The composition matrix includes both engines, four BGs, OBJ,
windows, priorities, blending, brightness and mosaic across full frames.
These are independent production-renderer comparisons, not exhaustive DS
state-space or cycle-level proof.

The focused production consumer `nds_gpu_replay` was migrated to accept both
v11 and v12 and reject unknown record types instead of skipping them. Both real
traces completed with 196,608/196,608 recorded 3D pixels, 12,189,696/12,189,696
framebuffer pixels and zero geometry-count mismatches. The live HGS encoder
remains v9-only and now fails closed with an explicit error on v10+ records
(`v10_rejection: passed` in the direct encoder test).

### Measured TARDIS work on a real trace

`clash/test/TraceTardisFull.hs` replays v12 and measures every line whose
engine-A BG0 is not 3D, including OBJ, windows, mosaic, display mode/brightness
and capture state through explicit sprite/window/capture/display tokens. On the
NTR trace through frame 123, 120 of 124 frames qualified (768 3D-active lines
were excluded and counted) and every one of 23,040 measured lines was
pixel-identical between the speculative and reference paths:

```sh
/tmp/nds-trace-tardis-full /tmp/nds-v12c/ntr-v12.nsd2 123
eligible frames=120 excluded_3d_lines=768
speculative: hits=23040 misses=0 fixups=0 prefetch=14025 demand=0 invalidated=13833 total_renders=14025
reference:   ... demand=23040 total_renders=23040
hit_rate=1.0
output_equal=True
wall_ms: speculative=6850.2 reference=10807.3
```

So on that slice the speculative path performed 14,025 line renders instead of
23,040 (39% fewer) and ran in 6.85 s versus 10.81 s (1.58x). The remaining
exclusion is 3D-active lines: their independent Haskell 3D cost is measured
separately by the M4 gate, not folded into this 2D cache number.

The independent M5 harness (public API, both engines, provider tokens from the
Haskell 3D line and composition) reports all 47,616 of 47,616 lines of the same
v12 trace pixel-exact, 29,586 renders versus 47,616, 100% hit rate and 29,202
evictions. Its 101-check stress suite passes, including
capacity/LRU/stale-plan rejection, key sensitivity for every memory, epoch,
register, latch, engine, line and the sprite/window/capture/display/3D tokens.
Our engine-A harness excludes 3D-active lines; the independent harness includes
them through `lk3D` tokens, and both agree on every measured line. Random
memory/register mutations,
missing/extra/wrong capture writes and same-bank feedback are covered by
`TraceCheck.hs`; sprite/window/capture/display token sensitivity is exercised
by the independent M5 harness.

Final M5 wall-clock comparison uses separate processes from trace-open
through fully forced output, including decoding, raw Chip replay, sprite and
capture preparation, hashing and GC. The exact variant skips cache-only
provider tokens; cached timing includes key/token work, planning, all
prefetch and demand rendering, and cache maintenance:

```sh
SPECULATE_MODE=cache clash/tests/run_speculate_measure.sh /tmp/nds-v12c/ntr-v12.nsd2 124
SPECULATE_MODE=exact clash/tests/run_speculate_measure.sh /tmp/nds-v12c/ntr-v12.nsd2 124
```

Observed: **36.129108 s cached versus 43.973591 s exact (1.21712x)**.
Both process all 124 frames / 47,616 lines and force 768 actual Haskell
Chip 3D lines. Cached work is 29,586 prefetch + 0 demand renders versus
47,616 exact renders (37.9% fewer), with 47,616 hits, 0 misses/fixups and
29,202 evictions. Diagnostic render-pass times are 14.339584 s cached /
21.904817 s exact; preparation components are not substituted for whole-run
time. Logs: `/tmp/spec-measure-cache-e2e.log` and
`/tmp/spec-measure-exact-e2e.log`.

Both independent runs produce `outputHash=147193483`; that hash is a
probabilistic cross-run check, **not** the pixel-exact proof. The separate
prepared-input comparison above checked all 47,616 lines bitwise. This is one
run per variant on one real trace, not a statistical benchmark or a claim of
parallel prefetch. The former unforced 0.000023 s 3D timer is invalid, the
older 1.51x is renderer-only, and shared-preparation arithmetic was not an
end-to-end measurement. No Quartus fit, regenerated composed HDL or board
result is established by these host checks.

## Visible host viewer (live stream, open loop)

`tools/hs_gpu_view/run.sh CART.nds [FRAMES]` opens a macOS window that shows
the cartridge as rendered by the Haskell models. The pipeline is:

```text
melonds_fbdump --direct --input CTRL --trace2d /dev/fd/3 --trace2d-raw3d CART /dev/null FRAMES
  -> pipe (NSD2 v12) -> trace-view (clash/test/TraceView.hs)
  -> nds-view (tools/hs_gpu_view/{NdsView,main}.swift)
```

- melonDS runs the ARM9/ARM7, memory and cartridge, plus its own GPU, which is
  what the emulated CPU reads back (GXSTAT, capture, etc.). `trace-view`
  renders every displayed pixel from the streamed inputs with
  `Nds.Gpu3D.Chip` (through `TraceReplay`) and the `Nds.Gpu2D`
  compositor. melonDS's own screen records are only *counted*: the status line
  shows how many lines are bit-identical.
- **Open loop.** The Haskell GPU never feeds back into the emulated CPU. This
  is a live streamed renderer, not a closed-loop console or a replacement for
  melonDS's GPU. The pipe throttles melonDS to the renderer's speed (a few
  frames per second). `FRAMES` defaults to 1,000,000.
- **Fails closed.** Any of these stops the stream with an explicit
  frame/line error: a 3D, sprite, render or capture model error; a GX event
  before the first render-start snapshot; a normalized type-5/7 GX record
  without the raw type-26 stream; or a frame without exactly lines 0-191.
  Only complete frames are emitted. `trace-view` ends with a terminal record
  (end of stream, or the error). The window then keeps the last actual frame
  and is marked `STOPPED, NOT LIVE` (red for an error); it never shows the
  frame as live after that.
- `run.sh --replay TRACE.nsd2` shows a recorded v12 trace instead (no input).
- Logs: `$TMPDIR/nds-hsview/{melonds,trace-view,nds-view,build}.log`.
  Stdout carries only frame and terminal records. `shown.png` is the exact
  bitmap last handed to the window. Closing the window ends the pipeline.

Controls (input is sent to melonDS through the `--input` control file):

- Game controller (GameController framework; the name is shown in the
  window): east/south/north/west face buttons = DS A/B/X/Y (Nintendo layout),
  LB/LT = L, RB/RT = R, Menu = Start, Options = Select, d-pad or left stick =
  directions.
- Keyboard, an extra to the pad (same keys as the standalone host):
  arrows, X = A, Z = B, S = X, A = Y, Q = L, W = R, Return = Start,
  right Shift = Select.
- Mouse = touchscreen. A left press on the bottom screen touches at the
  aspect-fit pixel (0-255, 0-191). Drags clamp to that screen. Releasing the
  button, leaving the view, the window losing focus or closing all release the
  touch. Clicks on the top screen are ignored.

Control file (16 bytes, little endian): `"NDSI"`, a 12-bit key mask in
`SetKeyMask` order (active low), touch (bit 31 pressed, x in bits 0-7, y in
bits 8-15) and a sequence number. melonds_fbdump applies changes before each
frame through `SetKeyMask`/`TouchScreen`/`ReleaseScreen` and logs them as
`input frame=...` on stderr. After each frame it writes back, at byte 16, the
sequence that frame ran with. The viewer holds a press or touch that is
shorter than one emulated frame until that acknowledgement arrives, so quick
taps reach the game.
