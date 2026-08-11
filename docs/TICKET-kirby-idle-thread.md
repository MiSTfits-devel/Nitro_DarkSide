# Kirby direct boot: the ARM9 enters `OS_IdleThread` and never reschedules out

**Filed** 2026-07-30 · **Severity: this IS the white screen** · Found on silicon
(`NDS_cache_20260730.rbf`) by breakpoint-bisecting real hardware against a melonDS
direct-boot trace.

## The one-line statement

Kirby performs its **first** `DISPCNT` write and **never** the display-on write.
The ARM9 reaches the point where every thread is blocked, enters
`OS_IdleThread`, and **stays there forever** — no context switch ever takes it out.
The screen is white because `DISPCNT` mode is 0, which is the hardware behaving
correctly for a game that never got as far as enabling its display.

## Method — worth reusing, it is ~4000x faster than simulation

Simulating Kirby to display-on is **3.4-4.0 s of DS time ≈ 6.5 h wall** per data
point. Hardware runs it in 4 seconds. So:

1. melonDS `--direct` with retail BIOSes → 10.1 M-instruction ARM9 trace that
   *does* reach display-on (`VIDLOG` frame 51, `DISPCNT_A=80211218`).
2. First-occurrence PC list, with occurrence counts:
   `awk '{if(!(($1) in f)) f[$1]=NR; c[$1]++} END{...}' | sort -n`
3. `nitrodbg.sh reach9 <archpc> <secs>` per candidate, bisecting on **boot depth**
   (first-occurrence order), not instruction index.

Each probe is ~5-9 s. Roughly 60 probes localised the failure to a
**1,791-instruction window** out of 10.1 M.

### Instrument facts established along the way

- **`reach9` works even though `nds_top` sets `BOOT_HOLD => '0'`**
  (`rtl/nds_top.vhd:1081`). It works by luck: the loader's main-RAM staging pass
  holds both cores for ~70 ms on hardware, which is plenty of time for
  `SOFTRESET → BRKSET → RUN`. Setting `BOOT_HOLD => not is_simu` would make this
  robust rather than incidental.
- **Controls pass**: ARM9 entry `02000808` REACHED, bogus `02BADBAC` not-reached,
  idle-thread WFI `0214FC10` REACHED.
- **`reach9` is not timing-sensitive here**: a not-reached PC is still not-reached
  with a 40 s window instead of 8 s. So "not reached" is real, not a timeout.
- **PEEK is exact for main RAM and useless elsewhere.** Verified against the ROM
  file: `peek9 0x02000000` and `peek7 0x02380000` match all 8 words byte-for-byte.
  But `nds_debug.vhd:101` muxes the peek onto the **ARM9 main-RAM channel**, so the
  `7`/`9` suffix is cosmetic for peek and *any* non-main-RAM address returns
  convincing garbage — shared WRAM at `0x037FCxxx` reads as all zeroes. Do not
  read "the CPU is executing zeroes" out of that.
- **`step7 1` / `step9 1` never retire an instruction** — a 1-cycle release
  restarts rather than advances. Use ≥10 cycles.

## What is NOT wrong (all measured, so none of these need revisiting)

| hypothesis | verdict |
|---|---|
| Interrupt configuration | **identical to the oracle.** `IME9=1 IE9=00040001 IF9=00080000 IME7=1 IE7=01040099`, oracle and silicon. Including `IF9` bit 19 (card transfer) latched while `IE9` does not enable it — the card driver polls, so that latched flag is a **red herring**. |
| ITCM | **works.** Three ITCM PCs REACHED (`01ffaba8`, `01ffac70`, `01ffab10`, trace 1.86 M-3.25 M). |
| Card reads | **work end-to-end.** The read loop at `0213F250` — poll `ROMCTRL` bit 23, drain `0x04100010`, 512 words/block — is reached at the head, the DATA_READY path, the store, **and the loop exit**. |
| Either CPU wedged | **no.** Both progress. The ARM7 moves between code regions, changes stack (main RAM → WRAM), and **clears `IF7` bit 18** — it services IPC. The ARM9 is woken by VBlank (`step9 1000000` moves it; `step9 10000` does not, because WFI). |
| ARM9 memory path stalled | **no.** `probe` shows `cache9 IDLE`, `membus9 IDLE`, `mainram MR_IDLE`, nothing outstanding. |

**A correction to a first impression**: a single early sample showed the ARM7 with
`CPSR I=1` and four enabled IRQs latched, which reads exactly like a wedge inside a
critical section. It is not — 30 s later the ARM7 had moved on and acknowledged
them. Sample twice before believing an ARM7 snapshot.

## The boundary, in numbers

| oracle trace line | PC | count | hardware |
|---|---|---|---|
| 3,316,320 | `02143960` — `str r1,[r12]`, `DISPCNT_A = 80200018` | 1 | **REACHED** |
| 8,380,968 | `0213f770` | 1 | **REACHED** |
| 8,381,212 | `0214db84` — `OS_IdleThread` prologue | 1 | (entered, never left) |
| 8,381,442 | `01ffad90` — deferred context **save** | 61 | **not reached** |
| 8,381,536 | `0213f7a8` — resumption in the other thread | 60 | **not reached** |
| 8,383,010 | `02136c7a` | 1 | **not reached** |
| **8,687,797** | **`021439cc` — `str r0,[r1]`, `DISPCNT_A = 80211218`, display ON** | **1** | **not reached** |

