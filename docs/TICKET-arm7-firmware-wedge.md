# Firmware boot: `ldm ^` never restored r8-r12 (FIXED 2026-08-05)

The 1.588 s "unhandled opcode" fault is only where a runaway PC landed, ~67 ms and
1.2M instructions after the real bug. Read the ROOT CAUSE section near the end
first; the material above it is a record of three wrong answers, kept because each
one is a trap that looked convincing.

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

> **RETRACTED 2026-08-05. There is no displacement. The memories are identical.**
> The oracle's ARM7-visible WRAM was dumped word for word (`ARM7WRAMDUMP`) and
> compared: every one of the seven watched words matches this core exactly,
> `E25EF004` included, at `0x037FE284` in **both**. Across all 96 KB of
> ARM7-visible WRAM the oracle contains `E25EF004` exactly **once**, at
> `0x037FE284` — precisely where this core has it. The "8 bytes low" reading came
> from comparing an `ARM7PROBE` **R15** value against a raw address: R15 is
> address **+8** in ARM, so "the oracle has `E25EF004` at `0x628C`" was the oracle
> *executing* `0x6284`. The other probe reading confirms the same bias — "at
> `0x037FE280`, `instr=E590E03C`" is `0x037FE278`, which the dump holds. So the
> whole displacement, and the search for what wrote the bytes 8 bytes low, was an
> artifact. See "Retraction and the real mechanism" at the end.
>
> ~~**ROOT CAUSE FOUND 2026-07-30. The bytes are correct and written 8 bytes too
> low.**~~ `0x6284` holds `E25EF004` — exactly what the oracle expects at `0x628C`.
> Everything below about wrong bytes, decompression, the SPI read path and the IRQ
> divergence is **retired**; see "Root cause" at the end. This is a displacement
> bug in where the ARM7 BIOS installs the firmware's exception handler, and the
> corruption is localised to **1.070 s** at ARM7 PCs **`0x2A8A` / `0x2AF4`**, so it
> no longer needs a 30M-instruction trace.

## Progress 2026-07-30 — two of the three memory-path candidates ruled out

Next step 2 named three candidates for where the wrong bytes come from. Two are
**correct by inspection against melonDS**, so the search should not start there:

- **WRAMCNT mapping the write somewhere other than where the read lands.** No.
  `0x037FE28C` and `0x0380E28C` are the same storage: `nds_membus7` decodes
  `0x03` with `if (cpu_adr(23) = '1' or wsh_mapped = '0') then T_WRAM7`, which is
  GBATEK's rule that the ARM7's `0x03000000` region mirrors ARM7-WRAM when
  WRAMCNT allocates it no shared WRAM, and it addresses that store with
  `w7p_addr <= cpu_adr(15 downto 2)` — `& 0xFFFF`, byte-identical to melonDS's
  `ARM7WRAM[addr & (ARM7WRAMSize-1)]` for **both** windows. The shared-WRAM path
  masks with `0x7FFF` and drops the block bit in the 16 KB modes, which is
  `SWRAM_ARM7.Mask` again.
- **`nds_spi`'s firmware read address/offset.** No. Command `0x03` shifts exactly
  three address bytes into a 24-bit `fw_a` (`fw_datapos` 1..3), serves from
  `fw_a(17 downto 2)` with `fw_lane <= fw_a(1 downto 0)` little-endian, then
  post-increments — a 2 Mbit chip wrapping at 256 KB, which is the retail part.

That leaves **the BIOS's decompression itself**, and it points somewhere more
uncomfortable than a memory-map bug: the ARM7 BIOS is a real retail dump, so if
its input bytes are right and its output bytes are wrong, our **CPU** computed
them wrong. A data-path bug — one wrong shift, rotate, or byte lane — produces
exactly this: wrong bytes, unremarkable control flow, and a fault thousands of
instructions later. Note what that does to the evidence already collected:
`loopdiff.py`'s "zero control-flow divergence across 323,826 collapsed basic
blocks" **cannot see it**, because it compares control flow only.

### Instruments added, because this cannot be found by trace

`ARM7DBG=1` on `tb_top_frame` (trace-free, so the ~4.5 h untraced run stays ~4.5 h):

- **ARM7 IRQ census.** Per-source pulse counts off `irq_in7`, every delivery of
  `cpu7_irq` with IF/IE/IME and the PC, and a census line every 10 ms of DS time.
  This is what next step 1 needs and `loopdiff.py` cannot give: a source that
  fires here and never in the oracle is visible as a count, where "an IRQ at a
  different time" and "an IRQ that should not fire" look identical in a trace.
- **ARM7 WRAM write watch** (`ARM7WATCH`, default `0x0380E28C`) on the write port
  after the loader mux, covering the faulting word and three either side, with
  each store's time, data, byte enables and PC. It keeps a shadow copy so the
  periodic line can report **`never`** for a word nothing ever wrote — which
  would be its own answer: the fault would then be executing WRAM that was never
  filled, and the question becomes why the copy did not happen rather than what
  corrupted it.

