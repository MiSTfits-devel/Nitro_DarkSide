# NDS_MiSTfits handoff — 2026-07-20

> ## SUPERSEDED IN PART — 2026-07-25. Read this box first.
>
> The white screen's **root cause was found, fixed and verified on hardware**:
> `nds_loader` never zeroed main RAM, so NitroSDK's cartridge lock
> (`swp r0,r0,[0x027FFFE8]`, which returns the OLD word and succeeds only if it
> was 0) read SDRAM power-up garbage and could never be acquired. Simulation hid
> this completely — its behavioral SDRAM is zero-filled, so the sim *supplied the
> precondition for success* on every run. Fix: a `CLR_WR` phase in
> `rtl/nds_loader.vhd` zeroing all 4 MB before staging. See the two
> **2026-07-25** entries at the tail of `COORDINATION.md` for the full evidence.
>
> **Kirby still does not boot**, but the failure moved: ARM9 now completes
> `OS_Init` and reaches the NitroSDK idle thread (`0x0214FC10`) and ARM7 runs
> game code in WRAM. The entire remaining problem is that **no interrupt is ever
> delivered to either CPU** (neither IRQ vector is ever reached, with a passing
> control). Next lead: ARM9's DISPSTAT VBlank-enable, and/or a card/FS read that
> never completes — a `CARD_LAT=48` sim run now reproduces a hang off-hardware
> for the first time.
>
> Consequently, in the body below: the "Immediate continuation point", the
> "Suggested next reasoning sequence" and the "Final evidence boundary" are
> **obsolete**. The SWP atomicity work was a real bug correctly fixed, but it was
> never this one. The disassembly note that `0xFFFF07D0` is a "delay return" is
> off by the Thumb pipeline offset — `r15` is architectural, so the sampled PCs
> are the `subs r0,#1 / bgt` **body** of BIOS `SWI 3 WaitByLoop`. (The claim here
> that `0x02000088` is a `svc 3; bx lr` trampoline is **correct** and was later
> wrongly disputed elsewhere; hardware reads `4770DF03` there.)
>
> New tooling, all in-tree: `nds_debug`'s `BOOT_HOLD` generic (cores held out of
> reset), mailbox op `0x09` SOFTRESET, `tools/nitrodbg.sh reach9/reach7`, and
> `MISTER_DEBUG_NOHDMI=1` in `NDS.qsf` — the last is what frees the area to fit
> any of it, and gave the first fully timing-clean build of the effort. It also
> means the current diagnostic images have **no HDMI output**.

This is the durable handoff for the M9 Cyclone-V fitting work and the Kirby
white-screen hardware investigation. Read `FITTING.md` for the original
resource history and the tail of `COORDINATION.md` for the append-only detailed
log. The working tree is intentionally large and uncommitted; the user commits.
Do not discard or broadly rewrite dirty files.

## State at a glance

- Target: DE10-Nano Cyclone V `5CSEBA6U23I7` — 41,910 ALMs, 4,191 LABs,
  553 M10Ks, 112 DSPs.
- The original ticket baseline was 49,238 ALMs / 4,979 LABs. The current
  integrated design fits at about 41.1k ALMs, 521 M10Ks, and 111 DSPs.
- `rtl/nds_cache9.vhd` has the high-risk serialized/per-way tag-RAM rewrite.
  Its functional regressions pass, but the real Kirby white screen remains.
- A genuine missing dual-CPU `SWP` atomicity bug was found and fixed in the CPU
  to main-RAM path. It passes deterministic and end-to-end regressions and
  materially changes live hardware state, but it is not sufficient to boot
  Kirby.
- The timing-clean SWP image currently loaded by the user is still white.
  Post-fix live telemetry shows cartridge lock words are now zero, ARM9 spends
  most samples in the retail ARM9 BIOS delay return at
  `0xFFFF07D0/0xFFFF07D2`, and ARM7 remains in its BIOS wait code near
  `0x00002F0C/0x00002F0E`.
