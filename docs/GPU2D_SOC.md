# Both-screen 2D tile SoC: ARM9 + one shared tile engine on DS line timing

`clash/src/Nds/WholeCore/TileSoc.hs` (Clash top `nds_tile_soc`) puts the
Clash ARM9 SoC (`Nds.WholeCore.Arm9Soc`, used through its ports, unchanged)
together with a GPU target and one `Nds.Gpu2D.TileHw` engine
(`docs/GPU2D_HW.md`) that draws both DS screens. A real assembled program
(`sim/tests/hs_tile_arm9.S`) runs from the boot ROM, programs a text BG and
sprites on both engines through the CPU's GPU link, and animates the scene
from its VBlank and VCount IRQs. `fpga/mister_hs_tile_slice/` is the MiSTer
build. Gate: `clash/tests/run_tilesoc_check.sh`.

This is a prototype, not an NDS core: no ARM7, no 3D, no DMA, one BG layer,
regular sprites, VRAM in block RAM, a 4 KiB boot ROM in place of BIOS and
cartridge. Every result below says what it was measured on: the pure model
against the authoritative host model (`Nds.Gpu.Live`), the generated Verilog
under Verilator against the pure model, or a Quartus fit. Nothing was run on
a board.

## Design decisions

### 1. One tile engine for both screens, not two

One `TileHw` instance serves engines A and B. Its palette (1,024 x 16), OAM
(3 x 256 x 16), OBJ extended-palette and line-buffer RAMs already hold both
engines, so a second instance would duplicate all of them (the standalone
engine is 28-30 M10K; most of that is the two 4,096 x 16 extended palettes)
plus 650-800 ALMs, for work that fits in one line time: per line the engine
does a BG job for A and one for B, then the sprites of the next line for A
and for B. In the 10-frame gate run (frames 1-9, scene up) the four jobs
kept the engine busy at most 928 of the 2,130 cycles between two HBlanks
(mean 908), with 1-cycle VRAM.

What sharing cost: sprites are drawn one line ahead into a line buffer that
holds both engines and both line parities (1,024 x 16 instead of 256 x 16),
and the engine got four job kinds (`JBoth`, `JBg`, `JObj`, `JClear`; see
`docs/GPU2D_HW.md`). The tile gate covers every kind (26 mutants, 3 of them
for the job kinds).

### 2. VRAM in M10K now; the engine is ready for SDRAM

This build keeps only the banks the scene uses, in block RAM, each as four
16-bit lanes of 8-byte words:

| bank | VRAMCNT accepted | implemented window | RAM |
| --- | --- | --- | --- |
| A | `0x81` (engine A BG, offset 0) | first 32 KiB | 4 x 4,096 x 16 |
| B | `0x82` (engine A OBJ, offset 0) | first 4 KiB | 4 x 512 x 16 |
| C | `0x84` (engine B BG) | first 32 KiB | 4 x 4,096 x 16 |
| D | `0x84` (engine B OBJ) | first 4 KiB | 4 x 512 x 16 |
| E | `0x80` (LCDC: CPU writes accepted and dropped) or `0x84` (engine A BG extended palette: never read, because the engine refuses BG extended palettes, fault bit 9) | none | none |
| F | `0x80` (LCDC: CPU writes go to the engine's engine-A OBJ extended-palette RAM) or `0x85` (engine A OBJ extended palette, which the engine then reads) | 8 KiB | in the engine |
| G-I | disabled only | | |

Any other VRAMCNT value is a link error (the CPU faults). An engine read
inside a mapped bank but outside its window sets GPU fault bit 3; a read of
an unmapped space returns 0, as the reference does.

The engine's memory port is in order and latency-agnostic (request/ready,
responses matched by order; the tile gate runs it with random stalls and
latencies up to 400 cycles). Moving VRAM to SDRAM therefore replaces this
module's lane RAMs with a provider and leaves the engine unchanged. The
budget: the tile gate's timing table (`docs/GPU2D_HW.md`, "Cycles per line")
gives a BG job `2L + 297` cycles once latency L dominates (L >= 64), so the
two BG jobs alone fit a 2,130-cycle line up to L = 384 with a pipelined
provider, less whatever the two sprite jobs take, and only up to L = 11
with a provider that answers one request at a time (`66L + 327` per BG
job) [INFERENCE: arithmetic on the standalone table; the SoC was measured
only with 1-cycle block-RAM VRAM]. An SDRAM provider must keep requests in
flight.