### Which memory the faulting fetch reads depends on WRAMCNT

Easy to get half right, and worth a paragraph because watching the wrong one costs
a 4.5 h run. melonDS's ARM7 read of the `0x03000000` region is

```c
if (SWRAM_ARM7.Mem) SWRAM_ARM7.Mem[addr & SWRAM_ARM7.Mask];
else                ARM7WRAM[addr & 0xFFFF];
```

so `0x037FE28C` is **shared** WRAM offset `0x628C` when WRAMCNT gives the ARM7 any
of it, and ARM7-WRAM offset `0xE28C` when it does not. `nds_membus7` decodes
identically. The watch therefore covers **both** words and prints WRAMCNT with each
census, so the run also reports which storage was live.

Measured on the way in: the ARM7 BIOS zeroes shared WRAM from `pc=0x3140` with
**`wramcnt=11`**, i.e. WRAMCNT=3, ARM9 none / ARM7 all 32 KB. So the faulting fetch
reads **shared WRAM `0x628C`**, and a watch on ARM7-WRAM alone would have watched
the wrong memory for the whole run. Give `ARM7WATCH` in hex and let the shell
convert it — writing the decimal out by hand put one run's watch on `0x0380108C`.

### Oracle IRQ baseline (measured, `kirby_4mb`, `--fw`, 120 frames)

`tracer.patch` now carries the matching census: per-source counts in
`NDS::SetIRQ` (cpu 1) and deliveries in `ARM::TriggerIRQ` (`Num == 1`), printed by
`melonds_fbdump` every `IRQ7CENSUS` frames.

```
IRQ7 census frame  20 deliveries=14   b6=7  b19=11
IRQ7 census frame 100 deliveries=182  b0=19  b3=2  b4=148  b6=7  b19=11
IRQ7 census frame 120 deliveries=390  b0=39  b3=5  b4=336  b6=7  b19=11
```

So across the whole firmware boot the oracle's ARM7 uses **exactly five sources**:
b0 VBlank, b3 Timer0, b4 Timer1, b6 Timer3, b19 card-transfer-complete. Nothing
else fires — in particular **no b23 SPI** and **no b16/17/18 IPC**, and the first
~80 frames use only Timer3 and the card.

### RTL census vs oracle: no spurious IRQ source, out to 1.070 s

First instrumented run (it died at 1.070 s on a bug in the instrument itself — a
32-bit word stored into VHDL `INTEGER`; fixed, and note the run reached 1.070 s in
**~35 minutes**, not the 4.5 h this ticket estimates):

```
** Note: 1065745175ns+1: IRQ7 census deliveries=16  b6=8  b19=12
```

Two sources, **b6 Timer3 and b19 card-transfer-complete** — the same two the oracle
uses in its pre-firmware phase, with counts differing by one each (oracle 7 and 11).
The oracle's b0/b3/b4 only appear later, once the firmware's own code is running,
which at 1.070 s this core has not reached (POWCNT1 init is at 1.49 s).

So, as far as 1.070 s: **no IRQ source asserts here that does not assert in
melonDS.** That is the measurement next step 1 asked for, and it does not support
this ticket's reason for reopening the instruction-2,258,084 divergence. A
one-count difference in Timer3 and card IRQs is exactly the relative delivery
timing the divergence was originally dismissed as. It should be re-dismissed unless
the census past 1.070 s shows a source the oracle never uses — which shifts the
weight onto the data-path hypothesis above, where the ARM7 BIOS computes the
handler's bytes wrongly with control flow that looks correct.

Also measured, same run: `WRAMWATCH shared(arm7) byte=25216 data=00000000
wramcnt=11 pc7=00002AF4` — the ARM7 BIOS writes **zero** to shared WRAM `0x6280`
at 1.070 s, from BIOS code, late in the boot rather than during early init.

Re-run the comparison with:

```bash
BIOS9=…/bios9.bin BIOS7=…/bios7.bin FIRMWARE=…/firmware.bin IRQ7CENSUS=20 \
  sim/melonds_tracer/build/melonds_fbdump --fw "<rom>.nds" /tmp/fb.txt 120
```

(the `.bin` images convert from the checked-in `.hex` as little-endian words, and
`kirby_4mb.hex` converts back to a usable `.nds` the same way).

## Root cause (2026-07-30): the handler is installed 8 bytes low

The instrumented run reproduced the fault byte-identically —
`1588231865ns: unhandled opcode 1C0E1C05 thumb=0 pc=037FE28C lr=00002E10
cpsr=8000001F` — and the write watch caught the installation. With `wramcnt=11`
the ARM7 owns all 32 KB of shared WRAM, so this is shared WRAM `0x628C`.

Every watched word is written by exactly two halfword stores, from ARM7 BIOS PCs
`0x2A8A` and `0x2AF4`, all at ~1.070 s:

| word | stores seen | content | |
|---|---|---|---|
| `0x6280` | `0000` then `E1A0` | `E1A00000` | ARM `nop` |
| **`0x6284`** | `F004` then `E25E` | **`E25EF004`** | **ARM `subs pc, lr, #4`** |
| `0x6288` | `B5F0` then `B081` | `B081B5F0` | Thumb `push {r4-r7,lr}` |
| **`0x628C`** | `1C05` then `1C0E` | **`1C0E1C05`** | **what the CPU faulted on** |
| `0x6290` | `1C14` then `F7FF` | `F7FF1C14` | Thumb |
| `0x6294` | `FD25` then `1C07` | `1C07FD25` | Thumb |
| `0x6298` | `2001` then `4004` | `40042001` | Thumb |

`0x628C` reconstructing to `1C0E1C05` matches the CPU's own faulting fetch, which
is what validates reading the words back out of the store pairs.

**`E25EF004` is present, verbatim, at `0x6284` — 8 bytes below where the oracle has
it.** The ARM exception-return veneer (`nop`; `subs pc, lr, #4`) occupies
`0x6280..0x6287` here and `0x6288..0x628F` in the oracle, with Thumb code following
it in both. The BIOS then branches to `0x628C`, lands in Thumb code, decodes it as
ARM, and bits 27-25 = `110` is coprocessor load/store, which ARM7TDMI does not
implement — so the decoder is right to reject it, exactly as wrong diagnosis #1
already said.

So the failure chain is complete: **displacement, not corruption.** Nothing is
wrong with the bytes, the SPI read, the WRAM decode, the decompression, or the CPU
data path.

### What this retires

- **"The bytes simply differ."** They do not. They are correct and misplaced.
- **The instruction-2,258,084 IRQ divergence.** The census over the whole boot is
  `b0=5 b4=30 b6=8 b19=12` — VBlank, Timer1, Timer3, card — every one inside the
  oracle's set {0, 3, 4, 6, 19}, and no source fires here that does not fire there.
  It really was relative delivery timing. Re-dismissed, with a measurement this
  time.
- **The decompression hypothesis** from this ticket's earlier progress note,
  including its uncomfortable implication that our CPU computes wrong values. It
  does not.

### Next step, now cheap

8 bytes is exactly the ARM PC pipeline bias, and both writer PCs are
non-word-aligned (`0x2A8A`, `0x2AF4` are ≡2 mod 4), so that copy loop is **Thumb**
— where the bias is +4, not +8. That is a hypothesis, not a finding.

What matters is that the corruption is now localised in time and space, so the next
run does not need a 30M-instruction trace: trace a window around 1.070 s and look
at how the destination pointer reaching `0x2A8A`/`0x2AF4` is computed.

Instrument gap worth closing first: the shared-WRAM watch logs `data` but not the
byte enables, so word contents had to be reconstructed from store pairs rather than
read. Add `s7_be`/`s9_be` to those reports.

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

## Retraction and the real mechanism (2026-08-05)

### The memories are identical — measured, not argued

`sim/melonds_tracer` grew `ARM7WRAMDUMP=<file>`, which writes the ARM7's view of
`0x037F8000..0x0380FFFF` through `ARM7Read32` (the CPU's own decode, so WRAMCNT is
applied exactly as `nds_membus7` applies it). Against this core's watched words:

| address | oracle | this core |
|---|---|---|
| `037FE280` | `E1A00000` | `E1A00000` |
| `037FE284` | `E25EF004` | `E25EF004` |
| `037FE288` | `B081B5F0` | `B081B5F0` |
| `037FE28C` | `1C0E1C05` | `1C0E1C05` |
| `037FE290` | `F7FF1C14` | `F7FF1C14` |
| `037FE294` | `1C07FD25` | `1C07FD25` |
| `037FE298` | `40042001` | `40042001` |

All seven match. `E25EF004` appears **once** in the oracle's whole 96 KB, at
`0x037FE284`. **Nothing is displaced, nothing is corrupt, and the decompressed
firmware image is right.** Everything this ticket said about where the handler was
installed, which PCs wrote it, and the LZ77 output pointer is retired with it.

### What the address actually is

`0x037FE270..0x037FE284` is the DS firmware's ARM7 **task-switch context restore**:

```
037FE270  E16FF001  msr  spsr_fsxc, r1     @ saved CPSR of the task to resume
037FE274  E590D040  ldr  sp, [r0, #0x40]   @ handler-mode sp
037FE278  E590E03C  ldr  lr, [r0, #0x3C]   @ handler-mode lr = resume address
037FE27C  E8D07FFF  ldm  r0, {r0-lr}^      @ restore the USER/SYSTEM bank
037FE280  E1A00000  nop                    @ delay slot required after ldm ^
037FE284  E25EF004  subs pc, lr, #4        @ return: pc = lr-4, CPSR = SPSR
```

and `0x037FE288` is a **Thumb** function (`push {r4-r7,lr}; sub sp,#4`), which the
oracle enters with odd `r14` values (`03802d69`, `037ff9f3`, `0380227f`) and runs
straight through `0x037FE28C`. Verified with `ARM7REGS_AT=037FE290`.

