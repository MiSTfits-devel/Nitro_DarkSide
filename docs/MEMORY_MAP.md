# NDS → DE10-Nano Memory Budget

This is the analysis that decides whether the core fits. Everything else is engineering;
this is the bet. Companion ground truth: [NDS_HARDWARE.md](NDS_HARDWARE.md).

## What the FPGA offers (Cyclone V 5CSEBA6U23I7)

| Resource | Amount | Notes |
|---|---|---|
| M10K block RAM | 557 blocks = 5,570 Kb ≈ **696 KB** | the scarce commodity |
| MLAB | ~621 Kb usable as small RAMs | good for FIFOs/linebuffers |
| ALMs | 41,910 (~110K LE) | GBA2P (two full GBA cores) fits with strips |
| SDRAM (module) | 32–128 MB, 16-bit @ ~100 MHz | ~200 MB/s peak, random access ~8–10 cycles; GBA2P proved 4 clients on one port |
| Secondary SDRAM (dual-RAM boards) | optional | do **not** require it; keep as perf escape hatch |
| DDR3 (HPS shared) | 512 MB+, 64-bit burst | high latency, high bandwidth; framebuffer/savestates/ROM staging in GBA2P |

Framework overhead (sys/, scaler line buffers, hps_io) plus core FIFOs historically eat
~50–80 KB of M10K. Assume **~600 KB of M10K genuinely available** to the core.

## What the NDS demands

| Memory | Size | Access pattern | Placement (phase 1 decision) |
|---|---|---|---|
| Main RAM | 4 MB | both CPUs, arbitrated (EXMEMCNT); real HW is slow-ish 16-bit-ish anyway | **SDRAM** via guest channels (the `gba_mem_ewram_sdram` pattern, scaled) |
| VRAM banks A–D | 4×128 KB = 512 KB | per-scanline renderer fetches + CPU/DMA writes; remappable | **SDRAM initially** with per-line prefetch into MLAB/M10K line caches; promote hot mappings to BRAM later if it doesn't hold (see §Renderer feed) |
| VRAM banks E,F,G,H,I | 64+16+16+32+16 = 144 KB | same, plus ext-palette roles need per-pixel random reads | **BRAM** (144 KB) |
| Std palettes (2 engines) | 2 KB | per-pixel | BRAM |
| Ext palettes (mapped from E/F/G/H/I) | up to 96 KB addressable | per-pixel | covered by E–I being BRAM (A–D can never be ext-pal — HW constraint) |
| OAM ×2 | 2 KB | per-line | BRAM |
| Shared WRAM | 32 KB | both CPUs, WRAMCNT-banked | BRAM |
| ARM7 WRAM | 64 KB | ARM7 only | BRAM |
| ITCM / DTCM | 32 + 16 KB | ARM9 zero-wait | BRAM |
| ARM9 I/D caches | 8 + 4 KB + tags | required to make SDRAM main-RAM viable | BRAM (~16 KB with tags) |
| BIOS 9/7 | 32 + 16 KB | boot + SWI calls | BRAM (or HLE, then smaller) |
| Card ROM | up to 512 MB | 512-byte page reads via ROMCTRL, latency-tolerant | **DDR3** direct (no SDRAM copy — unlike GBA; NDS card timing is slow and FIFO'd, DDR3 latency hides fine) |
| Save (EEPROM/Flash/FRAM) | ≤ 8 MB | AUXSPI, very slow | SDRAM or DDR3 + SD save path |
| Firmware NVRAM | 256 KB | SPI, slow | DDR3/HPS |
| Sound sample fetch | main-RAM reads, 16 ch | steady trickle | via ARM7 main-RAM channel + small FIFOs |

**BRAM ledger (phase 1):** 144 (E–I) + 2 (pal) + 2 (OAM) + 32 (SWRAM) + 64 (WRAM7) + 48 (TCM)
+ 16 (caches) + 48 (BIOS) ≈ **356 KB**, leaving ~240 KB M10K of headroom for line caches,
FIFOs, and whatever A–D mapping strategy needs. This fits. If A–D also had to be BRAM it
would not (356+512 = 868 KB > 696 KB) — hence the SDRAM strategy below is load-bearing.

## Renderer feed: why VRAM A–D in SDRAM can work

The 2D drawers (GBA-proven design) render one line ahead into line buffers. An NDS line is
2130 system clocks (355 dots × 6 clk); at 100 MHz the memory clock gives ~6390 cycles per
line. Worst-case per-line fetch for one engine: BG tilemaps+chars+bitmap ≈ a few KB, OBJ
up to ~1.5 KB visible per line. A per-line **VRAM read server** that streams the needed
regions into small caches has bandwidth to spare; the hard part is *address generation
correctness* across remappings, and CPU/DMA write coherency (write-through: CPU writes go
to SDRAM and invalidate/update line caches).

Fallback ladder if line-serving proves too complex or too slow:
1. Promote banks currently mapped as OBJ to BRAM (OBJ access is the most random): needs
   ≤ 256 KB only if games actually map A–D as OBJ; most 2D games use one 128 KB bank.
2. Shadow-BRAM scheme: keep a 128–256 KB BRAM pool, dynamically assign it to the ≤2 banks
   mapped to hot roles, spill LCDC/idle banks to SDRAM (banks in LCDC mode are CPU-only —
   trivially SDRAM-safe).
3. Dual-SDRAM build profile (like GBA2P's build-profile trick) for boards with the addon.

## SDRAM channel plan (single 16-bit port @ 100.5 MHz)

Clients, in priority order: (1) VRAM line server, (2) ARM9 main RAM (cache-line fills,
32-byte), (3) ARM7 main RAM, (4) DMA engines, (5) save backend. GBA2P already runs 4 guest
channels with `allow/active/busy/hold_ena` arbitration on one port — same pattern, more
clients, plus bank interleaving. Main-RAM on real NDS is already the slow path games are
tuned around (that's why the DS has TCMs and caches), so SDRAM latency lands in the same
regime the software expects. Cycle-accuracy target: match EXMEMCNT-era main-RAM timings
within a few percent, exact TCM/WRAM/VRAM timings.

## DDR3 map (extends GBA2P's DDR3Mux)

| Client | Window | Notes |
|---|---|---|
| Framebuffer out | 128 MB+ | two 256×192 screens composed; reuse videoout/scaler path |
| Card ROM image | 0.5–512.5 MB | streamed by card state machine |
| Savestates/rewind | high window | NDS state ≈ 5 MB/slot (main RAM dominates) — rewind ring shrinks to ~8 slots or compresses |
| Firmware/NVRAM image | small window | loaded by HPS |

## Clocking

- clk1x = **33.513982 MHz** (NDS system clock; ARM7, bus, video: 6 clk/dot, 2130 clk/line, 560190 clk/frame)
- ARM9 at 67.027964 MHz: implement as clk2x domain *or* GBA-style single fast domain with
  `ce` pacing (ARM9 ce = every clk2x tick, ARM7/bus ce = every 2nd). Decision deferred to
  CPU integration; the GBA single-clock+ce model is the default.
- clk6x ≈ 100.54 MHz memory clock (SDRAM controller reuse — GBA runs it at 100.66, same ballpark; verify sdram.sv timing margins).
- Video out ~59.826 Hz, both screens composed into one framebuffer (side-by-side/stacked,
  user-selectable, like GBA2P's dual view).