### 3. MMIO write path and fail-closed behaviour

The ARM9 slice forwards single transfers in its link window (DISPCNT,
DISPSTAT/VCOUNT, the engine A and B register blocks, VRAMCNT, POWCNT1,
palette, OAM, VRAM); LDM/STM beats into it fault in the slice (code 3). IME,
IE, IF and the timers stay in the CPU's `Arm9Io`; the GPU target raises IF
bits through the SoC's external IRQ-set input (`socIrqSet`) in the cycle of
the line event.

The target implements, and everything else is a link error (CPU fault,
sticky):

| access | supported |
| --- | --- |
| DISPCNT A/B | read and write, every width; engine B masked `0xc0b1fff7` |
| DISPSTAT, VCOUNT | read (flags live); DISPSTAT write of bits 3-5 and 7-15 (`writeStatus` mask) |
| engine registers 0x08-0x1f, 0x50-0x51 (A and B) | BGxCNT read/write; BGxHOFS/VOFS write (read 0, as Live2D); BLDCNT read/write, a halfword write at 0x50 masked to `0x3fff`; byte, half and word writes as byte writes, as Live2D |
| other engine registers (windows, mosaic, BLDALPHA/BLDY, MASTER_BRIGHT, ...) | none: link error |
| POWCNT1 | half/word, mask `0x820f`; turning engine A or B off is refused |
| VRAMCNT A-I | read; writes of the values in the table above |
| palette, OAM | half and word writes (a word is two halfword writes); OAM attribute 3 is not stored; byte writes and reads refused |
| VRAM | half and word writes through the mapping above; byte writes and reads refused |

Live ignores ARM9 byte writes to palette, OAM and VRAM (as the hardware
does); this target refuses them instead, so a program that relies on them
stops rather than drawing differently. A display state the engine cannot
draw sets a GPU fault bit and stops all drawing and the picture:

| GPU fault bit | meaning |
| ---: | --- |
| 0 | engine refusal (`TileHw` fault word nonzero: BG mode, windows, effects, affine/bitmap sprites, ...) |
| 1 | display mode 2/3, or forced blank, on a drawn line |
| 2 | OBJ extended palettes without bank F as engine A's OBJ extended palette, or on engine B |
| 3 | engine VRAM read inside a mapped bank but outside its implemented window |
| 4 | an HBlank's jobs not finished by the next HBlank |

### 4. Line scheduling against the real DS

Timing is Live's, in 33.513982 MHz cycles: 263 lines of 2,130. At cycle 0
of a line VCOUNT advances, the HBlank flag clears, the VCount match is
evaluated and raises IF bit 2 if enabled, VBlank sets at line 192 (IF bit 0
if DISPSTAT bit 3) and clears at line 262; the HBlank flag sets at cycle
1,584 (IF bit 1 if enabled).

At each HBlank, exactly as Live's `preDraw`/`drawLine`/`prepareSprites`,
each enabled engine shifts its DISPCNT history and forms the delayed layer
enables (BG and composed OBJ: DISPCNT and DISPCNT two HBlanks earlier;
sprite rendering: DISPCNT and one HBlank earlier); then line y (y < 192) is
drawn and the sprites of line y+1 (or line 0 at line 262) are rendered, as
four engine jobs: BG A, BG B (or a line-buffer clear when the line shows
black or white), OBJ A, OBJ B. Live draws at that instant; here the jobs
take about 910 cycles, so every CPU write that a job reads (DISPCNT,
engine registers, POWCNT1, VRAMCNT, palette, OAM, VRAM) is held from two
cycles before the HBlank until the jobs are done. The jobs therefore read
exactly the state Live draws from, and the gate finds no difference.

