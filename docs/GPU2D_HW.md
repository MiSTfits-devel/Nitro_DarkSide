# Synthesizable 2D tile engine: one text BG and regular sprites

`clash/src/Nds/Gpu2D/TileHw.hs` (Clash top `nds_gpu2d_tilehw`) is the first
synthesizable DS 2D slice in Haskell/Clash that draws tiles: one mode-0 text
background and regular (non-affine) sprites, composed over the backdrop into
one 256-pixel scanline per request. It is built for the mode Kirby: Squeak
Squad was measured to use (`sim/tests/arm9_2dk.s`, lines 1-25): BG mode 0, a
text BG3 on the standard palette, OBJ with 1D mapping and OBJ extended
palettes.

It is a block, not a console integration. Nothing here was wired into a core,
programmed onto a board or compared against hardware. Every result below is
one of: the pure model against the host reference, the Clash simulation
against the pure model, the generated Verilog under Verilator against the pure
model, or a standalone Quartus fit of that Verilog.

The reference is the existing host model, unchanged: `Nds.Gpu2D.Line`
(`bgLine`, `composeLine`, and `renderReferenceLine` wherever OBJ is off) and
`Nds.Gpu2D.Sprite.drawSprites` (the melonDS sprite transcription), its OBJ
line expanded through the palettes exactly as `Nds.Gpu2D.TraceRender`'s
`spritePixelAt` does. `renderReferenceLine` itself is not used with OBJ on
because its `objLine` is a simpler sprite model than `drawSprites` (it has no
1D tile mapping and no OBJ extended palettes).

## Scope

**Supported, bit-exact against the reference** (colour and layer of every
pixel):

- BG mode 0 with zero or one of BG0-BG3 enabled. BGCNT priority, character
  base, screen base, 256-colour bit and all four screen sizes; engine A's
  DISPCNT character and screen base offsets (bits 24-29; engine B has none);
  9-bit H/V scroll with wraparound; tile H/V flip; the 4bpp palette number;
  in 8bpp the palette number is ignored (standard palette). Colour 0 is
  transparent.
- OBJ with 1D tile mapping and its tile-boundary field (DISPCNT bits 20-21).
  Regular sprites of all twelve sizes (and the prohibited shape 3, drawn 8x8
  like the reference), H/V flip, 4bpp with palette number, 8bpp on the
  standard OBJ palette or, with DISPCNT bit 31, the OBJ extended palette with
  the palette number from attribute 2; clipping at both screen edges and the
  8-bit vertical wrap; OAM-order resolution between sprites (a sprite is
  overwritten only by a later one of strictly higher priority); priority
  against the BG (OBJ wins ties); OBJ-window sprites (no colour: windows are
  off); semi-transparent sprites while BLDCNT has no second target (they then
  compose as normal sprites, as in the reference).
- The backdrop (BG palette entry 0) wherever nothing is opaque.
- Engines A and B: palette half, VRAM sizes (BG 512/128 KiB, OBJ 256/128 KiB),
  DISPCNT offsets, display-mode rules.

**4bpp BG tiles are supported**: they cost one extra 4-bit lane select and
share the 8-byte row fetch (a 4bpp row is 4 bytes).

**Unsupported, fail-closed.** A line start whose registers ask for anything
else is refused: `FAULT` gets a bit per reason and the engine halts until
reset, with no pixel of that or any later line. A sprite on the line that the
engine cannot draw halts it the same way when the OAM scan reaches it, which
is before any pixel of the line leaves.

| bit | refused |
| ---: | --- |
| 0 | BG mode not 0 |
| 1 | more than one BG enabled |
| 2 | OBJ on with 2D tile mapping |
| 3 | any window enabled (DISPCNT bits 13-15) |
| 4 | forced blank |
| 5 | display mode not 1 (engine B: not BG/OBJ) |
| 6 | BG0 as 3D (engine A) |
| 7 | colour special effect (BLDCNT bits 6-7) |
| 8 | BG mosaic |
| 9 | 256-colour BG with BG extended palettes (DISPCNT bit 30) |
| 10 | memory response with no request outstanding |
| 11 | semi-transparent sprite on the line while BLDCNT has a second target |
| 12 | affine or double-size sprite on the line |
| 13 | bitmap sprite on the line |
| 14 | mosaic sprite on the line |

