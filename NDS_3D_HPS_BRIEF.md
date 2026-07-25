# NDS 3D on MiSTer: HPS Hybrid Rendering Brief

## The problem

We are building an FPGA Nintendo DS core for the MiSTer platform (DE10-Nano, Cyclone V 5CSEBA6U23I7). The 2D-only core — two ARM CPUs, two 2D PPUs, sound, DMA, card interface — consumes ~90-95% of the device's 41.9K ALMs with zero 3D. A faithful RTL implementation of the NDS 3D unit (geometry engine, rasterizer, texture mapping, lighting, fog, edge marking, alpha blending, W-depth) would need 20-35K ALMs. It does not fit. There is no headroom and no larger MiSTer-compatible FPGA.

## Why the NDS 3D unit is uniquely hard

The NDS 3D pipeline is comparable to or larger than both 2D engines combined:
- Geometry engine: 4x4 fixed-point matrix pipeline, 4-light lighting, frustum clipping (wide-datapath state machine)
- Rasterizer: scanline with dual edge walkers, perspective-correct interpolators for 6+ attributes
- Texture: five formats including 4x4 block compression, per-texel palette lookups against VRAM
- Post-processing: toon/fog/edge-marking/AA, W/Z depth buffer

But the throughput targets are low by 2026 FPGA standards: 6144 vertices per frame, 256x192 output, ~91 clk1x cycles per vertex, ~3-12 Mpx/s overdraw. A maximally serialized design could theoretically fit in ~12-18K ALMs — but the 2D core would need to diet ~10K ALMs first, and texture fetch (per-texel lookups against VRAM banks in board SDRAM) is a latency-dominated design problem that needs a texture cache and real engineering. This is a multi-month campaign at best.

## The escape hatch: the BG0 seam

The NDS hardware defines a clean interface between 3D and 2D: the 3D unit's entire output is a 256-pixel line fed into 2D engine A's BG0 layer. From the 2D pipeline's perspective, 3D is just another background layer source. Anything that produces correct 256-pixel lines can sit behind that seam — including software.

The DE10-Nano is a Cyclone V SoC: dual Cortex-A9 at 800 MHz bolted to the FPGA fabric. melonDS (a mature NDS emulator) runs its entire software 3D rasterizer on a single core of 2011-era hardware. The A9 can handle NDS 3D throughput without breaking a sweat.

## Proven precedent: MiSTer Frontier

The MiSTer community has recently shipped hybrid ARM+FPGA cores where the ARM does all rendering and the FPGA handles only video timing and audio output:

- **MiSTer Frontier** (MiSTerOrganize): PICO-8, OpenBOR (~300 games). GitHub: MiSTerOrganize/MiSTer_Frontier
- **3S-ARM** (kimchiman52): Street Fighter III 3rd Strike. GitHub: kimchiman52/3s-mister-arm

These cores prove the full pipeline: ARM renders frames, writes to DDR3, FPGA reads them back with native CRT/analog/HDMI output, zero scaler latency.

### Frontier shared-memory protocol

- ARM writes RGB565 frames to DDR3 at physical address **0x3A000000**
- Double-buffered: control word at offset 0x000 has active_buffer (0 or 1) + frame_counter
- ARM writes a complete frame to the inactive buffer, then flips the control word
- FPGA polls the control word and switches read address on VBlank — no SPI, no interrupt
- Audio: separate DDR3 ring buffer, 48 kHz S16 stereo, FPGA reads via I2S/SPDIF/DAC (no ALSA)

### FPGA-side video modules (from 3S-ARM, AGPL-3.0 — reference only, must reimplement)

- `native_video_reader.sv`: 96-beat DDR3 burst reads → RGB565→RGB888 decode → line buffer FIFO
- `native_video_timing.sv`: sync gen at target pixel clock via dedicated integer-N PLL
- `native_video_top.sv`: wrapper + MiSTer framework integration

### Daemon launch mechanism

The Frontier `Master_Daemon` is registered via `/media/fat/linux/user-startup.sh` (standard MiSTer boot hook). It inotify-watches `/tmp/CORENAME` (updated by the MiSTer binary on every core load). When it sees the target core name, it spawns the ARM rendering process. When the core changes, it kills it. No MiSTer binary patches, no OS changes.

## How this applies to NDS (the BG0-seam approach)

The NDS version is simpler than Frontier — Frontier does 100% of rendering on ARM. The NDS core only farms out the 3D layer.

### Step 1: Geometry command capture (FPGA → DDR3)

Capture raw bus writes at the NDS 3D register interface (0x04000400-0x04000680): port address + data, including packed-port writes and DMA-sourced writes. Capture at the register interface so both CPU and DMA writes are caught. The daemon replays them through melonDS's software geometry engine — no RTL geometry engine needed.

