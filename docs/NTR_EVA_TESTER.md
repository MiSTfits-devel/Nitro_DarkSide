# The NITRO Tester ("Nitro EVA") self-checker cart

An official Nintendo hardware-validation cartridge. It is the only test vector
we have that **runs itself**: no menu, no button input, no scripted stimulus.
It walks a 58-test suite, prints the current test id and `PROGRESS[nnn/058]` on
the top screen, and **halts on the first failure** with `RESULT:FAIL`.

That last property is what makes it valuable here: the number the screen stops
at is a single-integer regression signal covering the timer, DMA, IRQ and 2D
text-render paths at once. "Reaches `[07-01]`" is a pass; "stops at `[04-05]`"
names the broken subsystem without any diffing infrastructure.

The dump used is a GodMode9 cart dump, gamecode `AAAA`, blank title, 8 MB,
`unitcode=00` (NTR/DS only, despite the "TWL" in the folder name it shipped in).

    title      : ' '  gamecode AAAA  unit 00
    arm9       : off=00004000 entry=02000800 load=02000000 size=2538808
    arm7       : off=0026FE00 entry=02380000 load=02380000 size=39388
    used / file: 2696704 / 8388608 bytes

The used area is 2.57 MB, so the default 4 MB (`CARD_WORDS=1048576`) card image
covers the whole cart.

## Converting it

The dump is copyrighted; it is gitignored and never committed. Convert your own:

    sim/tests/make_test_cart.sh ~/dumps/__AAAA01_00.nds ntr_eva
    # -> sim/tests/ntr_eva.hex   (1048576 words)

The script refuses to truncate below the header's used-ROM size, because a card
model returning zeroes inside the used area fails in ways that read like core
bugs rather than a short image.

## Golden frames from melonDS

melonDS boots it in ~2.5 s for 60 frames, so it is a practical oracle:

    sim/melonds_tracer/build/melonds_fbdump --direct \
        ~/dumps/__AAAA01_00.nds gold_a.txt 150 gold_b.txt

The entire run is over by **frame 123** — 14 distinct screens, then a frozen
`RESULT:FAIL` screen forever after. Engine B stays blank throughout; this cart
only ever draws on engine A.

Observed sequence (frame: what is on screen):

| frame | screen |
|-------|--------|
| 0     | white (boot) |
| 34    | white, `MASTER_BRIGHT` fade |
| 71    | `[03-01] TIMER TIMER0` — `PROGRESS[006/058]` |
| 84    | `[03-04] TIMER PRESCALER` — `009/058` |
| 87    | `[04-02] DMA PRIORITY` — `011/058` |
| 90    | `[04-03] DMA ADDRESS CTRL` — `012/058` |
| 97    | `[04-04] DMA VBLANK START` — `013/058` |
| 108   | `[04-05] DMA HBLANK START` — `014/058` |
| 116   | `[04-06] DMA DISP START` — `015/058` |
| 118   | black |
| 120   | `#FAR Clipping` — two rendered 3D cubes, `Auto run` |
| 123   | `[07-01] 3D ATTR FARCLIP` — `016/058`, `RESULT:FAIL` `TOTAL:FAIL` |

Screens change only when the test id changes, so tests that complete inside one
frame are never sampled — the ids are a subsequence of all 58, not all of them.