Not refused because they cannot change the line: OBJ mapping bits while OBJ
is off, DISPCNT bit 30 with a 4bpp BG, sprites that are disabled or not on
the line whatever their other attributes.

## Interface

All ports are synchronous to `CLK`; `RST` is the Clash system reset.

| port | dir | meaning |
| --- | --- | --- |
| `START_VALID`, `START_ENGINE`, `START_LINE` | in | line start (engine 0 = A, 1 = B; VCOUNT line), taken when `READY` is high |
| `DISPCNT`, `BGCNT` (4 x 16, BG0 low), `HOFS`, `VOFS` (4 x 9, BG0 low), `BLDCNT` | in | register port, sampled only in the cycle a start is taken |
| `READY` | out | idle (or halted): a start is taken this cycle |
| `REQ_VALID`, `REQ_OBJ`, `REQ_ADDR` | out | registered memory request: OBJ or BG VRAM of the started engine, 8-byte word address (byte address bits 18..3) |
| `REQ_READY` | in | the provider takes the request this cycle (backpressure) |
| `RESP_VALID`, `RESP_DATA` (64) | in | response, little-endian, in request order, at least one cycle after the request was taken, any latency; never refused |
| `PIX_VALID`, `PIX_X`, `PIX_COLOR` (BGR555 + bit 15 of the palette word), `PIX_LAYER` | out | x = 0..255 in order, one per cycle, no backpressure; layer 0-3 BG, 4 OBJ, 5 backdrop |
| `PAL_WR_*` (1024 x 16) | in | standard palette write: BG-A, OBJ-A, BG-B, OBJ-B, as at 0x05000000 |
| `OAM_WR_*` (bit 9 engine, 8-2 sprite, 1-0 attribute) | in | OAM attribute 0-2 write (attribute 3, affine parameters, is not stored) |
| `EXT_WR_*` (bit 12 engine, 11-0 entry) | in | OBJ extended palette write |
| `FAULT` (16) | out | nonzero: halted until reset; bits above |

The memory port never assumes a latency: requests wait for `REQ_READY`, and
responses are matched to requests only by order. Engine B's addresses wrap at
128 KiB and engine A's OBJ addresses at 256 KiB in the engine, so the
provider sees only in-range word addresses. Per line the engine makes exactly
one map request and one row request per BG tile slot (32, or 33 with a fine
horizontal scroll) and one request per 8-pixel sprite tile column on the
line; the gate checks those counts on every line.

## Register-sampling rule

Every register on the register port (DISPCNT, BGCNT, HOFS, VOFS, BLDCNT) is
sampled **once, in the cycle a line start is accepted**, and held for that
line. Each sprite's OAM attributes are read once, when that line's OAM scan
reaches it (during the fetch phase). VRAM is read during the fetch phase and
the palettes during the output phase. This matches the reference, which
renders a whole line from one state, and does **not** model:

- register writes that land during the visible part of a line (on hardware a
  scroll or BGCNT write mid-line takes effect mid-line; here at the next
  start);
- the DS's one-line-ahead sprite timing: hardware renders OBJ for line y+1
  during line y, so an OAM write during line y shows on y+1 differently;
  here the OAM is read when the caller starts the line, and the caller owns
  that schedule;
- palette or VRAM writes during a line (they land wherever the engine is in
  its fetch or output phase);
- the DS's per-line OBJ rendering-cycle budget [INFERENCE: GBATEK describes
  one; neither the reference nor this engine models it]: this engine draws
  every sprite on the line, which costs time instead (see Cycles per line).

## Design

```
            line start + registers (sampled once)
                          |
             +------------v-------------+         REQ (BG map, BG row, OBJ column)
             | request sequencer        |-------> registered, waits on REQ_READY
             |  BG map 0..n-1           |
             |  BG row 0..n-1 (address  |<------- RESP, in order, any latency
             |   from the map RAM)      |
             |  OBJ columns, as the OAM |  responses -> map RAM 64x16
             |   scan latches sprites   |              row RAM 64x64
             +------------^-------------+              OBJ column RAMs 64x24 (descriptor), 64x64 (row)
                          |
   OAM RAM 3x256x16 ---> OAM scan (one sprite/cycle: skip, latch, or fault)
                                         |
            OBJ pixel writer (one pixel/cycle, read-modify-write of the
            OBJ line buffer 256x16 with OAM-order priority; one-cycle
            write forwarding)
                                         |
   output (256 cycles): BG decode from map+row RAM, line-buffer read and
   clear, BG/OBJ priority, palette RAM 1024x16 or OBJ ext palette
   2x4096x16, pixel register
```

