# Inverting the NDS split: 3D in Clash, the rest on ARM

NDS4MiSTer puts the DS CPUs and console timing in the FPGA and both 2D
engines, 3D geometry and software rasterisation on the HPS ARM. Its measured
A9 rasteriser result is a NO-GO at the DS frame rate, so the split is backwards
for this core: the FPGA should own 3D, and the ARM should own the cheap,
throughput-tolerant remainder.

This directory is the start of that inversion. The rule is absolute: new 3D logic is
written in Haskell/Clash. Hand-written Verilog or VHDL is only allowed at the
board/framework boundary, where a vendor primitive or a MiSTer port already
exists.

## Canonical source (M3 import, 2026-11-16)

This tree is now the single canonical `Nds.Gpu3D` workstream. The complete 3D
model, its melonDS oracles and its gates were imported from the sibling
workstream (a separate local `Nitro_DarkSide-clean` checkout) at clean worktree commit
`20dca93808aa3cf13ef8356dd756829c44176f0e`. At import, this tree's
2D/TARDIS modules (`Nds.Gpu2D.*`, `Nds.Gpu.Unified`) were preserved, as was
the current-tree-only `Nds.Gpu3D.Budget`. Subsequent 2D, unified replay and
hardware corrections are separate work, not part of the imported snapshot.

Files were reconciled, not copied over blindly:

- `DepthPipe.hs` is committed as the imported body without an explicit
  `RankNTypes` pragma; the library's GHC2021 default provides it. A local
  working-tree pragma is a separate uncommitted user change.
- `Depth`, `Flat`, `Raster` and `Slope` take the imported versions: they are
  strict supersets (W-buffer-aware edge setup, shared span rules, extracted
  edge parameters and attribute interpolation).
- The cabal library uses `default-language: GHC2021`, matching the `stack ghc`
  invocation the gates use. Haskell2010 rejected the imported
  `TypeOperators`/`FlexibleContexts` uses.
- `Nds.Gpu2D.Trace` and the `bytestring` library dependency were added for the
  2D trace workstream, not for 3D.