So the two cores do different things at the same correct bytes: the oracle executes
`0x037FE284` and returns into Thumb; this core executes `0x037FE28C` **as ARM**.
`1C0E1C05` is condition NE with bits 27-25 = `110`, a coprocessor load/store
ARM7TDMI does not implement, so the decoder is right to reject it — wrong diagnosis
#1 said this from the start and was correct.

### The reported state, decoded

- `lr=0x00002E10` is **not** an exception handler address. The ARM7 BIOS **SWI
  dispatcher** does `add lr, pc, #0` at `0x2E08`, giving exactly `0x2E10`, then
  `bx ip` at `0x2E0C`. The IRQ handler is a different routine (`0x2DC4`) whose
  equivalent value is `0x2DD4` and which stays in IRQ mode — so `lr=0x2E10` plus
  `cpsr` mode `0x1F` means **inside a SWI**, not inside an IRQ.
- `cpsr=0x8000001F` is System/ARM. The dispatcher's `msr` at `0x2E00` builds
  `SPSR & 0x80 | 0x1F`, which clears N/Z/C/V, so N=1 was set by instructions that
  ran after it — consistent with being deep inside a handler.
- `pc` in the assertion is `regs(15)`, and the opcode printed is the word **at**
  that address, so the pipeline had just been refilled: the core had **branched**
  to `0x037FE28C`.
- The oracle's restored CPSR here is `0x0000003F` (System **+ T**), against
  `0x8000001F` (System, no T) in this core.

That made "the exception return lost the T bit" the obvious suspect: same address,
right instruction, wrong instruction set.

### That suspect is now disproved, by a test that runs in one second

`sim/tests/arm7_ctxrestore/` is the sequence above, verbatim, as an ARM7 image for
`tb_arm7_island`, with a context block whose `+0x38` (r14_user) and `+0x3C` (resume
address) differ so a wrong `ldm ^` bank cannot pass by luck, and whose resume target
opens with the raw halfwords `1C05`/`1C0E` — so a lost T bit reports
`unhandled opcode 1C0E1C05 thumb=0`, the firmware symptom byte for byte.

```bash
HEXFILE=sim/tests/arm7_ctxrestore.hex TIMEOUT_MS=45 WORK=sim/nvc_work_ctx \
  sim/run_arm7_island.sh
```

**Result: `tb_arm7_island: PASS bitmask=0000000F`.** Four sub-tests:

0. `msr spsr_fsxc` → `mrs spsr` round-trips the T bit.
1. **Save side, `swi` from Thumb.** `mrs r1, spsr` in the handler shows T set and
   the caller's mode preserved, and `movs pc, lr` returns into Thumb. So exception
   *entry* records T correctly - which matters because sub-test 3 writes SPSR by
   hand and so cannot see an entry bug.
2. **Save side, IRQ from Thumb** - how a preemptive scheduler actually gets in,
   and a different decode path in `gba_cpu` (`decode_functions_detail = IRQ` vs
   `software_interrupt_detail`, with its own lr arithmetic). Three timer-0 IRQs
   are taken from a Thumb loop; each handler checks SPSR.T and returns with
   `subs pc, lr, #4`, and the Thumb loop keeps counting, so all three returned in
   Thumb state.
3. The full firmware restore resumes in Thumb at the right address.

(The IRQ sub-test needs its own `sp_irq`: the handler pushes, and with sp_irq left
at 0 the push lands at address 0 and the test hangs at bitmask 3. That is a bug in
the test, not the core, but it is an easy one to re-introduce.)

Reading `gba_cpu.vhd` agrees:
`execute_nextIsthumb` takes T from `execute_msr_setvalue(5)` = `SPSR(5)` for the
`decode_leaveirp` path (:2143), `msr` to SPSR commits all four fields to the current
mode's bank (:2627-2637), and `ldm ^` writes the `regs_0_*` user bank for r8-r14
(:2504-2515). **So `msr spsr` / `ldm ^` / `subs pc, lr, #4` is not the bug.**

`sim/run_arm7_island.sh` had to be fixed to make this runnable at all: it ignored
`HEXFILE` and always ran `arm7_island.hex`, so a new ARM7 test silently reported the
old test's result. Noted separately: `arm7_island.hex` itself currently ends
`FAIL magic=BADBAD00 bitmask=0000003F` — it clears six sub-tests and fails the IPC
FIFO receive. That is a pre-existing harness result, unrelated to this ticket, but
it means this tb has no clean all-pass baseline.

### The fault address is not the bug either: the ARM7 PC has RUN AWAY

A time-gated ARM7 trace of 1.550–1.588 s (1,246,281 instructions) settles it. The
run reproduces the fault byte-identically —
`1588231865ns: unhandled opcode 1C0E1C05 thumb=0 pc=037FE28C lr=00002E10
cpsr=8000001F` — and the trace shows what the ARM7 was doing on the way in:

```
04390AA8 00000000 8000001F
04390AAC 00000000 8000001F
04390AB0 00000000 8000001F      ... and so on, +4 every instruction
```

**Exactly 16384 retires in every 64 KB block, marching 0x0439xxxx up to
0x0483xxxx, with no branch anywhere in it.** The ARM7 is executing the I/O region as
code. It reads back `0x00000000`, which as ARM is `andeq r0, r0, r0` — a perfectly
legal instruction — so nothing stops it. A derailed ARM7 does not crash; it walks.

By the time the window opened at 1.550 s the ARM7 had **already been lost for tens
of milliseconds**. So the 1.588 s decode failure is only where the walking PC finally
hit a word that would not decode, over a million instructions downstream of the
actual bug, in code that has nothing to do with it.

The last ~1900 instructions of the trace are all correct behaviour on a corrupt
machine, and worth reading as a check on the rest of the core:

```
048432FC -> 00000020   op=EA000B69 cpsr=80000092   IRQ taken; pc 0x20 = vector 0x18
00000020 -> 00002DCC                              BIOS IRQ handler at 0x2DC4
00002DD8 -> 037FD7E4                              firmware's own IRQ handler
```

`0x037FD7DC` is **exactly** the oracle's `[0x0380FFFC]`, measured independently. So
IRQ delivery, the BIOS dispatch and the handler pointer are all right. The handler
runs its Thumb body, reaches the context restore at `0x037FE270`, and restores the
context it interrupted — which is the runaway's: `r1 = 0x8000001F` at
`0x037FE278`, i.e. the firmware is handed T-clear/System because that is genuinely
what the runaway CPSR was. `subs pc, lr, #4` returns into it and dies.

Every register value the original ticket reasoned from is therefore a *consequence*
of the runaway, not evidence about its cause.

### ROOT CAUSE (2026-08-05): `ldm ^` never restored r8-r12

`ARM7RUNAWAY=1` fired at **1.521 s** with `pc=0x04000140` (R15, so the instruction
is at **0x04000138**) and printed the 96 retires that led there. Subtracting the
+8 ARM bias, they read:

```
037FE25C  mrs r1, cpsr / bic r1,#0x1F / orr r1,#0xD3 / msr cpsr,r1   -> Supervisor
037FE26C  ldr  r1, [r0], #4          saved CPSR out of the context block
037FE270  msr  spsr_fsxc, r1
037FE274  ldr  sp, [r0, #0x40]
037FE278  ldr  lr, [r0, #0x3C]
037FE27C  ldm  r0, {r0-lr}^
037FE280  nop
037FE284  subs pc, lr, #4            -> CPSR = 0x0000001F (System, ARM)
00002E08  add  lr, pc, #0            <- BIOS SWI dispatcher
00002E0C  bx   ip                    <- branches to r12
04000138  runaway                    <- the RTC register, executed as code
```

The task being resumed had been preempted **inside the BIOS SWI dispatcher, one
instruction before `bx ip`**. So r12 had to survive the restore. It did not.

**The bug:** `ldm ^` / `stm ^` redirected **r8-r12** to `regs_0_8..regs_0_12`
whenever the mode was not User/System. On ARM7TDMI **r8-r12 are banked ONLY in
FIQ**; r13/r14 are banked in every privileged mode. And this register file is
**swap-based** - `regs()` is the live view, `regs_0_8..12` are backing store that
only means anything while in FIQ (the `execute_switchmode_new = CPUMODE_FIQ` swap
at gba_cpu.vhd:2716). So the redirect wrote storage nothing reads and the live
r8-r12 kept stale values.

Fixed at three sites per CPU - the `stm^` read side, the "write the live regs()"
gate, and the `ldm^` user-bank write side: `rtl/gba_cpu.vhd` (~1980, ~2357, ~2504)
and **`rtl/nds_cpu9.vhd` (~2588, ~3051, ~3277), which had the identical bug** and
runs the game code. The redirect now covers r13/r14 in any privileged non-System
mode, and r8-r12 only in FIQ.

### Why 1.588 s was such a bad place to look

Every earlier diagnosis anchored on the undecodable word at 1.588 s, which is
**~67 ms and 1.2 million instructions downstream of the cause**. The ARM7 does not
stop when it derails: I/O space reads back `0x00000000`, which is a legal ARM
`andeq r0,r0,r0`, so the PC just marches +4 - 16384 retires per 64 KB - until it
lands on a word that will not decode. Everything the original report reasoned from
(the address, `lr=0x2E10`, `cpsr=0x8000001F`, the bytes in WRAM) is a *consequence*
of the walk.

### Regression test, and the way it first lied

`sim/tests/arm7_ctxrestore/` - four sub-tests, ~30 s:

```bash
HEXFILE=sim/tests/arm7_ctxrestore.hex TIMEOUT_MS=60 sim/run_arm7_island.sh
# expect: tb_arm7_island: PASS  bitmask=0000000F
```