- The immediate next discriminator is a post-SWP image exposing architectural
  ARM9 `r0`, `lr`, and CPSR on the existing DDR telemetry lanes. Its seed-1
  Quartus build is in flight as described below.
- No commit was made. Do not commit unless the user explicitly changes the
  standing instruction.

## Immediate continuation point

At the time this file was first written, this build was active:

```sh
POD=nds-quartus-regprobe-swp-seed1 \
ARTIFACT_DIR=build/artifacts-regprobe-swp-seed1 \
SEED_OVERRIDE=1 DIRTY=1 build/remote-build.sh
```

Pod: `nds-quartus-regprobe-swp-seed1` in namespace `default`.
Unified local exec session at handoff creation: `23842` (session IDs are not
portable between Codex sessions, so inspect the pod if resuming elsewhere).
The build had only just entered `quartus_map`.

Update: seed 1 completed at **41,129 ALMs**. All hold checks passed (worst
+0.250 ns) and all NDS/core setup clocks passed, but HDMI setup failed by
0.204 ns (TNS -0.204 ns, one path). It was not uploaded. An isolated seed-3
register-probe build is the next route attempt.

Final update: seed 3 completed at **40,997 ALMs** but failed both setup and
hold. HDMI setup was -0.546 ns (TNS -0.567), the 33.5 MHz CPU-divider setup
was -0.082 ns, and CPU9 hold was -0.584 ns (TNS -2.754). It was not uploaded.
Both register-probe pods deleted normally and no Quartus build is active.

Check it with:

```sh
kubectl -n default exec nds-quartus-regprobe-swp-seed1 -- \
  ps -eo pid,etime,pcpu,pmem,comm
```

If the wrapper is no longer attached, inspect/copy results carefully rather
than launching a second pod with the same name. Expected artifacts are under
`build/artifacts-regprobe-swp-seed1/` if the wrapper completes normally.

Before deploying, require all of the following from the full final timing
model:

- Fitter successful.
- Worst setup slack non-negative for every clock.
- Worst hold slack non-negative for every clock.
- No negative endpoint TNS.
- Do not accept “Fitter succeeded” by itself.

If seed 1 misses, use isolated artifact directories and separate pod names for
additional seeds. Seeds 1 and 3 closed the preceding SWP source; 1 had the
better minimum of setup/hold margins.

When a clean register-probe RBF exists, name it with the user-requested suffix,
for example:

```text
NDS_swpfix_regs_20260719.rbf
```

Upload to a temporary filename, verify SHA-256, `sync`, atomically rename,
`sync` again, and verify both the new core and the production rollback. The
user must manually select the RBF; `/dev/MiSTer_cmd` reload attempts were not
visibly honored.

After the user loads the new probe and launches Kirby, read the six telemetry
beats and histogram PC/r0/lr. The purpose is to identify the caller of BIOS
delay and its argument after the SWP fix. Do not infer the caller from PC alone.

## Current post-SWP register-probe edit

Files intentionally changed for the new probe:

- `rtl/nds_top.vhd`
- `NDS.sv` (comment/layout description only)
- `COORDINATION.md`

The edit reconnects `nds_cpu9`'s existing `dbg_r0`, `dbg_lr`, and `dbg_cpsr`
outputs to the existing top-level DDR telemetry lanes. It removes the temporary
lock-word capture process from those lanes. It does not alter CPU behavior.

Fresh remote gates on this exact source all pass:

- `sim/run_arm9_cache.sh`: PASS bitmask `0xFF`.
- `sim/run_arm9_island.sh`: PASS bitmask `0x7FF`.
- `sim/run_dual_boot.sh`: PASS ARM9 `0x7F`, ARM7 `0x3F`.
- `sim/run_cache9_lookup.sh`: PASS.
- `sim/run_analyze_all.sh`: `analyze-all: OK`.
- `sim/run_mainram_tb.sh`: PASS 10,000 sequential + 10,000 concurrent pairs,
  including the deterministic SWP collision.