- **Storage is block RAM.** Eleven synchronous RAMs (Clash `blockRam` with a
  constant-zero initial vector; no `blockRam1`, no initial-value file needed):
  BG map entries 64 x 16, BG rows 64 x 64, standard palette 1024 x 16 (both
  engines), OAM attributes 3 x 256 x 16 (both engines), the OBJ line buffer
  256 x 16, sprite column descriptors 64 x 24 and rows 64 x 64, and the OBJ
  extended palettes 2 x 4096 x 16 (one per engine; a single 8192-entry RAM's
  initial-value loop would exceed Quartus 17's 5,000 iterations, the failure
  `blockRam1` hit in this repo). Registers hold only control, counters, the
  latched line configuration, one latched sprite and the pipeline stages.
- **Fetch once per tile, never per pixel.** One map request and one row
  request per BG tile slot: a 4bpp row is 4 bytes and an 8bpp row 8 bytes of
  one 8-byte word. Sprites: one request per 8-pixel tile column on the line.
- **Fetch pipeline.** All map requests issue back to back; each row request
  issues as soon as its map entry is in the map RAM, so a line costs two
  memory round trips plus one request per cycle, not one round trip per tile.
  Sprite column requests follow in the same in-order stream, up to 64
  columns ahead of the pixel writer.
- **Sprite pixels** go through the OBJ line buffer: one pixel per cycle (a
  column's pixels in screen order), each read-modify-written against the
  entry already there (opaque, priority, extended-palette flag, palette
  index). A candidate wins only if the entry is transparent or of strictly
  lower priority, which is the reference's OAM-order rule. The output phase
  clears each entry as it reads it; a 256-cycle sweep after reset clears it
  too.
- **Three state registers.** `Ctl` (sequencer, counters, latched line
  configuration, latched sprite), `Dp` (line-buffer read-modify-write and the
  output pipeline) and `Outs` (the request and pixel output registers) are
  three separate Clash registers, each built from one field of the step's
  result (`GeoMatrix`'s rule, against the sequencer-branch duplication that
  once cost that block 49 DSPs). The pure cycle step `tileStep` is the model;
  `tileHw` is it plus the RAMs, as in `Nds.Gpu3D.GeoMatrix`.
- **Time sharing.** The line configuration is latched with an engine index,
  and the palette, OAM and extended-palette RAMs hold both engines, so one
  instance could serve both screens if a caller presents the selected
  engine's registers with each start and routes the memory port. That is not
  built or tested.

## Gate

```sh
TIMING=1 clash/tests/run_tilehw_check.sh
```

`clash/test/TileHwCheck.hs` (checker), `clash/tests/tilehw_cosim.cpp`
(Verilator replay); see the script header. The gate's final line states the
failing-run count, whether the kirby135 capture ran, and how many mutants
ran (`MUTANTS="name ..."` selects a subset). Scenes:

- **arm9_2dk** (engines A and B, all 192 lines each): the checker assembles
  nothing itself; the gate first checks that `sim/tests/arm9_2dk.bin` equals
  a fresh `arm-none-eabi-as/ld/objcopy` of `arm9_2dk.s`, then the checker
  executes that binary in a small ARM interpreter (the instructions the
  program uses; CP15 writes ignored; byte writes to palette/VRAM/OAM dropped
  as on the ARM9) to its `0xCAFEBABE` mailbox store, and reads back VRAMCNT
  (checked against the expected mapping), DISPCNT, BG3CNT, scroll, BLDCNT,
  both standard palettes, both OAMs, BG-A/BG-B/OBJ-A/OBJ-B VRAM, bank E (the
  BG extended palette trap, slot 3 solid magenta, must stay unused) and bank
  F (engine A's OBJ extended palette). 125,861 instructions, 51,040 bytes
  stored; DISPCNT A `0x80211810`, B `0x00211810`, BG3CNT `0x0485` on both.
- **gpu2d_kirby135, optional**: a local capture from a commercial game
  (BG VRAM, palette, OAM, OBJ VRAM, OBJ extended palette and frame register
  words in seven `sim/tests/gpu2d_kirby135_*.hex` files). It is
  **untracked**: the files are gitignored and must never be committed, so a
  clean checkout does not have them. The checker uses it (engine A, all 192
  lines) only when all seven files are in `TILEHW_KIRBY_DIR` (default
  `sim/tests`); otherwise the gate prints `kirby135 capture not present (...),
  skipped`, runs every tracked scene, fault case, the Verilator replay and
  the mutants, and can pass. In the local copy its BG3CNT is `0x4113` (4bpp,
  512 x 256) and all 128 sprites sit at y = 192 (checked with a script over
  `gpu2d_kirby135_oam.hex`), so it exercises the BG, the OAM scan and the
  backdrop, not sprite pixels.
- **random scenes** (seeded): 0-15 directed BG scenes (both engines x both
  depths x four screen sizes, scrolls at the wrap points); 16-23 sprite
  chains in which each sprite starts on the previous one's last pixel at
  equal priority; the rest random in every field, OBJ on in about three
  quarters, with random DISPCNT bits the slice must ignore. Random sprites
  never ask for a refused feature (the checker fails if one would).

Each scene runs on its own through the pure step (with RAM models) and the
Clash circuit under one closed-loop driver: random gaps between lines and
palette or OAM writes, random register values on every cycle that is not a
line start (so a late sample would show), request stalls (`REQ_READY` low in
bursts) and in-order response latency of 1-6 cycles (70 %), 1-60 (25 %) or
1-400 (5 %). Each line is judged as it completes: pixel for pixel against the
reference, its request count against the expected count; the pure and Clash
outputs are compared on every cycle. Only counts are kept, so a run's memory
does not grow with the scene count: the checker runs under `+RTS -M3g`; run
alone, a 30-scene check peaked at 125 MB resident and `time` at 104 MB. The
whole gate's largest child process peaked at 2.9 GB resident (macOS
`time -l`; which child was not identified). The Verilator replay is fed by a
pipe from the checker's per-cycle stream of the same scenes with the same
seeds and compares as it reads; no trace is written to disk. Each scene of
that stream begins with a reset cycle; the Verilog's RAMs keep the previous
scene's contents across it (the pure model's start at zero), which the
engine must not observe.

