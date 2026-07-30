# Firmware boot wedges: wrong bytes in the ARM7 exception handler at 0x037FE28C

**Filed** 2026-07-29 · **Blocks** firmware boot (`FWBOOT=1` / OSD `Boot: Firmware`)
· **Does not affect** direct boot

---

## Symptom

With `FWBOOT=1` the firmware boot runs **1.588 seconds of DS time** and then the
ARM7 core aborts:

```
** Failure: 1588231865ns: ARM7 decode: unhandled opcode 1C0E1C05 thumb=0
                          pc=037FE28C lr=00002E10 cpsr=8000001F
```

`cpsr=0x8000001F` → System mode, T clear (ARM state). `lr=0x00002E10` is in the
**ARM7 BIOS**, so BIOS code around `0x2E0C` handed off and landed here.

## Root cause: the memory contents are wrong, not the CPU state

Compared against melonDS at the same address using the `ARM7PROBE_LO`/`ARM7PROBE_HI`
window probe (in `sim/melonds_tracer/tracer.patch`):

| at `0x037FE28C` | instruction |
|---|---|
| melonDS (oracle) | `0xE25EF004` = ARM `subs pc, lr, #4` |
| this core | `0x1C0E1C05` |

The oracle is in **ARM state there too** (probe at `0x037FE280`: `T=0`,
`instr=0xE590E03C` = `ldr lr,[r0,#0x3C]`), so nothing is wrong with Thumb handling.
**The bytes simply differ.**

What the oracle holds is the lead: `subs pc, lr, #4` is the canonical exception
return, so `0x037FE28C` is inside the **firmware's ARM7 exception handler**,
installed in ARM7 WRAM.

## Prime suspect: a divergence previously dismissed as benign

`sim/tests/loopdiff.py` puts the first ARM7 control-flow divergence at **instruction
2,258,084**, where this core branches to `pc=0x00000020` — the instruction at `0x18`,
the **IRQ vector** — and melonDS does not. That was written off as relative IRQ
delivery timing between two models that are not cycle-equivalent, which was
defensible in isolation.

**It is no longer defensible**, because the eventual fault lands in exception-handler
code. Re-examine this first. Also unexplained and possibly related: our CPSR at the
fault is `0x8000001F` (System) where melonDS at `0x037FE280` is `0x000000D3`
(Supervisor).

## Three wrong diagnoses, so they are not repeated

1. **"A decode case GBA titles never reach."** No — `0x1C0E1C05` is two Thumb
   `add rX,rY,#0` (the canonical Thumb `mov` idiom) and `thumb=0`, i.e. Thumb code
   being executed as ARM. As ARM, bits 27–25 = `110` is coprocessor load/store,
   which ARM7TDMI does not implement, so the decoder is right to reject it.
   Implementing the "missing opcode" would have papered over a control-flow bug.
