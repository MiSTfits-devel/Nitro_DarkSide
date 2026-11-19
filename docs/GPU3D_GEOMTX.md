# Compact geometry experiment: the geometry engine in block RAM

`clash/src/Nds/Gpu3D/GeoMatrix.hs` (Clash top `nds_gpu3d_geomtx`) tests one
idea from the GuardianSoul Pocket DS core (`rtl/gpu3d/gpu3d_gxeng.sv`): keep
the geometry engine's state in block RAM and share one arithmetic datapath
over time, instead of holding matrices in registers and LUT RAM. It is an
experiment beside `Nds.Gpu3D.GeometryHw`, not a replacement: neither the
existing engine, the model, the chip composition nor any shared build file
was changed. It grew in three steps, each gated and fitted:

1. the matrix and stack commands;
2. the vertex transform and the event stream;
3. (the current source) the rest of the geometry engine: lighting, the
   material and light registers, texture-coordinate mode 2, the box,
   position and vector tests with their result registers, and the swap with
   its VBlank wait.

Step 3 is the whole geometry engine, so its fit compares like for like with
the existing `nds_gpu3d_geometry`.

## Scope

Every command of the authoritative model `Nds.Gpu3D.Geometry` (after
`Nds.Gpu3D.Chip.gatherEntry`), which `run_geometry_check.sh` ties to melonDS:

- the matrix and stack commands `MTX_MODE` .. `MTX_TRANS` (0x10-0x1C), in all
  four modes;
- `COLOR`, `NORMAL` (up to four lights, and texture-coordinate mode 2),
  `TEXCOORD` (all four modes), `VTX_16`, `VTX_10`, `VTX_XY`, `VTX_XZ`,
  `VTX_YZ`, `VTX_DIFF`, `POLYGON_ATTR`, `TEXIMAGE_PARAM`, `PLTT_BASE`;
- `DIF_AMB`, `SPE_EMI`, `LIGHT_VECTOR`, `LIGHT_COLOR`, `SHININESS`;
- `BEGIN_VTXS`, `END_VTXS`, `SWAP_BUFFERS` with its VBlank wait, `VIEWPORT`;
- `BOX_TEST`, `POS_TEST`, `VEC_TEST` and their results;
- opcodes melonDS ignores (no effect), `ExecParams` gathering including
  another multi-word opcode retagging a non-final entry;
- stack pointers, stack-overflow error, the `GXSTAT` bit-15 acknowledge,
  `GXSTAT` bits 0, 1 and 8-15 and the busy bit;
- every result read at `0x04000620`-`0x040006A3` (`POS_RESULT`,
  `VEC_RESULT`, `CLIPMTX_RESULT`, `VECMTX_RESULT`).

The model's `Normal` register is not kept: nothing reads it after its
`NORMAL` has run, so the engine has no copy and the gate cannot compare it.
Everything else melonDS records is compared.

## Structure

| | compact (`nds_gpu3d_geomtx`) | existing (`nds_gpu3d_geometry`) |
| --- | --- | --- |
| matrices, one-slot stacks, 32-slot stacks | one 512 x 128-bit block RAM of rows (4 x s32 lanes) | LUT RAMs per matrix group, two 512 x 32 stack block RAMs |
| light directions and reciprocals, shininess table, box corners, clip buffers, test results | rows of the same RAM | LUT RAMs and registers |
| gathered parameters | 32 x 32 block RAM | 4-bank LUT RAM |
| vertex state, material and light colours, lighting temporaries | registers | registers |
| arithmetic | four 32 x 32 multipliers, four 44-bit accumulators | four-lane multiply unit (lane 0 is 34 x 33) |
| divider | `Nds.Gpu3D.GeoDiv`: `GeometryHw`'s radix-4 divider | radix-4 divider |
| events | `HwGeoEvent` in one valid/ready output register | the same encoding and handshake |
| power-on contents | 512-cycle write sweep | 512-cycle write sweep |