### Results, step 2 (current source: BG + OBJ)

Observed on 2026-11-18, `TIMING=1 clash/tests/run_tilehw_check.sh`, seed 1,
200 random scenes, 60 in the Verilator replay, 60 per mutant. **This full
run was local, with the untracked kirby135 capture present**: the rows that
name kirby135 include it; every other row is from tracked inputs only.

| run | scope | checked | result |
| --- | --- | --- | --- |
| fixture binary | `arm9_2dk.bin` vs fresh assembly of `arm9_2dk.s` | byte compare | identical |
| fault | 18 refused states (bits 0-9, 11-14) + response with nothing outstanding | fault bit, halt, no pixel, pure = Clash | 19/19 refused |
| accepted near-misses | engine B bit 3; 4bpp + bit 30; no BG; affine sprite off the line; disabled sprite with bitmap/mosaic bits; OBJ-window sprite; semi-transparent with first target only | every pixel vs reference | 7/7 exact |
| fixtures (pure + Clash), local run with the capture | arm9_2dk A, B, kirby135: 576 lines | 147,456 pixels (120,576 BG, 2,432 OBJ, 24,448 backdrop), 37,168 requests (counts exact), 425,827 cycles, 21,091 stalled request cycles, 1,544 responses later than 60 cycles | 0 failures, pure = Clash every cycle |
| random (pure + Clash) | 200 scenes, 1,264 lines | 323,584 pixels (136,545 BG, 140,280 OBJ, 46,759 backdrop; 50,733 distinct colours), 133,547 requests, 1,980,024 cycles, 79,422 stalled cycles | 0 failures, pure = Clash every cycle |
| Yosys (fresh Verilog `c0905042...`) | memory inference, multipliers | `proc; memory -nomap` | 11 `$mem_v2` of the expected shapes, 0 multipliers |
| Verilator | fixtures stream (3 scenes) | 425,827 cycles, 37,168 requests (304 OBJ), 147,456 pixels (2,432 OBJ) | 0 mismatches |
| Verilator | random stream (60 scenes) | 644,299 cycles, 45,910 requests (20,110 OBJ), 108,544 pixels (47,854 OBJ) | 0 mismatches |
| Verilator negative control | one pixel colour changed in the stream | | detected (1 mismatch) |
| mutants | 23 (11 BG, 12 OBJ), table below | pure check + fault cases | 23/23 detected |

