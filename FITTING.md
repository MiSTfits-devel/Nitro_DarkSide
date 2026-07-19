# M9 Fitter blowup — resource usage 21x over budget

Written by Agent A for review by a second, more capable model ("Fable").
Context: this is the NDS_MiSTfits project, a MiSTer FPGA port of a
from-scratch NDS core (donor: GBA_MiSTfits), currently in milestone M9
(first real Quartus synthesis / MiSTer top-level port). Three AI sessions
(Agent A/B/C) have been collaborating concurrently on this tree via
`COORDINATION.md` at the repo root — read that file for the full blow-by-blow
if useful, but this document is self-contained for the problem at hand.

## TL;DR

Analysis & Synthesis passed for the first time this session, after five
rounds of fixing genuine Quartus-17-front-end-vs-nvc VHDL incompatibilities
(all now resolved, see "How we got here" below). The Fitter then failed
because the design needs **~21.6x** the logic (ALMs) the target device has,
and more block-RAM (M10K) than the device has. Three specific RTL modules —
out of ~25 in the design — account for essentially the entire overrun, and
none of them look like they should, by ordinary VHDL-synthesis intuition,
cost anywhere near what they're costing. This document lays out the exact
numbers, what's been ruled out, what's been found, and open questions, and
proposes next steps without committing to one.

## Target device / build

- Device: Cyclone V `5CSEBA6U23I7` (the DE10-Nano part MiSTer's main FPGA
  board uses) — **41,910 ALMs, 553 M10K blocks (5,662,720 block-mem bits),
  112 DSP blocks.** This is a fixed constraint: MiSTer cores target this
  exact part, so "use a bigger device" is not an available option here.
- Quartus Prime 17.0.2 (Lite), `VHDL_INPUT_VERSION=VHDL_2008`, top entity
  `sys_top`.
- Build settings are deliberately aggressive (pre-existing project choice,
  not something I changed this session): `OPTIMIZATION_MODE=Aggressive
  Performance`, `PHYSICAL_SYNTHESIS_EFFORT=Extra`,
  `ROUTER_TIMING_OPTIMIZATION_LEVEL=MAXIMUM`, targeting 100.5 MHz on a
  design "bigger than GBA" (this donor's sibling GBA core fits this exact
  device fine at GBA scale).
- Build pipeline: `build/remote-build.sh <git-ref>` streams a `git archive`
  of the given ref to a disposable k8s pod running Quartus, runs
  `quartus_sh --flow compile NDS`, and copies `output_files/*.rpt` back to
  `build/artifacts/`. A full round trip (pod boot + Analysis & Synthesis +
  Fitter attempt) takes 45–70 minutes wall-clock for this design.
- The specific build discussed here: branch `synth-diag` (a disposable,
  isolated-worktree branch used all session for build iteration without
  touching `main`), commit `47a2103`, built via
  `build/remote-build.sh synth-diag`. `synth-diag` branched off `main` at
  `cf59e21`, **before** two other in-flight changes on `main` (a firmware-
  size widening from Agent B, and a Clash/Haskell HDL video-mixer migration
  from Agent C) — so this run reflects the RTL as of `cf59e21` plus five
  small Quartus-portability patches (below), nothing else in flight.
- Artifacts referenced below are on disk at `build/artifacts/NDS.map.rpt`
  (Analysis & Synthesis / `quartus_map` report, ~5.8 MB text),
  `build/artifacts/NDS.fit.rpt` (Fitter report, ~92 MB text),
  `build/artifacts/NDS.map.summary`, `build/artifacts/NDS.fit.summary`,
  `build/artifacts/NDS.flow.rpt`. These are real output on this machine —
  grep them directly rather than trusting transcription errors below.

## How we got here (context, not the problem)

Five rounds of Analysis & Synthesis failures were fixed this session, all
genuine Quartus-17-vs-nvc VHDL front-end incompatibilities (nvc 1.21.1 is
the simulator used for the sim-side regression suite and accepts all of
these forms; Quartus's elaborator/front-end does not):

1. `nds_bios7.vhd` / `nds_bios9.vhd`: Quartus 17's `std.textio` only has the
   `bit_vector` overload of `hread`, not the VHDL-2008 `std_logic_vector`
   one. Fix: read into a `bit_vector` variable, convert with
   `to_stdlogicvector`.
2. Same two files: Quartus's elaborator can't bound-prove a file-driven
   `while not endfile(f) and i <= x loop` stays in range. Fix: `for k in
   t_rom'range loop ... exit when endfile(f); ...`.
3. `files.qip` file order matters to Quartus's VHDL analyzer (it analyzes
   in listed order, unlike nvc which resolves via its work library
   regardless of order) — reordered to dependency order.