**Arithmetic.**

- *Matrix, vertex and test work* is "scalar x row". In one cycle, one RAM row
  is multiplied by one scalar and added to four 44-bit accumulators. The
  scalar is one of:
  - a parameter word;
  - a lane of a latched row;
  - a vertex, normal or box-corner coordinate;
  - `0x1000` or 1.
- *Result windows.* A finished sum is read as one of these bit ranges:
  - [12, 44): matrices and positions;
  - [24, 40) plus the raw coordinate: texture mode 3;
  - [21, 37) plus the raw coordinate: texture mode 2;
  - [12, 28): texture mode 1;
  - [12, 23): the normal and the light directions;
  - [9, 25): the vector test.
- *Lighting* drives the four multipliers with separate operands. It takes
  seven issue cycles per enabled light; `litA`/`litB` list them.
- *The two operand vectors are two separate case expressions.* When they
  were one case returning a pair, Clash copied the multipliers into the
  alternatives. The first step-3 netlist had nine 32 x 32 product sites:
  - eight from that copying;
  - one from a 64-bit `8 * byte index` shift amount.

  The gate's guard (exactly four sites) caught both.
- *The clip matrix* is recomputed at the end of every command that changes
  the projection or position matrix.

**The divider.** Only one command needs a division:

- **`BOX_TEST`** uses it for every interpolation of its face clipping,
  computed exactly as `Nds.Gpu3D.Polygon.Clip` does:
  - `vin + (vout - vin) * num / den`, a 64 / 32 division;
  - the NDS4MiSTer fork's widened denominator, which is exactly ±2^32 and
    therefore a shift.

  The 33 x 32-bit product is formed as four partial products on the same
  four multipliers.
- **`LIGHT_VECTOR`** shares the divider for its specular reciprocal
  `2^18 / den`.

The divider is `GeometryHw`'s algorithm. It lives in its own module,
`clash/src/Nds/Gpu3D/GeoDiv.hs`, so that only one copy has to be kept when
the existing engine is retired. `GeometryHw` does not export its divider, so
the gate checks two things instead:

- the definitions of `DivSt`, `divStart`, `divDone` and `divStep` are the
  same text in both files;
- the divider gives the reference results on random and edge operands (see
  Gate).

**Box test.** Face clipping is `GeometryHw`'s algorithm:

- it interpolates only the components a later pass reads;
- the X pass's -W half is decided by `x >= -w` while the +W half writes.

The algorithm runs over the RAM's corner and clip-buffer rows. A new half or
face spends one extra cycle so that no row is read in the cycle it is
written.

**Interface.**

- **Command entries** arrive on a valid/ready stream. Ready is a function of
  the state only, and is high only when:
  - no command runs;
  - the pipeline is empty;
  - no swap waits.
- **Events** leave from one valid/ready output register. An event-producing
  command does not finish until its event is in that register, so events
  leave in command order and a consumer holding `EV_READY` low holds the
  engine.
- **`STALL`** (the polygon pipeline is busy) holds back:
  - `BEGIN_VTXS`'s event;
  - the start of `LIGHT_VECTOR` and `BOX_TEST`.

  This follows melonDS's `StallPolygonPipeline` callers, as `GeometryHw`
  does.
- **The swap wait.** After `SWAP_BUFFERS`, no entry is taken until a
  `VBLANK` pulse arrives in a cycle after the swap event was transferred.
- **Result reads** are valid/ready, with data one cycle after the read is
  taken. They are taken whenever no command runs, during a swap wait too.
  The existing engine answers reads combinationally.
- **`ZERO_DOT_W`** is `ZeroDotWLimit` as the front end holds it. It is read
  into each vertex event.

**Netlist rules.** Constructor tests use pattern matches, never derived `==`
on sum types: the generated Verilog leaves unused payload bits undefined.
Control, vertex registers, lighting, pipeline and the event register are
five registers built separately.

