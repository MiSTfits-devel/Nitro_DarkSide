# Whole-core DS timers (`Nds.WholeCore.Timers`)

Status: standalone, verified, **not integrated**. Nothing in the console,
the IRQ controller (IE/IF), the ARM9/ARM7 buses or the scheduler ABI uses it.
The shipping core still uses `rtl/gba_timer.vhd`. One instance is one CPU's
four timers; a console would need two (ARM9 and ARM7).

| File | Role |
| --- | --- |
| `clash/src/Nds/WholeCore/Timers.hs` | DUT; Clash top `nds_ds_timers` |
| `clash/test/TimersOracle.hs` | independent melonDS oracle (no Clash, no DUT code) |
| `clash/test/TimersCheck.hs` | directed literals, random differential, vectors, VHDL witness compare |
| `clash/tests/tb_ds_timers.v` | replays oracle vectors on the generated Verilog |
| `clash/tests/tb_gba_timer_witness.vhd` | drives shipping `rtl/gba_timer.vhd` under nvc |
| `clash/tests/timers_gate.sh` | runs all of the above plus DUT mutants |

## Ports

| Port | Width | Meaning |
| --- | --- | --- |
| `CLK`, `RST`, `EN` | 1 | Clash `System` domain (`RST` asynchronous, active high; clears everything) |
| `TICK` | 1 | one timer clock: 33.514 MHz, melonDS `ARM9Timestamp >> ARM9ClockShift` (ARM9) or `ARM7Timestamp` (ARM7) |
| `REQ_VALID`, `REQ_WRITE` | 1 | single-cycle zero-wait access; no ready, no reply |
| `REQ_WORD` | 2 | `(address - 0x04000100) >> 2`: timer number |
| `REQ_LANES` | 4 | byte enables of the 32-bit word |
| `REQ_DATA` | 32 | write data, lane-aligned (`TMxCNT_L` in 15:0, `TMxCNT_H` in 31:16) |
| `RDATA` | 32 | `count \| (CNT_H & 0x00C7) << 16` of timer `REQ_WORD`, combinational |
| `IRQ` | 4 | registered one-cycle overflow pulses, bit n = timer n, only with CNT bit 6 |

Reads have no side effects; a byte or halfword master selects lanes from `RDATA`.
Address decode and the IF/IE latch belong to the integrating bus.

## Register semantics and sources

melonDS references are `third_party/melonDS/src/NDS.cpp`.

* **Counter.** Each timer holds melonDS's 26-bit `Counter`: the visible count
  over a 10-bit fraction. A timer clock adds `1 << CycleShift`: 1024, 16, 4, 1
  for F/1, F/64, F/256, F/1024 (`TimerPrescaler = {0, 6, 8, 10}`, `RunTimer`).
* **Overflow.** On a prescaled overflow the residue below 2^26, which is only
  fraction, is kept and `Reload << 10` added (`RunTimer`, `HandleTimerOverflow`).
  A cascaded overflow sets `Counter = Reload << 10` and drops the fraction.
* **Cascade.** Timer n+1 takes a carry when timer n overflows on that clock,
  only if its CNT has start and count-up set (`(Cnt & 0x84) == 0x84`). A
  cascaded overflow carries on to the next timer within the same clock;
  timer 3 carries nowhere.
* **Start edge.** A CNT write that turns bit 7 from 0 to 1 loads
  `Counter = Reload << 10` (`TimerStart`). 1 to 1 does not reload; it may
  change the prescaler and keeps the fraction. 1 to 0 freezes the count.
* **Reload.** Writing `TMxCNT_L` changes only the next reload, never the
  count. In a full 32-bit write the reload lands first, so a start edge loads
  the new value (`ARM9IOWrite32`: `Reload = val & 0xFFFF; TimerStart(val >> 16)`).
* **Byte lanes.** Lanes 0 and 1 merge into Reload. Lane 2 writes CNT bits 7:0
  (stored & 0xC7). Lane 3 holds only unused bits and has no effect. melonDS has
  no 8-bit timer writes; the lane behaviour follows `eProcReg_gba` in
  `rtl/proc_bus_gba.vhd`. The oracle instead merges into the raw Cnt and calls
  `TimerStart` for either CNT lane, which shows lane 3 alone is a no-op.

Two departures from melonDS, both from the shipping `rtl/gba_timer_module.vhd`.
In the oracle they are the `Hardware` mode; `Melon` is literal melonDS:

1. **TM0CNT_H bit 2 is ignored.** It is stored and read back, but timer 0 runs
   on its prescaler. melonDS removes timer 0 from `TimerCheckMask` when bit 2
   is set. Nothing cascades into timer 0, so melonDS freezes it.
   Covered by directed `tm0-countup-ignored` and `tm0-countup-melon-frozen`.