The exact hashes of the 35 imported/retained 3D source files are in
[Imported source hashes](#imported-source-hashes-2026-11-16).

### Observed M3 verification (2026-11-16)

`MELONDS_DIR=<repo>/third_party/melonDS clash/tests/run_pixel_gate.sh` was run
once on this tree. Report that run, not an older claim. It passed module
compile, the 2D checks, flat/depth/raster/slope, attribute/texel/shade,
Gouraud/textured/translucent frames, polygon, geometry, render, GX front end,
the model chip gate, polygon hardware and geometry hardware Clash simulation
(0 mismatches), and raster hardware. It failed only at the composed chip
hardware stage after 8,716.89 s: `chip-hw-check: 40 cases, 40 failures`, every
case a `FAIL hang` in `PbDrain`/`PbRenderRun` with all hardware outputs
undefined (x). The iverilog geometry cosim reports known informational
mismatches; the script asserts that cycles were compared, not that they match.
Full log: `/tmp/nds-m3-pixel-gate.log`. Do not claim a green M3 gate until
that block is fixed.

`stack build nds-mister-clash:lib` compiles all Gpu3D modules and then fails
in the pre-existing user-modified `Mister.HpsIoSubset.hs` and
`Mister.VideoMixer.hs`, outside this import.

### Post-import host corrections (2026-11-17)

The failed first full gate above is retained as provenance, not a current
acceptance verdict. The final chip-only acceptance and its exact totals are
recorded in [the Clash README](../clash/README.md). Earlier stages of that
full pixel gate were observed green; they were not rerun merely to replace
the final composed-chip stage.

Post-import fixes include response-tag FIFO ordering and lossless response
delivery, one-shot render-table start, IF acknowledgement from live FIFO
state, bus read alignment/lanes, correct checker memory timing and byte
enables, VCOUNT tracking and actual accumulated statistics. Two final
hardware defects were independent of the imported model:

- `RasterHw.Front`: calculate `(count + 3) >> 2` after widening `count` to
  13 bits. Resizing the 2,048-polygon bank count to 11 bits first produced
  zero scanner words and emitted no polygons.
- `RasterHw.Setup`: a backwards-Y edge can have negative line offsets,
  reciprocal, interpolation factors and coverage increments. The unsigned
  32x24-bit DSP now multiplies magnitudes and restores signs at each signed
  consumer, including arithmetic-shifted Z interpolation. Production's
  unsigned perspective numerator/denominator wrapping is retained, with a
  full 32-bit divider divisor rather than truncating to 25 bits. The model
  was not changed to match the hardware.

The checker also releases a stalled pending **write** when the next input is
a display event, then lets that event drain normally. This rule must not
release a current VBlank/render/frame-end event early. Narrow verification:
442 stall operations / 6,240 cycles / 0 mismatches; 198 strip operations /
two frames / 98,304 pixels / 0 mismatches. The first full overflow rerun
compared 17,861 operations / three frames / 147,456 pixels / 0 mismatches.

Burst scripts exposed a separate reference-schedule error: `+` used to freeze
the model while hardware geometry ran during bus cycles, and activity outside
the checker drain phase was not counted. The replacement `ChipHwReference`
checks every command/parameter and geometry-event payload against independent
queued model data before advancing the expected pipeline. It conserves
accepted/consumed/residual entries, independently schedules physical FIFO
levels and registered IRQ/check/DMA pulses (including packed zero iterations),
and checks `FIFO_LT_HALF` every cycle. Terminal work is drained unless a
verified swap/power block legitimately retains the queue.

Defined in-flight MMIO/display behavior is retained. Overlapping `RAM_COUNT`
reads use monotonic independent event-prefix linearizability with exact
quiescent values; only undefined-busy geometry result reads are fenced.
`ChipHwGeoSchedule` checks geometry status coherence using expected commands
and verified control/event progress, with bounded liveness, **not exact
geometry microcycle latency**. It never imports the status bits under test as
their own expected values. Focused IF mode-1/128 and mode-2/1→0 checks,
including coincident IF/refill priority, report 151 ops / 1,988 cycles /
0 mismatches. Full directed burst reports 3,889 ops / 12 frames / 589,824
pixels / 0 mismatches (`/tmp/nds-burst-final.log`).

The final fuzz case also exposed a real result-port validity bug:
`GeometryHw.geoResultOut` used architectural GXSTAT busy to zero result RAM,
including an otherwise quiescent `SWAP_BUFFERS` wait. It now uses
`geoTransactionIdle` (control/tag/event work settled), so completed nonzero
matrix values remain readable during swap wait. A 26-op regression reads
`0x4444` and `0xbbbb` before and during the wait: the old binary has exactly
two mismatches, the corrected binary has zero. Logs:
`/tmp/nds-swap-result-before.log`, `/tmp/nds-swap-result-after.log`.

Final host chip-only acceptance covers all **40 default cases** (16 directed,
16 random, 8 fuzz), **0 mismatches**: 144,401 operations, 116,556 GX entries,
98,634 DMA triggers, 215 rendered frames and 10,665,984 compared pixel words.
The checker observed 87,463,785 total / 82,991,029 render cycles. This is the
union of disjoint final-checker batches, with only fuzz8 rerun after the
localized result-port fix; no fresh whole pixel suite was run. Exact logs and
the original retained failures are enumerated in the README; aggregate:
`/tmp/nds-chip-acceptance-summary.txt`. Transaction-level timing and
generated-RTL/board limits above remain unchanged.



### M1–M5 evidence and boundaries

| Milestone | Independent or measured evidence | Boundary |
| --- | --- | --- |
| M1 | Ten requested NTR EVA frames, both displays: 20 direct-dump pixel-perfect comparisons; v11 separate capture shadow | One cartridge checkpoint, not exhaustive timing |
| M2 | BG 177 cases (A/B), sprite 100 cases per engine, capture 220 cases; combined composition 1,897 valid lines exact and 3 explicit invalid-mode rejections | Finite directed/seeded matrix; invalid video mode 7 is rejected |
| M3 | Imported model/oracle stages green in first full gate; final composed-chip cases and exact logs separately in README | Transaction-level geometry timing, host Clash simulation only; not generated-RTL/board proof; historical informational cosim mismatches remain disclosed |
| M4 | Raw v12 inputs replayed by production and Haskell: 768 cartridge 3D lines and 23,808 screen lines exact; 6,720 scene 3D/screen lines exact | Recorded inputs are used, never oracle pixels as the Haskell 3D provider |
| M5 | Bounded LRU, all memory/latch/engine/provider keys; 101 stress and 12 token checks; 47,616 lines bitwise exact with 29,586 total renders; separate whole-replay runs 36.129108 s cached / 43.973591 s exact (1.21712x) | One run per variant, sequential prefetch; cross-run hash is consistency only, separate exact comparison supplies correctness |

The trace, oracle commands and measured-scope caveats are in the README and
[TARDIS note](tardis.html). No Quartus or board check was run for these fixes;
older fit numbers below are historical, and composed HDL was not regenerated.

The final M5 modes are `SPECULATE_MODE=cache` and `SPECULATE_MODE=exact`
with `clash/tests/run_speculate_measure.sh /tmp/nds-v12c/ntr-v12.nsd2 124`.
Each starts from trace-open and forces all output, including 768 actual Chip
3D lines; exact skips cache-only token construction. Logs are
`/tmp/spec-measure-cache-e2e.log` and `/tmp/spec-measure-exact-e2e.log`.
Both produce hash `147193483`, which alone is not pixel-exact proof.
The earlier 1.51x number times rendering only; the lazy 0.000023 s 3D timer
and the shared-preparation 1.20271 estimate are not valid end-to-end timings.
Wall/GC noise and the single-trace/single-run scope remain explicit.


## Why native first

A Quartus fit is tens of minutes and a board run is worse. A Clash design is also
an ordinary Haskell program, so the same equations can run on the host at native
speed. Every block therefore lands in this order:

1. Pure Haskell model, no `Signal`, no clock.
2. Differential gate against the production melonDS implementation on the host.
3. Only after the gate is green: wrap the model in `mealy`, emit HDL, fit, and
   test on hardware.

The first block is the edge walk (`Nds.Gpu3D.Slope`), because every scanline
span, coverage value and depth interpolation in the rasteriser depends on it. It is
transcribed from `GPU3D_Soft.h`'s `SoftRenderer3D::Slope` and checked field by
field, step by step, against that class compiled straight out of the vendored tree.

## Gate

```sh
clash/tests/run_pixel_gate.sh
CASES=2000000 clash/tests/run_slope_check.sh
```

`run_pixel_gate.sh` type-checks every module first, then runs the cheap
reciprocal and row-union checks, then the streaming simulation and finally the
melonDS oracle gates, so a broken equation fails in seconds instead of after a
Quartus-length run.

The oracle includes the production header and exposes the private `Slope` class to a
test-only translation unit. No melonDS source is modified. The Haskell side is
`src/Nds/Gpu3D/Slope.hs`; the checker is `test/SlopeCheck.hs`.

Measured on the host: two million randomised setups plus the eighteen directed
corner cases, eight stepped scanlines each, zero mismatches in every exported
field. That covers both sides, negative edges, zero-height edges, one-pixel spans,
X-major and Y-major walks, and lengths on both sides of the reciprocal table
bound.

The Clash machine is `src/Nds/Gpu3D/Top.hs`. Its generated Verilog is checked in
at `clash/rtl/nds_gpu3d_slope.v`; it is not yet wired into `NDS.sv`, because
nothing consumes the edge yet. Generation command:

```sh
cd clash
stack exec clash -- --verilog -isrc -outputdir /tmp/nds-clash-out \
  src/Nds/Gpu3D/Top.hs src/Nds/Gpu3D/Flat.hs src/Nds/Gpu3D/ShadePipe.hs
```

Clash reports one dubious-primitive warning for `integerToInt#`, which is the
usual `fromIntegral` path between fixed-width integers. That is a datapath
cleanup item before the block is considered synthesis-final, not a behavioural
difference in the native gate.


## Second block: flat triangle fill

The next slice is `Nds.Gpu3D.Raster`. It models the narrow path the first Clash
top will own: three vertices, constant colour, constant depth, no texture, no
anti-aliasing, no translucency, no shadows. Under those assumptions the
rasteriser's per-pixel shading collapses to coverage, but the fill rule does not
collapse: the model still reproduces the left-edge, interior and right-edge passes,
the swapped-edge path, the right-edge pull-in, the bottom-scanline exceptions, and
the degenerate horizontal-line case.

The oracle now drives the production `SoftRenderer3D::RenderFrame` directly with
synthetic polygons, one triangle per frame. The checker compares the model's covered
pixel set against the oracle's non-zero pixels. A first run of 1,000 random
triangles exposed a real model bug: after an unfilled left edge the C++ cursor jumps
past the interior, while the model jumped *backwards* to the interior limit. That is
exactly the kind of drift the gate exists to catch.

Measured on the host: 10,000 random triangles, mixed facing, equal-Y edges and
off-screen X, zero failures. A directed fully horizontal triangle covers 190 pixels
and also matches. The edge-walk gate additionally checks both `EdgeParams`
templates, non-swapped and swapped, including the swapped path's length sequencing.

Limitations, stated plainly: the melonDS oracle gate is coverage only. The
streaming top carries the triangle's constant colour, but not depth, texture,
blending or the geometry engine.

## Third block: streaming flat top

`Nds.Gpu3D.Flat` wraps the raster model in an explicit-clock `mealy` machine.
It consumes one triangle, emits one inclusive `(y, x0, x1, colour)` span per
cycle in ascending scanline order, and honours `outReady`: a stalled sink sees the
same span held until it is accepted. Scanlines outside 0..191 and columns outside
0..255 are dropped, and empty rows are skipped.

The flat configuration is `RasterConfig 32 31 False 256`, which sets the
force-opaque display bit. In the production renderer that bit makes every polygon
opaque, so the reference's left, interior and right pieces are contiguous and the
union is exactly one span per row. The top therefore uses `setupRasterFast` and
`rowSpanFast`, which carry no coverage reciprocals and no per-row edge-length
maths. `reciprocal18` is replaced by a 257-entry constant table for the common
on-screen edge lengths, and taller edges fall back to the exact divider. No visible
triangle is rejected. The row walk starts at `max 0 top` and stops at
`min 192 bottom`, so clipped rows are never visited, and every emitted span is
checked against the 0..255 by 0..191 screen box. This is not an approximation
inside the table range: the native gate compares the fast path with the full
`rasterTri` model on the same configuration.

The gate is `clash/tests/run_flat_check.sh` (`CASES=N`). It runs the real
machine under Clash simulation, expands the emitted spans back to pixels, and
compares them with `rasterTri`. Every case is run twice, once with `outReady`
tied high and once with a 2-of-3 stalled ready pattern. Measured on the host:
5,051 cases, zero failures, including horizontal, degenerate, clipped and
off-screen triangles. The companion pure gate compares the fast row union with the
exact three-segment fill on 1,024,000 ordered small-grid triples plus 200,000 random
large-coordinate triples, also with zero failures. The reciprocal-table gate checks
every denominator in the table and the exact-divider fallback outside it. The final
combined run is 1,224,000 row-union cases, 5,051 streaming cases, 2,000 melonDS
raster cases and 200,018 melonDS slope cases, all zero failures.

The production oracle also gates the forced-fill configuration:

```sh
DISPCNT=0x20 CASES=2000 clash/tests/run_raster_check.sh
```

That drives the vendored `SoftRenderer3D` with `RenderDispCnt = 0x20` and compares
it with `rasterTri` on the same configuration. Measured: 2,000 cases, zero
failures. The oracle constructs final vertices directly, so its generator keeps Y
inside 0..191; real geometry-engine output is clipped the same way. The model's own
clipping gate covers negative and beyond-screen vertices. Bit 4 (`0x10`) is *not*
interchangeable with bit 5 in this fork; the oracle diverges from the model there,
which is why the flat path selects bit 5.

Synthesis and fit, standalone, no pins. These measurements predate the
pixel-perfect hardening: they were taken with the 256-scanline admission guard and
without the tall-edge divider fallback, so they are not current area claims.

| Variant | ALMs | Registers | DSP | Worst setup slack |
| --- | ---: | ---: | ---: | ---: |
| full setup, `RasterConfig 0` (Yosys estimate) | 20,332 LEs | 1,144 | 24 | not fitted |
| forced fill, divider row setup | 8,047 | 847 | 24 | -136.220 ns |
| forced fill, divider-free row setup | 7,959 | 847 | 24 | -136.071 ns |
| forced fill, 2,049-entry reciprocal table | 6,902 | 847 | 24 | -48.306 ns |
| forced fill, 257-entry reciprocal table | not separately fitted | 847 | 24 | not separately fitted |
| forced fill, pipelined 257-entry table | 5,730 | 881 | 24 | -37.711 ns at 100 MHz |

The first row is a Yosys `synth_intel -family max10` estimate, not a fit. The
other rows are Quartus 17.0 fits on `5CSEBA6U23I7` with virtual pins and a
100.542 MHz clock.

The 257-entry table removes the divider from every on-screen edge and cuts the
lookup logic from roughly 592 ALMs to tens of ALMs; taller edges still instantiate
the exact divider. The remaining row path is the edge step itself: the two DSP
multiplies that update the edge slopes and the comparators that advance the
cursors. The block is functionally gated; no fit has been run on the current tree.

Inside the full NDS4MiSTer console island on `5CSEBA6U23I7`, the guarded
257-entry version used **4,313.5 ALMs** (down from 4,901.5 for the 2,049-entry
version). The complete core fitted at **38,670 / 41,910 ALMs (92%)**, **4,187 /
4,191 LABs**, **536 / 553 M10K** and **51 / 112 DSPs**. That was a real fit, but
it is a pre-hardening measurement: the guard and its rejection path have since been
removed, and tall edges now instantiate the exact divider. No fit has been run on the
current tree.

The row walk is still a single combinational state-to-state path.  At 134.056 MHz
the guarded version measured **-50.965 ns**; at 33.514 MHz it measured
**-26.544 ns**.  The flat state register was enabled every fourth `clk1x` cycle,
and a `set_multicycle_path 4` constraint on that register reported **+36.806 ns**
on the routed guarded fit.  That established the integration operating point: one
row every four `clk1x` cycles, about **727 triangles per 60 Hz frame** for one
span per row.  The current tree adds the tall-edge divider fallback and starts the
row walk at the first visible scanline, so those timing and area figures must be
re-measured before release.

## Fourth block: depth interpolation

`Nds.Gpu3D.Depth` transcribes the production `SoftRenderer3D::Interpolator`
depth path: the 9/8-bit perspective factor, the W-buffer and Z-buffer branches,
the linear reciprocal, and the 22-bit edge reciprocal. The gate drives the
vendored `Slope` and `Interpolator` classes directly and compares eight
scanline samples per edge.

```sh
CASES=200000 clash/tests/run_depth_check.sh
```

Measured: 99,620 downward edges, zero failures. This historical unit gate
excluded upward edges; the assumption that real polygon walks never expose
negative Y lengths was disproved by the composed-chip strips fixture.
The post-import setup corrections above cover that path. The same unit gate
checks 200,000 W-normalization and `FinalZ`
transform cases against the production helpers, also zero failures. This gate
calls `SetX` itself before every sample, so it cannot see the interpolator state
`Slope::Setup` leaves behind; the frame gate below covers that.

## Fifth block: depth buffer and depth test

`Nds.Gpu3D.Frame` is the pure frame model: triangles in submission order,
per-pixel depth, the production comparators, and a depth buffer that also
records which pixels an opaque back-facing polygon wrote. The frame oracle
renders the same triangles through the production `SoftRenderer3D::RenderFrame`
and dumps both its colour buffer and its depth buffer; `FrameCheck` compares all
49,152 pixels on coverage, colour and final depth.

```sh
FRAMES=32 clash/tests/run_frame_check.sh
```

Measured: one directed frame (near/far order, equal-Z ties of both facings, a
single-point polygon, horizontals at X 0 and X 256, vertical lines, right edges
that start on X 256) and 32 seeded random frames of 48 triangles with
independent 24-bit Z and 16-bit W per vertex, three in sixteen flat at a shared
depth so ties occur. Every pixel of every frame matches, colour and depth.

Inputs stay inside the post-clip viewport (X 0..256, Y 0..192). The geometry
engine clips before rasterising, and melonDS starts its edge walk at `YTop`,
so its output for off-screen Y is an artefact rather than behaviour to
reproduce; with Y down to -16 the two disagree on whole triangles.

Building the full-buffer gate found five model errors that the earlier
coverage-only, constant-Z frame gate could not see:

- **Span interpolator.** Production builds it over the raw edge interval
  `[xstart, xend + 1)` after the pull-in and swap. The model used the clipped,
  inclusive range.
- **Z-buffer mode never reads W.** `InterpolateZ` uses only the X offset, the
  span length and its reciprocal, so the span interpolator is built with equal
  weights: it is linear and `SetX` does no division. There is no per-pixel
  divider in the Z path.
- **`Slope::Setup` calls `Interp.SetX(y)`.** With `interpoffset` the first row
  of an X-major edge sits at offset 1, not 0.
- **Equal-Z tie rule.** Back-facing polygons pass on `z < dst` only.
  Front-facing polygons also pass on `z == dst` when an opaque back face wrote
  the pixel (`dstattr & 0x400010 == 0x10`). The model had the facing mapping
  inverted and no attribute.
- **Horizontal polygons.** Production takes the minimum-X and maximum-X vertices
  as the edges (first vertex wins ties), so Z varies along the span.

The frame gate also caught two bugs in its own oracle: a 6-bit colour packer
feeding a 5-bit unpacker, and a 4-character record-kind buffer that read
`TRIZW` as `TRIZ`.

## Sixth block: streaming depth engine

`Nds.Gpu3D.DepthPipe` takes clipped spans from the flat rasteriser and walks
their pixels through read, compare, write and emit against an abstract memory
port. The board wrapper owns SDRAM arbitration. Each depth-buffer word holds
FinalZ in bits 0-23 and the back-facing attribute in bit 24. A clear command
writes all 49,152 words.

The engine contains no dividers:

- **Per pixel**, it uses `setXLinear`, which updates only the X offset.
  Z-buffer `interpolateZ` never reads the perspective factor, which is the only
  other field `setX` writes, so the depth is identical. The gate below checks
  the engine against the model, which keeps production's literal `SetX`.
- **Per span**, `0x400000 / xdiff` comes from a 258-entry table. A
  200,000-triangle, border-biased post-clip sweep (24.5M spans) measured
  `xdiff` from exactly 1 to exactly 257. The gate asserts that domain on every
  span it feeds, and both gates include a triangle that reaches 257.

Clash elaborates the top to `nds_gpu3d_depth.v`. The only division left in it
builds the constant table, the same pattern the flat path's reciprocal table
uses, which the integrated fit folded.

```sh
clash/tests/run_depth_pipe_check.sh
```

The gate runs the same `depthStep` as the Clash top against a behavioural
memory:

- read latency varies from 1 to 3 cycles;
- the sink stalls one cycle in five;
- memory powers on as garbage, so only the engine's own clear makes it valid.

Inputs are post-clip triangles, plus directed tie and right-border cases. The
gate compares two things:

- the final framebuffer, against the frame model, which the frame gate ties to
  production;
- all 49,152 final depth words, back-facing bit included, against the span
  reference.

Measured: 400 triangles, 45,738 pixels and 49,152 depth words, zero failures.

Both gates are mutation-tested. Each mutant is a plausible single-edit bug and
must make its gate fail. All 18 do:

| gate | mutants |
| --- | --- |
| engine | clear range, facing swap, dropped emit, span overrun, ignoring memory, dropped back-facing bit, clipped interpolator, table index, table top entry, X offset |
| model vs production | missing setup `SetX`, tie rule, facing map, exclusive end, clipped interpolator, flat horizontal Z, horizontal tie pick, horizontal pull-in |

Mutation testing found four gate holes, each now closed:

- The constant-colour test triangles hid which triangle won.
- No input put a Z gradient on a raw span end of 257.
- Every generated horizontal was also flat-Z.
- The engine gate compared colours only.

A survivor is either an equivalent mutant or a missing test, so each was
treated as one of those until shown otherwise.

Engine throughput is about three cycles per pixel plus read latency.

## What the edge walk has to reproduce

- 18-bit fractional X stepping, including the `0x40000` X-major threshold.
- The `2^18 / d` reciprocal table and its truncating-division fallback.
- The asymmetric left/right `dx` seeding, including negative edges.
- The `(y - y0) * Increment` extrapolation and 32-bit wrap.
- The `xmin`/`xmax` clamp and the AA coverage reciprocal.

Those are exactly the places where a "reasonable" reimplementation drifts from
the DS. The gate exists to make drift impossible to hide.

## Resource sketch

The pure model keeps the two 0x201 reciprocal tables, 32 bits wide. The flat
hardware path instead uses one 257-entry, 19-bit table for the common on-screen
denominators, with an exact divider fallback for taller edges. Inside the guarded
full NDS4MiSTer console island the flat hierarchy used 4,313.5 ALMs, with no M10K;
the current tree trades some of that area back for the fallback divider. The edge machine itself is a handful of 32-bit
adders and comparators. That is affordable only because the 2D renderer leaves the
FPGA; the whole point of the inversion is to spend the freed LABs on 3D.

## Order of work

1. Edge walk parity (this slice).
2. Triangle setup and span fill, flat opaque untextured, against the same oracle.
   Landed: `Nds.Gpu3D.Raster`, 10,000-case native gate, zero failures.
   Landed: `Nds.Gpu3D.Flat`, streaming top, 5,055-case simulation gate,
   exhaustive row-union gate and exact-divider fallback for clipped edges.
3. Depth test, W-buffer and 1/z interpolation.
4. Texture fetch, wrapping, palettes and modulation.
5. Blending, alpha test, anti-aliasing, edge marking, fog and shadows.
6. Geometry engine: matrix stacks, vertex transforms, lighting, clipping.
7. GX FIFO command decode and the FPGA-side frame publication.
8. ARM side: 2D engines and composition, replacing the FPGA 2D path.

Each step gets a native differential gate before it gets a Clash top.

## Seventh block: Gouraud, textured and translucent triangles

Steps 4 and most of 5 above now have pure models and native gates; the
per-pixel back end also has a Clash top. Anti-aliasing, edge marking, fog,
the clear-image (rear-plane) mode, quads and n-gons, and the geometry engine
are still not modelled.

### What the oracle is

The gates compile `../NDS4MiSTer/third_party/melonDS`, which is **melonDS 1.1
plus the NDS4MiSTer fork**, not 0.9.5. Between 0.9.5 and 1.1 upstream changed
exactly the code these gates exercise: interpolation accuracy (#1686), the
swapped-edge and translucent fill rules (#1815, #1816, #1882) and the 4x4
compressed lookup (#2051, slot-1 texel reads return 0, address wrap after
slot 3). Those are hardware-test-derived fixes, so 1.1 is the better reference
and the flat gates already follow it; matching 0.9.5 would mean reintroducing
known errors.

The fork's software renderer has two texture paths. By default it samples a
decoded texture cache and renders modulated interiors through its own fast
path; with the cache off it calls `TextureLookup` and the generic scanline
loop, which is upstream's only path. The scene oracle uses the direct path
(`ORACLE_TEXCACHE=1` selects the cache). The model agrees with the direct path
everywhere. The gate also renders every textured frame through the cache path
and counts its disagreements without failing on them. Four disagreeing
polygons were isolated one by one; each is one of two fork defects (the rest
of the counted pixels were not classified individually):

1. **Cached-interior cursor rewind.** `GPU3D_Soft.cpp:2438-2444` (fork) calls
   `RenderCachedModulateInteriorSpan(rp, y, x, xlimit, ...)` and then sets
   `x = xlimit`. When an unfilled X-major left edge overlaps the right edge's
   piece (`xstart + l_edgelen > xend - r_edgelen + 1`), `xlimit < x` and the
   right-edge loop restarts left of where it should, filling pixels that
   upstream (`for (; x < xlimit; x++)`, never rewinds) and the DS leave empty.
   Measured on one sliver: row 107, X 69-73 drawn only by the cache path.
2. **4x4-compressed texels in slot 1.** The direct path reads index 0 for texel
   data at 0x20000-0x3FFFF (upstream #2051); the decoded cache decodes the
   bytes.

The host oracle is arm64, so the fork's `__arm__ && __ARM_NEON` kernels (the
code the hybrid core runs on the Cortex-A9) are not what is compared.

### The models

- `Nds.Gpu3D.Depth.interpolate`: `Interpolator::Interpolate` for vertex
  colour, texture coordinates and W, perspective (unsigned 32-bit
  `yfactor`) and linear (truncating 64-bit division) branches.
- `Nds.Gpu3D.Raster`: `setupPolygonW`/`prepareRowDepthW` carry the polygon's
  W-buffer flag into the edge interpolators and take a horizontal polygon's
  edges from its minimum- and maximum-X vertices, as `SetupPolygon` does;
  `rowFill` is the left-edge/interior/right-edge split the coverage gate
  already checks, now shared.
- `Nds.Gpu3D.Texture`: `TextureLookup` as three hardware stages: texel address
  (wrap, clamp, flip, slot-1 rules), palette word address and texel alpha, and
  colour (including the 4x4 half and 5:3 mixes). Memory is abstract: halfword
  reads from the 512 KiB texture space and word reads from the 128 KiB palette
  space. Every texel needs at most two texture halfwords and one palette word.
- `Nds.Gpu3D.Shade`: `RenderPixel` (modulate, decal, toon, highlight, shadow
  as decal, wireframe alpha), `AlphaBlend`, and `plotPixel`: the alpha test,
  the opaque write and `PlotTranslucentPixel`'s translucent-ID, shadow
  opaque-ID, fog-flag and depth-update rules.
- `Nds.Gpu3D.Render`: the complete `RenderFrame` reference path from a
  `RenderFrame` (latched registers plus the sorted render list) to the
  `GetLine` output: n-gon edge walk, both layers, anti-aliasing, edge marking,
  fog, the rear-plane clear image, wireframe, toon/highlight, alpha test,
  translucency, shadows and W- or Z-buffer, scanline by scanline. It replaced
  `Nds.Gpu3D.Scene`, which modelled only the top layer of triangles with no
  anti-aliasing, edge marking or fog. Its gate compares both layers and every
  output line against production, 76 cases in the default run and 1,012 in soak.
- `Nds.Gpu3D.ShadePipe`: the per-pixel back end as a 3-stage pipeline
  (texel address, palette address, shade and plot) behind registered memory
  ports, one pixel per enabled cycle, stall by `Enable`. Clash top
  `nds_gpu3d_shade`, checked in at `clash/rtl/nds_gpu3d_shade.v`. The frame
  model calls the same stage functions (`pixelWithMemory`), so the frame gates
  check exactly what the pipeline registers.

### Gates

`run_pixel_gate.sh` gains seven stages: attribute interpolation
(`run_attr_check.sh`, production `Interpolator<0>`/`<1>`), Gouraud frames,
texture sampling (`run_texel_check.sh`, production `TextureLookup`, every
8x8 format x wrap/flip x colour-0 mode swept over texel positions -24..31 plus
random sizes and coordinates), shading (`run_shade_check.sh`, production
`RenderPixel`, exhaustive over blend mode, texture on/off, every
texel/vertex channel pair, every texture alpha x polygon alpha, every RGB555
texel through the direct VRAM path), textured frames, translucent frames, and
the Clash simulation of `nds_gpu3d_shade` against a registered memory, free
running and stalled one cycle in four. Frame stages (`run_scene_check.sh`)
render one directed frame and `SCENE_FRAMES` (default 64) seeded frames of 48
triangles through production `RenderFrame` and compare every pixel on the top
colour, depth and attribute layers. The generator covers horizontal and
single-point polygons, collinear slivers, vertical and right-border edges,
equal, aligned and extreme W, W-buffering, equal-depth tests, 12.4
coordinates far outside the texture, all formats and sizes, polygon IDs drawn
from a small set so translucent-ID collisions happen, depth update, fog flag,
alpha test, wireframe, blending on and off, translucent clear colours, and
shadow volumes (mask then shadow). Textures are uploaded the way a game does:
banks A-D, E, F and G written through LCDC, then mapped to texture and palette
slots; the oracle checks its flat VRAM views equal the image.

`GATE_RESUME=1` lets a restarted gate skip stages that already passed on the
identical tree (HEAD, diff and untracked files); their recorded output is
replayed and marked. Oracle builds are keyed by checkout path, so worktrees
never share a CMake cache.

Mutation check, on the models before the gate was finalised: 36 single-edit
mutants of shading, blending, texel addressing, interpolation, translucency,
stencil, wireframe, edge flags and setup. 34 failed a gate. One is equivalent
(the translucent-ID field mask, whose extra bits are always zero). One
survived, a wireframe shadow mask's alpha test, because no generated mask had
alpha 0; the generator now makes one mask in four wireframe. The sweep was not
rerun after that change.

### Measured

`clash/tests/run_pixel_gate.sh` on commit `6173f26` plus this section, exit 0.
The new stages, verbatim:

```
attr-check: 20000 interpolators, 2423726 samples x 4 values, 0 failures
gouraud-frames: 65 frames of 48 triangles, 0 failures
texel-check: 902464 lookups (A3I5=128543 pal4=128717 pal16=128881 pal256=128934 4x4=129165 A5I3=129020 direct=129204), 0 failures
shade-check: 572352 pixels, 0 failures
textured-frames: 65 frames of 48 triangles, 0 failures
textured-texcache (fork cache path, informational): 46 of 65 frames differ, 46801 pixel layers
translucent-frames: 65 frames of 48 triangles, 0 failures
translucent-texcache (fork cache path, informational): 21 of 65 frames differ, 17619 pixel layers
shade-pipe-check: 2 runs, 100000 pixels compared (58026 writes), 0 failures
```

Every frame compares 49,152 pixels on three layers; the directed frames, for
example: `gouraud0: ... 33600 written pixels, 0 translucent`,
`textured0: ... 37624 written pixels, 3626 translucent`,
`translucent0: 48 polygons (5 shadow masks, 12 shadows), 33532 written pixels,
16137 translucent`. The existing flat stages are unchanged.

### Historical limits at the `SceneCheck` stage

This list was accurate when `Nds.Gpu3D.Scene` was the only frame model. It is
superseded by `Nds.Gpu3D.Render` and `run_render_check.sh` (see "Seventh block"
and the wiring plan), which model and gate anti-aliasing, edge marking, fog,
the rear-plane clear image, X scroll and n-gons of three to ten vertices. The
remaining limits are the items below and the ones stated in the wiring plan.

- Polygons with off-screen Y are not compared; the geometry engine clips them
  before rasterising.
- The fork's cache path and its ARM NEON kernels are not the reference (see
  above).
- DS hardware itself: every claim is "equals melonDS 1.1's reference path".
- The span and edge attribute interpolators have no Clash top yet; only the
  pixel back end does. No Quartus fit of anything in this block.
- The regenerated `nds_gpu3d_flat.v` netlist differs from the previous one,
  not only in source-location comments: `setupLeft`/`setupRight`/
  `prepareRowDepth` are now the W-aware functions applied to `False`, and Clash
  elaborates that differently. The flat path is gated at the Haskell level as
  before; the two Verilog files were not compared by simulation.
  `nds_gpu3d_slope.v` differs only in source-location comments.

### Fit estimate

Yosys `synth_intel_alm -family cyclonev` on `nds_gpu3d_shade.v` (an
estimate, not a fit): 1,016 LUT cells (ALUT2-6 and NOT), 655 carry-chain
cells, 548 flip-flops, 15 MLAB cells (the toon table), 17 DSP blocks (10
27x27, 7 9x9: the 6-bit modulate, decal and blend multiplies). Packing two
LUTs per ALM and two carry cells per ALM, with the registers absorbed, gives
about 900-1,100 ALMs, roughly 90-110 LABs plus one MLAB LAB. The multiplies
can move from DSPs to logic (6x6 bits) if DSPs run short; the core uses 51 of
112.

Not synthesised, estimated by structure:

- Span interpolation: one perspective factor per pixel, a quotient of at most
  9 bits over a 24-bit denominator (9 restoring steps, about 120-250 ALMs
  unrolled or ~40 iterative at 9 cycles per pixel), plus five attribute
  multiply-shifts (16x9 bits, DSP or ~150 ALMs).
- Edge interpolation per row: the same for two edges along Y, iterative.
- Line buffers: colour, depth, attribute and stencil for one scanline (about
  80 bits x 256), double-buffered: 4-6 M10K. The core is at 536 of 553 M10K.
- Texture cache in front of the SDRAM texture slots and control: 2-4 M10K,
  ~200 ALMs.

Total for the new units: roughly 1,700-2,300 ALMs, 170-230 LABs, 8-12 M10K.
The shipping audio image closes by about 2 LABs, so this does **not** fit
next to the current FPGA 2D path; it needs the 2D-to-ARM inversion this
document plans (or the HDMI/audio trade-offs in `CLAUDE.md`).

### Wiring plan

Every block now exists twice: a pure model gated against melonDS at its own
boundary, and a Clash hardware entity gated against that model.

| block | model (gated vs melonDS) | hardware entity | Verilog |
| --- | --- | --- | --- |
| GX registers and FIFO | `Nds.Gpu3D.GxFront` | `nds_gpu3d_gxfront` | `rtl/nds_gpu3d_gxfront.v` |
| geometry engine | `Nds.Gpu3D.Geometry` (`Matrix`, `Lighting`, `BoxTest`) | `nds_gpu3d_geometry` | `rtl/nds_gpu3d_geometry.v` |
| polygon assembly, clip, sort | `Nds.Gpu3D.Polygon` (`Polygon.Clip`) | `nds_gpu3d_polygon` | `rtl/nds_gpu3d_polygon.v` |
| rasteriser | `Nds.Gpu3D.Render` | `nds_gpu3d_raster` | `rtl/nds_gpu3d_raster.v` |
| whole chip | `Nds.Gpu3D.Chip` | `nds_gpu3d` | `rtl/nds_gpu3d.v` |

`Nds.Gpu3D.Types` carries every value that crosses a block boundary:
`CmdEntry`, `ClipVertex`/`PolyState`/`GeoEvent`, `GxVertex`/`GxPolygon`,
`RenderRegs`/`RenderFrame`, `GeoStatus`, `PipeStatus` and `cmdNumParams`.
`Nds.Gpu3D.Mem` is the 64-bit external memory port all the hardware blocks
use, and `Nds.Gpu3D.PolyRam` owns the polygon and vertex RAM record layout
that the rasteriser reads.

Generate the Verilog with `-fclash-no-escaped-identifiers`. Without it, Clash
emits internal names such as `\c$*#_arg1 `, and Quartus 17 rejects them as
illegal names (`Error (12098)`).

#### Fits, standalone, no pins, `5CSEBA6U23I7`

| block | ALMs | registers | M10K | DSP | slack at 100.5 MHz | slack at 33.51 MHz |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| GX front end | 1,200 | 691 | 8 | 0 | -0.60 ns | - |
| geometry engine | 10,150 | 15,923 | 4 | 14 | -15.03 ns, TNS -95,890 | **+3.64 ns** |
| polygon pipeline | 4,889 | 2,138 | 4 | 3 | -13.44 ns, TNS -9,794 | **+4.46 ns** |
| shade back end | 1,187 | 945 | 0 | 24 | -18.47 ns, TNS -746 | **+1.11 ns** |
| rasteriser | 15,382 | 11,253 | 34 | 112 (all) | -43.29 ns, TNS -92,077 | -22.74 ns, TNS -17,288 |
| **all five, one entity** | **30,514** (clk1x) | 32,378 | 50 | 108 | -41.97 ns, TNS -282,301 | -22.16 ns, TNS -24,458 |

The composed entity is `nds_gpu3d` (`rtl/nds_gpu3d.v`, Yosys 39,484 LUT / 11,705
carry / 16,832 FF / 90 multipliers / 33 M10K). It fits at 30,514 ALMs at
`clk1x`, a little under the 32,808 the five fits sum to, because the blocks
share registers across their boundaries.

`clash/tests/remote_quartus_block.sh <block>` fits one block (a `3x` suffix
fits it at `clk1x`); `gen_quartus_block_project.sh` writes its project.

**The whole engine does not fit, and it is not close.** Moving both 2D engines
to the ARM frees 14,525 ALMs and leaves about 15,529; the five blocks want
32,808 ALMs, 50 M10K and 153 DSP blocks against 112, so ALMs are 2.1x over and
DSPs 1.37x over. The rasteriser alone is 15,382 ALMs, 34 M10K and every DSP
block in the device.

Timing is also still open, and it points the other way from area: the rasteriser
is the one block that *needs* 100.5 MHz (its mean frame is 565,837 cycles, 33.7%
of the budget, which does not fit in the 559,000 cycles a frame has at `clk1x`)
and it misses that clock by 43 ns; every other block closes at `clk1x`. So the
rasteriser needs pipelining to close at 100.5 MHz, and the rest should run at
`clk1x` where they already close.

What that leaves for the inversion plan: the pixel path is the only part that has
to be on the FPGA, because it is the only part whose work is proportional to
pixels. The vertex path (geometry) is 10,150 ALMs for work proportional to
vertices and belongs on the HPS ARM, as melonDS's hybrid core already splits it.
Shrinking the rasteriser is the other lever: its 112 DSP blocks come from
`Shade`'s 6-bit multiplies (decal, modulate, blend) and the 32-bit products
around them, and its interpolators divide per pixel where the DS pipeline divides
once per span.

To connect this unit:

1. **Registers** (ARM9 I/O, `nds_membus9`): DISP3DCNT `0x04000060`;
   EDGE_COLOR `0x04000330`; ALPHA_TEST_REF `0x04000340` (melonDS latches
   `AlphaRef = DISP3DCNT bit 2 ? ALPHA_TEST_REF : 0`, `GPU3D.cpp:3246-3248`,
   and copies it to the render state at frame start, `:2909-2922`);
   CLEAR_COLOR `0x04000350`, CLEAR_DEPTH `0x04000354`; FOG `0x04000358-0x0400037F`;
   TOON_TABLE `0x04000380-0x040003BF` (the back end's toon write port);
   GXFIFO `0x04000400` and the command ports `0x04000440-0x040005CC`
   (POLYGON_ATTR `0x4A4`, TEXIMAGE_PARAM `0x4A8`, PLTT_BASE `0x4AC`, COLOR,
   TEXCOORD, VTX_*, BEGIN/END_VTXS, SWAP_BUFFERS `0x540`, VIEWPORT `0x580`);
   GXSTAT `0x04000600` and RAM_COUNT `0x04000604`, with the GX FIFO DMA mode.
2. **Geometry engine**: `Nds.Gpu3D.Geometry` (all commands, matrix stacks
   with the overflow flag, lighting with the shininess table, texture-coordinate
   generation, the vertex transform, BOX/POS/VEC tests and the result
   registers) and `Nds.Gpu3D.Polygon` (primitive assembly for triangles,
   quads and both strips, culling, the six-plane clip, the viewport transform,
   W normalisation, FinalZ, polygon and vertex RAM of 2,048 polygons and 6,144
   vertices, and the SWAP_BUFFERS sort). Both models are gated against
   melonDS at the exact entry and event boundaries.
3. **Rasteriser**: `Nds.Gpu3D.Render` renders one latched frame per frame
   time exactly as `SoftRenderer3D::RenderFrame` does, n-gons of three to ten
   vertices included, and the hardware block reproduces it from a line buffer
   pair plus the two-line stencil. Pixels of one polygon never alias on a line;
   between polygons on the same line the shade back end must drain (three
   cycles) or forward, because it reads the destination at its input and
   writes it three cycles later.

4. **Memory**: texture slots are VRAM A-D, which live in SDRAM behind
   `nds_vram`'s renderer server (`sdram ch1`, 64-bit lines, one request in
   flight, `docs/MEMORY_MAP.md`). The back end's two halfword ports need a
   texture cache in front of a new renderer channel, and a cache miss stalls
   the pipeline. Palette slots are VRAM E, F and G, already M10K in
   `nds_vram`; the palette word port is a read port on them (exclusive with the
   2D extended-palette use by VRAMCNT mapping). Polygon and vertex RAM (about
   100-170 KB) do not fit in M10K: a DDR3 window beside the framebuffer at
   `0x0FE00000` with a per-scanline active list in M10K, on a new `ddram`
   channel or time-shared with the debug channel.
5. **Output**: the finished line feeds engine A's BG0 (DISPCNT bit 3) with
   BG0HOFS as the 3D X scroll; on today's FPGA 2D path that is a line-buffer
   read port into `nds_gpu2d`'s BG0, after the inversion it is a DDR3 line for
   the ARM compositor.

What is still missing for a 3D game to show on screen: wiring `nds_gpu3d` into
`nds_top` (the ARM9 I/O window, the VRAM texture and palette read channel,
the DDR3 window for polygon and vertex RAM and the output lines, the GXFIFO DMA
start mode 7 and IRQ bit 21), the 2D-to-ARM cutover that frees the ALMs, and a
real fit of the whole chip.

## Imported source hashes (2026-11-16)

Import-time `sha256sum` snapshot, relative to `clash/`; these are **not**
claims about post-import working-tree bytes. Manifest hash:
`be147def3771a7e739c484e16a1cf14a8b4280366f5ecc0f657bf9fe66e2d4fa`.

```
1bf0d198b8c2b54733de0e3131204567b1670d461da759726c549f395eb15b01  src/Nds/Gpu3D/Budget.hs
2d01d75dd277ba6d47661cb0be6f01120278cb581accac9dc0f8832512636e39  src/Nds/Gpu3D/Chip.hs
58d8529c63d61a2c46fcf4d330e679d329c9a15a6647c6a5d004e71f3a25ea60  src/Nds/Gpu3D/ChipHw.hs
7489d8c2edc5394459c19a45f78bec8bfbbf3a482095958c9497a33ac4abe8d2  src/Nds/Gpu3D/Depth.hs
d2b6198e9f03ef2647dcc22c756f81361c7441884cf778071f8514733aa633bc  src/Nds/Gpu3D/DepthPipe.hs
d202b8106d8e6529b8960e7653bd8c63f17800140fde8230cb759a6bf308f568  src/Nds/Gpu3D/Flat.hs
cc4b8c5724fe2b0b055f8218836e97197349f9bb2a836438c23e5b5a8bdccd71  src/Nds/Gpu3D/Frame.hs
11a2616913176a5d28bb3e259458a68120d6d4addb57e8a1dc42752ffb6b9248  src/Nds/Gpu3D/Geometry.hs
71240db61537da195971e5da5586fb4bed23a91e5b193ba9dbd4fbee9f9cccfb  src/Nds/Gpu3D/GeometryHw.hs
401e139358ae87706a2af365f5734705ad1d3e84af6d2d10f8d00ba2e83fbbaa  src/Nds/Gpu3D/GxFront.hs
1ad2c34e64e56a481dc800fb0bf9d679d7f5e43cf4306c242c0b547546823448  src/Nds/Gpu3D/GxFrontHw.hs
1c8e2a2f6041696926141f643b532ea60d279f1cfbfa520cf5c8fb6c61cf64fa  src/Nds/Gpu3D/Mem.hs
e41bbf09b0d85c2b45c410251bfff5e6fa7c69dc821ffb6d00646108efb00f43  src/Nds/Gpu3D/PolyRam.hs
18da850d0e123bbeb82f32e62aad62e4bcd93610255b7e1ae1580b8eb0c0bd7c  src/Nds/Gpu3D/Polygon.hs
13bd9095198cf204e2ea2e48b02272656477703462475940c139db37fc06c6b3  src/Nds/Gpu3D/PolygonHw.hs
50f02229a11848be6b4415d7704a7778f70a2b61d00ab810d1bc916d0f29622b  src/Nds/Gpu3D/Raster.hs
3afe2f1f4b2c94975e64fd2cf54adc120a1dde089e8d260f430e2b33d47e8538  src/Nds/Gpu3D/RasterHw.hs
bff82835dbf76abcadc3f56cde7aa9cc03cc20216ed91ffeac5809b381125e8f  src/Nds/Gpu3D/Render.hs
ff6273f80a9608eea52bb39db752eda1ccd07f80465e45de215458ea684abcf5  src/Nds/Gpu3D/Shade.hs
70b585bfc951dbc70ed632403c57b227e0d4fa47a9af534be497ce0938341dc3  src/Nds/Gpu3D/ShadePipe.hs
193a56467ab7e1968d720c9c6130395bc317a1c69274578578a25a2b144bdb94  src/Nds/Gpu3D/Slope.hs
0c6d6efe29ae7d85b8014184468f492b4ba8be79b90d132b9d6c5dc95743881f  src/Nds/Gpu3D/Texture.hs
c341786e305bc8d2744b7ffbe6bde3dd402261f28b89091677cdbc3a5a6f927e  src/Nds/Gpu3D/Top.hs
3b2bc38be5d700d19d054da3512788c33ae17acadf76cc4262cb1242ba2e7607  src/Nds/Gpu3D/Types.hs
34bcbf1e8eab3219e757d95b7f0f815ebc835d864fc8303dbe7261c201c846dd  src/Nds/Gpu3D/Geometry/BoxTest.hs
c037d2bbaab10d17d4c494c4864e2b2d8a57e909debc9785fc07f6eb6d3fbe46  src/Nds/Gpu3D/Geometry/Lighting.hs
96136f134902cf0ade228b1f455d9697b3c92290b26e69271bb8bcebee1121b7  src/Nds/Gpu3D/Geometry/Matrix.hs
4bccc933828e3b9949032e74fef4b396f91a1d84507114a840d95a52b6bc9d8d  src/Nds/Gpu3D/GeometryHw/Event.hs
704393bd64c1b7bec1408efe07218d6c1341aa6d8c9c566b8835d500ef9c8b31  src/Nds/Gpu3D/Polygon/Clip.hs
a92fafccb4c6e9703f8c4abaffa98ff5d7408c33ad3ca53c2fb17ba86f064f88  src/Nds/Gpu3D/RasterHw/Front.hs
a5b0d2afea43ed6673303ff2b3841fec290a4c18974f6c0e2b89ba642c176c1f  src/Nds/Gpu3D/RasterHw/Line.hs
a3eb98cadc70e29e152acdbd1cf0d75752d6a458c40fc2613c4d22b5908b3023  src/Nds/Gpu3D/RasterHw/Pixel.hs
8116c475d2ae77d70fc227918351ab39a17b1ee2ee1c94e5a8285245778c8797  src/Nds/Gpu3D/RasterHw/Setup.hs
9502b305083d26c5b7dd94cb3fe16364406a70e5e46330509809bfc1d85384ca  src/Nds/Gpu3D/RasterHw/TexCache.hs
5cca6fc8f49012c2cada633454c2c445ac2beb5b1845104f47a27047520faed2  src/Nds/Gpu3D/RasterHw/Types.hs
```


### Post-import corrected source hashes (2026-11-17)

These identify the corrected host sources, separately from the immutable
import snapshot above. `TraceReplay.hs` is a new v12 replay bridge, not an
unmodified member of the original 35-file import. `GxFrontHw.hs` remains at
its imported hash; front-end integration fixes live in `ChipHw.hs`.

```text
b8f791017c8435984cf4d04cebeda85bbd624ffa2a69eeb6b15fcb09d0a0f3a4  clash/src/Nds/Gpu3D/ChipHw.hs
4946469ff3b091c80e4132f1306b19b0b54f04e2cafeec73cd69f45191f0d656  clash/src/Nds/Gpu3D/GeometryHw.hs
1baf122bd8d9e37d35148bf26f6d88e20b988fd9520adb50e84a5f7cb3ce473e  clash/src/Nds/Gpu3D/RasterHw/Front.hs
89be1584cb71b74c99e4644ac498db85a01791f56638ac8e15de5f210598fb08  clash/src/Nds/Gpu3D/RasterHw/Setup.hs
c186b6be88d76eec0fbdb52c0e2ef167dd5d417ef638a532a6691e2f017899d4  clash/src/Nds/Gpu3D/TraceReplay.hs
375192dd465db8069b9d84f6182fb478975dfe6f85034a0ee6e095eb6708c410  clash/test/ChipHwCheck.hs
17c76319e8dd7e0b78283b100b7c0e8d595878768095fdb45cae180dc17e7334  clash/test/ChipHwReference.hs
a4f25dec771395ce742eb5ff169533b8fc48149960153b641f74c57ded020ec6  clash/test/ChipHwGeoSchedule.hs
24c136df4f853718cfbf1aedf6701f06289b1f62bac40ba3b58ff1312ceaf6fa  clash/test/ChipHwGeoScheduleCheck.hs
```