Against real hardware this keeps Live's simplifications, which are not
modelled here either: the DS renders progressively during the line, so a
register, palette or VRAM write in the middle of a line's drawing takes
effect at the beam position on hardware, but at the next HBlank here and in
Live. Held writes also stall the CPU while the jobs run, which a DS CPU
does not do (measured below).

### 5. Video path

One clock, 33.513982 MHz (see "Clock"). A pixel enable every 3 cycles gives
710 pixel slots per line; 512 are active (slots 116-627), with HS in slots
0-51 and VS on lines 220-222. The two screens are scanned side by side
(512 x 192, `VIDEO_ARX/ARY` 8:3): the left half is the top screen, which is
engine A when POWCNT1 bit 15 is set, as in Live. Picture line y is shown
during VCOUNT y+2, read from a 2,048 x 16 display line buffer (engine x
four lines x 256) that the BG jobs write; there is no frame buffer, and
MiSTer's scaler (`ascal`) converts the 59.83 Hz, 11.17 MHz pixel-rate stream
for HDMI. Colours go through the renderer's 15-to-18-bit expansion (green's
low bit from palette bit 15) and then to 8 bits per channel as Live's
`expand`. Screens off (POWCNT1 bit 0 sampled at frame start) show black; a
disabled engine A shows black and a disabled B white; display mode 0 white.

### 6. Verification

- **Pure SoC against Live** (`clash/test/TileSocCheck.hs check`): the pure
  cycle step of the whole SoC (the ARM9's `socStep`, `gpuStep`, the
  engine's `tileStep`, a model of every block RAM) runs the assembled
  program for 10 frames from reset. Every completed GPU link transaction is
  applied to `Nds.Gpu.Live` at the same cycle (after servicing Live's
  deadlines and frame starts up to that cycle, as the ABI2 GPU service
  does). Every read value must equal Live's, every IF bit Live raises must
  be raised by the SoC in the same cycle (and the reverse), and every pixel
  of both screens of every frame, taken from the SoC's video output, must
  equal Live's frame. Once the scene shows, every frame must differ from the
  one before.
- **Fail-closed**: four variants of the program (`--defsym`) must stop:
  a MASTER_BRIGHT write (link error at `0x0400006c`), an ARM9 byte write to
  the palette (`0x05000000`), a VRAM word past bank A's 32 KiB window
  (`0x06008000`), and BG mode 1 (engine refusal, GPU fault bit 0).
- **Verilog**: fresh Clash Verilog under Verilator replays the pure model's
  10-frame output stream, read from a pipe, cycle by cycle (every top-level
  output: boot address, 28-bit video bus, transaction probe, IF bits, fault
  words, store probe, retire strobe); one changed pixel must be detected.
- **Mutants** of `TileSoc.hs`, each of which must fail the pure check.
- Clash's own Signal simulation of the composed SoC is not compared: it keeps
  the ARM9 SoC's unused card and I/O output streams alive (heap profile:
  `CardState`, `IoIn`, `SliceOut` and Signal cons cells) and exhausted
  3 GiB within a frame. The generated Verilog is what is compared.
- Memory: every checker run and every GHC and Clash compile in the gate run
  with `+RTS -M3g`; no trace is written to disk.

### 7. Resources: estimate and measurement

The design estimate made before this build was one shared engine at about
28-30 M10K (two engines about 38) and A + B jobs at about 950 of the 2,130
cycles of a line. The RAM shapes give the VRAM lanes and display line
buffer 76 M10K (A and C 4 x 4,096 x 16 = 32 M10K each, B and D 4 each, the
2,048 x 16 line buffer 4). Measured, full MiSTer fit (Quartus 17.0.2,
5CSEBA6U23I7, core at 33.513982 MHz; per-entity rows of the fitter report;
the ARM9 SoC and the engine are separate netlist modules for this):