2. **CNT reads are masked to 0x00C7.** melonDS returns the raw written Cnt.
   Covered by directed `lanes-and-masks`.

## Request vs timer-edge ordering

Let S_t be the state during clock t. Then:

1. A read in clock t returns S_t, which already counts the timer clocks of
   cycles 0..t-1.
2. On the edge that ends clock t, a write in clock t is applied first.
3. Then, if `TICK` was high in clock t, that clock's tick is applied to the
   written state: prescale steps, overflows, then cascade carries from timer 0
   up to timer 3.
4. An overflow on that tick sets the `IRQ` bit in clock t+1. That is the first
   clock in which a read returns the reloaded count.

This matches melonDS. Every timer I/O access first calls `RunTimers` up to
the access timestamp, then applies the access. Clock t's tick is the first
tick after an access made at timestamp t. A write with `TICK` low still
applies. The gate checks each case with hand-worked literals, against both the
DUT and the oracle:

| Case | Directed test | Result |
| --- | --- | --- |
| Write in clock 0 starts F/1 timer with reload `FFFD` | `start-then-count` | reads `FFFE`, `FFFF`, `FFFD` in clocks 1–3; IRQ in clocks 3, 6 |
| Stop written in the clock whose tick would overflow | `stop-wins-over-overflow` | stays `FFFF`, no IRQ |
| Reload written in the clock whose tick overflows | `reload-write-on-overflow` | reloads the **new** value |
| Cascade timer started in its source's overflow clock | `cascade-start-on-carry` | takes that carry: reads reload+1 |
| F/64 phase | `f64-phase-from-start` | first increment 64 ticks after the start write (no free-running divider) |
| Prescaler change while running | `prescaler-switch-keeps-fraction` | 32 F/64 ticks (fraction 512), then 512 F/1024 ticks to increment |
| `TICK` low | `tick-gating` | write applies, no count |
| 1→1 / 1→0 / 0→1 | `restart` | no reload / freeze / reload |
| Carry ripple | `four-timer-ripple` | all four IRQs in the same clock |

## Divergences from the shipping `rtl/gba_timer.vhd`

`tb_gba_timer_witness.vhd` measured the start latency, IRQ timing and
reload-on-overflow cases under nvc. The prescaler phase and startwait items
come from reading the source; scenario B only confirms that periods agree.
The model follows melonDS and copies none of them:

* **Start latency.** At F/1 the VHDL loads Reload two clocks after the start
  write (`startwait`), not one. Its counts trail the model by 2 clocks; its
  `debugoutN` port adds 2 more.
* **IRQ timing.** `IRP_Timer` is combinational during the overflow clock,
  one clock before the model's registered `IRQ`.
* **Prescaler phase.** F/64, F/256 and F/1024 tick on a shared free-running
  10-bit divider. melonDS and the model measure the phase from the start write
  and keep the fraction when the prescaler changes.
* **Reload written on the overflow clock.** The VHDL reloads the **old** value,
  because `eProcReg_gba` updates on the same edge. The model reloads the new one.
* **startwait IRQ quirk** (source only, `gba_timer_module.vhd`). Starting an
  F/1 timer whose old count is `FFFF` raises IRP during `startwait`. The model
  does not.

The witness checks three things:

* Scenario A is a F/1 source with three cascaded timers over 20,000 clocks.
  Every count matches the model shifted by 4 clocks, and every IRP matches
  shifted by 1, from clock 10 on.
* Scenario B runs F/64, F/256, F/1024 and F/1 timers over 100,000 clocks. Every
  gap between overflows equals the period in both, and overflow counts agree
  within 1.
* Scenario C asserts the old-reload versus new-reload divergence above.

## Verification

Run from the repository root (needs `stack`, `iverilog`, `vvp`, `nvc`):

```sh
clash/tests/timers_gate.sh            # MUTANTS=0 skips stage 4
```

1. `TimersCheck` runs 12 directed literal cases plus 304 seeded random
   scripts (1,140,000 clocks; 53,425 oracle IRQs). Every read and every IRQ
   cycle is compared with the oracle. The random scripts use random lanes,
   ~85% `TICK` duty, reloads biased to overflow, and mode switches while
   running.
2. Fresh Clash 1.8.4 Verilog of `nds_ds_timers` is replayed under iverilog on
   180,795 oracle vector cycles (89,976 reads, 8,173 IRQ cycles), with resets
   between scripts.
3. The shipping VHDL witness runs (above).
4. Ten DUT mutants must each fail stage 1: IRQ enable sampled before the
   write, cascade fraction kept, prescaled fraction dropped, timer 0
   cascading, read mask 0xFF, start loading the old reload, 1→1 reloading,
   F/64 step 32, a stopped timer passing a carry, and tick before write.

Not covered: savestate, `console_sleep` gating, the IF/IE path, ARM7-side
integration, and Quartus timing/area.