**The GX FIFO itself is the capture FIFO.** Model the actual NDS GX FIFO in RTL (256 entries, depth-matched to hardware): drive GXSTAT occupancy flags (empty / less-than-half / full / word-count) from its real fill level, and backpressure the ARM9 with bus wait states when full. This gives faithful hardware behavior for free — the capture mechanism and the FIFO emulation are the same thing. Test commands are processed in-order from the same stream, so shadow-matrix state is definitionally coherent with test requests.

**Drain rate divergence (acceptable).** Real hardware drains the FIFO at geometry-engine speed (fast for VTX words, slow for MTX_MULT). The hybrid drains at DDR3-burst speed. Stalls occur at different moments, but the semantics — write blocks until space exists — are preserved. This is timing divergence, not behavioral divergence, same category as the frame-ahead design itself.

**GXSTAT "busy" needs a round trip.** A game waiting for geometry-engine-busy-clear before reading test results or RAM_COUNT could observe !busy while the daemon still chews buffered commands. Fix: the daemon posts a consumed-sequence-number to the mailbox; the FPGA drives `busy = (FIFO nonempty) OR (written_seq != consumed_seq)`. Cheap, closes the race.

Frame delimiters = SWAP_BUFFERS command writes in the stream, with VBlank auto-close as fallback for games that don't issue explicit swaps.

### Step 2: Interactive geometry reads (small RTL — the real design problem)

Games can synchronously read GXSTAT, BOX_TEST/POS_TEST/VEC_TEST results, CLIPMTX/VECMTX, and RAM_COUNT. A frame-ahead daemon cannot answer a mid-frame PosTest. A meaningful subset of games uses these for collision detection and object picking.

**Solution:** Keep a shadow matrix stack in RTL (snoop MTX_PUSH/POP/LOAD/MULT/TRANS commands from the FIFO — the stack is small, fits in BRAM) and implement just the three test units plus RAM_COUNT counters. This is a sequential 32-bit MAC, a couple DSP blocks, ~1-2K ALMs. That is 5% of a geometry engine for most of the compatibility surface.

### Step 3: ARM daemon renders 3D (DDR3 → ARM → DDR3)

A Linux daemon on the HPS embeds melonDS's GPU3D_Soft module (GPLv3 — fine for a userspace daemon across a memory protocol boundary). GPU3D_Soft is one of the cleaner modules in melonDS; its real dependencies are: VRAM bank-mapping tables (VRAMCNT state), the 3D register block, and the polygon/vertex RAM model — all behind a small interface. It does not need the melonDS scheduler, ARM9 core, or 2D side.

The daemon: reads geometry commands from the DDR3 command buffer, replays them through the software geometry + rasterizer, writes the 256x192 BGR result to a DDR3 framebuffer region.

### Step 4: FPGA reads 3D output as BG0 (DDR3 → FPGA)

The existing 2D engine reads rendered 3D lines from DDR3 through burst-read channels and composites them as BG0 data. The core already has DDR3 burst-read infrastructure (128-beat reads, dual-clock line buffers) for its own framebuffer scanout.

### Synchronization

Ping-pong command buffers + double-buffered framebuffers, sequence numbers in both directions, DDR3 control words polled on both sides (no interrupts). The real NDS renders 3D a frame ahead, so the ARM gets ~16.7ms per frame.

Under-run policy (daemon misses its 16.7ms deadline): repeat the previous frame and increment a drop counter. Real NDS hardware cannot under-run, so this is purely a daemon-health failure mode. Add a watchdog.

## VRAM texture access

The 3D rasterizer needs to read textures and palettes from VRAM. VRAM lives in board SDRAM (separate 16-bit SDRAM chip on FPGA pins), not in DDR3. The ARM has no direct path to board SDRAM.

### Recommended: Shadow texture/palette writes to DDR3 at write time

Redirect VRAM writes that target texture/palette-mapped banks directly to a DDR3 shadow region at the memory controller. The key load-bearing fact: **the 2D PPU never reads texture slots, and CPU reads of texture/palette-mapped VRAM are write-only on real NDS hardware** (verify this claim — the entire approach depends on it). If true, the write can go straight to DDR3 with zero per-frame copy cost.

Mirror VRAMCNT_A-I register state into the mailbox so the daemon can address textures correctly. The only expensive case is bank remaps (a game moves a VRAM bank from texture to 2D or vice versa), which requires a one-shot migration burst between DDR3 and board SDRAM. These are rare events — most games set VRAM mapping once at init. The two free ddram.sv channels (ch3, ch4) are available for exactly this.

**Static-mapping games (the majority) pay zero per-frame bandwidth for texture access.**

### Rejected: HPS-to-FPGA bridge (h2f at 0xC0000000)

Uncached `/dev/mem` reads across the h2f bridge are ~150-300ns per word. Even a once-per-frame 512 KB bulk texture read would cost ~20ms — exceeding the entire 16.7ms frame budget. Dead on arrival for texture traffic. Also unproven on MiSTer (no shipping core uses it, preloader may not enable it).