4. Record-typed debug/export signals in `nds_top.vhd` needed pragma-
   stripping for synthesis (donor idiom); simulation-only, no behavior
   change.
5. `rtl/nds_gpu2d.vhd`: `linebuf_objcol(dyn_idx) <= (others => x"8000");` —
   a row-wide aggregate assigned to a dynamically-indexed row of an
   array-of-array signal — hits Quartus error 10324 ("expression has N
   elements; expected M elements"), a real elaborator bug/limitation, not
   an nvc-vs-VHDL correctness question. Fixed by converting to an explicit
   `for i in 0 to 255 loop` per-element clear (functionally identical,
   confirmed nvc-clean via `sim/run_analyze_all.sh` both before and after).

All five are done; Analysis & Synthesis is green. **This document is about
what happens next, in the Fitter, and is a substantially bigger problem.**

## The Fitter failure

```
Error (170011): Design contains 684092 blocks of type combinational node.
                However, the device contains only 83820 blocks.
Error (170048): Selected device has 553 RAM location(s) of type M10K block.
                However, the current design needs more than 553 to
                successfully fit
Error (11802): Can't fit design in device. Modify your design to reduce
               resources, or choose a larger device.
Error: Quartus Prime Fitter was unsuccessful. 3 errors, 14 warnings
```

`NDS.fit.summary`:

```
Logic utilization (in ALMs) : 907,086 / 41,910 ( 2164 % )
Total registers              : 1,217,986
Total block memory bits      : 5,267,605 / 5,662,720 ( 93 % )
Total DSP Blocks             : 112 / 112 ( 100 % )
```

This is not "10% over, tighten a few things" — it's ~21.6x the device's ALM
budget. DSP blocks are also pegged at exactly 100% (112/112), a second
resource at its ceiling, though far less dramatically than ALMs/M10K.

Important: **this is not a Fitter-stage duplication artifact.** The raw
`quartus_map` (Analysis & Synthesis) per-entity resource table, generated
*before* the Fitter's physical-synthesis / register-duplication /
retiming heuristics ever run, already shows the same lopsided numbers
(`NDS.map.rpt`, section "7. Analysis & Synthesis Resource Utilization by
Entity", vs. the Fitter's own section 10 with the same title) — e.g.
`nds_membus7` shows 174,724 combinational ALUTs at the *raw synthesis*
stage, identical to what shows up post-Fitter. Whatever's happening is
baked in by the front-end synthesizer reading this exact RTL, not
introduced by later placement/duplication passes.

## Per-entity breakdown

Extracted from `NDS.fit.rpt`'s "Fitter Resource Usage Summary" (section
10), filtering to `nds_top`'s direct children (full path prefix
`|sys_top|emu:emu|nds_port_wrap:nds|nds_top:inds|<entity>`):

| Entity | ALMs needed | Comb. ALUTs | Registers | Block-mem bits |
|---|---:|---:|---:|---:|
| **nds_membus7** (leaf, ARM7 bus decoder) | ~109,544 | **174,724** | 293 | 0 |
| **nds_membus9** (ARM9 bus decoder, incl. child) | ~163,379 | 192,444 | 107,948 | 0 |
| — of which `nds_cache9` child alone | 81,150 | 61,143 | **107,500** | 0 |
| — nds_membus9's *own* share (subtract cache9) | ~82,228 | **~131,301** | ~448 | 0 |
| **nds_card** (cart-slot interface) | 47,892 | **96,287** | **65,872** | 0 |
| nds_gpu2d ×2 (engine A + B, both instances) | ~73,242 | ~63,629 | ~99,176 | ~615,046 |
| nds_cpu9 | 3,853 | 6,217 | 2,738 | 0 |
| nds_sound | 6,746 | 11,269 | 5,555 | 0 |
| nds_dma7 / nds_dma9 | ~1,022 / ~1,133 | ~1,695 / ~1,752 | ~727 / ~899 | 0 |
| nds_vram | 741 | 841 | 1,010 | 1,179,648 |
| nds_wram | 14 | 29 | 2 | 262,144 |
| everything else (irq, spi, rtc, ipc, timers, syscnt, loader, mainram) | small | small | small | small/0 |

