# All-Haskell native slice (macOS)

A narrow vertical slice, **not a full DS and not a game boot**. The pure cycle
function `Nds.WholeCore.Arm9Soc.socStep` runs an assembled boot ROM on the
production Clash ARM9 slice (`Nds.WholeCore.Arm9Slice`) and its local I/O
router (`Nds.WholeCore.Arm9Io`: DS timers via `Nds.WholeCore.Timers`, plus
the ARM9 IME/IE/IF latch). The router forwards every other request on its
external ready/valid link, in-process, to the authoritative `Nds.Gpu.Live`
device. melonDS isn't used anywhere, and there's no trace or oracle pixel
source. Every displayed pixel comes from a frame the device completed through
its own LCD path.

## Components

| file | role |
|---|---|
| `clash/src/Nds/WholeCore/Arm9Io.hs` | synthesizable router: timers + IME/IE/IF local, everything else passes through |
| `clash/src/Nds/WholeCore/Arm9Soc.hs` | slice + router: pure `socStep` and synthesizable top `nds_arm9_soc` |
| `sim/tests/hs_native_slice.S` | display fixture |
| `sim/tests/hs_native_soc.S` | display + timer/IRQ-latch fixture |
| `clash/test/NativeSliceFrames.hs` | host: guest clock, deadline service, GPU link, IRQ effects, model checks, capture |
| `tools/hs_native_slice/run.sh` | build + run (headless, or `--view`) |
| `tools/hs_native_slice/NativeSliceView.swift` | read-only AppKit viewer for the NDSF/NDSE stream |

## Router semantics (`Arm9Io`)

- **Routes.** The router serves TM0CNT..TM3CNT (0x04000100-0F), IME (0x208),
  IE (0x210) and IF (0x214) itself. Everything else goes unchanged to the
  external link. Which addresses leave the slice at all is decided by the
  slice's `linkOwns`; unrouted addresses fault inside the slice.
- **Timers.** Timer behaviour is exactly `Timers.timersStep`; the router
  only passes the byte lanes and lane-positioned data through. `TIMER_TICK`
  is one 33.514 MHz timer clock. The host asserts it on odd ARM9 cycles.
- **Register widths.** Widths follow melonDS ARM9 I/O:
  - IME: any width at 0x208; only bit 0 is stored.
  - IE: word writes, or halfword writes at 0x210/0x212.
  - IF: word or halfword writes are write-one-to-clear.
  - Byte writes to IE/IF are ignored, and byte reads of them return 0.
- **IF update order.** Each cycle,
  IF' = ((IF & ~extClear) | extSet | timer pulses << 3) & ~CPU W1C.
  A same-cycle CPU clear wins, matching melonDS's event-before-I/O order.
- **IRQ outputs.** `IRQ` = IME && (IE & IF) != 0. `Arm9Soc` drives the
  slice's IRQ input with it, and the slice takes the IRQ exception when
  CPSR.I=0 (contract: `clash/README.md`). Both shipped fixtures keep the
  reset CPSR (I=1), so they poll IF and no exception is entered. `IF_ACK`
  reports the mask written to IF; the host passes it to the GPU's
  `acknowledgeIF`, the GX FIFO IRQ recheck melonDS calls HsIFAck.
- **Reply timing.** A router-served request is accepted when no router
  reply is pending. It reads state at the start of the accept cycle; the
  reply is registered and presented from the next cycle.

## Fixtures

Both draw the same animated BGR555 pattern into a back VRAM bank and flip
DISPCNT's display bank during VBlank. The formula is in the .S headers, and
the host checks every frame pixel by pixel against an independent copy.

- `hs_native_slice.S` finds VBlank by polling DISPSTAT.
- `hs_native_soc.S` additionally sets IME=1 and IE = VBlank | timer 0, and
  enables the VBlank IRQ in DISPSTAT. Then, every frame:
  1. starts timer 0 (F/1, IRQ enabled, reload 0xFF00);
  2. polls IF until bit 3 is set, write-one-clears it, stops the timer and
     reads the count;
  3. clears a stale IF bit 0, waits for the GPU's next VBlank IRQ latch,
     and flips.

  Results go into a local-RAM mailbox.

## Host checks

- **Clock and deadlines.**
  - One `socStep` per tick; GPU/LCD time is tick/2. This is a nominal
    clock, not ARM946E-S cycle accurate.
  - Before each step, every device deadline <= now is serviced in order.
    The next LCD frame starts exactly at the EndFrame time (560190 per
    frame).
  - Device ARM9 IRQ set/clear masks go into IF in that same cycle; effects
    of a GPU write or an IF acknowledge go in the next cycle.
- **Per-cycle model.** Each cycle, the IF register, the IRQ level and every
  router-served read reply are compared with a host model. The model is
  written independently of `Arm9Io`: TM0 count arithmetic from the accepted
  start/stop cycles and odd-cycle ticks, plus IF set/clear events. Any
  router-served access the model doesn't cover fails as unmodelled.
- **Effects.**
  - ARM9 DMA start conditions are counted against reset-disabled channels.
    Display-FIFO and GX-FIFO DMA conditions fail the run.
  - ARM7 effects are counted; there's no ARM7.
- **Failures.** Malformed, overlapping or backpressure-unstable GPU
  requests fail the run, and so does any slice fault.

## Limits

- The demos never enter an IRQ exception: both fixtures keep CPSR.I=1 and
  poll IF. IRQ entry is covered by `sim/run_clash_arm9_irq.sh`, not here;
  `run.sh --soc 10` was rerun and passes on the IRQ-capable slice. No FIQ,
  DMA engine, ARM7, IPC, BIOS, cartridge, input or sound.
- Only the instruction set the slice implements; see the
  `clash/README.md` "Whole-core ARM9 boot witness" contract, which now
  includes Thumb, MUL and SWI. The fixtures here use plain ARM data
  processing, branches and single loads/stores only.
- 4 KiB boot ROM and the slice's local RAM (size per the `clash/README.md`
  contract); the fixtures use only its first 40 bytes as a mailbox.
- A locally packaged build of this tool predates `Arm9Soc` and is
  display-only (`hs_native_slice.S` on the bare slice); `--soc` needs a
  source build.
- Nothing here has run on physical hardware.
- GPU routing covers VRAM, POWCNT1, VRAMCNT, DISPCNT, DISPSTAT and VCOUNT
  (read-only). There's no palette, OAM or Engine B access.
- The host model covers TM0 F/1 start/stop and word IE/IF/IME accesses. The
  other timers, prescalers and cascade are covered by `Timers`' own checks
  and by `sim/run_clash_arm9_timers.sh`, not here.
- Engine B is off, so the bottom screen is the device's disabled-engine
  output.
- Runs at about 1 frame/s wall clock on Apple silicon. The viewer is
  labelled guest-time, not real-time.

## Run

```
tools/hs_native_slice/run.sh 24              # display fixture
tools/hs_native_slice/run.sh --soc 10        # timers + IRQ latch fixture
tools/hs_native_slice/run.sh --view --soc 60 # same producer piped into the viewer
```

Needs `arm-none-eabi-as`/`objcopy`, `stack` (lts-22.43) and `swiftc`. Use at
least 8 frames with `--soc`: buffers change every two frames, and the
acceptance needs three distinct buffers.