The first dual-boot retry failed only while streaming source because the k8s
exec websocket closed (`websocket: close 1006`, `tar: Write error`). A fresh
pod `nds-nvc-regprobe-dual2` then passed cleanly. Do not record the transfer
failure as an RTL failure.

## Live MiSTer access and telemetry

MiSTer:

- Address: `192.168.1.244`
- User: `root`
- SSH key access works.
- Default password remains `1`, though key access has been used.
- Core directory: `/media/fat/_Console/`

The independent debug writer stores six 64-bit beats in the top-screen line
191 DDR region. HPS-visible addresses:

| Address | Current register-probe meaning |
| --- | --- |
| `0x3FE2FC00` | ARM9 PC, two packed 18-bit halves |
| `0x3FE2FC08` | ARM9 r0 |
| `0x3FE2FC10` | ARM9 lr |
| `0x3FE2FC18` | low 18 bits ARM9 CPSR + low 18 bits ARM7 PC |
| `0x3FE2FC20` | high ARM7 PC + reserved |
| `0x3FE2FC28` | core status + shell status |

The writer alternates telemetry with normal framebuffer traffic. A read of
`0x0003FFFF0003FFFF` is the ordinary white-pixel value, not a telemetry word.
Collect many samples and retain/histogram non-white values.

Compact live snapshot command:

```sh
ssh root@192.168.1.244 '
i=0
while [ $i -lt 32 ]; do
  a=$(devmem 0x3FE2FC00 64)
  b=$(devmem 0x3FE2FC08 64)
  c=$(devmem 0x3FE2FC10 64)
  d=$(devmem 0x3FE2FC18 64)
  e=$(devmem 0x3FE2FC20 64)
  f=$(devmem 0x3FE2FC28 64)
  echo $a $b $c $d $e $f
  i=$((i+1))
done'
```

Useful per-lane histogram pattern:

```sh
ssh root@192.168.1.244 '
i=0
while [ $i -lt 700 ]; do
  devmem 0x3FE2FC00 64
  i=$((i+1))
done | sort | uniq -c | sort -nr | head -n 50'
```

Reconstruct a 32-bit debug value from the packed pair as
`low18 | ((high18 & 0x3fff) << 18)`. The upper unused bits in each 32-bit pixel
slot are zero in telemetry and ones in a white framebuffer beat.

Shell status `0xF1` has meant BIOS9 loaded, BIOS7 loaded, cartridge loaded,
NDS enabled, loader complete/boot complete. See `dbg_shellstat` in `NDS.sv`
for the authoritative current bit layout.

## Last physical observation

The user manually loaded:

```text
/media/fat/_Console/NDS_swpfix_20260719.rbf
```

Kirby remained uniform white. The framebuffer no longer deliberately flashes;
that is expected because the diagnostic writer is independent and no longer
paints visible debug colors.

Post-fix samples from that image:

- ARM9 PC dominated by `0xFFFF07D0` / `0xFFFF07D2`.
- ARM7 PC dominated by `0x00002F0C` / `0x00002F0E`.
- Last observed cartridge `lockFlag` word: zero.
- Last observed owner/extension word: zero.
- Shell/core status showed the core and loader active; no reset/error symptom.

This is materially different from the earlier pre-fix register probe, which
captured `MI_SwapWord` returning `0x40`/`0x80` in the cartridge-lock retry
path. Therefore the SWP fix is doing something real on hardware, but another
startup dependency remains unresolved.

The ARM9 BIOS bytes around the sampled PC decode in Thumb state as:

```text
FFFF07CC: subs r0, #1
FFFF07CE: bgt  FFFF07CC
FFFF07D0: bx   lr
FFFF07D2: movs r0, r0
```

It is a tiny countdown delay return. The post-fix `lr` and `r0` probe is needed
to learn which caller repeats it and whether the count is sane.

Local retail ARM9 BIOS used for this disassembly:

```text
/Users/heni/Downloads/[BIOS] Nintendo DS ARM9 Boot ROM (World)/
  [BIOS] Nintendo DS ARM9 Boot ROM (World).bin
```