## Gate

```sh
TIMING=1 clash/tests/run_geomatrix_check.sh
```

`clash/test/GeoMatrixCheck.hs` and `clash/tests/geomtx_cosim.cpp`; see the
script header.

The gate builds the checked-in melonDS oracle and generates its directed
and seeded random streams on each run. No cartridge or captured input is
needed for those checks or for Verilator co-simulation. For the optional
cartridge comparison, set `TRACE` to a local v12 NSD2 capture; the runner
looks for `ntr-v12.nsd2` under `/tmp/nds-v12c` by default and reports a
skip if the input is absent. The capture is not tracked.

- **Every stream runs whole.** Nothing is dropped. The model of the whole
  stream is the reference for every output.
- **melonDS** is compared on every record of the directed and random
  streams:
  - matrices, stack hash, pointers;
  - `GXSTAT` bits 1 and 15;
  - the vertex state, the four lights and the material;
  - the shininess table;
  - the position and vector test results;
  - every stored vertex;
  - all 33 result words.

  The cartridge stream has no melonDS record, so it is checked against the
  model only.
- **The pure step** (with a block-RAM model) and **the Clash circuit** run
  under one closed-loop driver with:
  - random entry gaps;
  - a random event ready (35% of cycles low);
  - a random polygon stall in bursts;
  - random VBlank pulses, plus one soon after every waiting swap.

  The runs check:
  - every transferred event, in order;
  - the status after every input;
  - the whole RAM and every register;
  - the swap wait against its VBlank (no entry while it waits, no release
    without a VBlank);
  - the circuit's outputs against the pure step's, every cycle, in lock step.
- **The divider** is checked as follows:
  - its definitions are compared with `GeometryHw`'s source;
  - 400,072 64 / 32-bit quotients, including edge operands, against `quot`;
  - all 4,096 `LIGHT_VECTOR` denominators, zero included, against
    `2^18 quot den`;
  - 83,612 box-test interpolations through the whole operand path against
    `Polygon.Clip.interpolate32`. These cover both planes, all sign cases,
    and 33,451 constructed wide denominators.
- **The existing engine** (`time`) runs the same entries back to back. As
  they happen, its events and its architectural `GXSTAT` bits (`& 0xBF02`)
  after every command are compared with the model's, the same model the
  compact engine is held to. Then the two engines' event and command counts
  must be equal.

**Memory.** The checker never holds more than one stream per worker:
- it reads a stream file one stream at a time, with unboxed records;
- at most four workers run;
- every comparison above is made as the cycle happens, folded into strict
  counters;
- each stream keeps at most 12 messages;
- the cosim trace is piped into the Verilator bench, so it is never written
  to disk. The bench fails a trace that lacks its end trailer.

The gate runs every checker call with `+RTS -N4 -M3g`, so a retention bug
fails the gate instead of exhausting the machine.

The first step-3 checker kept every stream, and both runs' per-cycle
outputs, until the end. On the 237 MB random file it exhausted a 3 GB heap
within 18 s; uncapped, it would have needed about 16 GB.

| stream | max residency | max RSS |
| --- | ---: | ---: |
| directed | 3.6 MB | 45 MB |
| random | 95 MB | 322 MB |
| cartridge | 1.1 MB | 36 MB |

These are the streaming checker's figures. All counts are identical to the
earlier runs.

Observed on 2026-11-18 (melonDS oracle from `third_party/melonDS`, seed 1),
the current source:

| run | inputs | events (vertices; swaps) | checked | result |
| --- | ---: | ---: | --- | --- |
| directed (11 streams) | 1,364, all with melonDS records | 300 (273, all vs melonDS; 4) | 1,364 whole-state checks vs model and melonDS, 45,012 result reads vs both, pure = Clash | 0 mismatches |
| random (50 x 4,000) | 200,016, all with melonDS records | 40,350 (32,094, all vs melonDS; 854) | 200,016 whole-state checks vs both, 6,600,528 reads vs both, 18,259,163 cycles (21,973 event-wait, 9,134,466 stall, 15,628 swap-wait) | 0 mismatches |
| random, interleaved `ExecParams` | 200,053 run | 41,032 (32,776; 854) | model only | 0 mismatches |
| cartridge stream | 338 | 55 (48; 2) | model only | 0 mismatches |
| existing engine, same streams | 201,718 | 40,705 | the same events, 194,817 post-command `GXSTAT` values | 0 differences |
| divider | | | 4 definitions, 400,072 quotients, 4,096 reciprocals, 83,612 interpolations | 0 wrong |
| generated Verilog, Verilator | 61,495 + 1,454,886 cycles (4 directed + 4 random streams) | 215 + 4,958 (1,288 swap-wait cycles) | every output every cycle, 330-bit events, 21,879 + 528,066 reads | 0 mismatches |
| mutants | 9 | | stack-error bound 1,356; `MULT_4x3` column 2,203,904; `VTX_DIFF` sign 894,374; texture mode-3 window 7,390; specular window 13,448; unlit diffuse 65,252; box far-plane rule 48,294; `VEC_TEST` bit 12 486,032; wide denominator 33,451 wrong | all detected |

The random streams contain:

| command | count |
| --- | ---: |
| `NORMAL` | 9,505 (6,882 with three or four lights) |
| `BOX_TEST` | 6,943 |
| `LIGHT_VECTOR` | 5,354 |
| `POS_TEST` | 4,409 |
| `VEC_TEST` | 4,276 |
| `SHININESS` | 1,250 |
| `SWAP_BUFFERS` | 854 |

The cartridge stream came from a local v12 capture of the NTR test cartridge.
Its 550 raw GX bus writes, replayed through
`Nds.Gpu3D.Chip`'s front end, make 338 geometry inputs:

| input | count |
| --- | ---: |
| commands | 334 |
| — vertices | 48 |
| — `NORMAL` | 48 |
| — lighting setup | 7 |
| — swaps | 2 |
| acknowledges | 4 |

Yosys sees exactly two inferred memories (512 x 128 and 32 x 32) and four
32 x 32 product sites.

## Resources and timing

**Flow.**

- These are local standalone fits (no pins, `5CSEBA6U23I7`,
  Quartus 17.0.2) on fresh Clash output. The fit workspace supplied a
  `geomtx3x` case to the Quartus block flow; that case is not in the
  checked-in scripts, so the fits are not reproducible from the repo alone.
- **The 100.5 MHz row.** A separate local fit workspace used a pre-written
  project:
  - its project was pre-written by the unmodified
    `gen_quartus_block_project.sh geomtx3x nds_gpu3d_geomtx
    nds_gpu3d_geomtx.v` with `CLOCK_NS=9.946`, which is the generator's
    default, the shipping 3D island clock;
  - the driver then uses that project as it is;
  - the qsf is identical to the 3x one; only the SDC period differs.
- **The baseline** is `Nds.Gpu3D.GeometryHw` generated fresh (SHA-256
  `355f096623ac48c40940ebb06f57a3ed8ac4352c4f78528cae188cb05b82ffab`),
  because the checked-in `clash/rtl/nds_gpu3d_geometry.v` no longer matches
  its source.

| netlist | commands | constraint | ALMs | registers | M10K | DSP | worst setup | worst hold |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| compact step 1 | matrix/stack only | 29.838 ns | 703 | 390 | 8 | 13 | +16.374 ns | +0.166 ns |
| compact step 2 | matrix/stack + vertex + events | 29.838 ns | 1,424 | 1,217 | 8 | 13 | +15.400 ns | +0.140 ns |
| **compact step 3 (current)** | **full geometry** | **29.838 ns** | **3,643** | **2,387** | **8** | **13** | **+10.338 ns** | **+0.140 ns** |
| compact step 3 (current) | full geometry | 9.946 ns | 3,661 | 2,387 | 8 | 13 | **-6.230 ns** | +0.165 ns |
| existing engine | full geometry | 29.838 ns | 10,125 | 15,923 | 4 | 14 | +1.770 ns | +0.116 ns |

