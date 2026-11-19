# Haskell both-screen 2D tile prototype for MiSTer

Standalone DE10-Nano core. The Clash ARM9 SoC runs a real assembled program
([`hs_tile_arm9.S`](../../sim/tests/hs_tile_arm9.S)) from a 4 KiB boot ROM;
the program programs a text background and sprites on both DS 2D engines
through the CPU's GPU link and animates them from its VBlank and VCount
IRQs. One Clash tile engine
([`Nds.Gpu2D.TileHw`](../../clash/src/Nds/Gpu2D/TileHw.hs)), shared by
engines A and B, draws both screens on DS line timing (263 lines x 2,130
cycles at 33.513982 MHz); [`Nds.WholeCore.TileSoc`](../../clash/src/Nds/WholeCore/TileSoc.hs)
composes them and scans both screens out side by side. Design and gate:
[`docs/GPU2D_SOC.md`](../../docs/GPU2D_SOC.md).

This is **not** an NDS core: no ARM7, 3D, DMA, sound, input, cartridge or
BIOS; one BG layer and regular sprites; VRAM in block RAM.

## What you should see

Over HDMI (MiSTer's scaler, 8:3), two 256 x 192 screens side by side,
starting within a frame of reset (the program finishes programming the
scene 0.64 frames after reset; the first frame is black):

- **Left (top screen, engine A):** a diagonal pattern of tiles in three
  colour ramps with black holes, scrolling 3 pixels left and 1 pixel up per
  frame. From the middle (line 96) down, the pattern scrolls the other way
  horizontally: the VCount IRQ rewrites the scroll mid-frame. Six sprites:
  a 16 x 16 four-colour sprite near the top moving right 4 pixels per frame
  (it leaves on the right and comes back on the left), an 8 x 8 sprite
  lower down, three 16 x 16 256-colour sprites in a row at the top drawn
  from the OBJ extended palette, and one cut off by the right edge.
- **Right (bottom screen, engine B):** the same tile pattern scrolling the
  same way over its whole height and the same six sprites (the moving one
  too; the 256-colour ones from the standard palette, as engine B has no
  extended palettes enabled). Its holes show thin horizontal colour stripes
  that change every frame: the main loop writes engine B's backdrop colour
  continuously, and each line shows the value its HBlank sampled.
- The **user LED** stays off. It lights, and the picture disappears, if the
  program hits anything this prototype does not implement (a sticky GPU or
  CPU fault). OSD **Restart program** (or the user button) resets the CPU
  and the GPU registers; VRAM keeps its contents and is reprogrammed.

## What a board run would and would not prove

It **would** show that this bitstream configures, the PLL locks at the DS's
33.513982 MHz, the fitted logic runs the program on silicon (CPU, GPU link,
IRQs, the shared engine, the block-RAM VRAM) at timing STA says closes, and
that MiSTer's scaler accepts the side-by-side DS-timed stream, with the
animation behaving as described.

It would **not** prove pixel exactness on hardware (nothing captures the
output; exactness rests on the simulations: pure model against
`Nds.Gpu.Live`, generated Verilog against the pure model, all pixels of 10
frames), compatibility beyond this one program, or anything about SDRAM,
sound, input, ARM7, 3D or games. It is not a test of the console core.

## Build

From the repository root, with Stack/Clash, Verilator, Yosys and
`arm-none-eabi` binutils:

```sh
gate=$(mktemp -d); work=$(mktemp -d)
OUT=$gate clash/tests/run_tilesoc_check.sh      # gate; leaves the netlist and program in $gate
bash fpga/mister_hs_tile_slice/stage.sh "$(ls "$gate"/hdl/*/nds_tile_soc.v)" "$gate/guest.hex" "$work/project"
(cd "$work/project" && quartus_sh --flow compile HaskellTileSlice)
```

`stage.sh` copies the Pong shell allowlist from `HEAD`
(`fpga/mister_hs_gfx_slice/stage.sh`'s closure), this `emu.sv` and qsf, the
gate's Clash Verilog modules (one `VERILOG_FILE` line each; their RAM
power-up contents are inline initial blocks, every one at most 4,096
entries) and the program as `hs_tile_arm9.hex` padded to the 4 KiB boot
window (async ROM in `emu.sv`). No game data is involved. Check
`output_files/HaskellTileSlice.sta.summary` and `.fit.summary` before using
the `.rbf`.

## Clock

One PLL output, 33.513982 MHz (fractional PLL from the 50 MHz board clock;
Quartus reports exactly 33.513982 MHz), drives the CPU, the GPU target, the
tile engine and the video (`CLK_VIDEO = clk_sys`, a pixel enable every 3
clocks). DS line timing is defined in this clock, so every timing event
lands on an edge and there is no clock-domain crossing. The CPU therefore
runs at half the DS ARM9's 67 MHz; see `docs/GPU2D_SOC.md` ("Clock").

## Measured build result

Quartus Prime Lite **17.0.2** (isolated `raetro/quartus:17.0` pod; only the
staged project was streamed in; the pod was deleted after the fit) fit and
assembled the gate-passing netlist (`nds_tile_soc.v` SHA-256
`780d40d31a67af9fada5431da981773c601148cbc650cf8f6974c47be5d061ec`) for
**5CSEBA6U23I7**: **12,296 / 41,910 ALMs (29 %)**, 11,979 registers,
**162 / 553 RAM blocks**, 14 / 112 DSP blocks, 3 of 6 PLLs. Of that,
`nds_tile_soc` is 6,135 ALMs, 2,548 registers, 112 M10K and 3 DSP: the
ARM9 SoC 3,380 ALMs / 6 M10K / 3 DSP, the tile engine 654 ALMs / 30 M10K /
0 DSP, the GPU target 2,099 ALMs, the VRAM lanes and display line buffer
76 M10K. The core PLL output is reported at 33.513982 MHz. TimeQuest: 120
corner/clock slacks, none negative; core clock worst setup **+7.808 ns**
(slow 100 °C), worst hold +0.079 ns (fast -40 °C), core Fmax 45.39 MHz
(slow 100 °C); the design's worst setup slack +0.545 ns (HDMI clock);
zero unconstrained or illegal clocks. A second fit of the same staged
project (adding core-clock path reports) produced a byte-identical RBF.
Not tested on a physical board.

Delivered `HaskellTileSlice.rbf` SHA-256:
`dc432b5513d3e9f5a815da7b4450d4acedb22afa05481c9892626d8378c69d3f`.
The RBF and the fit, map, assembler and timing reports are kept locally in
`artifacts/hs-tile-slice/` (gitignored).