Local extracted Kirby ARM9 binary already exists at `/tmp/kirby_arm9.bin`.
The game contains the Thumb `svc 3; bx lr` trampoline at `0x02000088`.

## SWP atomicity bug and fix

The exact Kirby lock buffer is `HW_CTRDG_LOCK_BUF` at `0x027FFFE8`.
Disassembly of Kirby's MPU setup proved:

- Region 7 is `0x027FF000`, 4 KiB, highest priority.
- The D-cache mask enables only regions 1 and 6.
- Therefore this lock buffer is non-cacheable and does not enter
  `nds_cache9`.

That invalidated the first theory that the cache tag rewrite directly
corrupted this lock.

The CPU operand alias was also tested exactly:

```asm
swp r0, r0, [r1]
```

at the uncached lock address. It passes in the ARM9 cache/island regression, so
the CPU correctly latches the write operand before replacing the destination.

The real discovered defect was dual-CPU contention. `nds_mainram` previously
had no lock signal, so ARM7 could be granted between the read and write halves
of an ARM9 `SWP`. A deterministic collision proved the pre-fix failure:

```text
phase3: SWP pair was split: ARM9 old=00000000 ARM7 old=00000000
```

Real hardware requires the pair to be atomic.

Implemented changes:

- `rtl/nds_cpu9.vhd`: new `gb_bus_lock` output. A lock-active latch starts
  from the actual SWP data request (`execute_RW_ena` plus
  `decode_datatransfer_swap`) and clears on SWP write completion.
- `rtl/gba_cpu.vhd`: equivalent lock output for ARM7.
- `rtl/nds_top.vhd`: qualifies CPU locks so DMA, loader, sound, and cache-fill
  traffic cannot falsely claim a main-RAM lock.
- `rtl/nds_mainram.vhd`: adds `mem9_lock`, `mem7_lock`, `MR_LOCKWAIT`, and
  retains the selected CPU across exactly two memory operations.
- `sim/tb_mainram.vhd`: deterministic colliding SWP pair plus the existing
  randomized soak.
- `sim/tests/arm9_boot.s`, `sim/tests/arm7_boot.s`, generated boot binaries,
  and `sim/tests/nds_dual.hex`: end-to-end simultaneous collision at the
  physical mirror `0x02FFFFE8`.
- `sim/tb_dual_boot.vhd`: lock signal wiring and progress checks.

The correct passing order is one atomic winner followed by the other, e.g.:

```text
ARM9 SWP read old 0
ARM9 SWP write 0x40
ARM7 SWP read old 0x40
ARM7 SWP write its value
```

The dual-boot progress masks `ARM9=0x7F`, `ARM7=0x3F` prove the collision test.

Important implementation lesson: an earlier version asserted the lock from
raw decode. Because decode is pipelined, it incorrectly marked the preceding
load. The final logic deliberately latches from the actual SWP data request.
Do not simplify it back to raw decode.

## SWP Quartus evidence

All builds below used the same verified SWP source snapshot and isolated
artifact directories:

| Seed | ALMs | Setup | Hold | Deployable |
| --- | ---: | --- | --- | --- |
| 0 | 41,059 | HDMI -0.064 ns | CPU9 -0.209 ns, TNS -0.574 | No |
| 67 | 41,155 | HDMI -0.350 ns, TNS -0.718 | all positive | No |
| 420 | 41,174 | all positive, HDMI +0.031 | CPU9 -0.151 ns | No |
| 69 | 41,196 | HDMI -0.234 ns, TNS -1.136 | CPU9 -0.480 ns, TNS -1.462 | No |
| 1 | 41,095 | worst +0.237 ns | worst +0.158 ns | Yes, deployed |
| 3 | 41,111 | worst +0.349 ns | worst +0.109 ns | Yes, retained locally |

The deployed seed-1 SWP RBF is:

