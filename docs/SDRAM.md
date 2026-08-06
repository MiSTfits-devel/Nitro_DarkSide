# rtl/sdram.sv — what was wrong with it, and what changed

Worked 2026-08-05. Two separate things came out of this: a **functional bug that
was corrupting every renderer VRAM read on hardware**, and the timing work needed
for clkMem 4x (134 MHz).

The file is vendored — `git log -- rtl/sdram.sv` shows a single commit, the M0
scaffold, so everything here predates this project and arrived with the
GBA_MiSTfits tree.

---

## 1. It could not be simulated, and had no bench

Before this work `rtl/sdram.sv` had **zero** simulation coverage:

- `sim/run_fb_pager_tb.sh` drives `rtl/ddram.sv` — the DDR3 controller. Same
  `ch1_*` / `ch2_*` port names, different module. Easy to mistake for coverage.
- The nvc frame sims substitute a VHDL memory model, so this file never runs.

It also *could not* be simulated, for two reasons that Quartus tolerates and no
standard-conforming simulator does:

- `inout reg [15:0] SDRAM_DQ` — `inout` ports must be nets. Now an explicit
  registered tristate (`dq_out`/`dq_oe` + `assign`), which is what Quartus was
  inferring anyway.
- `assign SDRAM_nCS = chip;` and friends sat *above* the declarations of `chip`
  and `command`. Declarations moved up.

New: `sim/run_sdram_ch.sh` (iverilog, ~2 s), `sim/tb_sdram_ch.sv`,
`sim/sdram_model.sv`, `sim/sdram_pat.vh`, `sim/altddio_out_stub.sv`.

Two things about the model worth not undoing:

- **It is clocked on `SDRAM_CLK`, not on `clk`.** MiSTer generates SDRAM_CLK 180°
  out of phase via `altddio_out`, and that half-period shift is exactly what
  turns a true CL=2 part into "the word is in `dq_reg` three `clk`s after READ".
  A model clocked on `clk` would bake the controller's own assumption in and
  prove nothing.
- **Unwritten memory reads back as a function of the full `{bank,row,col}`**
  rather than as zeros (iverilog 13 has no associative arrays and a 16M-entry
  array is not allocatable). That is *stricter* than a zero-filled array: a
  mis-mapped bank, row, column or burst-wrap bit cannot return plausible data.

---

## 2. The functional bug: `ch1_ready` fired one clock early

```verilog
if(data_ready_delay1[3]) ch1_dout[15:00] <= dq_reg;   // lands edge 4
if(data_ready_delay1[2]) ch1_dout[31:16] <= dq_reg;   //       edge 5
if(data_ready_delay1[1]) ch1_dout[47:32] <= dq_reg;   //       edge 6
if(data_ready_delay1[0]) ch1_dout[63:48] <= dq_reg;   //       edge 7
if(data_ready_delay1[1]) ch1_ready <= 1;              // high during cycle 7
```

Tap `[1]` is correct for a **48-bit** `ch1_dout`. Widening it to 64 bits added
the `[0]` tap without moving ready, so a consumer sampling on the ready cycle
gets `[63:48]` from the *previous* burst.

The consumer is `NDS.sv:984` — `if (vr_busy & sd_ch1_ready) vrsrv_dout_r <=
sd_ch1_dout;` — the renderer's VRAM service path. **Every 8-byte VRAM line the
renderer fetched had 2 of its 8 bytes from the previous line.** ch2 and ch3 were
already correct, which is what pins the cause on the widening.

Bench output before the fix — each read's top word is the previous read's:

```
addr 0000004   got xxxx28f72bf72af7   want 29f728f72bf72af7
addr 0123454   got 29f778c37bc37ac3   want 79c378c37bc37ac3
addr 1fffffc   got 79c3d008d308d208   want d108d008d308d208
addr 0abcde0   got d108cc3acf3ace3a   want cd3acc3acf3ace3a
```

### The trap

A bench written the obvious way — `@(posedge ch1_ready); check(ch1_dout);` —
samples a delta *after* the edge and gets one extra cycle of settling that the
hardware consumer never gets. **It passes.** `tb_sdram_ch.sv` deliberately takes
both captures, synchronous and late, and reports them separately.

### Cost of the fix

Moving ready to tap `[0]` adds **one clkMem cycle to every ch1 read** (9.95 ns at
3x). For a synchronous consumer that cycle is unavoidable: the last burst word
does not land until edge 7, so the earliest correct ready is cycle 8.

