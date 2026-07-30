# NDS_MiSTfits Architecture — Port Plan from GBA_MiSTfits

The donor core is `../GBA_MiSTer` (GBA_MiSTfits fork of GBA2P). This document maps every
NDS subsystem to its donor counterpart or marks it new-build. Ground truth for the NDS side
is [NDS_HARDWARE.md](NDS_HARDWARE.md); the fit analysis is [MEMORY_MAP.md](MEMORY_MAP.md).

## Inherited conventions (do not reinvent)

1. **Register bus + savestates**: `proc_bus_gba.vhd`'s `proc_bus_gb_type` + `eProcReg_gba`
   dual-instantiation (live bus + savestate bus) gives every IO register savestate support
   for free. Vendored verbatim; NDS register banks are new `regnds_*.vhd` packages using the
   same `regmap_type` convention. The 28-bit address covers NDS IO (`0x04000000`–`0x04001060`
   fits easily; engine-B block keys off Adr(12)).
2. **Core pacing**: single system-clock domain gated by `ce`, fast memory isolated behind an
   `ena/done` handshake. **As built this went the other way and then came back.** The ARM9 got
   a real second clock domain — `nds_top`'s `clk2x` port and the clk1x↔island bridge at
   `nds_top.vhd:837-1044` — and `NDS.sv:1017` now ties `clk2x` to `clk_sys`, so the island
   exists in the RTL and runs at 1:1. There is **no `ISLAND` generic** on `nds_top`; `ISLAND`
   is a testbench generic (`sim/tb_top_frame.vhd:61`), and in hardware the ratio is whatever
   `NDS.sv` drives into `clk2x`. Do not lower it: cross-domain setup budget follows edge
   alignment, not period, so only integer ratios are viable and 2:1 failed to close.
3. **SDRAM guest channels**: `allow/active/busy/hold_ena` arbitration
   (`gba_mem_ewram_sdram.vhd` pattern). As built there are two clients on this pattern, not
   four: `nds_mainram` owns `sdram ch2`, and the **CPU** VRAM A–D path borrows it
   (`NDS.sv:805-874`). The VRAM **line server** does not use it at all — it has its own
   read-only `ch1` (see §Renderer feed in MEMORY_MAP.md). No save backend exists yet.
4. ~~**DDR3Mux client-index** pattern for framebuffer / card-ROM stream / savestates.~~
   **Not used.** `DDR3Mux.vhd` is compiled into the project (`rtl/nds.qip:22`) but never
   instantiated; `ddram.sv`'s own six-channel round-robin arbitrates (`NDS.sv:716`).
5. **Build-profile macros** (GBA2P_LITE-style `.qsf` one-liners) for e.g. `NDS_DUALSDRAM`,
   `NDS_NOSAVESTATES` fitting experiments.
6. **nvc sim flow**: three-library build (`altera_mf` stub, `mem`, `work`), self-checking
   testbenches, `run_*.sh` wrappers, `--exit-severity=failure`. Long sims run on the k8s
   x86_64 host.

## Subsystem map