`02143960` and `021439cc` are both `count == 1` one-shots on the linear init path,
so this pair is free of the conditional-branch ambiguity that makes most
`reach9` negatives untrustworthy. They are the cleanest statement of the bug.

## The mechanism

`OS_IdleThread`, read off the running silicon with `dump9` (main RAM, so exact):

```
0214DB7C  E92D4000  push {lr}
0214DB84  EB000740  bl 0214F88C      ; mrs r0,cpsr / bic r1,r0,#0x80 / msr = OS_EnableIrq
0214DB88  EB00081D  bl 0214FC04      ; -> MCR p15,0,r0,c7,c0,4 (WFI) at 0214FC08 = OS_Halt
0214DB8C  EAFFFFFD  b  0214DB88      ; forever
```

Sampled over 24 s of hardware run time, the ARM9 r15 is `0214FC10` (that WFI) on
**every** sample. `OS_IdleThread` runs exactly **once** in the oracle
(`0214db84` count == 1) — a healthy boot enters it and is immediately switched out.

How the oracle gets out, all inside the 1,791-instruction window:

```
0214FC10  WFI
ffff0020  -> ARM9 BIOS IRQ vector
ffff0280  mrc  p15,0,r0,c9,c1,0     ; DTCM region register
ffff0288  mov  r0,r0,lsl #12        ; -> DTCM base
ffff028c  add  r0,r0,#0x4000
ffff0294  ldr  pc,[r0,#-4]          ; handler pointer at DTCM+0x3FFC  (= 0x03003FFC)
01ffac6c  -> the game's IRQ dispatcher, in ITCM
0214fc38  -> OS IRQ handler -> game handler
0214dcbc  mov  r0,#1
0214dcc0  strh r0,[r4]              ; r4 = 0x02206A50  <- "reschedule pending"
...tail of the ITCM handler:
01ffad18  ldrh r1,[r12]             ; r12 = 0x02206A50
01ffad1c  cmp  r1,#0
01ffad20  ldreq pc,[sp],#4          ; zero -> just return
01ffad2c  msr  cpsr_c,#0xd2         ; IRQ mode
01ffad90  mrs  r2,spsr              ; <- context SAVE, never reached on silicon
          -> resumes a different thread
```

and the `strh` that arms it is itself gated:

```
0214dc88  push {r4,r5,r6,lr}
0214dc90  ldr  r4,[pc,#0xd0]        ; r4 = 0x02206A50
0214dc9c  popne {r4,r5,r6,lr} / bxne lr    ; return if *ptr != 0
0214dca4  ldrh r0,[r4,#2]           ; *** the gate: halfword at 0x02206A52 ***
0214dcac  bne  0214dcbc             ; non-zero -> arm the deferred switch
0214dcb0  (else) fall through to the immediate path
```

Measured, hardware vs oracle:

| location | oracle | silicon |
|---|---|---|
| `0x02206A52` (the gate) | non-zero (drives `0214dcbc` **60** times) | **always 0** |
| `0x02206A50` (pending flag) | `0` ×72 then `1` ×61 | **`0` at every sample over 24 s** |
| `0214dca4` / `0214dcac` (gate read) | — | **REACHED** |
| `0214dcbc` / `0214dcc0` (arm it) | — | **not reached** |

So the function runs, reads the gate, finds it zero, and always takes the
fall-through. The deferred switch is never armed, so the IRQ handler tail always
returns without switching, so the idle thread runs forever.

**I dismissed this once as a benign timing difference** — reasoning that a zero
gate is the *unlocked* state and taking the immediate path is legitimate. That was
wrong, and the thing that disproved it is that `01ffad90` and `0213f7a8`, whose
first occurrences lie inside the divergence window, are both unreached: the
deferred path is not an alternative route here, it is *the* route out of the idle
thread.

## Next step

**Find what writes the halfword at `0x02206A52`.** It is main RAM, so it is
directly `peek9`-able on hardware and greppable in the oracle trace. That writer,
or its caller, is the root cause.

Care required, because this class of probe has already produced two wrong
conclusions in this ticket:

- **Always check the occurrence count before believing a REACHED.** `0214dccc`,
  `0214dd74` and `0214de94` all report REACHED and all are worthless as evidence
  here — they are hot (504-952 occurrences) and first occur millions of
  instructions before the window. Only a PC whose *first occurrence* is inside the
  window says anything about this invocation.
- **Prefer `count == 1` PCs.** They cannot be reached by an unrelated earlier call.
- **A negative on a PC behind a data guard is not a progress boundary.** That is
  exactly how the `01ffad38` / `02206A50` chain fooled me the first time.

## Related

- `HANDOFF.md` → "Kirby on hardware: NOT a deadlock", and the eliminated-causes table
- The two prior root causes on this path are both **already fixed and neither
  booted Kirby**: ARM9 CP15 direct-boot state (`nds_cpu9.vhd:142`, matches melonDS
  `SetupDirectBoot` register-for-register) and the ARM9 IPC RECV off-by-one
  (`ea0d8c6`)
- Method precedent: `nds-hw-bisect-by-breakpoint`, which cracked the 2026-07-25
  freeze the same way