**Without the capture** (`TILEHW_KIRBY_DIR` pointed at an empty directory,
`MUTANTS=hflip`, same seed and counts otherwise; the gate printed
`kirby135 capture not present (0 of 7 gpu2d_kirby135_*.hex in ...), skipped`
and passed, its last line `tilehw: 0 failing runs; kirby135 capture: not
present, skipped; mutants: 1 of 23 run`): fault cases 26, 0 wrong; arm9_2dk
A and B 384 lines, 98,304 pixels (71,424 BG, 2,432 OBJ, 24,448 backdrop),
24,880 requests, pure = Clash on 284,090 cycles, 0 failures; random as above
(1,264 lines, 0 failures); the same Verilog (`c0905042...`) with the same
11 memories and 0 multipliers; Verilator fixtures stream 2 scenes, 284,090
cycles, 24,880 requests, 98,304 pixels, 0 mismatches, random stream as
above, corrupted stream detected; mutant `hflip` detected (56,323 check
failures, 6 fault cases wrong). The matching run with the capture
(`MUTANTS=obj-hflip`) passed with the numbers in the table and `obj-hflip`
detected (25,562 failures). Both runs capped every checker at `+RTS -M3g`;
each run's largest child process peaked at 2.9 GB resident.

In the local run with the capture, the fixture lines include every line of
all three scenes (no fixture line had a refused sprite), and the coverage
below counts the capture's 192 lines too. Coverage of the checked lines (from scene state and
the reference, not the engine): 956 engine-A and 806 engine-B lines with a
BG, 78 backdrop-only; BG0/1/2/3 306/312/260/884 lines; 4bpp 776, 8bpp 986;
screen sizes 0-3 664/478/298/322; BG priorities 0-3 326/670/238/528; fine x
scroll 1,000; horizontal wrap inside the line 860; vertical wrap 497; DISPCNT
base offsets 572; nonzero char base 1,692, screen base 1,716; h-flip slots on
1,378 lines, v-flip on 1,186; 18,038 sprites drawn, every size (8x8 3,816 ...
64x64 2,232), h-flip 8,951, v-flip 8,911, 4bpp 8,945, 8bpp standard 4,447,
8bpp extended 4,646, semi-transparent 1,949, priorities 0-3 4,607/4,445/
4,510/4,476, clipped left 1,577 and right 1,499, wrapping from y > 255 2,392;
tile boundaries 0-3 on 214/206/886/268 OBJ lines; 971 lines with 8 or more
sprites; 9,005 equal-priority and 24,064 different-priority overlapping
sprite pairs; 142,712 OBJ pixels shown, 34,917 hidden by a higher-priority
BG, 31,102 winning a priority tie with the BG.

Mutants (each a `sed` on a copy of `TileHw.hs`; failures = failing pixels,
request counts and pure/Clash disagreements of the pure check, then wrong
fault cases):

| mutant | check failures | fault cases wrong |
| --- | ---: | ---: |
| BG h-flip tests the v-flip bit | 56,323 | 6 |
| BG v-flip ignored | 20,862 | 0 |
| BG horizontal scroll wraps at 512 in a 256-wide map | 23,178 | 0 |
| BG vertical wrap ignores the 512-tall half | 5,551 | 0 |
| BGCNT char base ignored | 168,391 | 6 |
| DISPCNT screen base offset ignored | 23,627 | 0 |
| 4bpp transparency tests the byte, not the nibble | 1,209 | 1 |
| transparent BG pixel reads its index, not the backdrop entry | 4,702 | 1 |
| engine B BG addresses not wrapped at 128 KiB | 28 | 0 |
| row request issued one cycle before its map entry is written | 13,489 | 6 |
| BG mode not refused | 0 | 1 |
| OBJ h-flip ignored | 25,562 | 0 |
| OBJ v-flip ignored | 26,836 | 0 |
| OBJ 1D tile boundary ignored | 43,535 | 6 |
| OBJ 8bpp row stride as 4bpp | 20,505 | 0 |
| OBJ left clip ignored | 2,960 | 0 |
| OBJ vertical position without the 8-bit wrap | 13,110 | 0 |
| OBJ loses priority ties to the BG | 9,998 | 0 |
| later sprite wins equal priority (OAM order) | 8,571 | 0 |
| OBJ extended palette number dropped | 11,506 | 5 |
| OBJ extended palette used with DISPCNT bit 31 clear | 14,235 | 1 |
| line-buffer write forwarding removed | 202 | 0 |
| semi-transparent sprite not refused with a second target | 0 | 1 |