Sub-test 3 loads distinctive values for r7-r12 into the context block and reports a
bitmask of **which** registers came back wrong (`0x10000 | 1<<N`). Against the bug
it printed **`0x00011F00`** - r8,r9,r10,r11,r12 wrong, r7 right, which is the
banking rule restated as a measurement.

**An earlier version of this exact test PASSED**, and was used here to declare the
`msr spsr` / `ldm ^` / `subs pc,lr,#4` family clear. It checked the resume address
and the T bit and nothing else. Verifying that control flow resumes is not
verifying that the context resumed - and that mistaken all-clear sent the
investigation looking for a second cause that did not exist.

Note also that the existing ARM9 regression `sim/tests/ldm_bx_irq` produces a
**byte-identical trace before and after** the ARM9 fix: it exercises `ldm^` with
pc, never r8-r12 outside FIQ. So it is no evidence either way, and its passing
never protected this.

### Lead this opens

`nds-kirby-idle-thread-rootcause` records Kirby sitting in the NitroSDK idle
thread, never rescheduling, with the DISPCNT display-on write never happening. A
scheduler whose context restore loses r8-r12 is a very plausible cause of exactly
that. Re-test Kirby direct boot against this fix before treating it as separate.


Instruments now in place for the next attempt, none of which existed before:

- `TRACE7_T0`/`TRACE7_T1` (us) on `tb_top_frame`: a **time-gated** ARM7 trace,
  flushed per line and closed at T1 so it survives the fatal decode assertion. The
  frame gate cannot be used here — `dump_frame_index` does not advance until the
  display runs at 1.49 s, so a frame-gated trace of a 1.588 s fault is empty.
- Oracle side: `ARM7WRAMDUMP`, `ARM7REGS_AT=<hex R15>` (all of r0-r14 at one
  instruction), `ARM7CB=<hex>` (the BIOS callback trampolines `0x3300: bx r1` /
  `0x3304: bx r3`, filtered by target). All run in seconds.

Firmware facts established on the way, all measured rather than assumed:

- ARM9 boot block: firmware offset `0x200` → `0x02320000`. ARM7 boot block:
  firmware offset `0xCCB0` → `0x037FA800`. Both from the ARM7 BIOS at `0x2462`,
  which reads the firmware header copied to `0x027FF830` and computes
  `src = hdr * (4 << shift)`, `dest = TOP - hdr * (4 << shift)` with the 3-bit
  shifts packed in `hdr[0x14]` (`0x2CB2` → 2, 6, 2, 6, 2) and TOP `0x02800000`
  (ARM9) / `0x03810000` (ARM7, literal at `0x25B0`).
- The faulting word is therefore output offset `0x3A8C` of the ARM7 block.
- The blocks are **encrypted**, not merely compressed: no LZ77 header validates
  anywhere in the 256 KB image, and even `E1A00000` does not occur in it. So
  "search the firmware image for the bytes" cannot work in either direction, and
  the earlier note that they are "compressed" understates it.
- SWI jump table at `0x2E38`, 34 live entries; `swi 0x12` = `0x2A2B` =
  LZ77UnCompReadByCallback, whose destination is `r1` taken verbatim
  (`0x2A2E: adds r6, r1, #0`). The ARM7 destination granularity is 256 bytes,
  so no destination error can ever be 8 bytes — which is what first showed the
  displacement story could not be right.
- Oracle's ARM7 user IRQ handler pointer `[0x0380FFFC] = 0x037FD7DC`, and the
  oracle reaches `POWCNT1=0x820F` — the firmware menu is up in the oracle.

**Method note worth keeping.** `ARM7PROBE` reports R15. `docs/TRACE_DIFF.md` and the
ARM7 trace already carry the same +8/+4 bias, and it is already written down — and
it still cost this ticket a root cause, three "retired" hypotheses, and a 4.5 h run
budget, because an R15 value was compared against a raw address once and never
rechecked. Dump the memory and compare it directly before concluding anything about
what is *in* memory.

---

# SECOND TICKET — pipelined drawer wedges under VRAM backpressure (hardware white screen)

**Filed** 2026-07-30 · **Severity: blocks hardware** · Reported from silicon: the
sdk2k test ROM white-screens under **both** boot modes and **both** GPU pace
settings.

> **RESOLVED 2026-07-30 — the wedge was a livelock in `drawline` routing, not the
> `vrsrv` channel.** With hardware-shaped backpressure the renderer went from
> **0 line renders completed per frame to 95 of 192**, and the framebuffer from
> 99.6% one value to real content. Two independent bugs were found and fixed; the
> diagnosis below was right that it is "a wedge, not slowness" and
> latency-independent, and wrong about the mechanism. See **Resolution** at the
> end of this ticket. What remains is a genuine throughput shortfall — 3,010
> cycles per rendered line against a 2,130 budget — which is fix candidate 3's
> territory and is NOT a wedge.

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

