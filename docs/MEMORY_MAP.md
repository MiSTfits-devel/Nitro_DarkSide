# NDS → DE10-Nano Memory Budget

This is the analysis that decides whether the core fits. Everything else is engineering;
this is the bet. Companion ground truth: [NDS_HARDWARE.md](NDS_HARDWARE.md).

> **Why even a hybrid core doesn't dodge this** — Robert Peip (July 2026), on whether a
> Dreamcast-style hybrid (CPU emulated on the HPS ARM, graphics on FPGA) could rescue the
> DS: "the issue with DS is the memory for the graphics part, so exactly what is running
> for dreamcast on the FPGA part is not great to do for DS. (yes DS is more demanding in
> this regard than DC)." The graphics-memory problem is unavoidable on any FPGA-rendered
> path — hybrid or full-FPGA — which is why this document attacks it head-on, and why
> solving it here keeps the (preferable) full-FPGA core viable. Our advantage over the DC
> situation: the NDS 2D engines' access patterns are line-buffered and prefetchable
> (§Renderer feed), unlike a PowerVR TA doing random texture walks.

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
| Std palettes (2 engines) | 2 KB *as spec*, **10 KB as built** | per-pixel | BRAM. Replicated: one 1 KB copy per BG plus one for OBJ, per engine, so no two readers share a port (`nds_gpu2d.vhd:857`) |
| BG ext palettes | 32 KB **per engine**, shadowed | per-pixel | BRAM, and **not** covered by E–I as this table assumed: `nds_gpu2d` keeps its own four 8 KB slot RAMs (`EPSLOT_WORDS=2048`, `nds_gpu2d.vhd:952`) refilled from VRAM during vblank. 64 KB for the pair |
| OBJ ext palettes | 8 KB addressable | per-pixel | *Not* shadowed — read live from E–I over the `objep` renderer channel, so this row's original assumption holds here only |
| OAM ×2 | 2 KB | per-line | BRAM (256 words per engine, `nds_gpu2d.vhd:882`) |
| Line buffers ×2 engines | 6 KB per engine | per-pixel | BRAM: four 1 KB BG buffers + a 2 KB OBJ buffer (`nds_gpu2d.vhd:1223`, `:1262`) |
| Shared WRAM | 32 KB | both CPUs, WRAMCNT-banked | BRAM |
| ARM7 WRAM | 64 KB | ARM7 only | BRAM |
| ITCM / DTCM | 32 + 16 KB | ARM9 zero-wait | BRAM |
| ARM9 I/D caches | 8 + 4 KB + tags | required to make SDRAM main-RAM viable | BRAM (~16 KB with tags) |
| BIOS 9/7 | **4 + 16 KB** | boot + SWI calls | BRAM. This row said 32 + 16; the ARM9 BIOS is 4 KB on real hardware and the instantiated ROM matches (1,024 words, `nds_bios9.vhd:42`). Both are hot-loadable from the OSD, with HLE constants as the fallback |
| Card ROM | **up to 128 MB reachable** | 512-byte page reads via ROMCTRL, latency-tolerant | **DDR3** direct (no SDRAM copy — unlike GBA; NDS card timing is slow and FIFO'd, DDR3 latency hides fine). This row said 512 MB, but `card_addr` is a 25-bit *word* address (`NDS.sv:545`), so 128 MB is the ceiling. Also an 8 KB M10K page store inside `nds_card` (`nds_card.vhd:172`) |
| Save (EEPROM/Flash/FRAM) | ≤ 8 MB | AUXSPI, very slow | SDRAM or DDR3 + SD save path |
| Firmware NVRAM | 256 KB | SPI, slow | DDR3/HPS |
| Sound sample fetch | main-RAM reads, 16 ch | steady trickle | via ARM7 main-RAM channel + small FIFOs |

**BRAM ledger — original estimate (kept for the record):** 144 (E–I) + 2 (pal) + 2 (OAM)
+ 32 (SWRAM) + 64 (WRAM7) + 48 (TCM) + 16 (caches) + 48 (BIOS) ≈ **356 KB**.

**BRAM ledger as built**, counted off the instantiated `SyncRamDualByteEnable` generics
(`ADDR_WIDTH` words × `BYTES`=4) rather than estimated:

| | KB | where |
|---|---|---|
| VRAM E–I | 144 | `nds_vram.vhd:294` (`BRAM_AW`: E 14, F 12, G 12, H 13, I 12) |
| 2D engines, ×2 | 88 | 44 each: BG ext-pal slots 32, palettes 5×1, line buffers 4×1, OBJ buffer 2, OAM 1 |
| ARM7 WRAM | 64 | `nds_top.vhd:1504` |
| ITCM + DTCM | 48 | `nds_top.vhd:1304`, `:1333` |
| Shared WRAM | 32 | `nds_wram.vhd:95` |
| BIOS 9 + 7 | 20 | `nds_bios9.vhd:42`, `nds_bios7.vhd:42` |
| ARM9 caches | ~14 | 8 + 4 data, ~1.5 of tags (`nds_cache9.vhd:338`–`:425`) |
| Card page store | 8 | `nds_card.vhd:172` |
| **total** | **≈ 418 KB** | |

The estimate was 62 KB light, in both directions: the BIOS row was 28 KB pessimistic, and the
2D engines cost 84 KB more than the 4 KB this table allowed them — the BG ext palettes are
*shadowed* inside `nds_gpu2d`, not read live out of E–I, and the standard palette is
replicated per BG to give every drawer a private read port.

**Do not plan against the byte total.** The fitter counts M10K *blocks* (557 × 1.25 KB), and
a 1 KB line buffer still consumes whole blocks, so block usage runs far ahead of byte usage:
the build that closed timing measured **85% of M10K** against a 418 KB ledger that looks like
60% of 696 KB. The conclusion the original ledger drew still holds and is now the load-bearing
one: if A–D also had to be BRAM the core would not fit, so the SDRAM strategy below is what
makes the whole thing possible.

## Renderer feed: why VRAM A–D in SDRAM can work

The 2D drawers (GBA-proven design) render one line ahead into line buffers. An NDS line is
2130 system clocks (355 dots × 6 clk); at 100 MHz the memory clock gives ~6390 cycles per
line. Worst-case per-line fetch for one engine: BG tilemaps+chars+bitmap ≈ a few KB, OBJ
up to ~1.5 KB visible per line. A per-line **VRAM read server** that streams the needed
regions into small caches has bandwidth to spare; the hard part is *address generation
correctness* across remappings, and CPU/DMA write coherency (write-through: CPU writes go
to SDRAM and invalidate/update line caches).

**What was actually built** differs from that sketch in one way that matters, and the
difference is where the current bug lives:

- The server is **pipelined, not per-line prefetch**. `nds_vram` accepts one request per
  cycle across all eight renderer channels, tracks them in an 8-entry completion queue and
  retires **in issue order**, so a client may hold several outstanding and needs no tags
  (`nds_vram.vhd:329-356`). Latency is hidden by prefetch FIFOs inside the drawers, not by
  streaming regions ahead of the line. The bandwidth argument above was never the problem.
- Caching is **one 8-byte line per channel**, not a region cache: indexed by channel so no
  channel can evict another's. That removed 76% of A–D reads on the mode-0 bench, where a
  single *shared* line removed 1% — eight interleaved channels destroy it
  (`nds_vram.vhd:413-427`).
- The channel is **64 bits, addressed by 8-byte line**, because `sdram.sv` reads four
  halfwords per access anyway (`BURST_LENGTH=4`) and a sequential burst wraps inside its
  aligned block. Asking for the line doubles the yield per access.
- **`sdram ch1` holds exactly one request in flight.** `ch1_rq` is a single bit, so
  back-pressure is exported to the core as `vrsrv_ready` and `nds_vram` holds its request
  until an accepting edge at `clkMemIndex == 2` (`NDS.sv:876-943`). This is the narrowest
  point in the whole path.

⚠️ **This is where the white screen came from, and it was not a bandwidth failure.** Until
commit `5cf5fe0` the testbench's memory model accepted a request every cycle and never
connected `vrsrv_ready` at all, so *no bench had ever exercised the back-pressure path* —
`tb_gpu2d`, `tb_gpu2d_frame`, `tb_gpu2d_timed`, `fbdiff` and the drawer equivalence bench all
passed against a memory that cannot say no. Adding `VRSRV_ONE=1` reproduced the reported
hardware symptom in minutes, and the cause was a **livelock**, not slowness: an over-budget
line was restarted from tile 0 by every subsequent `drawline`, so it could never finish.

| `nds_2dk`, GPUCEDIV=1, steady state | `done` lines | dropped | cyc/render |
|---|---|---|---|
| `VRSRV_ONE=1`, before either fix | 0–1 | 191 | 409,583 |
| + `drawline` gate (`nds_gpu2d.vhd:618`) | 95 | 97 | 3,010 |
| + 64-bit line and per-channel cache | **168** | 24 | **2,034** (under the 2,130 budget) |
| `VRSRV_ONE=0` (always-ready), after | 189 | 3 | 1,129 |

Two process lessons worth more than the fix:

- **Run anything headed for silicon with `VRSRV_ONE=1`.** A memory model that cannot say no
  cannot catch this class of bug, and four benches proved it by passing.
- **`renders` was a lying metric.** It counts `line_busy` *rising* edges, so a renderer that
  never goes idle reports one render per frame regardless of what it finished — and 0 when
  `line_busy` is still high at the frame boundary. Quote `done=` (falling edges) and
  `dropped=` instead. Full write-up in `TICKET-arm7-firmware-wedge.md` §Resolution.

**Still not verified on silicon.** All of the above is nvc against a *model* of `ch1`. The
64-bit path assumes `sd_ch1_dout[63:0]` is the aligned line in halfword order — read off
`sdram.sv`, never observed on hardware — and there is no renderer-side counter readable from
the HPS yet, so a first hardware run can only say "something / nothing on screen".

Fallback ladder if line-serving proves too complex or too slow:
1. Promote banks currently mapped as OBJ to BRAM (OBJ access is the most random): needs
   ≤ 256 KB only if games actually map A–D as OBJ; most 2D games use one 128 KB bank.
2. Shadow-BRAM scheme: keep a 128–256 KB BRAM pool, dynamically assign it to the ≤2 banks
   mapped to hot roles, spill LCDC/idle banks to SDRAM (banks in LCDC mode are CPU-only —
   trivially SDRAM-safe).
3. Dual-SDRAM build profile (like GBA2P's build-profile trick) for boards with the addon.

## SDRAM channel plan (single 16-bit port @ 100.5 MHz)

**As built** this is two `sdram.sv` channels, not one queue of five guests:

| Channel | Owner | Shape | Arbitration |
|---|---|---|---|
| `ch1` | renderer VRAM A–D reads | 64-bit read-only, 8-byte line | none needed — one op in flight, back-pressured by `vrsrv_ready` (`NDS.sv:953`, `:917`) |
| `ch2` | main RAM, **borrowed** by the CPU VRAM A–D path | 32-bit R/W + byte enables | `nds_mainram` owns it and issues at `clkMemIndex 0`; `vsrv` parks it (`mainram_allow` low), drains ≥4 cycles and until `mainram_busy` falls, runs one op, releases (`NDS.sv:805-874`) |
| `ch3` | — | — | tied off (`NDS.sv:970`) |

So the `allow/active/busy` pattern carries **two** clients, not four: the ARM9 and ARM7
main-RAM ports (which `nds_mainram` arbitrates between itself via `arm7_priority`), plus the
CPU VRAM borrow. The DMA engines are not separate clients — they master a CPU membus and
inherit its channel. There is no save backend. `sdram.sv` serialises its channels internally,
which is why `ch1` needs no scheduler handshake at all.

Original plan, kept for the record: clients in priority order (1) VRAM line server, (2) ARM9
main RAM (cache-line fills, 32-byte), (3) ARM7 main RAM, (4) DMA engines, (5) save backend.
GBA2P already runs 4 guest
channels with `allow/active/busy/hold_ena` arbitration on one port — same pattern, more
clients, plus bank interleaving. Main-RAM on real NDS is already the slow path games are
tuned around (that's why the DS has TCMs and caches), so SDRAM latency lands in the same
regime the software expects. Cycle-accuracy target: match EXMEMCNT-era main-RAM timings
within a few percent, exact TCM/WRAM/VRAM timings.

## DDR3 map (as built — `ddram.sv`, *not* DDR3Mux)

`DDR3Mux.vhd` is compiled into the project but never instantiated. `ddram.sv`'s own
six-channel round robin arbitrates, and each client gets a small pager FSM in `NDS.sv`, all on
`clk_sys` (`DDRAM_CLK = clk_sys`, `NDS.sv:542`).

| Client | Channel | Window | Notes |
|---|---|---|---|
| Card ROM image | `ch2`, 32-bit read | from byte 0, ≤ 128 MB reachable | staged straight to DDR3 by the HPS at load address `0x30000000`; beat-cached, and a dummy read at `0x1FFFFFE` displaces that cache after the HPS rewrites DDR3 behind it |
| Framebuffer | `ch5` write / `ch6` read, burst 128 | `0x0FE00000` | two 256×192 screens stacked, single-buffered, 32bpp `{14'b0, BGR666}`, two pixels per 64-bit beat |
| Firmware NVRAM | `ch1`, 64-bit read / 16-bit write lanes | `0x0FF00000`, 256 KB | `nds_spi` serves `fw[addr & 0x3FFFF]` (`nds_spi.vhd:241`). NB `nds_port_wrap.vhd:62` calls it 128 KB — that comment is wrong, the port carries 16 bits of *word* address |
| Debug mailbox | `ch4`, 64-bit R/W + BE | cmd `0x0FFF0000`, rsp `0x0FFF0008` | **the only uncached channel**, which is exactly why the mailbox uses it: every poll must see the HPS's newest write |
| Savestates/rewind | — | — | **not built.** The donor savestate buses are plumbed through `nds_cpu9`, `gba_cpu` and both timers but every `ss_wired_out` is left `open`; they are used at boot to preset the PCs, not to save state. NDS state ≈ 5 MB/slot when it happens |
| `ch3` | — | — | tied off |

## Clocking

One PLL, 50 MHz reference, **three** outputs at an exact 1 : 2 : 3 (`rtl/pll/pll_0002.v:25-34`).
Same VCO, so all three are *related* clocks and every crossing is a timed path, not a
synchroniser.

- `clk_sys` / clk1x = **33.513982 MHz** — the NDS system clock: both CPUs, all IO, both 2D
  engines, the DDR3 pagers, `nds_vram`. 6 clk/dot, 2130 clk/line, 560190 clk/frame.
- `clk_video_67` = **67.027964 MHz** (2×) — **video output only**. The ARM9 island used to
  share this, which is the only reason it was ever "at 67 MHz"; that was never an ARM9
  requirement. Pixel ce is `CLK_VIDEO`/4 = 16.757 MHz → **59.77 Hz** over a 533×526 frame
  with 256×384 active (`NDS.sv:1205-1214`).
- `clk_mem` = **100.541946 MHz** (3×) — the memory fabric: `sdram.sv` and the two VRAM
  channel adapters in `NDS.sv`. **Called "clk6x" elsewhere in this document and in the RTL
  comments — it is 3×, not 6×**; the 6 comes from the GBA donor's 16.78 MHz base.
- The ARM9 question is **settled, at 1:1.** `nds_top` has a `clk2x` port and a full
  clk1x↔island bridge, and `NDS.sv:1017` drives it from `clk_sys`. Not a `ce` schedule and not
  a 2× domain — a real second domain, currently running at the same rate. See ARCHITECTURE.md
  convention 2 for why it must not be lowered.

**`clkMemIndex` is a contract, not a convenience.** A `clk1x` toggle re-locks a mod-3 counter
every `clk1x` edge, so index 0 is the coincident edge (`NDS.sv:229-238`). Three modules depend
on a specific phase and none works on another: `nds_mainram` launches only at index 0
(`nds_mainram.vhd:178`); the renderer feed *accepts* a held request only at index 2, the edge
coincident with `clk1x`, so both ends agree which edge was the transfer (`NDS.sv:922`); and
`done` pulses are raised at index 1 so they are exactly one `clk1x` period wide
(`NDS.sv:870`, `:939`).

The GPU dot cadence is separately ce-paced at 1-of-`GPU_CE_DIV` = 3 (`nds_top.vhd:54`), so
relative to the CPUs a frame is 3× long; OSD `status[10]` switches it to 1-of-1 at real frame
rate (`NDS.sv:1038`).