melonDS itself fails at `[07-01] 3D ATTR FARCLIP`. This core has no 3D engine at
all, so `[07-01]` is the natural ceiling for it too. **Groups 01–06 are the
reachable, meaningful range**, and they are exactly the right subsystems: timers,
DMA priority/address-control/vblank-start/hblank-start/**display-start**, and the
BG text rendering that draws the report screen itself.

## Blocker: direct boot does not preset the stack pointer

The cart does **not** boot through the HLE section-copy path that
`rtl/nds_loader.vhd` implements. Measured, same tool, same image:

    --direct (SetupDirectBoot):  DISPCNT=00010100  POWCNT=0000820F  VRAMCNT=818380808380808080
    HLE section copy:            DISPCNT=00000000  POWCNT=00000001  VRAMCNT=808080808080808080

The HLE run never enables the display and never maps a VRAM bank. Across 150
dumped frames the engine-A framebuffer holds exactly one colour value,
`ffffffff` — `DISPCNT=0` is display-off, and display-off scans out white. It is
dead from the start, and it is dead in precisely the shape we keep chasing on
hardware: a permanent white screen.

(The tracer's `vb=` field is a raw read of main RAM at `0x02FFFF08`, `0` here
against a non-zero value under `--direct`. Corroborating, but it is a labelled
memory word, not an instrumented vblank count — the display registers above are
the load-bearing evidence.)

Both paths execute the *same* instruction stream — the divergence is register
state at entry. From `TRACE9`/`TRACE7` (columns are `PC opcode CPSR r0..r14`):

| | ARM9 r13 | ARM9 r14 | ARM7 r13 | ARM7 r14 |
|-|----------|----------|----------|----------|
| `--direct` | `03002F7C` | `02000800` | `0380FD80` | `02380000` |
| HLE copy   | `00000000` | `00000000` | — | — |

`r12=04000000` is *not* a preset on either path; the cart's own first
instruction (`e3a0c301` = `MOV r12,#0x04000000`) sets it.

`rtl/nds_loader.vhd:20-33` documents why: the direct-boot environment was
specced against **calico**, whose bootstubs "do their own CP15 and stack setup
so only the memory image matters", and the testbench "presets their boot PCs
from `arm9_entry`/`arm7_entry`" — PCs only. A NitroSDK-built commercial cart
like this one never sets its own SP; it inherits one from the boot ROM. With
`SP=0` the first function prologue pushes into ITCM at address 0.

CP15 is **not** part of this. `rtl/nds_cpu9.vhd:142-159` already initialises the
control register to `x"00012078"`, DTCM to `x"0300000A"`, ITCM to `x"00000020"`
and every PU register to the same values `SetupDirectBoot` writes — and the cart
reconfigures CP15 itself at `0x02000a80` regardless, both paths converging on a
write of `0x00002078`. The gap was only ever the register preset.

## Fix: preset the banked stacks, translated between two banking models

`rtl/nds_top.vhd`'s boot FSM wrote a single savestate address (the PC) and
stopped. It now walks a 7-entry table per CPU — r12, r14, the active r13, and
the user/system, IRQ and supervisor banked r13s.

The translation is the part worth reading before touching this code. melonDS
banks by `std::swap`; this core saves and restores per mode
(`gba_cpu.vhd:2724-2800`). So the fields do **not** copy across by name:

| melonDS | maps to | because |
|---------|---------|---------|
| `R[13]` | active bank | boot CPSR reads supervisor, but the value is the *user* stack `0x03002F7C` |
| `R_SVC[0]` | **user/system** bank | under swap, while supervisor is active this holds what swaps in on *leaving* supervisor — the outer stack, not the supervisor one |
| `R_IRQ[0]` | IRQ bank | IRQ is not the active mode, so it genuinely holds IRQ's own stack |

Reading `R_SVC[0]` as "the supervisor bank" — the obvious reading — diverges at
the cart's first `MSR CPSR,r0` out of supervisor, which is instruction **69**,
with every other column still matching.

Both CPUs leave reset in supervisor mode (`SAVESTATE_cpu_mode` defaults to
`CPUMODE_SUPERVISOR`), so the plain REGS r13 at savestate address 14 is the
active bank. Firmware boot (`FWBOOT=1`) still gets the PC only: the BIOS sets up
its own stacks, and presetting them would mask a BIOS that never got that far.

**Verified: 300,000 ARM9 instructions against melonDS, zero divergence, with no
columns ignored** — `sim/tests/compare_trace.py simout/isl9.txt <melonds.log>`.

## Still missing from SetupDirectBoot

Not needed to boot, but real gaps, and the first is a plausible failure in this
cart's own Sound Test group:

| melonDS | RTL |
|---------|-----|
| `SPU.SetBias(0x200)` | `nds_sound.vhd:144` `soundbias` initialises to `0` |
| `ARM7BIOSProt = 0x1204` | no BIOSPROT preset |
| `NDSCartSlot.SetSPICnt(0x8000)` | no preset in `nds_spi.vhd` |

`nds_syscnt.vhd:130-135` (`preset_direct`) covers WRAMCNT, POSTFLG and POWCNT
only.

## Current state: executes correctly, but ~2.3x too slow per frame

**The boot fix is done.** 7.5M ARM9 instructions match melonDS with nothing
ignored, and RTL frame 0 is pixel-perfect against the golden dump
(`compare_fb.py --rtl-frame 0 --mds-frame 0` → PASS).

**What a short run looks like, and why it misleads.** A 75-frame run
(`GPUCEDIV=1 DIRECT=1 PRELOAD=1`) renders uniform `0x3FFFF` on engine A for
every frame. That value is not a white backdrop — it is the display-off path at
`nds_gpu2d.vhd:1487-1489`, which forces all-ones when `dispmode_eff = "00"`.
So DISPCNT's display mode is still 0 at frame 74.

The colour arithmetic rules out the innocent explanation. melonDS switches from
`ffffffff` to `fffbfbfb` at frame 34; `0xfb` is 6-bit **62**, which is what
palette white `0x7FFF` becomes under `c5 << 1`, and `nds_drawer_merge.vhd:251`
does exactly that same expansion. So melonDS at frame 34+ is rendering a real
backdrop with the display ON, while the RTL is still emitting forced white.

### RETRACTED: pacing *is* the explanation, and there is no second divergence

An earlier revision of this file claimed pacing could not explain the white
screen, on the grounds that the RTL runs ~835k ARM9 instructions per frame and
so a mere 10-20% shortfall could not push display-on past frame 74. **That was
wrong, and the way it was wrong is worth recording.** The 835k figure came from
a 300k-instruction run that covered only ~6 ms — entirely inside the busy boot
phase. Steady state is nothing like it.

The block bisect settled it. Over a 1.1 s run:

| | instructions | frames | per frame |
|---|---|---|---|
| melonDS | 10,683,333 | 40 | ~267k |
| RTL     |  7,557,449 | ~65 | ~116k |

**All 75 full blocks match — 7,500,000 instructions bit-exact, no columns
ignored.** There is no functional divergence. The RTL's ARM9 simply retires
~2.3x fewer instructions per frame, so every event lands ~2.3x later in frame
terms. At 116k/frame the display-on write at instruction 10,616,585 falls near
frame **91**, not 34, and a 75-frame run stops just short of it.

That is a CPI gap, not a stall: ~1.126M ARM9 cycles per frame at 67 MHz gives
the RTL a CPI near 9.7 against melonDS's ~4.2. It is a performance problem in
known territory, not the Kirby display-on bug — so **do not** read this cart's
white screen as a reproduction of that. The two look identical on screen and
have nothing to do with each other.

Method note, because it cost a run to notice: neither trace stops on a block
boundary, so the last block on *either* side is short and will always mismatch.
`sim/run_ntr_trace_blocks.sh` now excludes short tails on both sides. Before
that fix it reported "FIRST DIVERGING BLOCK: 75" — which is the RTL's truncated
final block, and reads exactly like a real divergence at the far end of the run.

### Anchoring, for whoever bisects this next

Anchor from boot, not by frame. `TRACE9STARTFRAME` / `TRACE_START_FRAME` look
like the right tool but frame-anchored traces only line up if the CPU-to-video
rate matches on both sides — which is precisely what was in question here, and
it is off by 2.3x. From-boot traces align by construction.

That is affordable because the two sides are byte-identical once the RTL's
uppercase hex is lowercased (verified: same MD5 over 300k instructions), so
11M instructions reduce to a 107-line hash file and only the one disagreeing
block has to travel. The display-on write is `STR r0,[r1]` at PC `0x02039928`
(`r1=04000000`, `r0=00010100`, returning to `0x02000c5c`), instruction
**10,616,585** from boot.

## Confirmed: the display does come on, at frame 86

A 100-frame run (`DUMP_START_FRAME=85`) settles it by direct observation:

| frame | engine A |
|-------|----------|
| 85    | `3FFFF` — forced white, display off |
| 86    | mixed `3EFBE` / `3FFFF` — the display switches on mid-frame |
| 87–99 | `3EFBE` |

`0x3EFBE` is 6-bit **(62, 62, 62)**, which is exactly melonDS's `fffbfbfb`:
palette white `0x7FFF` under `c5 << 1`. And the frames compare pixel-perfect
against the golden dump at the corresponding points:

    compare_fb.py ntr_late_fb.txt <golden> --rtl-frame 2  --mds-frame 40  → PASS
    compare_fb.py ntr_late_fb.txt <golden> --rtl-frame 14 --mds-frame 60  → PASS

(`--rtl-frame` is an index into the dump, not a frame number — this dump starts
at 85, so index 2 is frame 87.)

Display-on lands at RTL frame 86 against melonDS's 34, a ratio of **2.53** —
the CPI gap, and nothing else. There is no functional bug here at all.

**Cost of a full green run.** Scaling by 2.53: the first `PROGRESS[nnn/058]`
text screen (melonDS frame 71) arrives near RTL frame **180**, and the `[07-01]`
halt (melonDS frame 123) near frame **311** — roughly 6.5 hours at the ~1.2
min/frame this configuration sustains. Closing the CPI gap is the thing that
makes this cart a practical regression vector rather than an overnight job.

Engine A logged **zero dropped lines** across all 100 frames.

Note engine A logged **zero dropped lines** across all 75 frames; the 300 drops
in that run were all engine B, which this cart never draws to.

## 2026-08-11: the CPI gap is 1.9x, and the sim needed one fix to boot at all

**The wedge, first.** `53bf403` gave `nds_mainram` a pair-read mode that retires
on `sdram_done64`, not `done32`. `tb_arm9_island` was taught to drive that;
`tb_top_frame` was not, and its `nds_top` port map simply omitted
`sdram_Dout_hi`/`sdram_done64`, which default to `'0'`. So the ARM9's first cache
line fill waited forever:

    HB 19999775000000 fs  ARM9 pc=02000B30 n=35 (+35)  ARM7 pc=02380030 n=44 (+44)
    HB 24999725000000 fs  ARM9 pc=02000B30 n=35 (+0)   ARM7 pc=02380030 n=44 (+0)

Both CPUs, because the ARM7 shares that channel — it reads as a total wedge, not
an ARM9 fault. Fixed in `4aaa7fe`. The lesson for anyone adding a port to
`nds_top`: a defaulted `in` port turns a missing testbench connection into a
silent deadlock instead of an elaboration error.

**Boot preset still correct.** First retire is `02000808 E3A0C301`
(`MOV r12,#0x04000000`) with `CPSR=000000D3`, `r13=03002F7C`, `r14=02000800` —
the `--direct` column of the table above, unchanged.

**No functional divergence from the 2026-08-11 work.** Blocks 0 and 1 of the
from-boot trace are byte-identical to the melonDS reference, i.e. the first
200,000 instructions match after the drawer merge, the `GPU_CE_DIV` removal, the
ARM9 pair fills and the card prefetch queue.

**The gap closed from 2.30x to 1.92x.** Steady state, three consecutive 10 ms
heartbeats, `DIRECT=1 PRELOAD=1`:

| | instr/frame | CPI @ 67.028 MHz | vs melonDS |
|---|---|---|---|
| melonDS      | ~267k | ~4.2 | 1.0 |
| RTL, previous| ~116k | ~9.7 | 2.30x |
| RTL, now     | ~139k | ~8.05 | **1.92x** |

+83,247 ARM9 instructions per 10 ms, dead flat across heartbeats, so 8.32 M/s
against a 16.715 ms frame. The pair fills are the difference; nothing else in
that set touches ARM9 throughput.

Scaling the observed frame-86 display-on by 116/139 puts it near frame **72**
now, and the `[07-01]` halt near frame **260**. Still an overnight job — the CPI
gap remains the thing that makes this cart practical, and it is now the only
thing left on it.

**`ISLAND=1` is the default and this is measured at 2:1.** The sim has always run
the ARM9 island at 66.67 MHz (`ISLAND_HALF_PS=7500`), so none of the numbers
above move with `7452cc8`, which fixed the *FPGA* running `clk2x` at 1:1. That
was a real factor of two on hardware and no part of it was ever visible here —
which is exactly why it survived so long.

## 2026-08-11 (later): why the cart stops at `[04-02] DMA PRIORITY`

On hardware the cart now reaches `PROGRESS[011/058]` and halts there:

    [04-02] DMA PRIORITY
     NG!:0_1 STEP_1 109449216 AD: 00000001
     NG!:1_2 STEP_1 109449216 AD: 00000001
     NG!:2_3 STEP_1 109449216 AD: 00000001
     CODE: 00000007        RESULT:FAIL  TOTAL:FAIL

melonDS passes this test and goes on to `012`–`016`, so this is ours. All three
adjacent channel pairs fail identically, and the numbers decode exactly — the
format string is ` NG!:%d_%d STEP_1 %d AD: %08X` at `0x022089C4`, its third
vararg is the walk pointer and its fourth is the saved IME, so `109449216` is
`0x06861000` (index **0** of the high-priority buffer) and `AD: 00000001` is
just IME. The failure is on the very first entry compared.

### What the test actually does

Disassembled from the dump at `0x0201A13C`. Per pair `(N, N+1)`, with
`TimerStart(3, 0xFFFF, 0)` — which writes `TM3CNT_L = ~0xFFFF = 0` and
`TM3CNT_H = 0xC0`, i.e. **prescaler /1, one tick per 33.513982 MHz bus cycle**:

| | ch `N` | ch `N+1` |
|-|--------|----------|
| SAD | `0x0400010C` (`TM3CNT_L`), **fixed** | same |
| DAD | `0x06861000`, increment | `0x06860000`, increment |
| units | 8, 16-bit | 2048, 16-bit |
| start | HBLANK | IMMEDIATE |

Both channels therefore fill VRAM bank D with snapshots of a free-running
counter. The checker then walks the 2048-entry buffer of the **low**-priority
channel and requires it to be exactly `t, t+2, t+4, …` — a 16-bit DMA unit is
one read plus one write, **two bus cycles**, on real silicon. Where that
sequence breaks, the 8 missing counter values must be sitting in the
high-priority channel's buffer, contiguous: proof that it preempted mid-transfer.

So `[04-02]` is a **DMA throughput** measurement, not an ordering one. Our
priority pick (`for i in 3 downto 0`, last-write-wins, `nds_dma9.vhd:275`) was
already correct, and preemption is not required to pass: a core with the right
cadence and no preemption walks the whole buffer in state 0 and prints
`PRIORITY_n_n: OK`, because the gap check only runs if there is a gap.

### Repro without the other 57 tests

`sim/tests/dmaprio` is a standalone ROM that does exactly the above, and
`check.py` applies the cart's own three-state checker to the dump:

    sim/tests/dmaprio/build.sh
    DUMP_STATE=1 PRELOAD=1 DIRECT=1 FRAMES=3 \
       sim/run_top_frame.sh sim/tests/nds_dmaprio.hex
    sim/tests/dmaprio/check.py

Minutes instead of the ~4 hours the cart needs to reach test 011. It reproduced
the board's failure exactly, down to the printed index.

### Bug 1, fixed: ARM9 DMA reads of IO registers returned 0

Both buffers came back **entirely zero** — VRAM bank D held 3 non-zero words,
all of them CPU-written markers.

`io_wired_done` is not a level on the ARM9. `nds_top` generates it as a
one-island-cycle *completion event*, unconditionally, so that reads of unclaimed
addresses retire too. `nds_membus9`'s read mux presented `io_wired_out` for
exactly that one cycle and `x"00000000"` on every other. The CPU is inside the
island and samples precisely then, so its reads were fine; `nds_dma9` is a clk1x
unit driven by the stretched `cpu9_done_1x`, a registered toggle-edge that lands
one to two clk1x cycles later — by which point `T_IO` read zero.

Every ARM9 DMA read from an IO register returned 0, in both the 1:1 and 2:1
island configurations. Only the DMA was affected: every other source (VRAM, main
RAM, shared WRAM) answers from a register that stays valid, which is why
ordinary memory-to-memory DMA always worked and this hid for so long. Fixed by
holding the IO word past the completion pulse (`io_rd_hold`); the CPU's
same-cycle path is untouched. The ARM7 is not affected — `io_wired_done7` is the
OR of plain address decodes, a level, so it holds for as long as its DMA needs.

### Bug 2, open: a 16-bit DMA unit costs 20 bus cycles, not 2

With real data flowing, the buffers are perfectly uniform and exactly 10x too
slow — one single distinct delta across all 2047 steps. Same source and same
DMA, varying only the destination, measures where it goes:

| DMA destination | cycles per 16-bit unit |
|-----------------|------------------------|
| palette (`T_PAL`, retires in `FINISH` — the fastest write in the core) | **11** |
| VRAM E (BRAM inside `nds_vram`) | 16 |
| VRAM D (off-chip over `vsrv`) | 20 |
| real hardware | **2** |

The destination memory is **not** the dominant term. Rebuilding the VRAM A..D
write path — the obvious first guess, since A..D leave the chip — would take 20
to 11 and still miss by 5.5x. The floor is the per-access cost: 11 = 3 cycles of
`nds_dma9` FSM states (`RD`, `WR`, `NEXTUNIT`) plus ~4 cycles of wait per access,
and that wait is mostly island CDC. Each access crosses clk1x -> clk2x for the
request and clk2x -> clk1x for the done, and an IO read additionally round-trips
the clk1x IO fabric through `cdc_io_cpl`.

Hardware needs no overlap to hit 2: each access there is a single bus cycle.
Matching it therefore needs single-cycle accesses, which means

1. `nds_dma9` inside the island (or the per-access CDC removed), so a request and
   its done cost no cycles of crossing;
2. the FSM reduced to one state per access — no `NEXTUNIT`, request asserted in
   the same cycle the previous access retires;
3. VRAM A..D writes accepted in one cycle, i.e. posted and write-combined behind
   the `vsrv` channel (palette and E already qualify).

Items 1 and 2 alone are worth having regardless — DMA is on the hot path for
every graphics upload, so 11 -> ~5 is a general win and low risk. Only item 3
plus a genuinely single-cycle IO read closes it to 2, and that is the expensive,
correctness-sensitive part.

**Cost/benefit.** `[04-02]` is the *only* test in group 04 that measures cycles:
`[04-04]`/`[04-05]`/`[04-06]` report ` DMA_%d: OK COUNT: %d`, i.e. they count
DMA firings, and `[04-03]` checks address patterns. So this one test gates four
that are probably close to passing already, and it cannot be reached any other
way — the cart halts on first failure. Nothing short of the datapath work above
moves `PROGRESS` off `011`.