**And it degrades to renders=0.** Frame 3 of the same run: `renders=0`,
`bg/render=558139`, `rvram_busy%=100` — busy for the entire 560,190-cycle frame with
**not a single line rendered**. That is the white screen exactly: the framebuffer is
never written after the reset clear, so the screen stays at its cleared value. The
symptom reported from silicon and the symptom in this reproduction are the same
thing.

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

---

## Resolution (2026-07-30)

### The wedge: `drawline` restarts the drawers even when the line was dropped

`nds_gpu2d` routed `drawline` **straight to every drawer, ungated**:

```vhdl
drawline_text(i) <= drawline when (bgtype(i) = 1) else '0';
```

The line FSM drops a `drawline` that lands mid-render — it only leaves `LIDLE` on
one — but the drawers saw all of them, and **every drawer restarts its whole line
on `drawline`**: `nds_drawer_text`'s `if (drawline = '1')` clears the tile queue,
the tag queue and the fetch walk. So an over-budget line was restarted from tile 0
every 2,130 cycles and could never reach the end. `any_bg_busy` never fell, `LDRAW`
never completed, `line_busy` never fell, and every following `drawline` was
therefore dropped too.

That is a **livelock**, and it explains every observation in this ticket that
"slowness" could not:

- **Latency-independent.** It starts the moment a line first needs more than its
  budget. `VRSRV_LAT` 4 vs 8 changes when, not whether.
- **410,000 cycles "on one line".** The restart loop runs until `drawline` stops,
  i.e. until vblank — 407,374 of a 560,190-cycle frame.
- **Degrades to `renders=0`.** Not "no lines rendered" but "`line_busy` never fell,
  so it never rose again" — see the metric note below.
- **Only under backpressure.** With an always-ready memory model no line ever
  exceeded budget, so a `drawline` never landed on a busy drawer. The failure was
  unreachable, not merely untested.

The evidence that settled it: with the stall probe stopped at 20,000 busy cycles on
line 0, the BG-A channel had been **served 1,701 times** while `text0` had advanced
15 tiles, and the ext-pal fill was idle. The renderer was not starved of service —
it was throwing service away and asking again.

Fix: gate the routing with the line FSM's own accept condition
(`drawline_acc <= drawline when linestate = LIDLE`), and `drawObj` with `obj_busy`
since OBJ pre-renders the next line while this one is still in `LDRAW`. A dropped
line then leaves that row at the previous frame's content, which is what a dropped
line already means everywhere else here, and progress continues.

### The second bug: the `rsrv` handshake depended on a stale `ready`

Independent of the livelock, found by inspection while reproducing it, and — state
this plainly — **not the hardware failure.** `nds_vram` **pulsed** `rsrv_req` on a
`rsrv_ready` it had sampled one cycle before the request existed. `ready` cannot
reflect a request that has not been presented yet, so with a one-deep channel the
core issued a second op while the first was still being accepted, the channel
dropped it, and the queue entry owed a word forever. Reproducible in `tb_top_frame`,
where `prserv` and `nds_vram` are both on `clk1x`, so it is not a clock-domain
effect at all.

On silicon that same pulse scheme happened **not** to drop: `vr_busy` rises, and so
`vrsrv_ready_c` falls, one clkMem cycle after acceptance — a third of a clk1x period
before the core samples again — so the core never issued into a busy channel. It was
correct by a timing coincidence between two domains. Worth fixing anyway (nothing
should depend on that), but it is not what silicon was doing.

Before the drawline gate, this fix alone moved `VRSRV_ONE=1` from `rvram_busy%=100,
renders=0` to `77`, `done=1` — visibly better, still a blank screen. Stopping there
and calling it fixed was the trap.

Fixed as candidate 2, but as a **valid/ready handshake** rather than "hold until
acceptance": the request is presented and held until an edge at which `ready` is
high, and that edge is the transfer. It is the same edge the channel samples
`req` on, so the two ends cannot disagree, and it needs no knowledge of the
channel's depth or latency.

`NDS.sv` **had** to change with it: its `vrsrv_req_c & ~vr_req_d` edge detect needs
the request to go low between requests, and a held one never does, so the first
would have been taken and every later one silently ignored — a wedge on hardware
only. It now accepts on `req & ready` at `clkMemIndex == 2`, the clkMem edge
coincident with the clk1x rising edge, so both ends agree on which edge the transfer
was. Accepting at any other phase would take a request the core goes on holding, and
serve it twice. **This half is verified by inspection and elaboration only — no
Quartus build and no silicon yet.**

**Candidate 1 was not implemented and should not be.** An `fwr_pend`-style latch
would have absorbed the over-issue instead of removing it, leaving a protocol whose
correctness depends on the exact ready round-trip staying one cycle — and it would
not have touched the livelock, which is what the white screen actually was.

### Correction to this ticket's own diagnosis