**Netlists** (SHA-256):

| step | netlist |
| --- | --- |
| step 1 | `8bdfe54d3f347c4a710e40b4abca341724232740706f1dd21ed3d1b4fd9165e8` |
| step 2 | `cb63da84a0ff82de595c114495852af74c02125adf7857a10298f49fae9dba58` |
| step 3 | `1cdd4da224b8f07422470acd1403b84a670d2cd4c7539686d03b67696ef15bb7` |

The step-3 netlist is the one both fits used, and the final gate run
(`TIMING=1`, every checker call under `+RTS -M3g`, 0 failing runs)
regenerated it with the same hash.

**At clk1x (33.51 MHz)** all 12 corner/analysis slacks are non-negative.

**At 100.5 MHz** the two slow-corner setup slacks fail:

| slow corner | worst setup |
| --- | ---: |
| -40C | -6.230 ns |
| 100C | -6.048 ns |

The ten others are non-negative. That makes the achievable clock
1 / 16.176 ns = **61.8 MHz**. The +10.338 ns at clk1x is a relaxed-constraint
figure (19.5 ns of path, about 51 MHz), not the limit.

**Critical path.** In both fits it is the box-test face clipper's
controller, all in one cycle:

1. a 32-bit plane distance and compare on the RAM row or the working
   vertex;
2. the next clipping phase;
3. the row RAM's next read address.

**A 2x clock (67.0 MHz, 14.92 ns) is not met as built**, by about 1.3 ns.
It looks like the sweet spot all the same:

- registering that compare (one more cycle per clipped vertex step) is the
  obvious cut;
- at 2x the whole streams run at about half of melonDS's charge (Latency).

Nothing in this experiment builds that clock.

**Against the existing engine.** The whole engine fits in 3,643 ALMs and
2,387 registers against 10,125 ALMs and 15,923 registers, with four more
M10K and one fewer DSP block.

**Against the 3D envelope of `Nds.Gpu3D.Budget`**, at clk1x:

| resource | used | envelope | headroom |
| --- | ---: | ---: | ---: |
| ALMs | 3,643 | 3,959 | 316 |
| M10K | 8 | 102 | 94 |
| DSP | 13 | 41 | 28 |

## Latency

Cycles from a command's first entry to the engine accepting the next entry.
The streams were fed back to back: entries always offered, event always
ready, no stall, and a VBlank one cycle after a swap starts waiting.
Measured with `geomatrix-check time` on the random streams; every class has
the same value for all its instances unless a range is given.

- **melonDS** is the vendored core's charge for the command in isolation:
  one cycle per entry plus its `AddCycles`, without the vertex/normal
  pipeline overlap. It is not a hardware measurement.
- **1x / 2x / 3x** say whether the compact engine's worst case is within
  1, 2 or 3 times that charge. That is the budget the GX front end's
  melonDS timing gives an engine clocked at 33.51, 67.0 or 100.5 MHz.

