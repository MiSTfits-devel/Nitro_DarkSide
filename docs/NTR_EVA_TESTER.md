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

So the loader's direct-boot env needs the register preset extended from
`{PC}` to `{PC, SP, LR}`, with the banked SVC/IRQ stacks, to match
`SetupDirectBoot`. This is adjacent to — and independent of — the known CP15
direct-boot gap; fixing CP15 alone will not boot this cart.

Until that lands, this cart cannot run on the core, in sim or on hardware.
