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
   `ena/done` handshake in a wrapper (`nds_wrap` ⟵ `gba_wrap` role). ARM9 2× speed is a `ce`
   schedule question, not a clock-domain question, until proven otherwise.
3. **SDRAM guest channels**: `allow/active/busy/hold_ena` arbitration
   (`gba_mem_ewram_sdram.vhd` pattern) scaled to: VRAM line server, ARM9 main RAM,
   ARM7 main RAM, save backend.
4. **DDR3Mux client-index** pattern for framebuffer / card-ROM stream / savestates.
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
| Divider/sqrt | none | new, small: iterative divider (64/64) + sqrt, latency-accurate |
| Math/keys/EXMEMCNT | reggba patterns | small |
| Wifi | — | stub: IDs + IRQ-silent, per melonDS-minimum |
| GBA slot | — | phase-2+: absent cart reads (open bus 0xFFFF), EXMEMCNT bits honored |
| 3D geometry/render | — | **out of scope phase 1**: GXSTAT reads sane-idle, GXFIFO swallows writes w/ correct FIFO counts so 2D games that poke it don't hang |
| Boot | savestates reset path | **HLE direct-boot**: HPS/loader parses card header, stages ARM9/ARM7 images into SDRAM main RAM (via romcopy-style channel), populates shared-area mailbox (user settings, header copies) per NDS_HARDWARE.md §Boot, sets WRAMCNT=3, releases both CPUs at entry addresses. **"Firmware boot menu = never" no longer holds**: a real firmware boot path exists as of 2026-07-29 (`fw_boot` / bench `FWBOOT=1`) — both retail BIOSes run from their reset vectors, `nds_card` implements the raw + KEY1 boot command sequence, and the ARM7 BIOS matches the melonDS oracle exactly. It is **sim-side only**; `NDS.sv` still hardwires `direct_boot(1'b1)`, and enabling it on hardware costs ~4 s of boot. See HANDOFF.md "Firmware boot". |
| Video out | `videoout160` + colorshade | rework: 256×192×2 screens → DDR3 framebuffer; layouts (stacked/side-by-side/single+swap via POWCNT.DSEL) |
| Savestates | trio vendored later | phase-3: NDS state ~5 MB (main RAM in SDRAM must stream through) |

## Top-level structure (target)

```
NDS.sv (emu)                        — MiSTer framework glue, HPS, PLL, sdram/ddram
└── nds_wrap.vhd                    — clk domains, SDRAM/DDR3 muxing, video compose
    ├── nds_top.vhd                 — the console, clk1x+ce domain
    │   ├── nds_cpu9 (ARM946E-S)    + itcm/dtcm/caches
    │   ├── gba_cpu  (ARM7TDMI)
    │   ├── nds_membus9 / nds_membus7   — per-CPU decoders (GBA memorymux pattern)
    │   ├── nds_wram.vhd            — shared WRAM + WRAMCNT
    │   ├── nds_vram.vhd            — banks, VRAMCNT (decode: nds_vram_map.vhd)
    │   ├── nds_gpu2d ×2            — engines A/B (drawer fork)
    │   ├── nds_dma ×2, nds_timer ×2, nds_irq ×2
    │   ├── nds_ipc.vhd             — SYNC + FIFOs
    │   ├── nds_sound.vhd           — 16ch + capture (ARM7 side)
    │   ├── nds_card.vhd            — ROMCTRL/AUXSPI
    │   ├── nds_spi.vhd             — touch/firmware/PM
    │   ├── nds_math.vhd            — div/sqrt
    │   └── nds_gx_stub.vhd         — 3D register façade
    ├── memory servers (clk6x): main-RAM channels, VRAM line server, card pager
    └── DDR3Mux (vendored) / sdram.sv (vendored)
```

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