### Results, step 1 (BG only; gated and fitted before step 2 was written)

The step-1 source (one text BG, no OBJ: OBJ on was fault bit 2) ran the
step-1 version of the same gate on 2026-11-18, seed 1, 200 random scenes,
locally with the kirby135 capture present, and passed: 17 fault cases (14
refused, 3 accepted near-misses) 0 wrong; fixtures (arm9_2dk A, B and the
local kirby135 capture) 576 lines, 147,456 pixels, 36,864 requests, pure =
Clash on 401,786 cycles, 0 mismatches; random 1,264 lines, 323,584 pixels,
77,904 requests, pure = Clash on 1,057,850 cycles, 0 mismatches; Yosys 3
inferred memories (64x16, 64x64, 1024x16), 0 multipliers; Verilator 401,786
+ 343,551 cycles, 0 mismatches, corrupted trace detected; 11 mutants (BG h/v
flip, both scroll wraps, char base, DISPCNT screen base, 4bpp transparency,
backdrop palette bank, engine-B wrap, map-entry hazard, OBJ not refused) all
detected. That checker read the capture unconditionally, held whole runs in
memory and wrote traces to disk; the current one does none of these. In that
run the fixtures had OBJ cleared from DISPCNT, so both were BG-only.

## Resources and timing

Standalone fits with the repo's flow, `clash/tests/remote_quartus_block.sh
tilehw3x` (Quartus 17.0.2, `5CSEBA6U23I7`, no pins, constrained at 29.838 ns =
33.51 MHz). The two shared scripts were not modified: they were copied with
the pod manifest into a scratch git tree under `/tmp` whose `clash/rtl` held
only the generated netlist, and one `tilehw)` line was added to the copy's
`*3x` case (top `nds_gpu2d_tilehw`). Only that netlist and the generated
project files were streamed to the pod; the pod was deleted by the script
after each fit (its claim `nitro-fit-tilehw3x-work` is kept, as the other
`nitro-fit-*` claims are).

| netlist | function | ALMs | registers | M10K | DSP | worst setup | worst hold |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| step 1 (`c73ca866...`) | one text BG, 4/8bpp, backdrop | 446 | 133 | 5 | 0 | +17.960 ns | +0.178 ns |
| **step 2 (`c0905042...`, current)** | **+ regular 1D sprites, OBJ ext palettes, priority** | **775** | **305** | **28** | **0** | **+15.581 ns** | **+0.181 ns** |
| legacy VHDL engine A (`nds_gpu2d g_gpu2d_a_slow`) | all BG modes, OBJ incl. affine/bitmap, windows, blending, mosaic, 3D BG0, ... | 3,083 | 3,712 | 7 | 17 | (whole-core fit) | (whole-core fit) |

The legacy row is the hierarchy row in
`artifacts/zero-arm-graphics/stage0-fit/NDS4MiSTer.fit.rpt` (ALMs needed,
dedicated logic registers, M10K, DSP), from a whole-core fit, not a
standalone one. **The legacy engine does far more**: every BG mode (text,
affine, extended/bitmap, large), all four BGs at once, affine and bitmap
sprites, windows, colour effects, mosaic and the 3D layer. Its row reports
13,824 block-memory bits; where that design keeps its line buffers and
extended palettes in this fit was not traced here. Of this engine's 28 M10K,
16 should be the two engines' OBJ extended palettes (8 KiB each) and the
rest the line state, both engines' standard palettes and OAMs [INFERENCE:
from the RAM shapes at 512 x 16 per M10K, which add up to 28; the fit report
was not broken down per RAM]. All slow and fast
corner setup and hold slacks were non-negative in both fits; the step-2
worst setup path runs from one block RAM's port-B write-enable register to
another block RAM's address register (11.701 ns data delay, 6 logic levels,
-2.496 ns clock skew). Full netlist SHA-256: step 1
`c73ca8664f9e3245d770cc8cc61271feab40b8fda2431467d5983d279cf6bd75`, step 2
`c090504234cfc6bed4aa83579d4fb8f2494503c95b68eda36a5e6e9d38768aa8`.

## Cycles per line

A DS line is 2,130 cycles at 33.513982 MHz. Cycles from a start being taken
to the engine ready again (last pixel out), pure model, `tilehw-check time`;
latency L is the number of cycles from a request being taken to its
response; "pipelined" is a provider that is always ready and keeps any
number of requests in flight, "serial" one that takes the next request only
after answering the last.

| L | BG, 33 slots | BG, 32 slots | BG 33, serial | no BG, no OBJ | 2dk A (BG + 6 sprites) | kirby135, local capture (BG, OBJ scan, no sprite on screen) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 328 | 326 | 393 | 261 | 459 | 389 |
| 16 | 343 | 341 | 1,383 | 261 | 459 | 389 |
| 32 | 361 | 360 | 2,439 | 261 | 462 | 389 |
| 64 | 425 | 424 | 4,551 | 261 | 494 | 424 |
| 256 | 809 | 808 | 17,223 | 261 | 875 | 808 |
| 512 | 1,321 | 1,320 | 34,119 | 261 | 1,387 | 1,320 |
| 900 | 2,097 | 2,096 | 59,727 | 261 | 2,163 | 2,096 |

- **Background only**, pipelined: 328 cycles at L = 1, growing by about one
  cycle per latency cycle up to L = 32 (361), then `2L + 297` from L = 64 on
  (two round trips, 66 requests, 256 output cycles; exact at 64, 256, 512,
  900 in the table). It misses the line above L = 916 (2,129 cycles at 916).
  Serial: `66L + 327`; it misses above L = 27.
- **With sprites**: the OAM scan costs one cycle per sprite (128 cycles,
  overlapping the BG fetch) and the pixel writer one cycle per sprite pixel
  on the line (transparent ones included). On the 2dk engine-A scene the
  limit is L = 883 pipelined, 23 serial. With 64 x 64 sprites on one line
  (2dk BG, 33 slots, L = 1): 4 sprites 586 cycles, 16 sprites 1,354, 24
  sprites (1,536 sprite pixels) 1,866, 32 sprites (2,048 pixels) 2,378 (over
  the line), 128 sprites 8,522. So the engine misses a line when the
  sprites on it cover more than about 1,800 pixels in total (plus `2L` once
  latency dominates the BG fetch).
- Under the check's random provider (stalls, latency up to 400) the worst
  fixture line took 1,104 cycles (with or without the capture) and the worst
  random-scene line 2,140, one of the lines with several large sprites; the
  cycle count is reported, not gated, because the engine has no line
  deadline.
- The kirby135 column and its limits (pipelined 917, serial 28) come from
  local runs with the capture present. Without it the other columns and the
  BG-only limits (916, 27) are unchanged (observed in the run above).

## What is not covered

- Everything in the fault table: BG modes 1-6, more than one BG, affine,
  extended and large BGs, BG extended palettes for 8bpp BGs, 2D OBJ mapping,
  affine/double-size, bitmap and mosaic sprites, windows (including OBJ
  windows as masks), colour effects and semi-transparent blending, mosaic,
  the 3D layer, master brightness, display capture, display modes 0/2/3.
- Composition is for one BG and OBJ: priority among several BGs is not built.
- No DS line timing: the caller starts lines; there is no VCOUNT, HBlank,
  VBlank or one-line-ahead OBJ schedule, and the sampling rule above is not
  the hardware's.
- No per-line OBJ cycle limit; heavy sprite lines take longer than 2,130
  cycles instead (see above).
- The memory provider here is a testbench model (in-order, random stalls and
  latency); no SDRAM controller, arbitration with other masters or VRAM bank
  mapping exists. Requests are 8-byte words addressed per engine space; the
  caller maps them to banks.
- Engine A/B time sharing is a property of the state layout only; it was not
  built or tested.
- The kirby135 capture (local, when present) shows no sprite pixels (all its
  sprites are at y = 192), so the only tracked fixture sprite pixels are the
  arm9_2dk scene's.
- No board, no console integration, no comparison against hardware or melonDS
  directly. The reference is the repo's host model; that it matches melonDS
  rests on the repo's other gates (`BgCheck`, `SpriteCheck`), which were not
  rerun here [INFERENCE].
