# Haskell CPU + VRAM display prototype for MiSTer

Standalone DE10-Nano core and its proof gate. The Clash ARM9 slice
([`Nds.WholeCore.Arm9Slice`](../../clash/src/Nds/WholeCore/Arm9Slice.hs), used
unchanged) executes a real assembled ARM program and drives its GPU link into
[`Nds.Gpu2D.VramDisplay`](../../clash/src/Nds/Gpu2D/VramDisplay.hs), a
synthesizable Clash target with NDS register and VRAM semantics. The program
([`hs_gfx_arm9.S`](../../sim/tests/hs_gfx_arm9.S)) maps VRAM bank A to LCDC,
selects display mode 2, rasterises a shaded triangle with three incremental
edge functions over a gradient (49,152 `STRH` transactions), and reads pixels
back. [`Nds.WholeCore.GfxSoc`](../../clash/src/Nds/WholeCore/GfxSoc.hs)
composes the two and scans the top LCD out 2x at 640x480 VGA.

This is **not** an NDS core and not evidence for the full-console milestone:
no ARM7, BG/OBJ/3D, palette/OAM, IRQ/DMA, DS LCD timing, cartridge or BIOS.

## Supported semantics

Everything outside this list is a GPU reply error (CPU fault 4, sticky), never a
silently different result:

| Register / memory | Supported | Rejected |
| --- | --- | --- |
| POWCNT1 (half/word) | all bits, read mask `0x820f`; bit 0 sampled at frame start, bit 15 selects engine A for the top LCD | — (byte accesses never leave the slice) |
| VRAMCNT_A/B | disabled, MST 0 (LCDC), MST 1 (engine-A BG, offset 0–3) | enabled MST 2/3 |
| VRAMCNT_C–I | stored while disabled | any enable |
| DISPCNT_A | display mode 0 (white) and 2 (VRAM, bank A–D select) | display mode 1/3, BG mode 7 |
| DISPSTAT/VCOUNT | — | every read (no DS-timed LCD here) |
| VRAM `0x06xxxxxx` | engine-A BG and LCDC apertures incl. mirrors; ARM9 byte writes ignored; overlapping banks OR on read, broadcast on write; unmapped reads 0 | — |

Top LCD: black with the LCDs off; engine B (fixed display mode 0, white) unless
POWCNT1 bit 15; mode 0 white; mode 2 shows the selected bank's halfword at
`y*512+x*2` through the renderer's 6-bit expansion if that bank is LCDC-mapped,
otherwise black. Bank C/D can never be mapped here, so selecting them is black,
as in the authoritative model.

## Memory footprint

Banks A and B are each a full 128 KiB, built as four Clash `blockRamFile`
instances of 32,768 x 16 bits (two lanes per bank; ARM9 byte writes never reach
VRAM, so no byte enables). That is 2 Mbit = 256 M10K at 8K x 1, out of 553 on
the 5CSEBA6. Each lane `$readmemb`s `nds_vram_zero.bin` (32,768 zero lines),
so VRAM is zero at configuration like the authoritative model's fresh memory;
the RAM always-blocks have no reset, so CPU/OSD reset clears registers and
the link but not VRAM. The gate generates the file before running Clash, which
copies it beside the netlist; `stage.sh` checks and stages that copy. (Clash's
`blockRam1` zero-fill is a 32,768-iteration `initial` loop: Quartus 17 rejects
it at the default 5,000-iteration limit, rejects a 32,768 limit, and had not
finished elaborating it after 10 CPU-minutes at a 65,536 limit.) One shared
read address serves the CPU and
the scanout: the scanout takes it one clock in eight on picture lines (one
32-bit word = two LCD pixels) and a CPU VRAM read waits for a free clock; the
write port is the CPU's alone. Besides the link/raster state, the display
target keeps only the 9 VRAMCNT bytes, POWCNT1 and DISPCNT in flip-flops. The
slice adds its own 64-word RAM and its 16-register file.

## Gate

From the repository root, with Stack/Clash, Verilator and `arm-none-eabi` binutils:

```sh
EVIDENCE_DIR=$(mktemp -d) bash sim/run_clash_gfx_soc.sh
```

1. `clash/test/GfxSliceCheck.hs` runs the pure slice against the pure
   `gpuStep` model (with irregular scanout contention) and against the
   authoritative ABI2 GPU service (`clash/test/GpuService.hs` over
   `Nds.Gpu.Live`). Every GPU transaction, reply and mailbox store must agree;
   the service then renders an LCD frame and its top screen must equal the
   model's colour on all 49,152 pixels.
2. Fresh Clash Verilog of `nds_gfx_soc` runs under Verilator
   (`sim/clash_gfx_soc.cpp`). Its transaction log must be byte-identical, and
   the first full 640x480 frame after the halt must be black outside the
   picture, uniform 2x2 per LCD pixel, and equal to the service's frame.
3. The same runs for the unchanged `hs_gpu_arm9.S` witness (bank B, LCDC/BG
   remap, aliases), and three negatives (`UNSUPPORTED_MODE`, `_BANK`,
   `_STATUS`) that must stop on the same GPU reply fault, at the access the
   service would have accepted.
4. The witness reruns with a `0101…` init file: its read of a never-written
   VRAM halfword must return `0x5555`, proving the power-up contents come from
   the staged file rather than a simulator default.

Mid-frame timing is not compared: the service frame is rendered after the
program halts, and the RTL frame is the first one that starts after the halt.

## Build

```sh
work=$(mktemp -d)
bash sim/run_clash_gfx_soc.sh "$work/project"
(cd "$work/project" && quartus_sh --flow compile HaskellGfxSlice)
```

The staged project is the Pong shell allowlist read from `HEAD`
(`fpga/mister_hs_pong/stage.sh`'s closure), this `emu.sv`, the qsf, the tested
`nds_gfx_soc.v` with its `nds_vram_zero.bin`, and the program as
`hs_gfx_arm9.hex` padded to the 4 KiB boot window (async ROM in `emu.sv`). OSD
**Restart program** resets the CPU and display registers; VRAM keeps its
contents and is redrawn. Check
`output_files/HaskellGfxSlice.sta.summary`, `.fit.summary` and `.asm.rpt`
before using the `.rbf`: the flow can exit 0 with negative slack.

## Measured build result

Quartus Prime Lite **17.0.2** (isolated `raetro/quartus:17.0` pod, staged
project only) fit and assembled the gate-passing netlist for **5CSEBA6U23I7**:
**8,252 / 41,910 ALMs (20%)**, 10,719 registers, **308 / 553 RAM blocks**, of
which the four VRAM lanes are 64 M10K each (256; simple dual port, 32768 x 16,
old-data read-during-write as in Clash `blockRam`, MIF from
`nds_vram_zero.bin`). TimeQuest: 120 corner/clock slacks, none negative;
worst setup **+0.726 ns** (HDMI) and **+0.813 ns** (core 50 MHz clock), worst
hold **+0.039 ns**, worst removal **+0.523 ns**, recovery **+3.888 ns**; zero
unconstrained or illegal clocks. Not tested on a physical board.

Delivered `HaskellGfxSlice.rbf` SHA-256:
`ae3c495d1b535d91ceff5022def4a3be49903e5662fc0bbc08db992a8d0c52a2`.
