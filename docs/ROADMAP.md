# Roadmap — to a booting 2D game and beyond

Milestones are sim-first (nvc on the k8s host), hardware-second. Each has a concrete,
self-checking exit test. Reference emulator for differential traces: melonDS.

## M0 — Scaffold (this commit)
Repo, docs, vendored primitives + ARM7TDMI, VRAM map decoder + passing unit test.

## M1 — Memory fabric in sim
- `nds_vram.vhd` with real backing stores (E–I BRAM; A–D behind a stub server), overlap
  and ARM7-mapping semantics; `nds_wram.vhd` (WRAMCNT 4 modes); main-RAM guest channels
  against the real `sdram.sv` + `ddrram_model`.
- Exit: memory torture testbench — randomized VRAMCNT/WRAMCNT reconfiguration with
  read/write verification against a behavioral model, 10M ops clean.

## M2 — ARM7 island boots
- Vendored `gba_cpu` wired to `nds_membus7`: BIOS(HLE-min) + WRAM + main RAM + timers +
  IRQ + IPC regs.
- Exit: hand-written ARM7 binary (NitroSDK toolchain or devkitARM) runs, exercises timers/
  IRQ/IPC-loopback, writes magic to shared RAM. Cycle counts sanity-checked.

## M3 — ARM946E-S  ✅ (2026-07-16)
- `nds_cpu9.vhd`: v5TE instruction set, CP15, TCMs, caches (write-back D-cache w/ correct
  clean/invalidate ops — `nds_cache9.vhd`, self-checking exit test `run_arm9_cache.sh`),
  2× pacing (CPU at full ce, peripherals at ce/2 with IO-pulse alignment in membus9).
- Exit: armwrestler-style workload = `gen_arm9_torture.py` (seeded random v5TE chunks);
  differential trace vs melonDS 0.9.5 (docs/TRACE_DIFF.md) over 10M instructions,
  **zero divergence**, caches off and on. Took ~40 min on the cluster, not 60 hours.
  Found 1 RTL bug (ROR-by-reg C flag) and 2 melonDS 0.9.5 bugs (EORS/LSR table typo,
  ADC/SBC/RSC V-flag double-overflow) on the way.

## M4 — Dual-CPU + boot HLE
- Both CPUs + IPC FIFO + EXMEMCNT + card-header HLE loader (images pre-staged in SDRAM).
- Exit: NitroSDK demo binary (e.g. from SDK samples) reaches main() on both CPUs,
  IPC handshake completes (crt0/OS_Init path in sim trace).

## M5 — Engine A renders
- Drawer fork with NDS text/affine/extended modes + ext palettes + new OBJ modes; VRAM line
  server v1; framebuffer out through `graeval`-compatible dump.
- Exit: SDK 2D graphics samples render pixel-perfect vs melonDS screenshot dumps.

## M6 — Engine B + full display path
- Second engine, POWCNT routing/swap, master brightness, video compose to DDR3.
- Exit: dual-screen SDK sample pixel-perfect on both screens.

## M7 — Sound + touch + RTC + save
- 16ch mixer + capture; SPI touch; RTC; AUXSPI save with SD persistence.
- Exit: sound sample plays bit-accurately (mixer unit tests + capture loopback);
  touch sample responds; save survives reset.
- 2026-08-06: the mixer now **fits and ships on hardware** (`SOUND_ENABLE=1`,
  `NDS_audio_20260806`, 41,024 ALMs / 98%, all slack positive). An A/B
  equivalence bench against a verbatim pre-refactor copy exists and is
  fault-injection verified (c06cdce). NOT yet exit-tested: bit-accuracy on
  hardware is unconfirmed — nobody has listened to it against a reference.
  Area is measured and the diet is planned; see FITTING.md "Sound area".
- 2026-08-08: **the SPU is moving to the HPS ARM** — a diet cannot close the
  ~3,600 ALM gap to HDMI, and only a full farm-out can (docs/HPS_AUDIO.md).
  The transport half is built and sim-verified: a DDR3 ring at `0x0FFD0000`,
  `rtl/nds_audio_ddr3.sv` draining it into `AUDIO_L/R`, on ch3. Exit test for
  this step is a tone out of the DE10-Nano with no daemon running at all
  (`tools/audio-tone.sh on`). The SPU state itself has not moved yet, and
  `nds_sound` stays as the reference the daemon gets judged against.

## M8 — First game
- Card DMA patterns, remaining DMA triggers, IRQ edge cases, open-bus behaviors.
- Exit: **Kirby: Squeak Squad** (Robert's proven title) playable start-to-first-boss in sim
  fast-forward + on hardware.

## M9 — Hardware bring-up & fitting war
- NDS.sv + qsf profiles; timing closure at 100.5/67/33.5; the BRAM knife-fight.
- Exit: RBF boots M8's game on a DE10-Nano at full speed.
- 2026-08-06: **Kirby: Squeak Squad is playable on hardware.** Two timing-clean
  images ship from one tree, selected by two generics + two QSF macros:
  `NDS_audio_20260806` (41,024 ALMs, sound, no HDMI) and
  `NDS_hdmi_noflicker_20260806` (38,176 ALMs, HDMI, no sound). They cannot be
  combined — HDMI costs a measured ~3,600 ALMs. Not "at full speed": affine-heavy
  scenes miss the line budget (docs/TICKET-obj-affine-slowness.md), and known
  rendering defects remain open in that ticket.

## M10 — Compatibility sweep (2D library)
- The long tail: per-game issues, DISPCAPCNT, main-mem display FIFO, GBA-slot stubs.
- Exit: curated 2D compatibility list ≥ 20 titles.

## Deferred indefinitely
3D engines (games needing them), wifi beyond stubs, DSi, GBA-slot pass-through to a real
GBA core instance (tantalizing — the donor core is *right there* — but no).
