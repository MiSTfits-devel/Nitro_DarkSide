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

## Current state: boots and executes, but the display never turns on

The cart is NOT green yet. Two separate facts, and it is worth keeping them
apart:

**The boot fix is done.** 300k ARM9 instructions match melonDS with nothing
ignored, and RTL frame 0 is pixel-perfect against the golden dump
(`compare_fb.py --rtl-frame 0 --mds-frame 0` → PASS).

**There is a second, later divergence.** A 75-frame run
(`GPUCEDIV=1 DIRECT=1 PRELOAD=1`) renders uniform `0x3FFFF` on engine A for
every frame. That value is not a white backdrop — it is the display-off path at
`nds_gpu2d.vhd:1487-1489`, which forces all-ones when `dispmode_eff = "00"`.
So DISPCNT's display mode is still 0 at frame 74.

The colour arithmetic rules out the innocent explanation. melonDS switches from
`ffffffff` to `fffbfbfb` at frame 34; `0xfb` is 6-bit **62**, which is what
palette white `0x7FFF` becomes under `c5 << 1`, and `nds_drawer_merge.vhd:251`
does exactly that same expansion. So melonDS at frame 34+ is rendering a real
backdrop with the display ON, while the RTL is still emitting forced white.

Pacing does not explain it either. The 300k-instruction trace run covered ~6 ms
of DS time, i.e. ~835k ARM9 instructions per frame, against ~1.12M cycles/frame
on real hardware — the same ballpark. A 10-20% shortfall would put display-on
near frame 40, not past 74. The margin is 2.2x.

This is the same signature as the Kirby stall (DISPCNT display-on write never
happens), but reached at **frame 34 instead of frame 337** — which makes this
cart a much cheaper reproduction of that bug than Kirby is.

Next step is a trace bisect, not another blind frame run: `TRACE9STARTFRAME`
(melonDS) and `TRACE_START_FRAME` (tb_top_frame) both exist precisely to take a
trace from frame ~30 without a multi-GB from-boot dump. Diff those to find where
the ARM9 stops agreeing.

Note engine A logged **zero dropped lines** across all 75 frames; the 300 drops
in that run were all engine B, which this cart never draws to.