The "likely contributing race" — `vrsrv_ready_c` combinational in clkMem while
`nds_vram` samples in clk1x — is **not** how requests were being dropped. On
hardware `vr_busy` rises, and so `ready` falls, one clkMem cycle after acceptance,
which is a third of a clk1x period before the core's next sampling edge. The drop
was a single-clock-domain over-issue.

### Measured: `nds_2dk`, `DIRECT=1 GPUFAST=0 GPUCEDIV=1`, frames 2-4

| | `done` lines | `dropped` | `cyc/render` | `rvram_busy%` | fb distinct values |
|---|---|---|---|---|---|
| `VRSRV_ONE=0`, before | 189 | 3 | 1,134 | 32 | 958 |
| `VRSRV_ONE=1`, before | **0-1** | **191** | 409,583 | 77-100 | **47** (99.6% one value) |
| `VRSRV_ONE=1`, after | **95** | 97 | 3,010 | 50 | **508** |
| `VRSRV_ONE=0`, after | 189 | 3 | 1,129 | 32 | 959 |

The always-ready path is unchanged (1,129 vs 1,134 cycles/line: the 3 over-budget
lines per frame are now dropped instead of restarting their drawers, which is also
why total ops fall slightly). `tb_gpu2d`, `tb_gpu2d_frame`, `tb_gpu2d_timed` and
`tb_vram_ls` all still pass pixel-exact.

### The metric that hid this

`renders` counts `line_busy` **rising edges**, so a renderer that never goes idle
reports one render per frame no matter what it finished — indistinguishable from a
wedge, and it reported `0` when `line_busy` was still high at the frame boundary.
`p_vramops` now also prints `done=` (completions, falling edges) and `dropped=`
(drawlines that landed on a busy renderer). Those two are the honest numbers;
`cyc/render` divided by a rising-edge count is not.

### Test-gap fixes, so this class cannot hide again

- `tb_gpu2d_timed` gets `RSRV_ONE` and `STALL_CYC`. It ran against an always-ready
  memory too, and at `CE_DIV=1 RSRV_ONE=1` it reproduces the over-budget condition
  in ~40 s locally instead of 5 minutes of system sim.
- Both `prserv` models now **assert** that a request they could not take is still on
  the wire, unchanged, at the next edge. A requester that pulses and forgets fails
  at the point of the mistake instead of wedging 400,000 cycles later.
- `STALL_CYC` in `tb_top_frame` (and `tb_gpu2d_timed`) fails with a dump of the
  whole chain — drawer, gpu2d arbiter, `nds_vram` queue, `rsrv` channel, plus
  per-channel dispatch counts — which is what turned this from a guess into a
  measurement. `GPUFAST=0` only; the generate guard keeps it out of other runs.

### Throughput: fixed too, by using the whole 64-bit read

The wedge fix left 3,010 cycles per rendered line against a 2,130 budget — ~half the
lines dropped, a half-stale screen. That is now **2,034 cycles, under budget**, with
**168 of 192 lines** completing.

`sdram.sv`'s ch1 already returns **64 bits** per read (`BURST_LENGTH=4`,
`ACCESS_TYPE` sequential) and `NDS.sv` was using `[31:0]` and discarding the rest.
The channel is now addressed by 8-byte **line** (`rsrv_addr : unsigned(16 downto 3)`,
`rsrv_dout : 64`), and `nds_vram` keeps **one cached line per renderer channel**,
indexed by channel — no associative search, one comparator, and no channel can
evict another's.

Line alignment is not cosmetic: a sequential SDRAM burst **wraps inside its aligned
block**, so an unaligned request returns the same eight bytes rotated and
`dout[63:32]` would not be the neighbouring word at all.

The size was measured before anything was built — `LINEPROBE` in `tb_top_frame`
models several cache sizes and counts what each would have saved:

| lines (shared, fully associative) | 1 | 2 | 4 | 8 | 16 |
|---|---|---|---|---|---|
| A..D reads avoided | **1%** | 44% | 67% | 76% | 87% |

A single shared line is worth **1%**: eight channels interleave and each evicts the
others, so the obvious "cache the last line read" buys nothing and would have looked
like a dead idea. That measurement is why the cache is per-channel.

| `nds_2dk`, GPUCEDIV=1, steady state | `done` lines | dropped | cyc/render |
|---|---|---|---|
| before either fix | 0–1 | 191 | 409,583 |
| drawline gate only | 95 | 97 | 3,010 |
| **+ 64-bit line + per-channel cache** | **168** | 24 | **2,034** |

All four benches still pass pixel-exact, and the always-ready path got faster too
(mode-0 947 → 838 cycles/line), so this is not a backpressure-only win.

**Not verified on silicon.** All of the above is nvc against a *model* of ch1. The
64-bit path assumes `sd_ch1_dout[63:0]` is the aligned line in halfword order, which
is read off `sdram.sv` and has never been observed on hardware. A first hardware run
can only say "something/nothing on screen" — there is no renderer-side counter
readable from the HPS yet, and adding one to the debug mailbox is the obvious next
step if the first core comes up blank.