```text
build/artifacts-swp-seed1/NDS_swpfix_20260719.rbf
SHA-256 0b3deed1322831e298b86ed63f8a4fb3373c0259f0132901b0a0619cb0c942d8
```

## Cache9 restructure status

The original ticket specifically targeted `rtl/nds_cache9.vhd`, formerly an
8,864-own-ALM entity. Round-one work had already moved line data to per-way
M10Ks but left tags/valid/dirty/round-robin state in flops to retain four-way
parallel comparisons.

The current working tree contains the later high-risk tag/compare restructure:
per-way tag storage is BRAM-shaped and lookup timing is serialized rather than
checking all four ways combinationally in one cycle. Treat this as real cache
coherency logic, not a mechanical storage change.

Evidence currently available:

- `sim/run_cache9_lookup.sh`: focused lookup timing PASS.
- `sim/run_arm9_cache.sh`: write-back, clean/invalidate, I-cache staleness,
  exact uncached same-register SWP, and cached NitroSDK-shaped lock traffic;
  current mask `0xFF`.
- ARM9 island and full dual boot pass.
- Full analysis passes.
- The integrated core now fits near 41.1k ALMs, versus the ticket baseline of
  49,238 ALMs.

Caveat: Kirby still does not boot physically, but current MPU and live-lock
evidence say its `0x027FFFE8` cartridge lock bypasses `nds_cache9`. Do not call
the cache rewrite physically proven merely because this particular lock is
uncached; likewise, do not revert the cache work based solely on this lock.

## Other established white-screen facts

- Hardware and RTL both produced a white Kirby screen; melonDS begins the HAL
  Laboratory/Nintendo fade around frame 120.
- Kirby's reference display is not waiting on unimplemented 3D. Reference
  `DISPCNT=0x80211810`: mode 0, BG3 text + OBJ, BG0-3D clear.
- `BG3CNT=0x4113`.
- A melonDS frame-134 BG/OBJ/palette/OAM/register snapshot passes the current
  RTL 2D engine pixel-exact: 49,152 / 49,152 pixels.
- Therefore the white screen is upstream of the BG3 drawer/merge rasterizer:
  CPU execution, initialization, memory mapping, DMA/IPC/IRQ, or data arrival.
- A full integrated nvc run using the real ROM, retail firmware, and both boot
  ROMs reaches VBlank IRQ by frame 2 and observes WFI wakeups. That behavior
  has not matched all physical probes.
- Earlier IRQ hardware telemetry found ARM9 halted at SDK WFI with
  `IE9=0x00040001`, `IF9=0x00080000`, IME enabled, and no live enabled source.
  VCOUNT crossed 192 without VBlank IF latching in that image. Later source
  and probes reached a different BIOS-delay state. Preserve the distinction;
  do not merge observations from differently built RBFs.
- The cartridge lock is currently no longer persistently owned after the SWP
  fix, but ARM7 still appears not to leave its BIOS wait code.

## MiSTer RBF inventory

As verified live on `192.168.1.244`:

| Remote file | SHA-256 | Notes |
| --- | --- | --- |
| `NDS_20260719.rbf` | `5a55cac344f7d2d56b244c0af18338c846d115c514ad59d8ffad4ae01457d8f6` | Production rollback; keep untouched |
| `NDS_swpfix_20260719.rbf` | `0b3deed1322831e298b86ed63f8a4fb3373c0259f0132901b0a0619cb0c942d8` | Timing-clean SWP fix, still white |
| `NDS_hwtelemetry_ctrdglock_20260719.rbf` | `c7f98be8b31cb72ed5bc82eee392a16dfe77352a7cc29b6903e63cbb5ec416d4` | Pre-SWP lock telemetry |
| `NDS_hwtelemetry_regs_20260719.rbf` | `8ff62e07f7d32cca625376f4ec7ce4e6d2b1ca48e76e2ca6cca543dc4d7732db` | Pre-SWP r0/lr/CPSR probe |
| `NDS_hwtelemetry_irq_20260719.rbf` | `41fd1b5433d45579d6286e22048121db92d1c29ddf651e020b3791dd8182130b` | IRQ probe; HDMI timing missed |
| `NDS_hwtelemetry_dispstat_20260719.rbf` | `d4bf5cc0cf5bea1091a56d9b351263b421a83d03d71f30860439c3b22d182b07` | Seed-420 DISPSTAT probe |
| `NDS_hwtelemetry_dispstat_seed0_20260719.rbf` | `e67cdb882dbaf5a9dbdf65e93af0d073ee0bec8ab211d5070215468095ee4152` | Seed-0 A/B probe |
| `NDS_hwtelemetry_20260719.rbf` | `0ccc43f37de5f8fb52813e2185c9162a5ca301e1e93dd28157df48a770cf4caa` | Earlier general telemetry |
| `NDS_pre_timingfix_20260719.rbf` | `3ec696e7dff3af5bfc8560707b295dc49079c5e0e4ed22da9c461c1395515a8a` | Old rollback/diagnostic |

