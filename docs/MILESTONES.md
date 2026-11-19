# Haskell GPU milestone ledger

M0–M6 record the host-side Haskell/Clash DS GPU workstream (2D engines,
3D chip, TARDIS line cache, visible viewer). M7 tracks the move to a
whole-core Haskell/Clash implementation. This numbering is independent of the
console bring-up milestones in [`ROADMAP.md`](ROADMAP.md).

Every "done" row below is host evidence that was actually observed: Haskell
models compared against independent melonDS production oracles on this Mac.
None of it is generated-HDL, Quartus or board evidence. The commands, logs and
exact totals live in the linked sections; `/tmp/...` logs are local run
artifacts, not repository files.

| Milestone | State | Scope of the claim |
| --- | --- | --- |
| M0 canonical 3D source | Done | One `Nds.Gpu3D` tree, imported and reconciled |
| M1 2D trace checkpoint | Done | One cartridge, ten frames, both screens |
| M2 2D feature oracles | Done | Finite directed/seeded matrices |
| M3 3D chip hardware model | Done (host) | Transaction-level geometry coherence |
| M4 Haskell 3D in the trace | Done | Raw v12 inputs, no oracle pixels used |
| M5 TARDIS speculation | Done | One trace, one run per variant |
| M6 closed-loop pairing | Done (host, finite evidence) | Authoritative Haskell GPU with melonDS CPUs/non-GPU peripherals |
| M7 whole-core Haskell/Clash, cartridge and board | **Not accepted** | Finite Clash ARM9-slice gates (ISA, Thumb/interworking/multiplies/SWI/User-System modes, link, native Live frames, Arm9Soc timers + IE/IF/IME latch, ARM9 IRQ exception entry/return from a real timer chain incl. from Thumb, read-only NTR game-card commands from a synthetic image, against the product RTL, pure and generated HDL; a boot-ROM loader copying a synthetic image's ARM9 binary through the card into executable RAM and running it, pure and generated HDL; generated CPU+VRAM graphics HDL); one isolated graphics-prototype Quartus fit (board untested); no ARM7, FIQ/abort/undefined exceptions, DMA, KEY1/BIOS cartridge boot or game boot, integrated-console fit or board evidence |

## M0: canonical prerequisite (done)

The complete 3D model, its melonDS oracles and gates were imported from the
sibling workstream at commit `20dca93808aa3cf13ef8356dd756829c44176f0e` and
reconciled with this tree's 2D/TARDIS modules. Provenance, reconciliation
rules and import-time versus corrected hashes:
[GPU3D_CLASH.md, Canonical source](GPU3D_CLASH.md#canonical-source-m3-import-2026-11-16).
Only `clash/rtl/nds_gpu3d_geometry.v` is carried from the generated Verilog,
for the existing iverilog geometry co-simulation stage. `Nds.Gpu3D.Budget`
remains a local, uncommitted module; no committed source imports it.

## M1: 2D trace checkpoint (done)

NTR EVA cartridge, v11 trace, frames 34 71 84 87 90 97 108 116 120 123: zero
mismatching pixels against the trace records and 20/20 independent direct-dump
comparisons `PASS: pixel-perfect (256x192)`; 192 capture lines and 49,152
capture VRAM writes without mismatch. Commands:
[clash/README.md, 2D trace checkpoint](../clash/README.md#2d-trace-checkpoint).
The changed-chunk oracle checks resulting bytes, not bus write events.

## M2: 2D feature oracles (done)

BG 177 cases (0 mismatches), sprite 100 cases per engine, capture 220 cases
(0 mismatches), composition 1,897 valid lines exact plus 3 explicit video
mode-7 rejections. Gates: `clash/tests/run_bg_check.sh`,
`clash/tests/run_compose_check.sh`, `clash/tests/run_gpu2d_check.sh`; results
in [clash/README.md, v12 raw 3D replay](../clash/README.md#v12-raw-3d-replay-and-composition).
Finite directed/seeded coverage, not every register history.

## M3: 3D chip hardware model (done, host only)

Final chip-only acceptance: **40/40 default cases (16 directed, 16 seeded
random, 8 fuzz), 0 mismatches**: 144,401 operations, 215 rendered frames,
10,665,984 compared pixel words, 87,463,785 cycles. Observed in disjoint
batches with the final checker; the corrected final fuzz case was rerun after
the completed-result/SWAP-wait fix. Commands, logs and the aggregate summary:
[clash/README.md, Final M3 chip-only acceptance](../clash/README.md#final-m3-chip-only-acceptance);
corrections and the burst reference contract are in the sections just above
it. Reproduce with `clash/tests/run_chip_hw_check.sh`.

Boundary: the reference checks **transaction-level geometry coherence**. It
is not an independent proof of exact geometry microcycle latency, not a
generated-HDL simulation and not a board result. Composed HDL was not
regenerated and no Quartus fit followed acceptance.

## M4: Haskell 3D in the trace (done)

`MELONDS_DIR=$PWD/third_party/melonDS clash/tests/run_m4_check.sh /tmp/nds-v12c/ntr-v12.nsd2`:
768 3D lines and 23,808 screen lines, 0 mismatches. Synthetic scene gate
(`clash/tests/run_m4_scene_check.sh`): 6,720/6,720 3D and screen lines exact.
The Haskell 3D line is generated from raw recorded GX inputs; recorded oracle
pixels are never the provider. Details:
[clash/README.md, v12 raw 3D replay](../clash/README.md#v12-raw-3d-replay-and-composition).

## M5: TARDIS speculation (done)

- Correctness: the independent harness compared all **47,616/47,616 lines
  directly** (bitwise, prepared inputs) with 29,586 renders instead of
  47,616; 101 stress checks pass.
- Wall clock: two **separate independent processes** from trace-open to
  fully forced output, `SPECULATE_MODE=cache|exact
  clash/tests/run_speculate_measure.sh /tmp/nds-v12c/ntr-v12.nsd2 124`:
  **36.129108 s cached versus 43.973591 s exact, 1.21712x**.
- Both runs print `outputHash=147193483`. The hash is a cross-run
  consistency check, not exact equality; the direct 47,616-line comparison
  is the correctness proof.
- Single run per variant on one trace, sequential prefetch; not a
  statistical benchmark.
  This is a historical pre-M6 benchmark, not current-tree timing after the
  full-region `TraceMemory` equality/fork correction. The existing M5
  cache/store API is retained; its 11-case checker now includes a
  same-parent red/blue palette fork through cached output. No benchmark rerun.

Details: [clash/README.md, Measured TARDIS work](../clash/README.md#measured-tardis-work-on-a-real-trace)
and [TARDIS note](tardis.html).

## M6: closed-loop pairing

**Host acceptance observed, including the final real atomic GXFIFO regression.
The timing/coverage and M7 limits below remain explicit.**

- [x] Haskell state answers GPU MMIO/results, GXSTAT/RAM_COUNT and status,
      owns physical GPU memory/mapping and capture/FIFO, and supplies actual
      IRQ/DMA and LCD/geometry deadline effects.
- [x] Real cartridges execute without the stock GPU in the runtime path.
      Independent stock execution is an oracle only.
- [x] Native display/input works at diagnostic-interactive speed, with honest
      whole-process and native-path measurements, not a 60 fps claim.
- [x] Directed real ARM STM crosses the full GXFIFO boundary under SWAP,
      retains instruction-start timing, and matches the independent stock control.

### Ownership and timing contract

Default `tools/hs_gpu_view/run.sh CART.nds` is labelled **closed-loop Haskell
GPU; melonDS CPUs/non-GPU peripherals**. It does not claim a Haskell SoC.
`Nds.Gpu.{Live,Live2D,LiveMemory}` and `Gpu3D.Timed` run through ABI2 in
`sim/melonds_tracer/HsGpuAbi.h`; the native consumer receives only actual
Haskell frames and explicit terminal records. Stock runtime GPU entry
points are guarded. Open-loop/replay are explicit diagnostic modes only.

The executor is timed functional, not per-MMIO unbounded `chipRun`.
The coordinator preserves the interpreters' reported instruction/DMA
timestamps in 33,513,982-Hz system cycles, services each exact deadline
before a same-time access, and separately drains coincident GX/LCD events.
Borrowed frames/errors are copied before reentrant effects.
The original instruction-start timing is retained: ABI2 operation9 admits
only authenticated remaining word GX writes of the actual ARM9 handler
whose ordinary command write first caused the stall, at the same scope and
exact raw core clock. The service checks its observed stall origin too.
Those entries join the existing pending FIFO; ordinary guards remain.
The next instruction stays blocked. No new CPU microcycle model, retiming,
spill capacity or per-MMIO drain is used.
This is not physical sub-instruction bus timing, an independently exhaustive
geometry-microcycle oracle, generated-HDL or board proof.

### Independent and focused evidence

- 69 production-C++ authority records equal Haskell: widths/read masks,
  power, VRAM overlap/aliases/ARM7 bytes, affine partial reloads, delayed
  DISPCNT, window/mosaic and directed pipeline boundaries.
- Independent LCD/IRQ/capture histories and four complete both-screen frames
  equal. A request armed after line0 survives line192, then actually writes
  `0x801F` to CPU-visible VRAM at the following frame's line0.
  `/tmp/nds-m6-state-oracle/{stock,uncached}-capture.out` and
  corresponding `.frames` compare directly.
- v5 direct: **200 NTR both-screen frames and all 4 MiB main RAM exact**
  against stock-GPU interleaved control; control also equals original stock
  scheduling. **32 directed real ARM bus/DMA/ARM7 variants** match, including
  access exactly at a deadline and DMA split/preemption across it.
- An actively changing real ARM palette cartridge matches for **120 frames**,
  CPU toggle counter120, not merely a warm frozen failure screen.
- Final cleaned service: real coincident GX/LCD1584 CPU status/IRQ/DMA,
  late-capture actual VRAM, fail-closed/terminal/reset regression passes.
  Existing M5 checker: **11 cases, 0 failures**, including the same-parent
  palette fork through cached consumer pixels. The failed new live cache
  and its APIs/flag/tests were removed; original M5 remains.
- Retained linear compositor/3D-row fixes: **29 independent layered/window
  lines, 0 differences**, plus unordered duplicate-x/transparent/wrong-y/OOB
  regression. No whole pixel suite or old 40-case chip gate was rerun.

Artifacts: `/tmp/m6-final/`, `/tmp/m6-run/`, `/tmp/nds-m6-state-oracle/`,
`/tmp/nds-m6-final-{service,speculate}-check.log`.
Full cartridge/performance comparison used v5 direct (cache off), SHA256
`f4283979e59f50fcac8eb821871d2d56f096d22df9b1d84651cac85df98ad664`.
Pre-continuation cleanup ABI1 library `/tmp/nds-m6-gpu-final.dylib`:
`d80dd4d25a2432d07922e5560ec9fe1c02a9b4883c0cccb92e079bf1e5361c7b`.
Cleanup was followed by focused and native/input checks, not another 200/120
run. Import-time M0 hashes are not relabelled as current M6 hashes.
Current ABI2 library (local run artefact, built from `clash/test/GpuService.hs`
as `tools/hs_gpu_view/run.sh` builds it), SHA256:
`fc8f9c9a4619519b0d569d9bb3c32c845f6d1d98b23fa3ca07e2ec4daec02d70`.
Its targeted `GpuServiceCheck --continuation-only` passes same-clock
queueing, five admission guards, direct ordinary-chip guard, and timed versus
standalone refill busy/result checks. Test/PUSH counts are first added on
FIFO admission, not twice; the timed wrapper must preserve newly asserted
refill flags as well as delayed retirement flags. Old gates and throughput
measurements were not repeated for this correction.

### Final atomic GXFIFO acceptance

Unchanged real cartridge `/tmp/m6-scen/atomic-watch.nds` fills the FIFO under
pending SWAP, then performs one STM containing POS_TEST and matrix PUSH.
It polls the original test/push busy bits 0/14, not a substituted bit 27 wait
or an added delay. The original service rejected the third beat while
stalled. ABI2 admits only the authenticated remaining beats; a second
exposed bug in the timed wrapper had overwritten newly asserted refill
status with old cleared flags. OR-ing pre-pop and post-pop flags fixes that
without changing standalone counting or the polling program.

Final ABI2 execution **exit 0; all 44 dumped RAM words stock-equal**:

- Pre-STM GXSTAT `09000000` (FIFO 256, busy); settled post-state `06000100`
  (empty, not busy, one matrix push).
- POS_RESULT = `00001111,00002222,00003333,00001000`.
- ARM7's real VCOUNT 64 observer saw ARM9's post-STM marker still 0 and wrote
  sentinel `DECAFBAD`; after VBlank the `02020202`/`03030303` markers exist.
  Thus ARM7/events continued while ARM9 could not retire another instruction.
- All four writes use scope 263, system timestamp 15302, raw ARM9 clock 30604:

  | Address | Value | ABI op | Returned stall |
  | --- | --- | --- | --- |
  | `04000400` | `00000071` | 2 ordinary | 0 |
  | `04000404` | `22221111` | 2 ordinary; observed stall origin | 1 |
  | `04000408` | `00003333` | 9 authenticated continuation | 1 |
  | `0400040C` | `00000011` | 9 authenticated continuation | 1 |

Actual outputs: `/tmp/m6-scen/atomic-watch.final.{out,err,txn}`;
independent reference: `/tmp/m6-scen/atomic-watch.stock.out`.
Reproducer sources `atomic.s` and `atomic-watch7.s` are retained alongside
the generated cartridge. Earlier `.before`, `.after` and `.fixed` failure
artifacts remain evidence, not acceptance. The focused check log is a local
run artefact; the `GpuServiceCheck --continuation-only` command in
`clash/README.md` regenerates it. Normal stalled writes, other scopes,
DMA/no scope, later clocks and reset-origin reuse all reject.
No old 200-frame, native-input, pixel, chip, throughput or M7 gate was rerun.

Reproduce only this two-frame witness using retained synthetic sources/cart
(HLE section loading, no `--direct`/firmware); fresh output avoids clobbering
the acceptance artifacts:

```sh
B=/tmp/m6-cpp-build/melonds_fbdump
C=/tmp/m6-scen/atomic-watch.nds
L=${HS_GPU_LIBRARY:?GpuService library built as tools/hs_gpu_view/run.sh does}
R=$(mktemp -d /tmp/m6-atomic-repro.XXXXXX)
"$B" --sched=interleave --no-text-dump --ram-dump 0x02000100:44 \
  "$C" /tmp/ignore 2 >"$R/stock.out" 2>"$R/stock.err"
"$B" --hs-gpu "$L" --hs-txn-log "$R/actual.txn" \
  --hs-ndsf "$R/actual.ndsf" --no-text-dump --ram-dump 0x02000100:44 \
  "$C" /tmp/ignore 2 >"$R/actual.out" 2>"$R/actual.err"
```

These commands record the accepted scope; they were not rerun for this
documentation. Meaningful reproducer sources remain in `/tmp`, not in the
production runtime. No user files were deleted or restored.



### Throughput, surface, input and limits

`/tmp/m6-final/drive.out` whole-process walls include startup/output:
NTR200 **16.1 s**, active120 **4.6 s**; their producer-internal totals were
15.91488 s/about4.55 s, not complete process walls. NTR phases were roughly
64–91 ms/frame and the headless active scene roughly36 ms/frame.
The slower experimental live cache (18.6 s/6.6 s whole process) was deleted.

Actual native active-input streaming without PNG/clock/profile/frame-file
diagnostics: **40 frames, 3.582 s**, about **11.2 fps**, not 27 fps GUI.
Own-window same-source AppKit press(64,48), drag(192,144), release records
reached real `TouchScreen`/`ReleaseScreen` calls at frames2/4/6,
sequences2/4/6 acknowledged; observed sampling-ACK delays were
67.464/191.405/128.511 ms (10 ms polling, one run). These acknowledge input
latched/applied before a frame, not game/display response or completed
frame timing. The copied input persists until the next frame poll.
Continuous-PNG plus clock diagnostics measured 3.74 s and 162–168 ms
sampling ACKs; no statistical speedup/root-cause claim follows.
Logs: `/tmp/nds-m6-ui-touch-direct/{harness,producer,wall}.log`.
Normal launch no longer encodes/writes PNG or logs CPU clocks per frame;
existing `NDS_VIEW_SNAPSHOT` is explicit opt-in.

Native AX and the exact app-produced bitmap were observed. Real native X
(DS A) reached `FFE` at frame1770, release `FFF` at1772, acknowledged seq4.
Current GameController enumeration: **no game controller detected**;
mapping/notification code remains, no current physical DS4 press claimed.
Mouse proof is same-source own-window programmatic events, not physical
pointer automation; no macOS permission was changed or bypassed.
Truncating one byte of a real status-0 terminal produced the actual
`STOPPED (ERROR)` surface with the protocol reason and all **98,304 visible
RGB pixels** equal to its last real frame5. Windows retain the last actual
frame on fatal errors rather than showing stale data as live.

NTR's actual native bitmap still shows `[07-01] 3D ATTR FARCLIP`,
`PROGRESS[018/058]`, `RESULT:FAIL TOTAL:FAIL`, bottom white. The independent
baseline failure was not hidden or relabelled. Historical `016/058` is a
configuration-specific earlier baseline, not a universal position.
The requested original ROM currently has 2,696,840 bytes and mtime
2001-02-17; no helper changed/restored it. These comparisons are finite,
not all games, all register histories or full58 diagnostic progression.
Unsupported paths (JIT/DSi/real firmware/savestates/sleep) fail explicitly,
not through stock-GPU substitution.

Usage/controls: [Visible host viewer](../clash/README.md#visible-host-viewer-closed-loop-haskell-gpu).


## M7: whole-core Haskell/Clash, cartridge progression and board (not accepted)

The NDS4MiSTer RTL is the executable reference, not the intended production
CPU half of a permanent RTL/Haskell split. The witness below gives a golden
comparison path for the supported ARM9 bus sequence. It does not make that
finite run a universal timing or hardware oracle.

- [ ] Haskell/Clash owns ARM9, ARM7, the bus and memory fabric (including
      cartridge and main RAM), and the GPU including VRAM and its mappings.
- [ ] Haskell/Clash owns DMA (including GXFIFO and capture), IRQ, timers and
      IPC; verify their interactions with the GPU against independent
      references.
- [ ] Haskell/Clash owns the emulated SPI, RTC, touchscreen and sound blocks.
- [ ] Deterministic frame, line and input timing, so runs are reproducible
      and comparable line by line.
- [ ] Full NTR EVA diagnostic progression through all 58 tests, past the
      observed FARCLIP point, with every result determined by our hardware
      models; no fixed intermediate count is the acceptance target.
- [ ] Compare generated HDL for each synthesizable partition against its
      host behavior, then measure partition resources and timing.
- [ ] Quartus fit and timing for the integrated core.
- [ ] Board acceptance on MiSTer hardware.

### Synthesizable partition measurements (not yet accepted)

Host co-simulation tests behavior, not whether a Haskell design generates
usable hardware. Track each generated CPU, bus/peripheral and GPU partition
separately: source revision, generated top, target device and clock
constraints, ALMs/LABs/registers, RAM/DSP blocks, and Fmax/setup slack.
Standalone results do not add up to a board fit: integration has its own
clock crossings, interfaces, resource sharing and placement. The
zero-ARM-graphics fit baseline (local fit data in
`build/zero-arm-graphics/fit-baseline.md`, not tracked)
is historical NDS4MiSTer/standalone GPU data, not a measurement of the
proposed whole-core Haskell partitioning. This hookup adds no synthesis or
fit result.

### M7 executable reference: product ARM9 RTL to the Haskell GPU

Run `sim/run_hs_gpu_arm9.sh` with NVC, a host C compiler, Stack
(`lts-22.43`) and GNU `arm-none-eabi-as`/`arm-none-eabi-objcopy`. It builds the
current `GpuService.hs` library by default, or accepts an explicit ABI2
library via `HS_GPU_LIBRARY`.

Observed on NVC 1.23.1 with a freshly built service: the same `nds_cpu9`,
`nds_cache9` and product-local `nds_nitro_membus9.vhd` from the NDS4MiSTer
file manifest executed an assembled ARM boot program. Ten decoded, real
ARM9 bus transactions crossed NVC's foreign interface into the authoritative
Haskell GPU, at system cycles 4–37 after CPU reset release. GPU reads returned
through the RTL response handshake; ARM9 instructions stored these six
words at `0x02000000`:

| Offset | ARM9 store | Meaning |
| ---: | --- | --- |
| 0 | `0000820F` | POWCNT1 read masks attempted halfword `FFFF` |
| 4 | `00000080` | VRAMCNT_B byte read from lane 1 |
| 8 | `0000A526` | Upper halfword of LCDC-mapped bank B |
| 12 | `0000A526` | The same bytes after remapping the bank to Engine A BG |
| 16 | `A5260000` | Whole word via Engine A BG, with the original lane placement |
| 20 | `00000000` | Old LCDC aperture is no longer mapped |

The second run executed an actual ARM9 byte load from WRAMCNT (`04000247`)
and stopped with the explicit unsupported-I/O error. There is no melonDS
CPU, stock GPU, fabricated GPU bus traffic, or mirrored GPU state in the
witness. Boot ROM and the checked main-RAM mailbox are bench backing stores.
The bridge owns only POWCNT1, GPU-only VRAMCNT lanes and VRAM in this run; it
rejects unwired targets and any GPU deadline, IRQ/DMA effect, stall or frame
instead of acknowledging it. No LCD frame is started.

This is the ARM9/memory-bus slice, not an elaboration of the complete
NDS4MiSTer island. The installed NVC rejects SystemVerilog constructs in
`nds_nitro_console_island.sv` (including `'0` and `.*`). The witness does not
cover the production clock-domain bridge, ARM7, cartridge boot, GPU
scheduling, the other peripherals, generated HDL, synthesis or the board.

### M7 finite slice gates observed 2026-11-18 (not acceptance)

**M7 remains not accepted.** Every item below is a finite gate on a narrow
partition; none satisfies a checklist box above. None boots a game, and the
game-card row reads a synthetic test image without KEY1, BIOS or a real
boot. None has an ARM7, BIOS, FIQ, abort or undefined exceptions, DMA engine or input
integrated. The Clash ARM9 takes IRQ exceptions from Arm9Soc's IME/IE/IF
level (IRQ and game-card rows); the other Arm9Soc rows keep CPSR.I=1 and
poll IF, so they do not exercise entry. The native display rows do service the authoritative
`Nds.Gpu.Live` LCD frame deadlines, but on a nominal guest clock, not a
cycle-accurate ARM946E-S. The one Quartus result is an isolated prototype
fit, not a full-DS or integrated-console fit, and no board was run.

The CPU in every row is the Clash ARM9 slice
[`Nds.WholeCore.Arm9Slice`](../clash/src/Nds/WholeCore/Arm9Slice.hs): ARM
and ARMv5T Thumb state with architected predication, NZCV, data processing,
B/BL/BX/BLX (register and immediate, ARMv5 interworking including LDR pc
and LDM/POP `{.., pc}`), MUL/MLA/UMULL/UMLAL/SMULL/SMLAL, CLZ, MRS/MSR with
User, System, SVC and IRQ modes (three R13/R14 banks, SPSR_svc/SPSR_irq,
User-mode MSR writing only the flags), IRQ entry at instruction boundaries
and SWI, both returning by S-form data processing to PC or LDM `{.., pc}^`
with SPSR.T, single transfers with immediate/register offsets, writeback and
post-indexing, signed loads, and LDM/STM on the boot ROM and local RAM only
(no swap, FIQ, abort or undefined exceptions; ARMv5-only behaviour and the
vector base sit behind one `Arch` switch), a 4 KiB boot
ROM window, a 4 KiB local RAM that code can also execute from, and a blocking single-transfer link
(POWCNT1, VRAMCNT, DISPCNT, DISPSTAT, read-only VCOUNT, VRAM, and
timer/IME/IE/IF and game-card addresses for the devices in front of the
GPU; WRAMCNT fails closed). Its exact contract is in
[the Clash README](../clash/README.md#whole-core-arm9-boot-witness).
The rows were observed on successive slice revisions; the graphics fit and
its RBF predate the addressing-mode/LDM-STM revision.

| Gate | Runner | Observed result | Not covered |
| --- | --- | --- | --- |
| ARM-state ISA and addressing, three models | `sim/run_clash_arm9_isa.sh` | Two fixtures with hand-derived mailboxes: `hs_arm9_isa.S` (54 words: conditions, flags, data processing, branches) and `hs_arm9_mem.S` (46 words: register/immediate offsets, pre-writeback, post-index, signed loads, LDM/STM in four modes, PUSH/POP and LDR pc returns, condition-failed hazards). Both equal on the product `nds_cpu9` RTL, the pure `sliceStep` and freshly generated Verilog; 25 exact-fault variants (UNPREDICTABLE hazards, SWP, LDM/STM past RAM, into the link or onto the ROM, faulting before any beat) and 7 exact-link-offer variants pass on the latter two. Passed again on the Thumb/mode slice, whose Thumb-target fault variants were removed (Thumb row below) | Product oracle runs an ISA build without one condition-failed `MOVSNE pc, lr`: the product core leaves r14_svc = 0 there (CPSR kept), a product deviation. Unaligned transfers fault rather than rotate |
| GPU link backpressure and reset | `sim/run_clash_arm9_witness.sh` | The `hs_gpu_arm9.S` witness: 10 ordered ABI2 GPU accesses and 6 mailbox stores equal the product RTL run, under request stalls, on the pure slice and generated Verilog; WRAMCNT fails closed; generated RTL reset during a stalled offer, a pending write and a pending read discards pre-reset replies | No link epoch/stale-reply rejection proof; cycles are not compared |
| Standalone timers | `clash/tests/timers_gate.sh` | See [WHOLECORE_TIMERS.md](WHOLECORE_TIMERS.md): directed, seeded and generated-Verilog comparisons against an independent melonDS oracle | The same `Timers.timersStep` is now reused, unmodified, by the `Arm9Io` router (rows below); no ARM7 timers |
| Integrated Arm9Soc timers + IRQ latch | `sim/run_clash_arm9_timers.sh` | [`Nds.WholeCore.Arm9Soc`](../clash/src/Nds/WholeCore/Arm9Soc.hs) = slice + [`Arm9Io`](../clash/src/Nds/WholeCore/Arm9Io.hs) router (timers, IME/IE/IF with melonDS widths, same-cycle W1C wins). `sim/tests/hs_arm9_timers.S` (timer-1 cascade from F/1 timer 0, IF latch, byte IF write ignored, halfword/word W1C, IE/IME readback): all 11 hand-derived mailbox words, IRQ assert/deassert and IF_ACK [8,16] match on pure `socStep` and freshly generated Verilator HDL (`nds_arm9_soc`); RTL also checks external IF set/clear with IME off. Passed again on the IRQ-entry slice | Fixture keeps CPSR.I=1 and polls IF, so exception entry is not exercised here (IRQ row below); no DMA/ARM7/IPC; not on a board |
| ARM9 IRQ exceptions from a real timer chain | `sim/run_clash_arm9_irq.sh` | `sim/tests/hs_arm9_irq.S` on `Arm9Soc`, whose `Arm9Io` IME && (IE & IF) level drives the CPU's IRQ input: SVC/IRQ R13/R14 banking, a timer 0 overflow held off by CPSR.I, IME and IE, IRQs taken from the real timer with `SUBS pc, lr, #4` and five `LDM {r0-r3, pc}^` returns, CPSR/SPSR in and after the handler. The first 34 hand-derived mailbox words equal on the product `nds_cpu9` with product `gba_timer`/`nds_irq` on its I/O bus, the pure `socStep` and fresh `nds_arm9_soc` Verilog; the latter two also match 14 more words (entry at the first boundary after the MSR clearing I with F kept; external IF sources raised while an LDR waits on the link and at the first STM beat, both taken after the instruction completes) and 9 exact-fault builds for PSR/return forms outside the subset (retargeted to System/FIQ modes on the Thumb/mode slice). Six CPU mutants (I ignored, wrong R14_irq, SUBS pc not restoring CPSR, no bank switch, entry during a link wait, entry between STM beats) each fail the pure check | The product executes one more instruction after an MSR clearing I and loads CPSR flags/F from the old SPSR on entry, so those slots are slice-only. No FIQ, undefined or abort exceptions, no WFI/halt, no CP15 vector control; nominal timing, not ARM946E-S interrupt latency; not on a board |
| Thumb, interworking, multiplies, SWI, User/System modes | `sim/run_clash_arm9_thumb.sh` | Three fixtures with hand-derived mailboxes: `hs_arm9_thumb.S` (46 words, every ARMv5T Thumb format incl. MUL Rd = Rm, `ADD pc`, PC-relative loads at both alignments, LDMIA with base in list, BL, POP `{pc}`), `hs_arm9_interwork.S` (50 words: BX/BLX both ways, ARM `BLX <imm>` H = 0/1, Thumb `BLX <imm>` landing on ARM with bit 1 of the computed address set, `BX pc`, LDR pc/LDM/POP state switches, `MOVS pc, lr` into Thumb, six multiplies with C/V kept and overlapping Rd/Rm/RdLo/RdHi, CLZ, SWI from ARM/System/Thumb with R14_svc/SPSR_svc, shared User/System bank, User MSR flags-only) and `hs_arm9_thumb_irq.S` (12 words on `Arm9Soc`: IRQ entry from Thumb with R14_irq = next + 4 and SPSR.T, return to Thumb by SUBS and LDM^, an IRQ between a Thumb BL prefix and suffix). The product `nds_cpu9` matches all 46 Thumb words, all 50 interwork words (`PRODUCT_ORACLE`: SPSR_svc primed) and the first 7 Thumb-IRQ words; pure model and fresh `nds_arm9_slice`/`nds_arm9_soc` Verilog match every word plus 18 exact-fault builds. 17 CPU mutants (Thumb PC alignment, BL/BLX link bit 0, BLX H and bit-1 rounding, no load interworking, return ignoring SPSR.T, entry keeping T, MUL C/V cleared, unsigned SMULL, Rd = Rm faulting, SWI/IRQ R14 step, User MSR writing control, System with its own bank, LDMIA base writeback, CLZ off by one) each fail the pure check. Yosys generic size of `nds_arm9_slice` 49,746 → 99,644 cells, 991 → 1,156 flip-flops | Product loads CPSR flags/F from the old SPSR on exception entry (seen for SWI) and mishandles a condition-failed `SUBS pc` (bank corruption), so fixtures avoid both on its build; no harness IRQ source on the product. No FIQ/abort/undefined exceptions, no Jazelle/DSP (QADD, SMULxy, LDRD) forms, no CP15, no ARMv4T configuration built; nominal timing |
| Read-only NTR game card behind Arm9Soc | `sim/run_clash_arm9_card.sh` | [`Nds.WholeCore.Card`](../clash/src/Nds/WholeCore/Card.hs) (AUXSPICNT, ROMCTRL, command bytes, data port; image behind a ready/valid word port) running `sim/tests/hs_arm9_card.S` on a synthetic 64 KiB image (ASCII title, arithmetic filler) in a raw-power-up build (reset release, 9F, 00 header, 90) and a direct-boot build (B7 incl. secure-area redirect and mirroring, B8), with one completion taken as an IRQ exception and the rest polled through IF bit 19. Mailboxes and image-address streams come from `hs_arm9_card_oracle.py`, an independent model of melonDS's NTR protocol. The product `nds_cpu9` with product `nds_card`/timers/`nds_irq` matches the first 15 raw and 17 direct words; the pure `socStep` and fresh `nds_arm9_soc` Verilog match all 19 and 22 words and the 256 and 516 image addresses under image-store backpressure, plus 15 exact-fault builds; six controller mutants (no redirect, no mirroring, no IRQ, header address ignored, 9F fill, no 4 KiB wrap) each fail | Product differs after those words: its 00 ignores the header address and its direct-boot AUXSPICNT reads 0 at power-up (both observed); its source reads B7 without the 4 KiB wrap (not exercised on it). No KEY1/KEY2, BIOS boot, backup SPI, card writes, card DMA, ARM7 slot ownership or cart-bus timing; no real cartridge or game; not on a board |
| Card loader runs a synthetic DS image's ARM9 binary from RAM | `sim/run_clash_arm9_boot.sh` | Boot-ROM loader `sim/tests/hs_arm9_boot.S` on Arm9Soc with the card in direct-boot mode: CRC16 and fields of the cartridge header the launcher hands over in the boot ROM at `0xFFFF0E00` (the image's own 0x200-byte header, standing in for the BIOS copy at `0x027FFE00`, since B7 cannot read the header), B7 copy of the ARM9 binary from ROM offset 0x8000 into the now-executable 4 KiB RAM, `BX` to its entry. The image (standard header layout, logo area zero, ARM7 fields empty, binary = assembled `hs_arm9_boot_payload.S`) and every expectation come from `hs_arm9_boot_oracle.py`: 16 mailbox words, 128 image addresses and the 31-entry RAM retirement trace match on the pure `socStep` and fresh `nds_arm9_soc` Verilog under image-store backpressure; no RAM instruction retires before the whole binary is stored and each is the word the guest stored. A raw-power-up build reads the header from the card with 00 and finds it identical to the handoff (8 words); bad-CRC and entry-outside headers are rejected with nothing run. RAM-fetch mutants (stale port word, boot-ROM word) fail | Not a BIOS boot: the header arrives by launcher handoff, no KEY1 secure area or raw-to-data mode transition, no ARM7 binary, firmware or game; nominal timing; no product-RTL comparison for this gate; not on a board |
| Native all-Haskell display | `tools/hs_native_slice/run.sh 24` | `sliceStep` running `sim/tests/hs_native_slice.S` drives the authoritative `Nds.Gpu.Live` in process: 24 frames each equal an independent formula pixel by pixel (2 reset-black frames, then buffers t=0..10 each shown twice: 11 unique displayed patterns); the AppKit viewer showed the same pixels as a captured frame, also from a locally packaged build. That package predates Arm9Soc and remains display-only. See [its README](../tools/hs_native_slice/README.md) | Nominal guest clock, not ARM946E-S cycles; Engine B off; no palette/OAM; ~1 guest frame/s |
| Native Arm9Soc timers + VBlank IRQ latch with display | `tools/hs_native_slice/run.sh --soc 10` | `socStep` running `sim/tests/hs_native_soc.S` with `Nds.Gpu.Live`: 10 LCD frames pass the pixel formula (2 reset-black, buffers t=0..3); each frame the CPU starts TM0 (F/1, IRQ), polls IF bit 3, W1C, stops, then waits on the GPU's VBlank IF latch to flip. 457,696 router replies, IF and the IRQ level matched an independent host model every cycle (5 TM0 overflows, 10 GPU VBlank sets, 15 W1C); passes with request stalls every 0/2/5 cycles; IE=0x8 ROM and a wrong-IF-bit router mutant fail. `run.sh --soc 10` passed again on the IRQ-entry slice | Fixture keeps CPSR.I=1 and polls, so exception entry is not exercised; host model covers TM0 F/1 and word IE/IF/IME only; a set-dominant mutant is not distinguished by this fixture |
| Generated CPU + two-bank VRAM graphics | `sim/run_clash_gfx_soc.sh` | `sim/tests/hs_gfx_arm9.S` rasterises a shaded triangle into bank A through the slice into [`Nds.Gpu2D.VramDisplay`](../clash/src/Nds/Gpu2D/VramDisplay.hs) (composed in `Nds.WholeCore.GfxSoc`). Generated Verilog's log of 49,160 GPU transactions is byte-identical to the pure model and the ABI2 service, and its 640x480 VGA capture equals the service's 49,152-pixel top LCD; the `hs_gpu_arm9.S` witness (10 transactions) and three unsupported-register negatives (fault 4 at `04000000`, `04000242`, `04000006`) also match. The same gate passed again on the addressing-mode/LDM-STM slice revision. One-off probes on that revision (not part of the gate) wrote/read TM0CNT_H, TM3CNT, IME, IE, IF and DISPSTAT, now routed onto the link: the pure model and generated RTL both stopped with fault 4 at the access, with equal logs. Isolated Quartus 17.0.2 fit on 5CSEBA6U23I7 (previous slice revision) succeeded: 8,252 ALMs (20%), 308/553 M10K (256 of them VRAM banks A/B), worst setup slack +0.726 ns, hold +0.039 ns. The fitted RBF (local build artefact, not in the repo) has SHA-256 `ae3c495d…0c52a2`. Project: [Haskell CPU + VRAM display prototype for MiSTer](../fpga/mister_hs_gfx_slice/README.md) | Physical board untested; not an NDS core or integrated-console fit; no refit of the current slice; display mode 0/2 only, no BG/OBJ/3D, no mid-frame timing comparison |

The ISA and native rows are different programs with different purposes:
`hs_arm9_isa.S` and `hs_arm9_mem.S` are CPU-only fixtures with no link
traffic in their main images, while `hs_native_slice.S` and `hs_gfx_arm9.S`
are display programs over the link to two different GPU targets (the host
`Nds.Gpu.Live` service and the synthesizable `VramDisplay`). The link also
carries timer and IME/IE/IF addresses for an I/O router; `VramDisplay`
rejects them, so the graphics prototype has no timers or interrupts.