| part | earlier figure | this fit, in the SoC |
| --- | --- | --- |
| ARM9 SoC (`Arm9Soc`, unchanged) | 3,442 ALMs (earlier slice); 4,341 ALMs standalone at 67.03 MHz (pipelined slice, CPU worker's fit) | 3,380 ALMs, 1,561 registers, 6 M10K, 3 DSP |
| tile engine (`TileHw`) | 775 ALMs / 305 registers / 28 M10K / 0 DSP standalone (previous netlist, 256-entry line buffer); current netlist standalone: 797 ALMs / 315 registers / 29 M10K / 0 DSP, +14.646 ns setup at 33.51 MHz | 654 ALMs, 299 registers, 30 M10K, 0 DSP |
| GPU target | | 2,099 ALMs: `gpuStep` 1,857 plus the SoC's top level 242 (its three state registers, the RAM ports and glue); 688 registers, all at the top level; 0 M10K, 0 DSP |
| VRAM lanes, display line buffer | 76 M10K (from the RAM shapes) | 76 M10K |
| `nds_tile_soc` total | | **6,135 ALMs, 2,548 registers, 112 M10K, 3 DSP** |
| whole MiSTer build (shell, scaler, SoC) | CPU + VRAM display prototype: 8,252 ALMs, 308 RAM blocks | **12,296 ALMs (29 %), 11,979 registers, 162 RAM blocks (29 %), 14 DSP** |

The ARM9 SoC is smaller in this fit than standalone [INFERENCE: its card
input is the constant `noCartridge` and the timer tick is 0 here, so
Quartus removes logic, and the clock constraint is half]. The GPU target is
larger than the engine: about 400 ALMs are the eight byte writers of the
two engines' register files, about 80 the address decoder, 30 a
divide-by-3 in the scanout, the rest the link, line control and read
multiplexers.

### 8. What the owner sees, and what a board run would prove

See `fpga/mister_hs_tile_slice/README.md`. In short: two 256 x 192 screens
side by side; on each, a diagonal pattern of three colour ramps with black
holes (the top screen's BG, the backdrop is black) scrolling 3 pixels left
and 1 up per frame; on the top screen the lower half (from line 96) scrolls
the other way; a 16 x 16 sprite moving right 4 pixels per frame on both; the
bottom screen's holes show horizontal colour stripes that change every frame
(the main loop's backdrop writes, sampled once per line). The user LED stays
off; it lights, and the picture disappears, on any GPU or CPU fault.

A board run would show that the bitstream configures, the PLL locks at the
DS clock, the logic runs the program on silicon at timing that STA says
closes, and that MiSTer's scaler accepts the stream. It would not prove
pixel exactness (there is no capture; that rests on the simulations above),
DS compatibility beyond this one scene, or anything about SDRAM, sound,
input, ARM7, 3D or real games.

## Clock

One clock, the DS's 33.513982 MHz (one fractional PLL output; Quartus
reports exactly 33.513982 MHz), for the CPU, the GPU target, the tile
engine and the video. Why:

- DS LCD and GPU timing is defined in these cycles (2,130 per line, HBlank
  at 1,584), so one domain at this rate puts every timing event on a clock
  edge with no clock-domain crossing, and the gate's cycle-exact comparison
  with Live uses the same time unit.
- Measured: the fitted SoC closes 33.51 MHz with +7.808 ns worst setup slack
  (slow 100 °C) and has a core Fmax of 45.39 MHz, so it would not close at
  67.03 MHz as built. The critical path (21.6 ns, 13 logic levels) runs from
  a GPU-target state register through the scanout's divide-by-3
  (`slotNext = (h + 1) div 3`) into the display line buffer's read address;
  a slot counter in place of the divider is the first step if a faster
  clock is wanted [INFERENCE: not tried].
- The standalone ARM9 SoC closes 67.03 MHz. Running only the CPU at 67 MHz
  would need the GPU target on a 2:1 clock enable (its timing, the link and
  the gate's time base in half-rate steps) or a clock-domain crossing on
  the GPU link; neither is built.

So the CPU runs at half the DS ARM9's clock.

## CPU speed

Measured on the pure model of the final slice, `hs_tile_arm9.S`, 10 frames
(the gate's check):

- **Setup**: palettes, 32 KiB through bank E, the 8 KiB OBJ extended
  palette, tiles, maps, OBJ tiles and OAM of both engines, 15,876 GPU link
  writes in all, finish at cycle 355,802 (0.64 of a frame): 170,733
  instructions in frame 0, about 3.3 cycles per instruction including the
  link writes.
- **Link writes**: consecutive GPU link writes are at least 5 cycles apart;
  the setup's tight store loops (`str` with post-increment, `subs`, `bne`)
  issue one every 11 cycles (8,234 such gaps). At that rate a VBlank
  (70 lines, 149,100 cycles) holds about 13,500 writes, a 2 KiB tile map
  (1,024 halfwords) about 11,000 cycles [INFERENCE: arithmetic from the
  measured 11-cycle gap].
- **IRQs**: from the cycle the SoC raises VBlank in IF to the handler's
  store of its count to the mailbox (its 10th instruction, counting the
  vector's branch): 64 cycles in frame 0, 174 in frames 1-3 [INFERENCE: the
  extra cycles are the main loop's palette write, held by line 191's jobs,
  finishing before the CPU takes the IRQ].
- **Steady state** (frames 1-9): 93,465 instructions per frame, about 6.0
  cycles per instruction. The main loop (8 instructions) does one GPU read,
  which waits for its reply, and one palette write, which is held while the
  line's jobs run (about 910 of every 2,130 cycles); 11,677 iterations per
  frame, 33 cycles apart when not held. Development runs of the same slice
  without the palette write ran 23,316 iterations per frame (24 cycles
  each), and without the read as well 160,026 instructions per frame (3.5
  cycles per instruction for a 4-instruction loop with a load-use and a
  taken branch).

Does the CPU's speed limit this program? No: its per-frame work (the two
handlers, about 45 instructions and 7 link writes) takes well under 1 % of
a frame; the rest is the deliberately busy main loop. For DS software it
would: the CPU runs at 33.5 MHz, half the DS ARM9's clock, at about 3.3-3.5
cycles per instruction on these loops, so roughly 10 million instructions
per second against several times that on a DS [INFERENCE: the DS figure is
not measured here], and a GPU-state write that lands during a line's jobs
waits up to about 930 cycles, which a DS CPU never does.

## Results

Observed on 2026-11-19 with `clash/tests/run_tilesoc_check.sh` (defaults:
10 frames, 4 per mutant) on the final ARM9 slice (pipelined; the CPU
worker's gate green; `Arm9Slice.hs` SHA-256 `18836c00...`, `Arm9Soc.hs`
`7ed75301...`, `Arm9Io.hs` `ef2e6896...`) and the fixed reference
(`Nds.Gpu2D.TraceState.phaseOBJExtRead` reads physical banks F/G; before
that fix Live drew engine A's OBJ extended-palette sprites from bank G and
differed from this SoC on 896 pixels per frame, all on those sprites).
Program `hs_tile_arm9.S`, 342 words, SHA-256 `be3aff73...`.

| run | checked | result |
| --- | --- | --- |
| pure SoC against `Nds.Gpu.Live`, 10 frames (5,601,905 cycles) | 237,338 GPU link transactions (126,638 writes, 110,700 reads) applied to Live at their cycles; every read value; every IF bit (10 VBlank, 9 VCount); all 98,304 pixels of both screens of each of the 10 frames | **0 pixel mismatches, 0 read or IRQ mismatches**, no Live event the SoC missed, no other Live effect |
| animation | pixels changed from the previous frame | frame 0 black (scene not yet up); frames 1-9: 86,234-89,660 of 98,304 changed every frame; 947-1,211 distinct colours per frame |
| IRQs taken by the CPU | handler count stores | 10 VBlank handler entries in 10 frames (the count store 64 cycles after the IF set in frame 0, 174 in frames 1-3); 9 VCount handler entries (frames 1-9) |
| fail-closed variants (2 frames each) | stop on the expected fault, Live identical up to there | MASTER_BRIGHT `cpu:0400006c`, palette byte write `cpu:05000000`, VRAM past the window `cpu:06008000`, BG mode 1 `gpu:1` (bit 0): 4/4 |
| Yosys, fresh Verilog (`nds_tile_soc.v` `780d40d3...`, 13 modules) | memory inference, multipliers | 31 `$mem_v2`: 16 VRAM lanes (8 x 4,096 x 16, 8 x 512 x 16), display line buffer 2,048 x 16, the engine's eleven, the ARM9's 1,024 x 32 RAM and two 32 x 32 register files. 39 `$mul` cells after `proc; flatten`, before constant folding: 25 of 64 bits, 13 of 5 bits, one of 66 bits. In the Quartus fit all 3 of the SoC's DSP blocks are in the ARM9 part, none in the GPU target or the engine [INFERENCE: the narrow and 64-bit cells have constant operands from index arithmetic such as `8 * fromEnum k`; the 66-bit one is the CPU's multiply] |
| Verilator, 10 frames | every top-level output every cycle against the pure model | **5,601,905 cycles, 983,040 picture pixels, 237,338 transactions, 1,011,919 retired instructions: 0 mismatches** |
| Verilator negative control | one picture pixel changed in the stream | detected (1 mismatch) |
| mutants of `TileSoc.hs` (4 frames each) | table below | **10/10 detected** |

| mutant | failures (pixels; reads/IRQs) |
| --- | ---: |
| VBlank IRQ one line late | 8 (0; 8) |
| VCount match one line late | 3 (0; 3) |
| HBlank flag 8 cycles late | 141 (0; 141) |
| sprites drawn for the current line, not one ahead | 6,816 (6,816; 0) |
| POWCNT1 swap bit inverted | 187,202 (187,202; 0) |
| scanout one picture line off | 262,279 (262,279; 0) |
| bank F LCDC writes dropped | 2,688 (2,688; 0) |
| engine B palette writes land in engine A's half | 183,297 (183,297; 0) |
| writes during the line's jobs not held | 35,925 (35,925; 0) |
| screens-on bit sampled every line instead of at frame start | 95,808 (95,808; 0) |

The gate printed `tilesoc: 0 failing runs; mutants: 10 of 10 run` and took
97 minutes. Memory: every checker run and every GHC and Clash compile was
capped at `+RTS -M3g`; the whole run's largest child process peaked at
4.6 GB resident (macOS `time -l`) [INFERENCE: the Clash generation of
`nds_tile_soc`, which peaked at 4.59 GB when run on its own under the same
cap; the excess over the cap would be GHC's memory outside the heap]. A
pure 10-frame check run on its own peaked at 75 MB resident (an earlier
version of this checker and program, same structure).

## Not covered

- Everything `TileHw` refuses (`docs/GPU2D_HW.md`), plus here: windows,
  BLDALPHA/BLDY, MASTER_BRIGHT, display capture, display modes 2/3 and
  forced blank (refused), BG extended palettes, OBJ extended palettes on
  engine B, more than the listed VRAM banks and windows, VRAM/palette/OAM
  reads by the CPU.
- No DMA, no ARM7, no 3D, no sound, no input, no cartridge (the SoC's card
  input is tied to `noCartridge`), no BIOS: a 4 KiB boot ROM.
- Mid-line register, palette and VRAM writes take effect at the next HBlank
  (as Live), not at the beam position (as hardware); held writes stall the
  CPU during the line's jobs.
- The CPU runs at half the DS ARM9's clock.
- One program and its four negative variants; one scene. The authoritative
  model is the repo's `Nds.Gpu.Live`; this gate does not compare against
  melonDS or hardware directly.