Do not overwrite production. Use a new dated diagnostic name and preserve all
rollback cores unless the user explicitly asks for cleanup.

## ROM, firmware, and BIOS inputs

Game ROM supplied by the user:

```text
/Users/heni/Downloads/Kirby - Squeak Squad (USA)/Kirby - Squeak Squad (USA).nds
```

BIOS/firmware source directories supplied by the user:

```text
/Users/heni/Downloads/[BIOS] Nintendo DS ARM9 Boot ROM (World)/
/Users/heni/Downloads/[BIOS] Nintendo DS ARM7 Boot ROM (World)/
/Users/heni/Downloads/[BIOS] Nintendo DS Firmware (World) (En,Ja,Fr,De,Es,It) (2005-12-07)/
/Users/heni/Downloads/[BIOS] Nintendo DS Lite Firmware (World) (En,Ja,Fr,De,Es,It) (2006-03-08)/
```

MiSTer firmware/BIOS filename handling was expanded earlier to support the
user's `.rom` copies as well as `.bin`; inspect the corresponding loader and
hot-load changes before changing naming behavior.

## Remote verification workflow

Never run heavy nvc or Quartus locally.

Fresh remote simulation pattern:

```sh
POD=nds-nvc-UNIQUE DIRTY=1 build/remote-sim.sh run_arm9_cache.sh
```

Mandatory gates for cache/CPU/main-RAM changes:

```text
sim/run_arm9_cache.sh
sim/run_arm9_island.sh
sim/run_dual_boot.sh
sim/run_analyze_all.sh
```

Also run for this SWP/cache path:

```text
sim/run_mainram_tb.sh
sim/run_cache9_lookup.sh
sim/run_arm7_island.sh
```

Quartus pattern with isolated artifacts:

```sh
POD=nds-quartus-UNIQUE \
ARTIFACT_DIR=build/artifacts-UNIQUE \
SEED_OVERRIDE=SEED DIRTY=1 build/remote-build.sh
```

Read `NDS.fit.summary`, `NDS.sta.summary`, and the setup/hold summaries in
`NDS.sta.rpt`. Verify the active source snapshot and do not compare mixed
artifact directories as if they differed only by seed.

`build/remote-build.sh` was extended to accept `POD`, `ARTIFACT_DIR`, and
`SEED_OVERRIDE`; preserve that isolation behavior.

## Quartus 25.1 experiment and cluster hygiene

The official `alterafpga/quartus-std:25.1std-cyclonev` image really reports
Quartus 25.1std but stops with Error (292025): no license file specified. It
does not silently fall back to free Lite mode for this flow.

`raetro/quartus` had no 25.1 or 25.1std tag when queried; published tags ended
at 21.1.1. The failed 25.1 pod, work directory, and 5.8 GB image were removed.
At the time of that audit, every remaining cached image backed a live pod.

The user explicitly authorized clearing unused images and old GBA/PSX/N64
build artifacts, but do not repeat destructive cluster cleanup without first
reconfirming current targets and state.

