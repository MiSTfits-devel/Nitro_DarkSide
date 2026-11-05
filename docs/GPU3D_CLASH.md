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
  src/Nds/Gpu3D/Top.hs
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

Measured: 99,620 downward edges, zero failures. Upward edges are excluded
because the production polygon walk only presents downward edges to the
interpolator. The same gate checks 200,000 W-normalization and `FinalZ`
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