| class | compact | existing | melonDS | 1x | 2x | 3x |
| --- | ---: | ---: | ---: | --- | --- | --- |
| `NORMAL`, 0 lights | 6 | 5 | 2 | miss | miss | ok |
| `NORMAL`, 0 lights, texcoord mode 2 | 9 | 8 | 2 | miss | miss | miss |
| `NORMAL`, n = 1-4 lights | 7n + 7 | 7n + 6 | n + 1 | miss | miss | miss |
| the same, texcoord mode 2 | 7n + 10 | 7n + 9 | n + 1 | miss | miss | miss |
| `LIGHT_VECTOR` | 7-17 | 6-16 | 6 | miss | miss | ok |
| `SHININESS` | 42 | 41 | 32 | miss | ok | ok |
| `DIF_AMB`, `SPE_EMI`, `LIGHT_COLOR` | 1 | 1 | 4, 4, 2 | ok | ok | ok |
| `BOX_TEST` | 50-3,758 (mean 214) | 3,536 max (mean 199) | 257 | miss | miss | miss |
| `POS_TEST` | 8 | 7 | 7 | miss | ok | ok |
| `VEC_TEST` | 6 | 4 | 5 | miss | ok | ok |
| `SWAP_BUFFERS` | 5 | 4 | 1 | miss | miss | miss |
| `VTX_10` / `XY` / `XZ` / `YZ` / `DIFF` | 8 | 6 | 4 | miss | ok | ok |
| the same, texcoord mode 3 | 11 | 9 | 4 | miss | miss | ok |
| `VTX_16` | 9 | 8 | 5 | miss | ok | ok |
| `VTX_16`, texcoord mode 3 | 12 | 11 | 5 | miss | miss | ok |
| `BEGIN_VTXS`, `END_VTXS` | 2 | 1 | 1 | miss | ok | ok |
| `TEXCOORD` mode 1 | 7 | 2 | 1 | miss | miss | miss |
| `COLOR`, `TEXCOORD`, attributes, `VIEWPORT`, `MTX_MODE` | 1 | 1 | 1 | ok | ok | ok |
| `IDENTITY` mode 0/1, 2, 3 | 27, 31, 7 | 21, 25, 5 | 19, 19, 1 | miss | ok, ok, miss | ok, ok, miss |
| `LOAD_4x4` mode 0/1, 2, 3 | 54, 70, 34 | 37, 41, 21 | 34, 34, 26 | miss | ok, miss, ok | ok |
| `LOAD_4x3` mode 0/1, 2, 3 | 47, 60, 27 | 33, 37, 17 | 30, 30, 19 | miss | ok | ok |
| `MULT_4x4` mode 0/1, 2, 3 | 58, 78, 38 | 49, 65, 33 | 35, 65, 33 | miss | ok | ok |
| `MULT_4x3` mode 0/1, 2, 3 | 51, 68, 31 | 42, 55, 26 | 35, 65, 33 | miss, miss, ok | ok | ok |
| `MULT_3x3` mode 0/1, 2, 3 | 45, 59, 25 | 36, 46, 20 | 35, 65, 33 | miss, ok, ok | ok | ok |
| `SCALE` mode 0-2, 3 | 28, 8 | 24, 8 | 35, 33 | ok | ok | ok |
| `TRANS` mode 0/1, 2, 3 | 29, 33, 9 | 27, 34, 11 | 35, 65, 33 | ok | ok | ok |
| `PUSH` / `STORE` pos/vec; proj or tex | 11; 7 | 17; 5 | 17 | ok | ok | ok |
| `POP` / `RESTORE` pos/vec; proj; tex | 31; 27; 7 | 34; 21; 5 | 36; 36; 18 | ok | ok | ok |

`SWAP_BUFFERS` includes the bench's one-cycle VBlank latency, and the
existing engine's 4 is measured the same way.

Whole streams:

| streams | compact | existing | melonDS's isolated charges | compact / melonDS |
| --- | ---: | ---: | ---: | ---: |
| directed | 44,742 | 40,660 | 42,305 | 1.06 |
| random | 4,463,787 | 3,906,879 | 4,193,455 | 1.06 |
| cartridge | 3,031 | 2,577 | 1,490 | 2.03 |

The cartridge stream is 48 lit vertices of `TEXCOORD` mode 1, `NORMAL` with
one light and `VTX_16`:

| per vertex | cycles |
| --- | ---: |
| compact | 30 |
| melonDS | 8 |