## Clash and HPS context

- The tree includes `clash/rtl/nds_clash_video_mixer*.sv` and
  `clash/rtl/nds_hps_io_boundary.sv`.
- Earlier evidence did not show that Clash caused the old 117% ALM failure;
  the overuse was core-wide and the decisive fit work was targeted RTL/BRAM/
  DSP rebalance.
- The HPS replacement/boundary is present in the integrated source. Preserve
  the current instantiated path unless a new differential proves otherwise.
- Do not answer “original would be smaller” from intuition. Compare exact
  source snapshots and entity reports if this question returns.

## Working-tree warning

This checkout contains many intentional changes and generated artifacts from
multiple completed/in-progress efforts. At handoff creation, modified files
included cache, CPU, main-RAM, BIOS/loader, sound, GPU, framebuffer, top-level,
testbenches, generated boot binaries, and coordination/build scripts. Numerous
artifact directories are untracked.

Before editing or staging:

```sh
git status --short
git diff --check
sed -n '1,220p' FITTING.md
tail -n 180 COORDINATION.md
```

`git diff --check` currently passes except for Git's warning that `NDS.qsf`
will convert CRLF to LF if Git touches it. Avoid gratuitously rewriting that
file. Do not delete untracked artifact directories until their evidence has
been recorded and the user authorizes cleanup.

## Suggested next reasoning sequence

1. Finish/inspect the in-flight post-SWP register-probe fit.
2. If timing-clean, package/upload it atomically as a new `_20260719` RBF.
3. Have the user manually load it and launch Kirby.
4. Capture PC, r0, lr, CPSR, PC7, core status, and shell status histograms.
5. Map `lr` into Kirby/NitroSDK code. Compare the physical delay argument and
   caller with the existing melonDS traces in `/tmp`, especially
   `/tmp/kirby_mds_retail_trace9_boot15.txt` and
   `/tmp/kirby_mds_retail_trace9_110.txt` if still present.
6. Determine whether ARM9 is repeatedly requesting a legitimate short delay,
   returning to a lock/IPC poll, or failing to make forward progress because
   of a missing ARM7 response.
7. Inspect ARM7's BIOS wait condition and the shared word/IPC/register that
   should release it. Since ARM7 remains near `0x2F0C`, this may be more useful
   than another cache hypothesis.
8. Add the exact failing cross-CPU/BIOS sequence to a dedicated regression
   before modifying behavior.
9. Re-run the mandatory remote gates and obtain a fully timing-clean RBF.
10. Only call the white screen fixed after the physical Kirby test advances.

## Do not repeat these dead ends

- Do not bypass `0x027FFFE8` around the cache as a “fix”; Kirby's MPU already
  makes it non-cacheable.
- Do not blame same-register `swp r0,r0,[r1]`; the exact alias passes.
- Do not treat a behavioral main-RAM model pass as proof against a dual-CPU
  arbitration bug; the deterministic contention test was required.
- Do not infer that a timing-violating RBF is safe because it loads.
- Do not rely on remote MiSTer reload commands; require the user's manual load
  confirmation before interpreting telemetry.
- Do not interpret `0x0003FFFF0003FFFF` as CPU state; it is white framebuffer
  data between telemetry bursts.
- Do not assume the white output implicates the 2D renderer; frame-134 state is
  pixel-exact in the isolated 2D test.
- Do not mix observations from IRQ, DISPSTAT, register, lock, and SWP RBFs.
  They represent different source snapshots and telemetry lane meanings.

## Final evidence boundary

The SWP fix is simulation-proven, synthesis/fitter-proven, timing-clean at two
seeds, deployed, and physically observed to change the lock state. It is not a
physical Kirby boot fix. The current strongest physical statement is:

> Kirby remains white after the timing-clean SWP fix; the cartridge lock now
> reads free, ARM9 repeatedly visits BIOS delay, and ARM7 remains in BIOS wait.

Everything after that is an active diagnosis, not a completed fix.