The h2f bridge remains potentially useful for low-bandwidth control (mailbox registers, VRAMCNT state), but not for bulk texture data.

### Also considered: Dirty-page mirroring (per-frame snoop + DMA)

FPGA snoops VRAM writes to texture regions and DMA's dirty pages to DDR3. Works but pays copy bandwidth on every frame with texture updates. The write-time shadow approach above is strictly better for static-mapping games and equivalent for dynamic ones.

## Known risks and fidelity limits

### Display capture (must wire)

Engine A's capture unit can grab the 3D output back into VRAM. Games use this for motion blur, depth-of-field, and 3D-as-texture effects. The capture path must read from the BG0 seam post-daemon — i.e., after the daemon's rendered lines are composited. Verify this path exists and wire it explicitly.

### Mid-frame 3D register pokes (fidelity limit)

A few games tweak viewport or polygon attributes per-scanline via HBlank DMA. Frame-ahead rendering structurally cannot reflect mid-frame changes into the current frame's output. Mitigation: timestamp the capture stream per-scanline (cheap — just tag each command with the current VCount). The daemon can honor per-scanline changes for next-frame effects. Document the limit: "3D output is correct per-frame, not per-scanline."

### Licensing

- melonDS: GPLv3 — fine for a userspace daemon communicating across a memory-mapped protocol boundary. The FPGA core (GPLv2+ from the GBA donor) is a separate work.
- 3S-ARM: AGPL-3.0 — reference only; reimplement the FPGA-side video reader (the pattern is straightforward).
- MiSTer Frontier: GPL-3.0 — same consideration; the daemon launch pattern is a convention, not copyrightable code.

## Current core DDR3 layout

All at base offset 0x30000000 (FPGA-side, via f2sdram bridge):

| Region | Address | Size | Purpose |
|--------|---------|------|---------|
| Card ROM | 0x30000000 | up to 128 MB | .nds image, HPS-staged at load time |
| Framebuffer | 0x3FE00000 | 512 KB | 2 screens x 192 lines x 1 KB/line |
| Firmware | 0x3FF00000 | 256 KB | NDS firmware image |

The DDR3 arbiter (`ddram.sv`) has 6 channels; ch1 (firmware), ch2 (card ROM), ch5 (FB write bursts), ch6 (FB read bursts) are active. Ch3 and ch4 are tied off and available.

New regions needed for 3D HPS:

| Region | Size (est.) | Purpose |
|--------|-------------|---------|
| GX command buffer | ~64 KB x2 (ping-pong) | Serialized 3D register writes |
| 3D framebuffer | ~192 KB x2 (double-buffered) | Daemon-rendered 256x192 output |
| VRAM texture shadow | up to 512 KB | Texture/palette data shadowed at write time |
| Mailbox | 256 bytes | Control words, sequence numbers, VRAMCNT state |

## RTL cost estimate

| Component | ALMs | M10K | DSP | Notes |
|-----------|------|------|-----|-------|
| GX FIFO (= capture FIFO) | ~200-400 | 1-2 | 0 | 256-entry, depth-matched; GXSTAT flags from fill level |
| Shadow matrix storage | ~200-300 | 2 | 0 | Proj+pos+dir+tex matrices = 2 Kbit regs; position stack (32x16x32b = 16 Kbit) in 2 M10K BRAMs |
| Sequential 64-bit MAC datapath | ~1000-1500 | 0 | 2-4 | Shared by MTX_MULT (64 MACs), BoxTest (6 plane tests), PosTest (16 MACs), VecTest (9 MACs); operand routing dominates ALMs |
| RAM_COUNT + vertex tracking | ~200-400 | 0 | 0 | BEGIN/END_VTXS, polygon counters, consecutive-VTX dedup compare |
| DDR3 command writer | ~200-300 | 1 | 0 | Burst-write FSM (reuse ch5 pattern) |
| DDR3 3D line reader | ~200-300 | 1 | 0 | Burst-read into BG0 feed (reuse ch6 pattern) |
| VRAM write shadow logic | ~300-500 | 0 | 0 | Bank-decode + DDR3 redirect |
| Mailbox registers | ~50-100 | 0 | 0 | Control words, sequence numbers, VRAMCNT mirror |
| **Total** | **~2.5-4K** | **5-6** | **2-4** | |

## Open questions

1. **Verify the load-bearing VRAM fact:** are CPU reads of texture/palette-mapped VRAM banks truly write-only on real NDS hardware? If games can read back texture data through CPU, the shadow-at-write-time approach needs a read path too.

2. **Display capture wiring:** trace the engine A capture unit's data source in the current RTL and confirm it can read from the DDR3-fed BG0 seam post-daemon.

3. **melonDS GPU3D_Soft extraction:** build a minimal shim that drives GPU3D_Soft standalone — verify the interface boundary and identify all VRAM/state dependencies.

4. **VRAM bank remap frequency:** survey commercial NDS titles to confirm that mid-game texture bank remaps are rare (one-time init for most games).