The existing engine has the same per-class costs within a few cycles. It
misses the same budgets at 3x (`NORMAL`, clipped `BOX_TEST`, `SWAP_BUFFERS`,
`IDENTITY` mode 3), except `TEXCOORD` mode 1, where its separate texture-row
registers give 2 cycles.

## Known timing differences

The compact engine is not timing-exact. **At the clock it closes timing at
(clk1x, 1x)**, these classes take longer than melonDS charges:

- every `NORMAL`;
- `LIGHT_VECTOR` and `SHININESS`;
- `BOX_TEST` with clipped faces;
- `POS_TEST` and `VEC_TEST`;
- `SWAP_BUFFERS`;
- every vertex, `BEGIN_VTXS` and `END_VTXS`;
- `TEXCOORD` mode 1;
- `IDENTITY` and `LOAD` in every mode, `MULT_4x4` in every mode, `MULT_4x3`
  in modes 0-2 and `MULT_3x3` in modes 0 and 1.

**At 2x**, the classes still over budget are:

- `NORMAL`;
- clipped `BOX_TEST`;
- `LIGHT_VECTOR`;
- `SWAP_BUFFERS`;
- `TEXCOORD` mode 1;
- `IDENTITY` mode 3;
- `LOAD_4x4` mode 2;
- texture-mode-3 vertices.

**At 3x**, the classes still over budget are:

- `NORMAL` (except 0 lights without mode 2);
- clipped `BOX_TEST`;
- `SWAP_BUFFERS`;
- `TEXCOORD` mode 1;
- `IDENTITY` mode 3.

These are recorded as known differences, not passes.

**What the guest can observe** is only *when* things happen:

- `GXSTAT` bit 27 (geometry busy) stays high longer after these commands.
  So do bit 0 (test busy) after `BOX_TEST`, `POS_TEST` and `VEC_TEST`, and
  bit 14 (matrix stack busy) after push and pop. A game polling bit 0 for a
  box-test result, or bit 27 before reading the clip matrix, polls longer.
- The GX FIFO drains more slowly. The FIFO level (bits 16-24), "less than
  half full" (bit 25) and "empty" (bit 26) change later, and the GX FIFO
  interrupt fires later.
- When the FIFO and PIPE are full, CPU writes to the GX FIFO or the
  command ports stall the ARM9, and GX FIFO DMA (start mode 7) waits. The
  CPU and the DMA lose time.
- Geometry that ends later can push `SWAP_BUFFERS` past a VBlank, so the
  frame flips one frame later.

**What cannot change**:

- every result: matrices, stacks, vertex positions, colours and texture
  coordinates, light registers, test results, the result registers, and the
  architectural `GXSTAT` bits after a command;
- the order and content of the event stream the polygon pipeline sees.

The gate checks all of these on every stream. It also checks that the
existing engine produces the same events and post-command `GXSTAT` bits.

## Step records

**Step 1** (matrix/stack, netlist `8bdfe54d...`) and **step 2** (plus vertex
transform and events, netlist `cb63da84...`) passed the same kind of gate
on projected streams, with the out-of-slice commands dropped and halting the
engine. The interleaved-gather run in step 2 found one real bug, now fixed:
a `VTX_16` completed inside a longer gather took its z from the completing
entry.

| step | directed / random inputs kept | result reads | other checks |
| --- | --- | ---: | --- |
| 1 | 804 / 87,254 | 2,879,382 | 48,830 + 657,660 Verilator cycles; 2 mutants |
| 2 | 1,155 / 156,903 | 5,177,799 | 60,060 + 1,071,108 Verilator cycles; 4 mutants |

Step 1 also ran Yosys `synth_intel_alm` (informational):

| netlist | LUTs | carry | FF | MLAB cells | M10K |
| --- | ---: | ---: | ---: | ---: | ---: |
| compact | 1,019 | 402 | 567 | 0 | 8 |
| existing | 7,463 | 2,195 | 2,597 | 932 | 4 |

No board was programmed and nothing here is wired into a console build.
