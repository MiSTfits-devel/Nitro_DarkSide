# Haskell GPU milestone ledger

Status of the host-side Haskell/Clash DS GPU workstream (2D engines, 3D chip,
TARDIS line cache, visible viewer). The numbering here is this workstream's
own; it is unrelated to the console bring-up milestones in
[`ROADMAP.md`](ROADMAP.md).

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
| M6 closed-loop pairing | **Closed loop not started** | Open-loop live frontend done |
| M7 SoC, cartridge and board | **Not accepted** | RTL pieces exist; no integrated acceptance |

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

Details: [clash/README.md, Measured TARDIS work](../clash/README.md#measured-tardis-work-on-a-real-trace)
and [TARDIS note](tardis.html).

## Visible viewer status (supports M6, not M6)

`tools/hs_gpu_view/run.sh CART.nds` streams NSD2 v12 from melonDS into
`trace-view` and shows every pixel rendered by `Nds.Gpu3D.Chip` and the
`Nds.Gpu2D` compositor in a native macOS window. Controller, keyboard and
mouse-as-touchscreen input reach the game through melonDS's `--input` file;
real input and live output were observed. Caveats:

- **Open loop**: the emulated CPU still reads melonDS's own GPU (GXSTAT,
  capture, RAM_COUNT, results). The Haskell output never feeds back.
- Throughput is a few frames per second; the pipe throttles melonDS.
- It fails closed and marks the window `STOPPED, NOT LIVE` on any model error.

Usage and controls: [clash/README.md, Visible host viewer](../clash/README.md#visible-host-viewer-live-stream-open-loop).

**Cartridge verdict (NTR EVA, FARCLIP)**: in the live viewer run, the
observed `shown.png` was at `[07-01] 3D ATTR FARCLIP` with `PROGRESS[018/058]`.
The historical `016/058` at the same test in
[NTR_EVA_TESTER.md](NTR_EVA_TESTER.md) is a configuration-specific baseline,
not a universal current position. melonDS itself
reports FARCLIP as `RESULT:FAIL TOTAL:FAIL` in that baseline. The Haskell
render reproduces what melonDS's CPU drives; it cannot change the verdict,
because the open-loop CPU evaluates melonDS's GPU state, not the Haskell one.

## Remaining checklist

### M6: closed-loop pairing (not started)

- [ ] Haskell GPU state answers the emulated CPU's GPU reads (GXSTAT,
      RAM_COUNT, geometry results, capture/VRAM effects, IRQ/DMA timing)
      instead of melonDS's GPU.
- [ ] A cartridge runs in that closed loop with no melonDS GPU in the path,
      with frames still compared against an independent melonDS run.
- [ ] Throughput sufficient for interactive use (currently a few fps).

### M7: full SoC, cartridge progression and board (not accepted)

SoC RTL pieces already exist in this repository (CPU islands, memory fabric,
DMA/IRQ/timer/IPC, SPI/RTC/touch/sound blocks); what is missing is their
integration with this GPU and acceptance of the whole.

- [ ] Explicit ownership of the CPU/bus path, cartridge, main memory and VRAM
      between the SoC and the Haskell GPU.
- [ ] DMA (including GXFIFO and capture), IRQ, timers and IPC integrated
      with the GPU and checked against an independent reference.
- [ ] SPI, RTC, touchscreen and sound integrated.
- [ ] Deterministic frame, line and input timing, so runs are reproducible
      and comparable line by line.
- [ ] Full NTR EVA diagnostic progression through all 58 tests, past the
      observed FARCLIP point, with every result determined by our hardware
      models; no fixed intermediate count is the acceptance target.
- [ ] After host acceptance: generated HDL from the corrected sources,
      simulated against the host models.
- [ ] Quartus fit and timing for the integrated core.
- [ ] Board acceptance on MiSTer hardware.