| NDS subsystem | Donor | Work |
|---|---|---|
| ARM7TDMI (the NDS ARM7) | `gba_cpu.vhd` vendored verbatim | near-zero: swap memory map (no GBA prefetch quirk on NDS side; BIOS at 0x0 16 KB; halt/IME semantics identical) |
| ARM946E-S (ARM9) | fork of `gba_cpu.vhd` → `nds_cpu9.vhd` | **major**: +ARMv5TE ops (BLX, CLZ, QADD/QSUB/QDADD/QDSUB, SMULxy family, LDRD/STRD, PLD as nop), CP15 (PU regions, cache control, TCM base regs), I-cache 8K/D-cache 4K, ITCM/DTCM zero-wait paths, high vectors |
| 2D engine A | `gba_gpu_drawer` + drawers | **large delta**: 512 KB BG space w/ global char/screen base, ext palettes, big affine (BG2/BG3 modes incl. 8bpp affine + direct-color bitmaps), bitmap OBJs, 1D OBJ mapping strides, 3D-as-BG0 slot (stub: transparent), capture unit (later), master brightness |
| 2D engine B | second drawer instance | parametrize engine A implementation (generic `is_engine_b`: no 3D slot, no capture, ext-pal from H/I) — the GBA2P dual-instantiation experience applies directly |
| VRAM banking | none (GBA VRAM was fixed) | **new**: `nds_vram.vhd` — VRAMCNT decode, bank hit/offset math, overlap semantics, ARM7 C/D mapping, ext-pal ports. Decode logic exists (`nds_vram_map.vhd`), backing store per MEMORY_MAP.md |
| WRAMCNT shared WRAM | none | new, small: 4 mapping modes, both CPUs |
| DMA 4+4 ch | `gba_dma*.vhd` ×2 | moderate: 32-bit SAD/DAD everywhere, new start triggers (main-mem display FIFO, card, GXFIFO stub), DMA fill regs |
| Timers 4+4 | `gba_timer*.vhd` ×2 | trivial |
| IRQ ctrl ×2 | `reggba_system` pattern | small: more sources (bits 16–24), two controllers |
| IPC SYNC+FIFO | none | new, small: 16-deep 32-bit FIFOs ×2 + IPCSYNC nibbles + 4 IRQs |
| Sound 16ch + capture | `gba_sound_dma.vhd` concepts | **new-ish**: 16 uniform channels (PCM8/PCM16/ADPCM/PSG duty/noise), per-channel timer/loop, mixer, 2 capture units; ARM7-side main-RAM fetch FIFOs |
| Card interface | none | new: ROMCTRL/CMD state machine, 512-byte page FIFO from DDR3, KEY1 encryption **skipped** via HLE fast-boot (load binaries directly, set boot state) |
| AUXSPI save | `memorymux_extern` flash/EEPROM FSMs | adapt: EEPROM/Flash/FRAM behind SPI framing |
| SPI: touch, firmware, PM | none | new, small: TSC2046 model fed by MiSTer touch/analog input; firmware image in DDR3; PM stub |
| RTC | `gba_gpioRTCSolarGyro.vhd` | adapt bit-bang protocol to reg 0x138 |
| Divider/sqrt | none | **NOT BUILT.** Planned as `nds_math.vhd` (iterative 64/64 divider + sqrt, latency-accurate). No such file exists and there is no `DIVCNT`/`SQRTCNT` decode anywhere in `rtl/`, so `0x04000280`–`0x040002B8` falls through to an unclaimed IO read (returns 0) |
| Math/keys/EXMEMCNT | reggba patterns | small |
| Wifi | — | **NOT BUILT** (not even the stub): `0x048xxxxx` is open bus in the ARM7 map (`nds_membus7.vhd:164`) and DMA7 timing mode `11` never fires (`nds_dma7.vhd:239`). No IDs, no registers, no IRQ |
| GBA slot | — | phase-2+: absent cart reads (open bus 0xFFFF), EXMEMCNT bits honored |
| 3D geometry/render | — | **out of scope phase 1**, and **the register façade was never built either**: grep finds no `GXFIFO` and no `GXSTAT` in `rtl/`, so a title that polls them gets an unclaimed IO read rather than the sane-idle answer this row promised. The only 3D-adjacent thing that exists is DISPCNT's BG0-is-3D bit, and the slot renders transparent |
| Boot | savestates reset path | **HLE direct-boot**: HPS/loader parses card header, stages ARM9/ARM7 images into SDRAM main RAM (via romcopy-style channel), populates shared-area mailbox (user settings, header copies) per NDS_HARDWARE.md §Boot, sets WRAMCNT=3, releases both CPUs at entry addresses. **DECISION REVERSED 2026-07-29: "Firmware boot menu = never" no longer holds, and it is now wired to hardware.** A real firmware boot path exists (`fw_boot`, bench `FWBOOT=1`) — both retail BIOSes run from their reset vectors, `nds_card` implements the raw + KEY1 boot command sequence, and the ARM7 BIOS matches the melonDS oracle with zero control-flow divergence over 323,826 basic blocks. **Selectable at runtime from the OSD on `status[9]`** (`Boot: Direct (HLE) / Firmware`), so direct boot remains the default and the tested path. Requires ARM7 BIOS, ARM9 BIOS and Firmware all loaded from the OSD. Costs ~4 s of boot when enabled. Known limit: it reaches 1.588 s of DS time and then the ARM7 executes Thumb code in ARM state (lost T bit) — see HANDOFF.md "Firmware boot". |
| Video out | `videoout160` + colorshade | rework: 256×192×2 screens → DDR3 framebuffer; layouts (stacked/side-by-side/single+swap via POWCNT.DSEL) |
| Savestates | trio vendored later | phase-3: NDS state ~5 MB (main RAM in SDRAM must stream through) |

## Top-level structure (as built)

This was a *target* tree and three parts of it never happened: there is no `nds_wrap.vhd`,
no `nds_math.vhd`, no `nds_gx_stub.vhd`, and the memory servers are not in a separate clock
domain. What is actually instantiated:

```
NDS.sv (emu)                        — MiSTer glue, HPS, PLL, OSD, *and* everything the
│                                     planned nds_wrap was going to do: clock plan,
│                                     clkMemIndex, SDRAM/DDR3 channel adapters, video
├── pll                             — 50 MHz ref → 3 outputs, exactly 1:2:3
│                                     clk_sys 33.513982 / CLK_VIDEO 67.027964 / clkMem 100.541946
├── nds_hps_io_boundary             — HPS transport (currently framework hps_io)
├── sdram.sv   (clkMem)             — ch1 renderer VRAM reads, ch2 main RAM + CPU VRAM
├── ddram.sv   (clk_sys)            — ch1 firmware, ch2 card, ch4 mailbox, ch5/ch6 framebuffer
├── nds_fb_ddr3.sv                  — line accumulators, burst writer, scanout prefetch
└── nds_port_wrap.vhd               — VHDL/SV boundary ONLY. No logic: terminates record
    │                                 ports, converts ranged integers. Sets GPU_FAST => 0
    └── nds_top.vhd                 — the console, clk1x + ce
        ├── ARM9 island (clk2x port, tied to clk_sys — see convention 2)
        │   ├── nds_cpu9 (ARM946E-S), nds_membus9, nds_cache9 (8K I + 4K D)
        │   ├── ITCM 32 KB / DTCM 16 KB (SyncRamDualByteEnable, M10K)
        │   └── nds_bios9 — 4 KB, and it is clocked at clk2x on purpose (nds_top.vhd:1128)
        ├── gba_cpu (ARM7TDMI), nds_membus7, nds_bios7 16 KB, ARM7 WRAM 64 KB
        ├── clk1x↔island bridge     — toggle requests, edge-detected dones, payload latches
        ├── nds_dma9 / nds_dma7, gba_timer ×2, nds_irq ×2
        ├── nds_ipc.vhd             — IPCSYNC + two 16-deep 32-bit FIFOs
        ├── nds_syscnt.vhd          — WRAMCNT / VRAMCNT / POWCNT / EXMEMCNT / HALTCNT
        ├── nds_wram.vhd            — shared WRAM 32 KB + WRAMCNT
        ├── nds_mainram.vhd         — 4 MB in SDRAM, two guest channels, arm7_priority
        ├── nds_vram.vhd            — banks + CPU datapaths + the pipelined line server
        │                             (decode: nds_vram_map.vhd). ON clk1x, not a memory clock
        ├── nds_gpu_timing.vhd      — dot/line/frame, DISPSTAT, drawline/drawObj
        ├── nds_gpu2d_fast ×2       — clock-domain wrapper around nds_gpu2d, engines A/B.
        │                             GPU_FAST=0 elaborates `gslow` = straight through on clk1x
        ├── nds_sound.vhd           — 16ch (capture NOT built), ARM7 bus guest
        ├── nds_card.vhd            — ROMCTRL/AUXSPI regs + raw & KEY1 boot sequence
        ├── nds_spi.vhd             — PMIC / firmware flash / TSC framing
        ├── nds_rtc.vhd, nds_loader.vhd, nds_debug.vhd (IS-NITRO-style mailbox)
        └── (no nds_math, no nds_gx_stub — see the subsystem map)
```

Each 2D engine holds **ten** drawer instances, not five: `nds_drawer_text` ×4,
`nds_drawer_affine` ×2, `nds_drawer_extended` ×2 (BG2/BG3 carry all three, selected by mode
and muted otherwise), `nds_drawer_obj`, `nds_drawer_merge`. The BG VRAM arbiter inside
`nds_gpu2d` multiplexes **only the four BG layers**; OBJ, BG ext-palette and OBJ ext-palette
are three further independent channels per engine, so eight renderer channels reach
`nds_vram` (`nds_top.vhd:1719-1736`).

## Risk register (ordered)

1. **VRAM-in-SDRAM line server** — the fitting bet. Mitigations in MEMORY_MAP.md §Renderer feed.
2. **ARM946E-S correctness** (v5TE + CP15 + caches) — biggest new RTL; mitigated by vendoring
   the proven ARM7 pipeline and diffing against melonDS traces in sim.
3. **SDRAM bandwidth under worst-case contention** (both CPUs + VRAM server + sound) — build
   the bandwidth model early in sim with the real sdram.sv.
4. **Fitting two drawers + two CPUs in ALMs** — GBA2P proves 2×(CPU+GPU) fits with strips;
   NDS drawers are bigger but there is one console's worth of everything else.
5. **HLE boot fidelity** (games reading firmware user data, RTC state) — shared-area
   population must be complete; melonDS is the reference.