This is not free for the renderer, and it cannot be measured in the existing
sims, because none of them instantiate this file. Rough sizing from the numbers
in `nds_2dk`: ~421 ch1 reads per line, `rvram_busy` 54%, so on the order of a few
percent of the 2130-cycle line budget. Kirby (836 cyc/render) has ample room. If
the heavy case does turn out to be tight, the zero-latency alternative is a
combinational bypass on `[63:48]` at the ready cycle — deliberately *not* taken
here, because that path is already the worst in the design (see below) and a mux
on it is the wrong direction.

---

## 3. Timing: three families, from the 4x fit

From `build/artifacts-nosnd-4x/NDS.paths.rpt` (clkMem 134.056 MHz, period
7.456 ns), all inside `sdram.sv`:

| worst | family | cause |
|---|---|---|
| −0.846 | `dq_reg[*] → ch{1,2}_dout[*]` | **0 logic levels.** 5.810 ns of pure interconnect (89% of the data delay) from `DDIOINCELL_X82_Y0` to `FF_X24_Y20`, plus −1.584 ns clock skew because the I/O cell's clock arrives 3.223 ns late against the fabric flop's 1.883 ns |
| −0.584 | `state → SDRAM_DQ[*]~reg0` | a `state`-selected mux between the halves of `saved_data` feeding the I/O register |
| −0.533 | `refresh_count[*] → command[*]` | a 14-bit magnitude compare sharing a cone with the three-channel grant arbitration |

The first is the important one, and it reframes the problem: **there is nothing
to optimise logically.** Zero logic levels means the only lever is distance.

### What changed

- **`DQ_PIPE`** (parameter, 0 by default) inserts a register stage between the
  pin capture and the wide dout banks, so the fitter can place it halfway and
  split the hop. Three copies, one per channel — fanout is not the problem
  (`dq_reg` drives 6 loads), distance is, and three copies let each sit near its
  own channel's consumers instead of at their compromise centroid. `RDLY` moves
  the whole delay line up one bit so the taps stay put.
- **`dq_pre`** carries the word due next, so the I/O register is fed by one plain
  flop with no select in the way.
- **`refresh_due`** registers the comparison. Exact, not approximate:
  `(count >= N)` sampled at `count==N` is visible in the cycle where
  `count==N+1`, which is precisely when `(count > N)` first evaluated true.

---

## 4. Two things STA cannot see

There are **no SDRAM constraints in `NDS.sdc`** — checked. STA analyses the
fabric; it has nothing to say about whether the part is being given the
nanoseconds it needs. A build can report every slack positive and still read
garbage.

| | at 100.5 MHz | at 134.1 MHz |
|---|---|---|
| `CAS_LATENCY = 2` | fine — file's own comment says "2 for < 100MHz, 3 for >100MHz" | **needs 3** |
| ACTIVE→READ, fixed at 2 clocks | 19.9 ns | **14.9 ns** — under tRCD |

Both are now parameters (`CAS_LATENCY`, `TRCD_WAIT`), and NDS.sv derives all
three knobs from `CLKMEM_RATIO`, so **3x builds are unchanged** and 4x gets CL3
plus a second wait state.

### Not checked by the model

tRP / tRC / tWR — the fixed `STATE_IDLE_5..IDLE_1` slot after a burst. The
`STATE_RW2` comment says that slot was already hand-tuned for a 63 ns tRC "on
AS4C32M16SB-7", i.e. **at 100 MHz**; at 134 MHz the same cycle count is 25% less
wall-clock time. This is the next thing to suspect if 4x misbehaves on hardware.
Do not assume it is fine because the bench passes.

---

## 5. Running it

```
sim/run_sdram_ch.sh                                      # 3x, as deployed
DQ_PIPE=1 CLK_PS=7460 sim/run_sdram_ch.sh                # 4x, STA fixes only
DQ_PIPE=1 CAS_LAT=3 TRCD_WAIT=2 TRCD_CK=3 CLK_PS=7460 sim/run_sdram_ch.sh
```

All four configurations pass 12 checks.

---

## 6. The standing question: is 4x worth it?

Worth restating with what this work established. SDRAM latency is fixed in
**nanoseconds**. Clocking the controller faster mostly buys more cycles of the
same wall-clock wait, and CL3 plus the extra tRCD wait hand back much of what the
faster clock gained. So a consumer limited by *latency* gains far less from 4x
than a throughput-limited one — and the renderer's VRAM path runs **one op in
flight** (`VRSRV_ONE=1`), which is the latency-limited case.

The lever for a latency-bound consumer is **more outstanding ops**, not a faster
clock. That is where the effort probably belongs.