2. **"The ARM7 lost its T bit"** (BX not taking bit 0, exception return not
   restoring SPSR's T, or the `ldm^` mode switch). No — the oracle is in ARM state
   at the same address. Ruled out by the probe above.
3. **"The wrong bytes are in the raw firmware image."** Searching
   `firmware_retail.hex` for `1C0E1C05` gives **0 hits and proves nothing**: the DS
   firmware's boot code is **compressed** in the image, so decompressed instruction
   words legitimately do not appear. Do not repeat this test.

## Reproduce

```bash
DIRTY=1 POD=nds-sim-fwlr KEEP=1 \
  ENV="WORK=sim/nvc_work_fwlr PRELOAD=0 HEXFILE=sim/tests/kirby_4mb.hex DIRECT=0 FWBOOT=1 \
       FWFILE=sim/tests/firmware_retail.hex HEARTBEAT_MS=400 \
       TIMEOUT_MS=1700 FRAMES=100 GPUCEDIV=1 CYCLE_HIST=0" \
  build/remote-sim.sh run_top_frame.sh
```

Untraced, ~4.5 h wall to reach 1.588 s. **Do not try to find this by trace**: 1.588 s
is ~30M ARM7 instructions and `TRACEFILE` costs ~40x. The assertion in `gba_cpu.vhd`
prints opcode, Thumb flag, PC, LR and CPSR, which is what made it findable.

Oracle side:

```bash
BIOS9=…/bios9.bin BIOS7=…/bios7.bin FIRMWARE=…/firmware.bin \
ARM7PROBE_LO=037FE28C ARM7PROBE_HI=037FE28C \
  sim/melonds_tracer/build/melonds_fbdump --fw "<rom>.nds" /tmp/fb.txt 200
```

(`.bin` images convert from the checked-in `.hex` as little-endian words.)

## Next steps

1. **Re-examine the instruction-2,258,084 IRQ divergence.** Identify which IRQ
   source asserts in this core and not in melonDS at that point. `loopdiff.py`
   cannot distinguish "IRQ at a different time" from "IRQ that should not fire",
   which is exactly the gap that let it be dismissed.
2. **Diff the written bytes.** Find where the firmware's ARM7 handler is written and
   compare against melonDS. Candidates: `nds_spi`'s firmware read address/offset,
   the BIOS's decompression input, or WRAMCNT mapping the write somewhere other than
   where the read lands.
3. Note that on real hardware this raises an **Undefined Instruction** exception
   rather than halting, so the core arguably should vector. **Do not fix that
   first** — it would hide this.

## How far firmware boot gets before this (all verified)

- Both retail BIOSes execute from their true reset vectors — ARM9 `0xFFFF0000`,
  ARM7 `0x00000000`, CPSR `0xD3`
- ARM7 BIOS matches the melonDS oracle with **zero control-flow divergence across
  323,826 collapsed basic blocks** (~1.1M instructions) after the RTC fix
- Full card negotiation: raw `9F`/`00`/`90`/`3C`, then KEY1 — KEY2-data-mode, chip
  ID, four secure-area blocks at `0x6000`/`0x7000`/`0x5000`/`0x4000`, then `Ax` into
  main data mode
- The firmware's own code runs and initialises video: `POWCNT1` goes
  `0x8000 → 0x820E → 0x820F` at **1.49 s**, matching the oracle

So this is the last known blocker between firmware boot and the firmware menu.

## Related

- `HANDOFF.md` → "Firmware boot" and "The ARM7 fault at 1.588 s is WRONG MEMORY"
- Two bugs already fixed on this path: `nds_rtc` `status1` needed bit 7 (power-off
  detect, which the BIOS branches on for cold-vs-warm boot), and `nds_card` needed
  the whole raw + KEY1 boot command sequence
- The KEY1 command sequence is **ROM-dependent** (7 commands retail, 2 for homebrew
  with no secure area) — see `nds_card.vhd`'s header

---

# SECOND TICKET — pipelined drawer wedges under VRAM backpressure (hardware white screen)

**Filed** 2026-07-30 · **Severity: blocks hardware** · Reported from silicon: the
sdk2k test ROM white-screens under **both** boot modes and **both** GPU pace
settings.

## Root gap: simulation never modelled backpressure

| A..D renderer reads (`vrsrv_*`) | simulation (before this) | hardware |
|---|---|---|
| in flight at once | **unlimited** | **one** |
| latency | fixed 4 cycles | real SDRAM + CPU contention |
| `vrsrv_ready` | **never connected** | `~vr_busy & ~vr_fin` (NDS.sv:889) |

`tb_top_frame`'s `prserv` accepted a request every cycle with no gating. So every
passing test — `tb_gpu2d`, `tb_gpu2d_frame`, `tb_gpu2d_timed`, `fbdiff`, and
`run_drawer_text_equiv.sh` — ran against a memory model that cannot say no.

## Reproduction (new generics, ~5 minutes)

```bash
DIRTY=1 POD=nds-sim-hw1 \
  ENV="WORK=sim/nvc_work_hw1 PRELOAD=0 HEXFILE=sim/tests/nds_2dk.hex DIRECT=1 \
       GPUFAST=0 VRAMOPS=1 VRSRV_ONE=1 VRSRV_LAT=4 TIMEOUT_MS=120 FRAMES=3 \
       GPUCEDIV=1 CYCLE_HIST=0" \
  build/remote-sim.sh run_top_frame.sh
```

`VRSRV_ONE=1` models hardware (ready low from acceptance until done);
`VRSRV_LAT` sets the response latency. Results:

| | `renders` | `bg/render` | `rvram_busy%` |
|---|---|---|---|
| `VRSRV_ONE=0` (old sim) | **189/192** | 832 | 32 |
| `VRSRV_ONE=1 LAT=4` | **1** | 409,876 | **100** |
| `VRSRV_ONE=1 LAT=8` | **1** | 407,374 | 42 |

410,000 cycles on one line against a 2,130 budget is a **wedge, not slowness**, and
it is latency-independent — the one-in-flight restriction alone triggers it.

## Diagnosis

Serialised memory needs ~324 ops/line x ~5 cycles = ~1,620 of the 2,130 budget, so
it should be *tight but feasible*. It is not merely saturating. `rvram_busy%` at 100
while ops account for ~76% of cycles indicates `nds_vram`'s renderer FSM sits
**non-IDLE waiting for a response that never arrives** — precisely the failure
NDS.sv's own comment at :878 describes: *"every request arriving while ch1 was busy
was simply dropped - the core would then wait forever for a word that was never
asked for."* The `rsrv_ready` line was added to prevent that; at this request rate it
does not fully.

A likely contributing race, by inspection: `vrsrv_ready_c` is combinational in
**clk_mem** (3x clk1x) while `nds_vram` samples it in **clk1x**, so `vr_busy` can
rise after the core sampled ready high and committed to its one-cycle `rsrv_req`
pulse. That pulse lands while busy and NDS.sv drops it — `if (vrsrv_req_c &
~vr_req_d & ~vr_busy)`. Note the **firmware** channel handles exactly this hazard
with an explicit `fwr_pend` latch (NDS.sv:491) and its comment says a dropped
request "stalls ARM7 permanently". The vrsrv channel has no equivalent latch.

**Why v1 was safe:** it held `req` until `done` and allowed one op, so it only ever
issued into an idle channel and never depended on a sampled-then-stale ready.

## Fix candidates (owner: whoever holds the accept-protocol work)

1. **Latch a dropped `vrsrv_req` in NDS.sv**, mirroring `fwr_pend`. Smallest change,
   matches an existing commented pattern in the same file for the same hazard.
2. Make `nds_vram` hold `rsrv_req` until it observes acceptance, rather than
   pulsing on a sampled `ready`.
3. Pipeline ch1 itself so `AD_DEPTH > 1` is real on hardware — NDS.sv:881 already
   notes this "is a separate change and needs hardware to validate".

**Do not ship the current tree to hardware until this is fixed.** `GPU_FAST` is
already off and is not implicated.