(Numbers pulled with an `awk` one-liner over the Full Hierarchy Name column
of `NDS.fit.rpt`; re-derive directly from the report if you want to
double-check — it's plain semicolon-delimited text, `grep -n
'nds_membus7:imembus7 ;\|nds_membus9:imembus9 ;\|nds_card:icard ;'` won't
match due to column padding, filter on the "Full Hierarchy Name" field
instead, see the awk pattern used: match
`nds_top:inds\|ENTITY:INSTANCE$` on the trimmed hierarchy-name field.)

**Sanity check on what "normal" looks like:** both `nds_gpu2d` engines
combined (a full duplicated NDS 2D PPU — affine/text/object rendering,
mode 7-ish, x2 for engine A/B) cost ~63.6k comb ALUTs and ~615k block-mem
bits — a lot, but proportionate to what it does, and its memory correctly
landed in block RAM (not registers). `nds_vram` (656 KB of VRAM, 9 banks)
costs 841 ALUTs and 1.18M mem bits — again, correctly using BRAM, trivial
logic overhead. These are the two biggest *legitimate* consumers and
neither is a mystery. `nds_membus7`, `nds_membus9`'s own logic, and
`nds_card` are the anomaly: three small, ordinary-looking files (319 / 467
/ 490 lines) accounting for the overwhelming majority of the 21x overrun,
between them costing more combinational logic than the rest of the entire
NDS core (CPUs, both PPUs, sound, all DMA, all bus fabric elsewhere)
combined.

## Two different symptom shapes — likely two different root causes

**Shape 1 — storage that should be BRAM became registers instead** (seen in
`nds_cache9` and, on inspection, almost certainly also `nds_card`):

- `nds_cache9.vhd` (instantiated inside `nds_membus9`) implements the
  ARM946E-S 4-way set-associative I$ (8 KB) + D$ (4 KB). Its own header
  comment is explicit about this being a known, deferred problem:
  > "The line stores are plain signal arrays (fine for nvc; the BRAM
  > knife-fight happens in M9."
  That's now. Storage is declared as:
  ```vhdl
  type t_itags is array (0 to 255)  of std_logic_vector(20 downto 0);  -- way*64+set
  type t_dtags is array (0 to 127)  of std_logic_vector(21 downto 0);  -- way*32+set
  type t_idata is array (0 to 2047) of std_logic_vector(31 downto 0);  -- (way*64+set)*8+word
  type t_ddata is array (0 to 1023) of std_logic_vector(31 downto 0);  -- (way*32+set)*8+word
  ```
  Total real storage here is modest (~98 Kbit, i.e. ~10-12 M10K blocks'
  worth if it inferred as BRAM) — the problem isn't the size, it's the
  access pattern. A 4-way set-associative cache needs to read all 4 ways'
  tags for the *same set* simultaneously, every cycle, to do a combinational
  hit/way compare. As coded (one flat array indexed `way*N+set`), that's 4
  *simultaneous* reads from one array in the same cycle — which cannot map
  to a single M10K block (1-2 ports), so Quartus has no legal way to use
  BRAM and falls back to one register per bit: 107,500 registers, 0 block-
  mem bits, exactly matching the reported numbers (2048+1024 words × 32
  bits + 256×21 + 128×22 tag bits ≈ 98K bits of *logical* storage, but
  ~107.5K *physical* registers once flops + compare/mux logic are counted).
  **This one is understood and scoped**: needs restructuring into
  per-way-separate arrays (4 independent BRAMs, addressed by set only, read
  in parallel, each on its own port) or a serialized/fewer-way tag compare.
  Real design work, not a syntax patch.

- `nds_card.vhd` almost certainly has the *same* disease, on inspection
  (not yet build-confirmed in isolation — flagging as a strong hypothesis,
  not a verified fact): it implements an 8 KB SPI/EEPROM-style backup save
  as
  ```vhdl
  type t_sram is array (0 to 8191) of std_logic_vector(7 downto 0);
  signal sram : t_sram := (others => (others => '1'));
  ```
  accessed via single dynamic-index reads/writes (`sram(to_integer(...))`)
  buried deep inside one large multi-purpose clocked process alongside
  dozens of unrelated register writes (AUXSPICNT/ROMCTRL/cmdbytes/FSM
  state/etc.) — not isolated in its own narrowly-scoped process the way
  Quartus's `altsyncram` inference heuristic typically wants. 8192 × 8 =
  65,536 register bits lines up almost exactly with the reported 65,872
  registers for this entity (the remainder being the FSM/control
  registers). Unlike the cache, there's no *structural* reason this can't
  be BRAM (it's single-port, single dynamic index, no simultaneous multi-
  way access) — it looks like a plain missed-inference case, possibly
  fixable by isolating the array's read/write into its own small process in
  the canonical `if we='1' then mem(addr)<=din; end if;` / registered-read
  shape Quartus's pattern-matcher expects.

**Shape 2 — pure combinational bloat, no matching register growth**
(seen in `nds_membus7` fully, and `nds_membus9`'s own logic once you
subtract the `nds_cache9` child):

- `nds_membus7`: 174,724 comb. ALUTs, only 293 registers (293 is exactly
  in line with just its ~14 output ports' bit-widths — bios/wram/vram/
  mainram addresses + write-data + the IO record — nothing surprising
  there).
- `nds_membus9`'s own share (192,444 − 61,143 = ~131,301 comb. ALUTs;
  107,948 − 107,500 = ~448 registers): same shape, small register count,
  huge purely-combinational logic.
- I read both files **in full** (319 and 467 lines respectively, both
  pasted below in the appendix) and neither contains anything that
  should synthesize to six figures of LUTs by any ordinary reading: each
  is an FSM (accept-one-request-at-a-time bus adapter, same idiom in both,
  clearly derived from the same template) plus three small combinational
  processes — an address decoder (`case addr(27 downto 24) is ...`, ≤10
  branches), a write-lane placement (2-bit case, byte/halfword/word),
  and a read-data mux + rotate (5-8-way `when/else` chain + a rotate
  case). None of these have a plausible path to 100K+ LUTs under normal
  synthesis. There are no large arrays, no wide dynamic shifts beyond a
  couple of 33-bit `shift_left` barrel shifts in `nds_membus9`'s TCM-window
  decode (dynamic shift amount 0–31, which is at most a few hundred gates
  for a barrel shifter, not relevant at this scale) — nothing that jumps
  out.
- **Both anomalous files are near-identical in structure** (same FSM
  idiom, same three combinational-process shape, both instantiate no
  large arrays themselves) and **both** show the same disproportionate
  pure-combinational blowup with normal register counts. That's a strong
  hint the root cause is something *common* to this file template/pattern
  — not something specific to one file's particular logic — and is worth
  investigating as such rather than treating them as two unrelated bugs.
  Possible angles nobody has checked yet:
  - Something about the shared `proc_bus_gb_type` record type (defined in
    `rtl/proc_bus_gba.vhd`, a record with `Din`/`Adr`/`rnw`/`ena`/`acc`/
    `bEna`/`rst` fields) combined with how `io_bus` (an output port of this
    record type) gets driven across multiple `case`/`if` branches in the
    request FSM — record-typed port assignment across many conditional
    branches is exactly the kind of thing that tripped Quartus's front-end
    earlier this session (the debug-record pragma issue, item 4 above) and
    is worth re-suspecting.
  - Whether Quartus's cross-hierarchy synthesis-time optimization (nothing
    pins partition boundaries here — no `SYNTHESIS_ONLY_QIP`-adjacent
    partition assignments) is pulling in and re-attributing logic from
    something these files are wired to (e.g. the big OR-reduced
    `io_wired_out` mux across many peripherals, which nds_membus7/9's
    header comments describe as living *outside* these files, in
    `nds_top.vhd` — but if Quartus dissolves that hierarchy boundary during
    optimization, the resulting logic could get bucketed under whichever
    instance the tool picks, which might not be where the RTL author put
    it).
  - Whether there's a Quartus-17-specific synthesis pathology in one of
    the specific constructs both files share (the `process(all)` sensitivity
    + `case` construct on a `std_logic_vector` slice, an unconstrained
    `when/else` priority-mux chain of a certain shape, etc.) — i.e. another
    entry in the same family of real Quartus front-end quirks already found
    5 times this session, just in the technology-mapping stage instead of
    the elaboration stage this time.
  - Not yet ruled out: an isolated single-entity compile of just
    `nds_membus7` (a tiny throwaway top-level wrapping only that entity)
    would get a fast (~minutes, not 45-70 min) yes/no on whether the
    blowup reproduces standalone, and Quartus's post-synthesis "Technology
    Map Viewer" / RTL viewer (or at least deeper report sections not yet
    grepped) might show what's actually being built if someone can drive
    the GUI or extract more detail from the text reports non-interactively.

## What has NOT been done

- No edits yet to `rtl/nds_membus7.vhd`, `rtl/nds_membus9.vhd`, or
  `rtl/nds_card.vhd`. None of these three files are claimed by either
  Agent A or Agent B in `COORDINATION.md`'s file-claims table — claim
  them there before editing, and post findings/diffs to that log per the
  established convention so the other concurrent sessions don't collide.
- No isolated single-entity diagnostic build has been run yet (the fast,
  cheap way to bisect the membus7/9 mystery without a 45-70 min round
  trip each time).
- `nds_cache9`'s BRAM restructuring hasn't been started — it's understood
  well enough to scope but the actual redesign (per-way separate storage)
  hasn't been attempted.
- `nds_card`'s "same disease as cache9" theory is inspection-based, not
  confirmed by an isolated build.
- Haven't tried disabling the aggressive physical-synthesis settings to
  see if the raw resource numbers change — but this is expected to be a
  dead end and probably not worth trying: the *raw* Analysis & Synthesis
  numbers (before any Fitter-stage physical optimization even runs)
  already match the Fitter's numbers almost exactly, which is what
  originally ruled out "it's a Fitter duplication artifact" in the first
  place.

## Options going forward (not prioritized, all worth considering)

1. **Isolated single-entity Quartus diagnostic for nds_membus7/9.** Build a
   throwaway top-level that instantiates only `nds_membus7` (or `nds_membus9`
   minus its `nds_cache9` child) with its ports tied off, run just
   `quartus_map` against it. Minutes instead of an hour per iteration;
   fastest path to actually bisecting which specific line/construct causes
   the blowup, by bisecting the file content itself (binary-search-comment-
   out sections) inside that fast loop. This is the most direct way to
   resolve the still-unexplained ~300K-ALUT mystery, which is the *larger*
   of the two problems by raw resource count.
2. **Restructure `nds_cache9`'s tag/data storage for BRAM inference.** Split
   the flat `way*N+set`-indexed arrays into 4 independent per-way arrays
   (or otherwise restructure so each cycle's access pattern is inferable),
   so Quartus can use M10K blocks instead of ~107.5K registers. Root cause
   is already understood and scoped; this is real design/redesign work on
   a cache (associativity, replacement-policy interaction, timing of the
   parallel-to-BRAM-friendly-serialized tradeoff), not a quick patch — and
   whoever does it should be careful not to change I$/D$ *behavior*, only
   its *storage implementation*, since correctness here has already been
   validated against melonDS by Agent B's Kirby run.
3. **Do both in parallel** — they're independent files/subsystems (no
   shared code, no dependency between fixing one and being able to fix the
   other), so there's no reason not to run the isolated-membus diagnostic
   and the nds_cache9 restructuring as concurrent work if two
   sessions/agents are available.
4. **Investigate `nds_card`'s likely BRAM-inference miss** as a third,
   probably-lower-effort task once the pattern from #2 is validated —
   possibly as simple as moving the `sram` array's read/write into its own
   dedicated process rather than restructuring anything architecturally.
5. **Not viable / not recommended:** targeting a larger device. MiSTer's
   main board is a fixed `5CSEBA6`; this isn't a build-setting choice.
6. **Already effectively ruled out:** dialing back
   `PHYSICAL_SYNTHESIS_EFFORT`/`ROUTER_TIMING_OPTIMIZATION_LEVEL` to get a
   "cleaner" number — the raw Analysis & Synthesis (pre-Fitter,
   pre-physical-synthesis) numbers already match, so less aggressive
   Fitter settings would only affect *placement/routing* of an already-
   oversized netlist, not shrink the netlist itself.

## Appendix: full source of the two mystery files

Both are reproduced here in full since they're short and the whole point is
"nothing in here obviously explains this" — worth an independent read
rather than trusting my summary.

### rtl/nds_membus7.vhd (319 lines, the simpler/worse-per-line-count case:
174,724 comb. ALUTs / 293 registers / 0 mem bits, ALL of it "own" logic,
no child instances)

See `rtl/nds_membus7.vhd` in the repo (full file, unmodified this session
except that it was *not* touched — included by reference, not pasted here
to keep this document reviewable; it's 319 lines, read it directly).

### rtl/nds_membus9.vhd (467 lines: 192,444 comb. ALUTs / 107,948 registers
total, of which the `nds_cache9` child alone is 61,143 / 107,500 — so this
file's *own* code is ~131,301 comb. ALUTs / ~448 registers / 0 mem bits)

See `rtl/nds_membus9.vhd` in the repo, same note as above.

### rtl/nds_cache9.vhd (418 lines: the understood BRAM-inference case)

See `rtl/nds_cache9.vhd`; the relevant storage declarations are at the top
of the architecture (`t_itags`/`t_dtags`/`t_idata`/`t_ddata`, ~lines 66-79),
quoted in full above in the "Shape 1" section.

### rtl/nds_card.vhd (490 lines: the suspected-same-disease-as-cache9 case)

See `rtl/nds_card.vhd`; the `t_sram`/`sram` declaration is at ~lines 120-121,
quoted above in the "Shape 1" section. The read/write sites are deep inside
the single big `process (clk)` starting ~line 166, specifically the AUXSPI/
EEPROM command handling around lines 268-298 (`sram_cmd` case, commands
`x"02"` write / `x"03"` read).

---

# RESOLUTION (Fable review, 2026-07-18)

## TL;DR: the mystery is solved, and there is no Quartus pathology

Shape 2 does not exist. Both symptom shapes are the same, single disease:
**deferred behavioral memories synthesized as register files with
asynchronous read ports.** The membus7/9 "pure combinational bloat" is the
LUT read-mux trees of memories whose flip-flops live in `nds_top.vhd` —
the per-entity table just books the flops and the muxes in different rows,
and the awk filter used to build this document's table dropped the row
that held the flops.

## The missing row

The filter `nds_top:inds\|ENTITY:INSTANCE$` matched only nds_top's
*children* and silently excluded **nds_top's own row**, which reads (map
report, "total (own)" format):

```
nds_top:inds   672,355 (116,661) ALUTs   1,206,370 (917,598) regs
```

917,598 registers of nds_top's *own* logic. That is also the answer to an
arithmetic anomaly this document reproduced without noticing: the fit
summary's 1,217,986 total registers vs. only ~285K accounted for in the
per-entity table. The other ~918K were in the filtered-out row all along.

`nds_top.vhd` declares exactly these behavioral arrays, all flagged by its
own comment "TCMs, ARM7-private WRAM: behavioral arrays (BRAM entities
land in M9)" (nds_top.vhd:21):

| Array | Decl | Size | Read style |
|---|---|---|---:|
| `wram7` (ARM7-private WRAM) | nds_top.vhd:330-331 | 16384 × 32 = 524,288 bits | async: `w7p_readdata <= wram7(to_integer(w7p_addr))` |
| `itcm` | nds_top.vhd:206,208 | 8192 × 32 = 262,144 bits | async (nds_top.vhd:771) |
| `dtcm` | nds_top.vhd:207,209 | 4096 × 32 = 131,072 bits | async (nds_top.vhd:772) |

Cyclone V M10K block RAM is **synchronous-read only**. An asynchronous
read of a signal array is un-inferable by construction — not a heuristic
miss, a hardware impossibility — so Quartus emits one flop per bit plus a
combinational read mux. The flops are booked to nds_top (where the arrays
are declared); the read-mux LUT cones get merged into the consuming logic
during technology mapping and are booked to **the entity that consumes
the read data**: the membuses.

## Arithmetic proof (all five numbers close exactly)

A 4:1-per-ALUT mux tree over an N-deep, 32-bit register file costs
(N/4 + N/16 + ... + 1) × 32 ALUTs:

| Predicted | Reported | Δ |
|---|---:|---:|
| wram7 read mux: (4096+1024+256+64+16+4+1)×32 = **174,752** | nds_membus7 = 174,724 | 28 |
| itcm 87,392 + dtcm 43,680 = **131,072** | nds_membus9 own = 131,301 | 229 (= the file's real FSM/decode logic) |
| flops 524,288 + 262,144 + 131,072 = **917,504** | nds_top own regs = 917,598 | 94 |
| cache9 storage 2048×32 + 1024×32 + 256×21 + 128×22 = **106,496** | nds_cache9 regs = 107,500 | ~1K (valid/LRU bits) |
| card sram 8192×8 = **65,536** | nds_card regs = 65,872 | 336 (control regs) |

nds_top's own 116,661 ALUTs are the *write side* of the same three
arrays: per-word, per-byte-lane enable decoders for 16384 + 8192 + 4096
words. membus7's 293 registers being "exactly its output ports" was the
tell: the file was never the problem.

This also retires every open question in the "possible angles" list:
no record-port pathology, no `process(all)` pathology, no cross-hierarchy
optimization mystery (the only cross-hierarchy effect is mux-cone
*attribution*, cosmetic), and no isolated single-entity diagnostic build
is needed — an isolated membus7 build with its ports tied off would in
fact have shown ~500 ALUTs and sent everyone hunting in the wrong file.

## Round-1 fixes (all mechanical, all cycle-neutral)

The repo already contains the proven vehicle: `rtl/SyncRamDualByteEnable.vhd`,
which inferred altsyncram/M10K correctly in this exact build for both
nds_vram (1.18M bits, 841 ALUTs) and nds_wram. Reuse it.

1. **wram7 / itcm / dtcm → SyncRamDualByteEnable** (nds_top.vhd +
   membus7/9 port timing). The timing trick that makes this cycle-exact:
   today the membus FSM registers `*_addr` at the accept edge and consumes
   data during the FINISH cycle (one cycle later). Replace "registered
   address + async read" with "combinational address + BRAM's internal
   address register": drive the store's address from `cpu_adr` in the
   accept cycle (gate on the same accept condition), and the sync-read
   data is valid in FINISH exactly as before. The address register moves
   *into* the M10K; no state-machine or handshake change.
2. **bios7 / brom, same shape** (`bios_data <= ROM(to_integer(bios_addr))`,
   nds_bios7.vhd:162). In the synth-diag build these collapsed to near-free
   constant LUT-ROMs (HLE image ≈ zeros), which is why no bios row appears
   in the entity table — but real hardware needs the retail images loaded
   at runtime via HPS ioctl, so they must become writable BRAM anyway.
   Size bios9's store to the real 4 KB (1024 words, log-confirmed retail
   hex size), not the 32 KB window — mirror the window in the address
   wiring.
3. **nds_card sram → its own two-line process.** The inference blocker is
   now identified precisely: the read at nds_card.vhd:292 targets
   `spi_data`, a register that is *also assigned from other sources in
   other branches* (e.g. `spi_data <= sram_status`, line 275) of the
   mega-process — an M10K's output register cannot have other drivers, so
   inference fails and the whole array falls back to flops. Fix: dedicated
   process (`if we then sram(wa) <= wd; end if; sram_q <= sram(ra);`) with
   a dedicated `sram_q`; set `ra` when the SPI byte exchange starts and
   latch `spi_data <= sram_q` when the `spi_busy` countdown expires — the
   countdown provides dozens of cycles of slack, so behavior is unchanged.
4. **nds_cache9 per-way split** — as already scoped in option 2 above
   (the one part of the original analysis that was fully correct): 4
   independent tag BRAMs + 4 data BRAMs addressed by set, all read in
   parallel with registered address, hit/way compare one cycle after
   issue. The membus already waits on `cresp_done`, so the handshake
   absorbs the pipeline change. Storage is ~106K bits ≈ 12 M10K + MLABs
   for the small tag arrays. Keep behavior identical (Kirby-validated).

Expected effect: −~1.09M registers, −~545K comb ALUTs. This alone takes
the design from 21.6× over to roughly 1.5–2× over on ALMs (see "What
round 1 does NOT finish" below) and is a prerequisite for everything else.

## The second problem this document didn't reach: the M10K budget

Block memory was already at 93% (5,267,605 / 5,662,720 bits) *before*
converting anything. The round-1 conversions add ~1.25M bits, and Agent
B's in-flight firmware widening (fw_ram 128 KB → 256 KB in NDS.sv,
already in the working tree) adds another ~1.05M on the next mainline
build. Naive total ≈ **7.57M bits = 134% of the device.** Conversion
without eviction just moves the fitter error from ALMs to M10Ks.

Current big consumers (map RAM summary):

| Buffer | Bits | Where | Verdict |
|---|---:|---|---|
| fb_top + fb_bot (2× 256×192×18bpp) | 1,769,472 | NDS.sv:753-754 | **evict to DDR3** via the MiSTer framework framebuffer path (ascal already reads DDR3; standard pattern in PSX/N64/ao486 cores) |
| fw_ram (firmware) | 1,048,576 (→2,097,152 after widening) | NDS.sv:373 | **evict to DDR3/HPS** — SPI-byte-paced, utterly latency-tolerant; Agent B already flagged it "an M9 knife-fight eviction candidate" |
| nds_vram (9 banks) | 1,179,648 | rtl | keep (latency-critical) |
| gpu2d ×2 (pal/oam/eng shadows) | 615,046 | rtl | keep for now |
| framework (ascal/OSD/gamma/…) | ~391,000 | sys | keep |
| shared WRAM | 262,144 | rtl | keep |
| round-1 additions (w7p/tcm/cache/card/bios) | ~1,253,000 | rtl | new |

Post-round-1 with both evictions: ≈ **3.70M bits = 65% of M10K capacity**
— comfortable, with headroom for round 2 and eventual 3D work.

## What round 1 does NOT finish (expectation-setting)

After round 1 the design still holds an estimated ~140K comb ALUTs and
~128K registers against a device with 41,910 ALMs (≈83,820 ALUT sites) —
i.e. likely still ~1.5–2× over, now dominated by the *same disease at
smaller scale* inside entities this document classified as "normal":

- **nds_gpu2d: 45K registers per engine** (90K total) — line/attr buffers
  as register arrays (`linebuf_objcol/objset/objwnd`, BG line buffers),
  plus a large slice of its 47K own ALUTs as their read muxes. Same
  medicine: per-line buffers → M10K/MLAB. This is round 2's main course.
- nds_sound: 11.2K ALUTs / 5.5K regs — per-channel state likely muxed the
  same way; audit after gpu2d.
- DSP blocks: 117 needed vs 112 present (map summary; the fitter clamped
  to 112/112). gpu2d takes 32/engine. A small trim or logic-implemented
  multipliers will be needed; revisit after rounds 1-2 change the picture.

Re-measure after round 1 before designing round 2 — ALM packing estimates
from ALUT counts are crude, and Quartus's optimizer gets smarter when it
isn't drowning in a million flops.

## MEASURED RESULTS (round 1 implemented and built, 2026-07-18)

The conversions above were implemented (see COORDINATION.md log) and built
as branch `synth-fitfix` (= the failed build's exact baseline `synth-diag`
@47a2103 + the fixes, so numbers are apples-to-apples; artifacts in the
synth-fitfix worktree's `build/artifacts/`, the originals here untouched):

| Metric | before | after | device |
|---|---:|---:|---:|
| ALMs (fitter estimate) | 907,086 (2164%) | **126,051 (301%)** | 41,910 |
| Combinational nodes | 684,092 | **123,637** | 83,820 |
| Total registers | 1,217,986 | **151,340** | — |
| Block memory bits | 5,267,605 (93%) | 6,333,611 (112%) | 5,662,720 |
| DSP | 112/112 (117 map) | 112/112 (117 map) | 112 |

Per-entity, the three "anomalies" collapsed to exactly the predicted sizes:
membus7 174,724 → **477** ALUTs; membus9-own 131,301 → **641**; nds_card
96,287/65,872 → **501/358** (+65,536 mem bits, altsyncram inferred);
nds_cache9 61,143/107,500 → **10,321/9,256** (+98,304 mem bits); nds_top
own 116,661/917,598 → **1,347/94**. Regression status: arm9_cache (the
self-checking cache exercise incl. write-back/clean/invalidate/staleness)
and arm9_island PASS; arm7_island/dual_boot in flight at time of writing —
see COORDINATION.md for final status.

The fitter still fails, as expected, on the two remaining fronts, both
already scoped above: **M10K at 112%** (the fw_ram + fb_top/fb_bot DDR3
evictions, −2.8M bits, land it at ~62%) and **ALMs at ~3x** (round 2:
gpu2d's 2×45K line-buffer registers and their muxes, then sound/misc, then
re-measure; DSP 117-vs-112 also needs a small trim). The 21.6x mystery is
closed; what remains is a normal, per-module diet.

## Suggested work split (respects COORDINATION.md claims)

Independent, parallelizable lanes:
- **Lane 1** (nds_top.vhd = Agent A's claim, + membus7/9 + bios stores,
  coordinate with Agent B whose generators own nds_bios7/9): conversions
  1-2. Biggest single win (−306K ALUTs, −918K regs).
- **Lane 2** (nds_card.vhd, unclaimed): conversion 3. Small, isolated.
- **Lane 3** (nds_cache9.vhd, unclaimed): conversion 4. Real design work.
- **Lane 4** (NDS.sv = Agents A+C mixed hunks): fw_ram + fb evictions to
  DDR3. Must land before or with round 1 or M10K overflows.
