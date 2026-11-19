# Clash migration boundary

This directory is a source-owned replacement for the small part of the MiSTer
framework that the NDS core instantiates directly. None of the checked-in RTL
carries a GPL license; it is written fresh to the interface and timing
contracts the framework's consumers rely on.

| NDS use | Current owner | Migration status |
| --- | --- | --- |
| `hps_io` | `nds_hps_io.sv` + `nds_hps_io_boundary.sv` | Replaced. `nds_hps_io` decodes the uio/fp command subset the core uses (config, joystick, status, gamma, analog, file transfer); SD and unused commands are answered with protocol-legal values instead of implemented. Differential-fuzzed against the framework reference by `clash/tests/run_hps_io_diff.sh`. |
| `video_mixer` | `Mister.VideoMixer` | Replaced in `NDS.sv`. The checked-in Clash-aligned core implements the NDS-active path: no scandoubler/HQ2x and `HDMI_FREEZE=0`. `gamma_corr` remains a deliberately tiny SystemVerilog island because it is a dual-clock RAM. |
| `video_freak` | `nds_clash_video_freak.sv` | Replaced in `NDS.sv`. Source-owned port of the integer aspect/scaling calculator (crop path present but inert, since NDS ties CROP_SIZE=0). Differential-fuzzed against a fresh reference by `clash/tests/run_video_freak_diff.sh`. |

The checked-in RTL in `rtl/` is the build input, so a Quartus build never
depends on a local Haskell installation. It mirrors the Clash source and is
kept beside it to make the exact hardware reviewable. Regenerate it with Clash
and check in the reviewed result whenever the Haskell changes.

To regenerate after installing Clash (the command may vary slightly by
Clash release):

```sh
cd clash
clash --verilog -isrc --outputdir rtl src/Mister/VideoMixer.hs
```

`nds-mister-clash.cabal` pins the source dependency range; `cabal build` is a
quick type-check before emitting HDL.

Run the smoke test from the repository root with
`sim/run_clash_video_mixer_tb.sh`. It exercises the checked-in core's CE
recovery and one-cycle output pipeline. (The stock framework relies on a
Quartus-accepted declaration order in `gamma_corr.sv` that Icarus rejects, so
the direct stock-vs-generated comparison belongs in the Quartus build.)

Differential fuzzers (deterministic, `SEED`-driven):

- `clash/tests/run_video_mixer_diff.sh` — mixer core vs the NDS-selected
  video_mixer branch. `CYCLES=250000 SEED=0xc001d00d` for a long run.
- `clash/tests/run_video_freak_diff.sh` — `nds_clash_video_freak` vs a fresh
  reference of the aspect/scale calculator.
- `clash/tests/run_hps_io_diff.sh` — `nds_hps_io` vs the framework hps_io
  reference over the core's command set.

The isolated dirty-tree Quartus integration build is
`clash/tests/remote_quartus_integration.sh` (default pod: `nds-quartus-clash-9`).

## Whole-core ARM9 boot witness

[`Nds.WholeCore.Arm9Slice`](src/Nds/WholeCore/Arm9Slice.hs) is the first
synthesizable CPU/bus slice, not a replacement for the shipping ARM9. It
executes the unchanged [`hs_gpu_arm9.S`](../sim/tests/hs_gpu_arm9.S) image
from `0xFFFF0000`. It decodes ARM and ARMv5T Thumb state with architected
predication: all fifteen conditions against NZCV, and a condition-failed
instruction retires with no register, flag, link or bus effect whatever its
encoding (only the `cond = 1111` space, apart from `BLX <imm>`, faults
before predication). Executed ARM forms: all sixteen data-processing
opcodes with rotated-immediate, immediate-shift (including `LSR/ASR #32`
and RRX) and register-shift operands and their shifter carry-out; Rd = PC
without S as a branch; MRS and MSR (see below); B, BL, BX, BLX register and
immediate; MUL, MLA, UMULL, UMLAL, SMULL and SMLAL; CLZ; SWI; single
transfers; and LDM/STM. Every ARMv5T Thumb format executes: the branch
formats (B<cond>, B, the BL/BLX prefix and suffix) are decoded directly and
every other format, Thumb SWI and BX/BLX Rm included, is rewritten into the
equivalent AL-condition ARM opcode for the one shared execute stage, with
R15 reading as pc + 4 (word-aligned for the PC-relative LDR and ADD). Thumb
therefore inherits the ARM flag, link, LDM/STM precheck and fault rules,
plus Thumb-only ones: LDMIA with its base in the list does not write back,
a hi-register ADD/CMP/MOV naming two low registers, BX/BLX with nonzero SBZ
bits, `BLX pc`, a BLX suffix with offset bit 0 set, BKPT, the undefined
B<cond> space and ARMv6 encodings fault 1. ADD/MOV to PC stay in Thumb with
bit 0 dropped. Interworking follows ARMv5: BX/BLX register, LDR pc,
LDM/POP `{.., pc}` take the state from bit 0 (an ARM target must then be
word-aligned or the fetch faults 2); ARM `BLX <imm>` always enters Thumb
(H selects the halfword), a Thumb BLX suffix always enters ARM at
`(LR + offset) & ~3`; BL/BLX links in Thumb carry bit 0. The ARMv5-only
behaviours (BLX forms, CLZ, interworking loads) and the vector base sit
behind one switch, `Arch` in `Arm9Slice` (`armV5`, `vectorBase`), so an
ARMv4T/ARM7TDMI configuration with vectors at 0 can reuse the slice; only
the ARMv5/high-vector configuration is built or tested.

Multiplies read every operand before writing any result, so Rd = Rm (Thumb
`MUL r0, r0`) and Rm overlapping RdLo/RdHi give the product, as on the
ARM946E-S. S sets N and Z from the 32- or 64-bit result and keeps C and V
(ARMv5). An R15 operand, RdHi = RdLo, or nonzero SBZ bits fault 1. All
forms share one 33x33 multiplier and one 64-bit accumulate adder.

Modes and exceptions: reset is SVC, ARM state, IRQ and FIQ masked (CPSR
`0xD3`). The modes are User, System, SVC and IRQ, with three R13/R14 banks
(User/System share one) and SPSR_svc and SPSR_irq. MRS reads T and the
mode. A privileged MSR may switch among the four modes and set or clear I
and F; in User mode an MSR to the CPSR writes only NZCV (other fields are
ignored, as architected). A CPSR write naming FIQ, abort, undefined or any
other mode, changing T, or setting Q/J or reserved bits faults, as does an
MSR with an empty field mask and any SPSR access in User or System mode.
The `IRQ` input is a level, sampled only at an instruction boundary: when
it is high and CPSR.I is clear, the CPU enters IRQ mode instead of fetching
(SPSR_irq <- CPSR, ARM state, I set, F kept, R14_irq <- next instruction +
4 in either state, PC <- `0xFFFF0018`, the DS high vector). An instruction
whose bus access or LDM/STM beats are in flight always completes first (a
Thumb BL prefix and suffix are separate instructions; the IRQ may come
between them, as on hardware), and an MSR or exception return that clears
I lets a pending IRQ in at the very next boundary. SWI (ARM or Thumb)
retires into SVC: SPSR_svc <- CPSR, ARM state, I set, F kept, R14_svc <-
the next instruction, PC <- `0xFFFF0008`. Exception returns are any
data-processing S form with Rd = PC (`SUBS pc, lr, #4`, `MOVS pc, lr`) and
`LDM {.., pc}^`, in SVC or IRQ mode, copying that mode's SPSR to the CPSR,
T included (bit 0 of a Thumb target is dropped); an SPSR outside the subset
faults there. There is no FIQ input and no undefined-instruction, abort or
FIQ exception: those encodings and modes fault 1.

Single transfers are LDR/STR, LDRB/STRB, LDRH/STRH, LDRSB and LDRSH with an
immediate or register offset (word/byte: any immediate shift, RRX taking C),
added or subtracted, pre-indexed with or without writeback or post-indexed.
A word LDR to R15 is an ARMv5 interworking branch. LDM/STM cover IA, IB, DA
and DB with or without writeback, in ascending register order; LDM with R15
returns the same way (so PUSH/POP `{.., pc}` work), and STM! that names its
base as the lowest register stores the original base. Writeback is applied
when the instruction completes. Faults with code 1 at the instruction, never
a chosen UNPREDICTABLE behaviour: writeback with Rn = R15 or Rn = Rd, Rm =
R15, writeback with Rm = Rn, LDRT/STRT, LDRD/STRD, nonzero SBZ bits, STR of
R15, byte or halfword loads to R15, LDM/STM
with an empty list, R15 base or STM of R15, LDM! with its base in the
list and STM! whose base is not the lowest register. Also not executed:
S with Rd = PC outside SVC/IRQ mode, user-bank LDM/STM `^`, register shifts
naming R15, and swaps. Unaligned single transfers fault 2 rather than
rotate.

Boot ROM fetch and literal reads share a 4 KiB external ROM window; supply
the aligned little-endian word combinationally from `BOOT_ADDR & ~3`. A
local 4 KiB block RAM begins at `0x02000000` and is also executable: a
fetch from it presents the address on the RAM's one synchronous port for a
cycle and decodes the word returned, so instructions are exactly the bytes
the guest stored (no separate instruction memory or cache; while a RAM
fetch runs `BOOT_ADDR` shows the RAM PC and is ignored). `STORE_VALID` reports the aligned
RAM address and full post-write word once per RAM store, including each STM
beat; `RETIRE_VALID` reports the instruction address (not pipeline-visible
R15) and opcode once per instruction, condition-failed ones included.
Neither output requires an acknowledgement.

The blocking link (the `GPU_*` ports) carries only single transfers. It
owns the `0x06xxxxxx` VRAM aperture, DISPCNT and DISPSTAT (`0x04000000-05`),
VCOUNT (`0x04000006-07`, reads only), TM0CNT-TM3CNT (`0x04000100-0F`),
AUXSPICNT (`0x040001A0-A1`), ROMCTRL and the game-card command bytes
(`0x040001A4-AF`), IME (`0x04000208-0B`), IE and IF (`0x04000210-17`),
POWCNT1 halfword/word, entirely GPU-owned VRAMCNT byte spans and the
game-card data port (`0x04100010-13`); every access must lie wholly inside
one span. Timers, IME/IE/IF and the game-card registers are not GPU
registers: they are routed for the devices `Arm9Soc` puts in front of the
GPU, and a target that does not implement an address must reply with an
error (the [CPU + VRAM display prototype](../fpga/mister_hs_gfx_slice/README.md)
replies fault to all of them and to DISPSTAT). LDM/STM never use the link:
every beat is route-checked before the first one issues, and a block with a
beat outside the boot ROM (reads) or local RAM faults 3 at that beat's
address with nothing transferred, so no burst or GXFIFO-style atomic scope
is implied. A request holds its original byte address, byte count, lane mask
and right-justified data until `GPU_REQ_VALID && GPU_REQ_READY`; only one
beat may be in flight. The target holds its right-justified reply until
`GPU_REPLY_VALID && GPU_REPLY_READY`; a write must also return a reply.
Transfers and observation pulses count only with `EN` high and `RST` low.
Reset clears CPU/link state, not RAM. Any adapter must discard pre-reset
replies before the next request. `FAULT` is sticky until reset:
1 = unsupported opcode (instruction address), 2 = alignment (including a
misaligned branch target, reported at fetch, and an unaligned LDM/STM base),
3 = unrouted address (including VCOUNT writes and link addresses in
LDM/STM), 4 = link reply error. WRAMCNT is never sent on the link.

Generate the isolated top with Stack and Clash 1.8.4:

```sh
cd clash
out=$(mktemp -d)
stack exec clash -- --verilog -isrc -fclash-no-escaped-identifiers \
  -outputdir "$out" -fclash-hdldir "$out/hdl" src/Nds/WholeCore/Arm9Slice.hs
```

Run `sim/run_clash_arm9_witness.sh` from the repository root. The generated
`nds_arm9_slice` and the pure `sliceStep` share CPU/router logic; both execute
the assembled witness against the same authoritative Haskell GPU service
used by the [product RTL witness](../docs/MILESTONES.md#m7-executable-reference-product-arm9-rtl-to-the-haskell-gpu).
The comparison is of ordered GPU accesses and committed RAM words, not
instruction/pipeline cycles. The GPU service itself is not generated HDL.
The slice has no ARM7, LCD schedule, DMA, CP15, cartridge boot, or board
integration; its IRQ input is tied low in this witness.

`sim/run_clash_arm9_isa.sh` is the CPU-only ISA check for two assembled
fixtures. [`hs_arm9_isa.S`](../sim/tests/hs_arm9_isa.S) stores 54 mailbox
words that must equal the hand-derived
[`hs_arm9_isa.expected`](../sim/tests/hs_arm9_isa.expected): a full
condition/NZCV truth table, arithmetic and shifter flags, loops, signed and
unsigned branches, BL/BLX/BX and MOV PC returns, a PC-relative jump table,
and condition-failed stores, loads (including unrouted and misaligned ones),
unimplemented forms and links that must leave no trace.
[`hs_arm9_mem.S`](../sim/tests/hs_arm9_mem.S) stores 46 words that must equal
[`hs_arm9_mem.expected`](../sim/tests/hs_arm9_mem.expected): every offset and
indexing form above, signed loads, LDM/STM in all four modes (base in the
list, STM! of its own base, a block ending at the top of RAM, a block from
the boot ROM), a recursive PUSH/POP subroutine, `LDR pc` returns and jumps,
and condition-failed transfers (including UNPREDICTABLE encodings) that
leave no register, memory or PC trace. It uses RAM words `0x30-0x3F` as
scratch and reads every scratch result back into the mailbox. The
independent oracle is the product `nds_cpu9` with only boot ROM and main RAM
attached ([`tb_arm9_isa_oracle.vhd`](../sim/tb_arm9_isa_oracle.vhd)); for
the ISA fixture it runs a `PRODUCT_ORACLE` build without one
condition-failed `MOVSNE pc, lr`, which the product core mishandles (r14_svc
reads 0 afterwards). The pure `sliceStep` and freshly generated Verilog run
those builds, the full ISA build, 25 variants that must fault exactly (each
hazard above, NV condition, misaligned PC and LDM base, SWP,
VCOUNT write, LDM/STM past RAM, into the link or onto the ROM) with no store
after the mailbox, and 7 that must hold one exact link offer (DISPCNT write,
VCOUNT read, post-index and register-writeback transfers, a timer write, an
IE read, a DISPSTAT write).

`sim/run_clash_arm9_irq.sh` checks IRQ exceptions on the composed
[`Nds.WholeCore.Arm9Soc`](src/Nds/WholeCore/Arm9Soc.hs), where
`Nds.WholeCore.Arm9Io`'s IME && (IE & IF) level drives the CPU's IRQ input.
The assembled [`hs_arm9_irq.S`](../sim/tests/hs_arm9_irq.S) stores 48
mailbox words that must equal the hand-derived
[`hs_arm9_irq.expected`](../sim/tests/hs_arm9_irq.expected): SVC/IRQ banking
of R13/R14 across MSR mode switches; a timer 0 overflow latched in IF but
held off by CPSR.I, then by IME and by IE; entries from a real timer chain
returning with `SUBS pc, lr, #4` and, for five free-running overflows,
`LDM {r0-r3, pc}^`; CPSR/SPSR seen in the handler and restored after it;
entry at the first boundary after the MSR that clears I with F kept; and
external IF sources raised by the harness while an LDR on the link waits
and at the first beat of an STM, both taken only after the instruction
completed. The independent oracle is the product `nds_cpu9` with the
product `gba_timer` and `nds_irq` on its I/O bus at half rate
([`tb_arm9_isa_oracle.vhd`](../sim/tb_arm9_isa_oracle.vhd) with `IRQ_IO`),
running a `PRODUCT_ORACLE` build that stops after the first 34 words. Its
handler-CPSR slots mask F and its first entry is checked only to resume
the right instruction within one instruction of the MSR, because the
product executes one more instruction after an MSR that clears I and, on
exception entry, loads the CPSR flags and F from the old SPSR of the target
mode instead of keeping them (seen directly for SWI in the Thumb gate
below; `nds_cpu9` sets the entered CPSR from that SPSR for IRQ too). The
pure `socStep` and fresh Verilog of `nds_arm9_soc` run the full build and
nine builds that must fault 1 at the instruction (SUBS pc and MRS SPSR in
System mode, MSR to FIQ mode, T, Q or an empty mask, user-bank LDM/STM `^`
in IRQ mode, and an exception return from an SPSR naming FIQ mode). The
harness raises its external IF sources only where the runner asks
(`--link-read`, `--store-irq ADDR MASK`, `--retire-irq PC MASK`) and fails
unless each one fired.

`sim/run_clash_arm9_thumb.sh` checks Thumb, interworking, multiplies, SWI
and the modes with three assembled fixtures and hand-derived mailboxes.
[`hs_arm9_thumb.S`](../sim/tests/hs_arm9_thumb.S) (46 words, CPU only):
every Thumb format with its flags (read by `BLX` to an ARM helper), MUL
with Rd = Rm, hi-register ops and `ADD pc`, PC-relative loads at both
halfword alignments, register/immediate/SP-relative transfers, STMIA/LDMIA
(base in the list), BL and `POP {.., pc}`.
[`hs_arm9_interwork.S`](../sim/tests/hs_arm9_interwork.S) (50 words, CPU
only): BX/BLX register both ways, ARM `BLX <imm>` with H = 0 and 1, Thumb
`BLX <imm>` from both halfword alignments (one whose computed target has
bit 1 set), `BX pc`, LDR pc/LDM/POP state switches, `MOVS pc, lr` into
Thumb through SPSR.T, all six multiplies with C/V kept and overlapping
operands, CLZ, SWI from ARM (comment field read back through R14_svc),
System and Thumb, the shared User/System bank and User-mode MSR.
[`hs_arm9_thumb_irq.S`](../sim/tests/hs_arm9_thumb_irq.S) (12 words, on
`Arm9Soc` with real timer 0 overflows): an IRQ pending at an exception
return into Thumb is taken before the first Thumb instruction (R14_irq =
next + 4, SPSR.T), a timer IRQ in a Thumb loop returns by `LDM {.., pc}^`,
and an IF bit the harness raises when a Thumb BL prefix retires is taken
between prefix and suffix, after which the suffix still links and lands
correctly. The product `nds_cpu9` (no I/O for the first two, timers and
`nds_irq` for the third) matches all 46 Thumb words, all 50 interwork
words of a `PRODUCT_ORACLE` build that first copies the CPSR into SPSR_svc
(the entry deviation above would otherwise show in the handler CPSR), and
the first 7 Thumb-IRQ words (it has no harness IRQ source); its handler
branches rather than using a condition-failed `SUBS pc`, which corrupts
the product's banks (the known `MOVSNE pc, lr` deviation). The pure model
and fresh Verilog of `nds_arm9_slice`/`nds_arm9_soc` run every image in
full plus 18 builds that must fault exactly (BKPT, undefined B<cond>,
two-low-register hi op, BX SBZ, `BLX pc`, odd BLX suffix, empty LDMIA,
STMIA base not lowest, an ARMv6 encoding, POP to a misaligned ARM target;
MRS SPSR and `MOVS pc, lr` in User mode, MUL to PC, MUL SBZ, UMULL with
RdHi = RdLo, SMLAL to PC, CLZ to PC, user-bank LDM `^` in SVC). Seventeen
CPU mutants (Thumb PC alignment, BL and Thumb BLX-register link bit 0,
ARM `BLX <imm>` ignoring H, Thumb BLX keeping bit 1, no load interworking,
returns ignoring SPSR.T, exception entry keeping T, MUL clearing C/V,
unsigned SMULL, Rd = Rm faulting, ARM-step SWI link, wrong Thumb IRQ link,
User MSR writing control bits, System with its own bank, LDMIA base
writeback, CLZ off by one) each fail the pure fixtures.

Size (Yosys 0.71 generic synthesis of the generated `nds_arm9_slice`:
`hierarchy; proc; flatten; opt; memory -nomap; opt; techmap; opt -fast;
abc; stat`, the 4 KiB RAM kept as one memory): 49,746 cells and 991
flip-flops before this Thumb/mode/multiply work, 99,644 cells and 1,156
flip-flops after; about 8,900 of the new cells are the 33x33 multiplier,
which an FPGA maps to DSP blocks. The extra flip-flops are the R13/R14
banks, SPSR_svc, T and the mode field.

`sim/run_clash_arm9_card.sh` checks the read-only NTR game-card slot,
[`Nds.WholeCore.Card`](src/Nds/WholeCore/Card.hs), which `Arm9Soc` puts
behind the router for `0x040001A0-A1`, `0x040001A4-AF` and `0x04100010`
(card requests never appear on the GPU outputs), with its transfer-done
pulse on IF bit 19. Register and command semantics follow melonDS
(`NDSCart.cpp`, `NDSCart/CartCommon.cpp`): AUXSPICNT and ROMCTRL masks,
cart reset held until ROMCTRL bit 29 after a raw power-up, block sizes 0,
4 and 0x100 << n bytes, a two-word FIFO behind ROMCTRL bit 23. Raw mode
answers 9F, 00 (header words at (addr + 4k) & 0xFFF) and 90; with
`CARD_DIRECT_BOOT` the slot powers up as melonDS's direct boot leaves it
(AUXSPICNT 0x8000, bit 29 set, main data mode) and answers B7 (address
masked to the image, below 0x8000 redirected to 0x8000 + (addr & 0x1FF),
wrapping inside its 4 KiB page) and B8. The image lives outside, behind a
one-request ready/valid word port (`CARD_ROM_*`), with the chip ID and
image mask as straps. Fail closed, as a link reply error: starts with the
slot disabled, in SPI mode, with ROMCTRL bit 30, with no cart or the cart
in reset, any other command (including the KEY1 entry 3C, which needs BIOS
keys) or an unaligned address; ROMCTRL writes during a transfer;
command-byte reads; data-port writes, non-word reads and reads with no
word ready. Not modelled: KEY1/KEY2 (KEY2 is transparent to software),
backup SPI, card writes, card DMA, ARM7 slot ownership (EXMEMCNT) and
cart-bus timing.

The assembled [`hs_arm9_card.S`](../sim/tests/hs_arm9_card.S) runs in a raw
build (reset release, 9F with the IRQ exception, a size-0 transfer, the
header, the chip ID, a header read wrapping at 4 KiB) and a direct-boot
build (B7 reads with the IRQ exception, redirected, mirrored, 0x400 bytes,
one wrapping at 4 KiB, B8). Its expected mailboxes
([raw](../sim/tests/hs_arm9_card_raw.expected),
[direct](../sim/tests/hs_arm9_card_direct.expected)) and image-address
streams come from [`hs_arm9_card_oracle.py`](../sim/tests/hs_arm9_card_oracle.py),
which also builds the synthetic 64 KiB test image (ASCII title, arithmetic
filler, no commercial data) and shares no code with the Clash model. The
product `nds_cpu9` with the product `nds_card`, timers and `nds_irq` on its
I/O bus (`nds_card` and `nds_irq` at the full clock, as
`nds_nitro_console_top` runs them) matches the words before the first
slice-only check (15 raw, 17 direct). Observed differences after that: its
00 ignores the header address and its direct-boot power-up AUXSPICNT reads
0; its source also reads B7 contiguously, without the 4 KiB page wrap,
which this gate does not exercise on it. The pure `socStep` and
fresh `nds_arm9_soc` Verilog match every word (19 and 22) and the oracle's
image-address streams (256 and 516 words) under image-store backpressure,
and 15 builds that must fault exactly.

`sim/run_clash_arm9_boot.sh` is the card-boot gate: the boot-ROM loader
[`hs_arm9_boot.S`](../sim/tests/hs_arm9_boot.S) runs a synthetic DS image's
ARM9 binary from RAM after copying it there through the game-card
registers. The image comes from
[`hs_arm9_boot_oracle.py`](../sim/tests/hs_arm9_boot_oracle.py): a
standard-layout cartridge header (title, game code, ARM9 ROM offset 0x8000,
entry, RAM address 0x02000400 and size at 0x020-0x02C, ARM7 fields empty,
Nintendo logo area and logo CRC zero, header CRC16 at 0x15E) and, as ARM9
binary, the assembled position-independent
[`hs_arm9_boot_payload.S`](../sim/tests/hs_arm9_boot_payload.S). The
launcher handoff is how the loader learns the header in main data mode,
where B7 cannot read it (it redirects below 0x8000): the launcher places
the image's own 0x200-byte header in the boot ROM at `0xFFFF0E00`, the role
a real BIOS plays by copying the header to `0x027FFE00`; no other image byte
is preloaded. With `CARD_DIRECT_BOOT` the loader checks that header's CRC16
and its fields against its limits (ROM offset >= 0x8000 in whole 0x200-byte
blocks, binary inside `0x02000400-0x02000FFF`, entry inside the binary),
copies the binary with B7 block reads (words past its end are drained, not
stored) and `BX`es to the entry with r0 = RAM address, r1 = size, r2 = CRC.
A raw-power-up build reads the header from the card itself with command 00,
checks its CRC16 and compares it word by word with the boot-ROM copy; there
is no raw-to-data mode transition (that needs KEY1). From the image bytes
alone the oracle derives each build's mailbox, the image addresses the slot
fetches and the exact sequence of instructions retired from RAM (the
binary's words from the entry to its first `b .`, which then repeats). The
pure `socStep` and fresh `nds_arm9_soc` Verilog match all of them under
image-store backpressure; the harnesses also require every word of the
binary to be stored before the first RAM retirement and every RAM
instruction to be the word the guest last stored at that address, and a
header with a bad CRC or an entry outside the binary must be rejected with
nothing run from RAM. This is a finite loader test, not a BIOS boot: no
KEY1 secure area, no ARM7 binary, no firmware, no game.

Today's observed slice gates (ISA, link reset, native `Nds.Gpu.Live` frames,
generated CPU + VRAM graphics) and their limits are listed in the
[M7 ledger](../docs/MILESTONES.md#m7-finite-slice-gates-observed-2026-11-18-not-acceptance);
M7 remains not accepted.

## 3D inversion

The 3D path is moving into Clash and the 2D path is moving to the ARM; see
[the inversion plan](../docs/GPU3D_CLASH.md). Since 2026-11-16 this tree is the
single canonical `Nds.Gpu3D` source: the complete model, oracles and gates were
imported from `Nitro_DarkSide-clean` commit `20dca93` (see the plan's canonical
source and hash sections). The first block is the exact
melonDS edge walk in `src/Nds/Gpu3D/Slope.hs`, gated on the host by
`tests/run_slope_check.sh`. The flat triangle fill is `src/Nds/Gpu3D/Raster.hs`,
gated by `tests/run_raster_check.sh`. The streaming top is
`src/Nds/Gpu3D/Flat.hs`, gated under Clash simulation by
`tests/run_flat_check.sh`, with the exhaustive row-union gate in
`tests/run_flat_property.sh` and the reciprocal-table gate in
`tests/run_recip_check.sh`. The depth interpolator is `src/Nds/Gpu3D/Depth.hs`,
gated by `tests/run_depth_check.sh` against the production `Interpolator` and
`Slope` classes. `Nds.Gpu3D.Flat` carries FinalZ and the raw depth-interpolator
endpoints on every span; its gate compares every expanded pixel against
`rasterTriFinalDepth`. `Nds.Gpu3D.Frame` is the depth-tested frame model;
`tests/run_frame_check.sh` renders directed and seeded random frames through the
production `RenderFrame` and compares all 49,152 pixels on colour and final
depth. `Nds.Gpu3D.DepthPipe` is the streaming depth engine (Clash top
`nds_gpu3d_depth`); `tests/run_depth_pipe_check.sh` runs it against a
behavioural memory and compares the framebuffer and every depth word.
`tests/run_pixel_gate.sh` type-checks every module, runs the 2D checks first,
then the cheap 3D checks and the melonDS oracle gates last. Run it with the
local vendored fork explicit:

```sh
MELONDS_DIR=$PWD/third_party/melonDS clash/tests/run_pixel_gate.sh
```

No Quartus build is attempted until those gates are green.

The native toolchain is `stack` with `stack.yaml` (GHC 9.6.6, Clash 1.8.4). The
gate needs no Clash install: the pure model is base-only. Synthesis uses
`stack exec clash -- --verilog -fclash-no-escaped-identifiers ...`; without that
flag Clash emits names Quartus rejects as illegal. This M3 import carries only
`rtl/nds_gpu3d_geometry.v`, which the geometry co-simulation gate replays under
iverilog; the remaining generated Verilog (`nds_gpu3d_slope.v`,
`nds_gpu3d_flat.v` and its `_enc_` include, `nds_gpu3d_shade.v`,
`nds_gpu3d_gxfront.v`, `nds_gpu3d_polygon.v`, `nds_gpu3d_raster.v` and the
composed `nds_gpu3d.v`) stays in the sibling workstream until a fit is run.

The whole 3D engine is in Clash, block by block, each block a pure model gated
against melonDS plus a Clash entity gated against that model:

| block | model | gate |
| --- | --- | --- |
| GX registers and FIFO, GXSTAT, IRQ, DMA | `Nds.Gpu3D.GxFront` | `run_gxfront_check.sh` |
| geometry commands, matrix stacks, lighting, box/pos/vec tests | `Nds.Gpu3D.Geometry` | `run_geometry_check.sh` |
| primitive assembly, culling, clipping, RAM, VBlank sort | `Nds.Gpu3D.Polygon` | `run_polygon_check.sh` |
| the whole render path, every frame feature | `Nds.Gpu3D.Render` | `run_render_check.sh` |
| all of the above composed, ARM9 MMIO to output lines | `Nds.Gpu3D.Chip` | `run_chip_check.sh` |

Each block's hardware entity is gated against its model in Clash simulation
(`run_gxfront_check.sh`, `run_polygon_hw_check.sh`, `run_geometry_hw_check.sh`,
`run_raster_hw_check.sh`), and the block-level Quartus fits are
`tests/remote_quartus_block.sh <block>`.

`Nds.Gpu3D.Render` replaced `Nds.Gpu3D.Scene`, which modelled only the top
layer of triangles with no anti-aliasing, edge marking or fog. Gouraud, textured
and translucent frames still gate through `tests/run_scene_check.sh`, with unit gates
`tests/run_attr_check.sh`, `tests/run_texel_check.sh` and
`tests/run_shade_check.sh`.

`tools/gx3d_oracle` is the headless melonDS raster oracle. It constructs
polygons directly, calls the production `SoftRenderer3D::RenderFrame`, and writes
the 256x192 RGBA buffer, so the Clash rasteriser can be compared against the
same code the hybrid core runs. `tools/gx3d_oracle/gen_main.py` generates the
oracle from the vendored headers so layout constants cannot be retyped wrong.

## 2D trace checkpoint

Milestone status (M0–M6 host evidence and the separate M7 boundary) is tracked in
[`docs/MILESTONES.md`](../docs/MILESTONES.md).

`Nds.Gpu2D.Trace` replays ordered NSD2 input snapshots and memory deltas;
framebuffer and engine oracle records are delivered on a separate callback and
are never renderer inputs. The production trace format remains v9 by default.
The opt-in v10 stream adds sprite-phase input snapshots, display/capture/FIFO
state and oracle-only engine lines. Opt-in v11 additionally brackets display
capture and reports oracle-only changed VRAM chunks and lifecycle flags.
Normal CPU/DMA deltas update both replay shadows; Haskell capture writes update
only the renderer shadow, and oracle capture deltas update only the expected
shadow. The trace renderer carries each sprite buffer between its preparation
and composition phases. Existing live HGS receivers remain v9-only and reject
newer versions rather than discarding their phase information.

The following commands were run on the NTR EVA cartridge with the local
vendored melonDS and its default uncached software renderer:

```sh
sim/melonds_tracer/build-fbdump-vendored.sh
mkdir -p /tmp/nds-v11-capture
sim/melonds_tracer/build-vendored/melonds_fbdump --direct \
  --trace2d /tmp/nds-v11-capture/ntr-v11.nsd2 --trace2d-provenance \
  '<path to your NTR test cart>.nds' \
  /tmp/nds-v11-capture/top.txt 124 /tmp/nds-v11-capture/bottom.txt \
  2>&1 | tee /tmp/nds-v11-capture/run.log
runghc -iclash/src clash/test/TraceCheck.hs
ghc -O2 -outputdir /tmp/nds-trace-ghc -iclash/src \
  clash/test/TraceCompare.hs -o /tmp/nds-trace-compare
/tmp/nds-trace-compare /tmp/nds-v11-capture/ntr-v11.nsd2 \
  /tmp/nds-v11-capture/haskell 34 71 84 87 90 97 108 116 120 123
for f in 34 71 84 87 90 97 108 116 120 123; do
  for screen in top bottom; do
    python3 sim/tests/compare_fb.py \
      "/tmp/nds-v11-capture/haskell/frame-$f-$screen.txt" \
      "/tmp/nds-v11-capture/$screen.txt" --rtl-frame 0 --mds-frame "$f"
  done
done
```

Observed: all ten selected frames reported 192 lines, zero mismatching
pixels and zero unsupported lines against trace framebuffer records; all 20
independent direct-dump comparisons printed `PASS: pixel-perfect (256x192)`.
The v11 trace is 162,915,000 bytes and contains ordered register/memory and
capture provenance records. The Haskell replay compared 192 capture lines,
49,152 independently generated VRAM writes and two lifecycle events without a
capture mismatch; the replay including rendering took 22.54 seconds in the
observed run. The directed replay regression also rejects missing, extra and
wrong capture writes and checks CPU-delta ordering and same-bank feedback.
The changed-chunk oracle checks observable resulting bytes, not individual bus
write events: it cannot distinguish an extra no-op write or a missing write of
an unchanged value. Write-sensitive dirty-state or capture effects therefore
need separate event-level coverage; no bus write-event parity is claimed.
Artifacts are under `/tmp/nds-v11-capture`.

This is the M1 cartridge checkpoint, **not** exhaustive DS feature proof.
Frame 120 in this v11 check uses recorded melonDS 3D scanline input; the
separate v12 M4 check below replaces it with independently generated Haskell
3D. M2 additionally has both-engine BG/sprite/composition and capture oracles,
including combined multi-line state; these remain finite directed/seeded
coverage, not all possible register histories. Video mode 7 fails explicitly.

The chip-hardware narrow regression was also run after fixing response-tag
ordering, render-table start pulses, testbench memory timing, byte enables and
statistics aggregation:

```sh
KINDS=tiny SEQS=0 FUZZ=0 STOP_ON_FAIL=1 clash/tests/run_chip_hw_check.sh
```

It reported 84 operations, one frame, 49,152 pixels compared, zero
mismatches and `1 cases, 0 failures`. The directed arbiter/table check reports
`chip arbiter response tags and render-table pulse: passed`. These are narrow
checks, not a claim that the complete chip or pixel gate passes.

### Post-import chip-hardware corrections

The initial full pixel gate's composed-chip failure is historical evidence
(`/tmp/nds-m3-pixel-gate.log`), not the imported model's acceptance result.
Repairs made after import include lossless arbiter response-tag ordering,
one-shot render-table start, correct checker memory timing/byte enables,
read-lane/address alignment, VCOUNT abort tracking, statistics accumulation
and IF acknowledgement against live FIFO state. No C++ renderer is used as
the Haskell implementation.

The final directed failures had three distinct causes:

- `RasterHw/Front.hs`: a 2,048-polygon count wrapped to zero when narrowed
  to 11 bits before calculating scanner words. The addition now widens to
  13 bits before `(count + 3) >> 2`.
- `RasterHw/Setup.hs`: backwards-Y edges need signed offsets, reciprocal,
  interpolation products/divisions and coverage. The shared unsigned DSP
  now takes magnitudes and restores signs at the signed consumers. The
  perspective denominator retains production's Word32 wrapping and the
  setup divider supports all 32 divisor bits.
- `ChipHwCheck.hs`: a stalled pending write can finish its comparison
  before a following display event, but a current VBlank/render/frame-end
  must still drain normally. Releasing every stalled op prematurely skipped
  five VBlank drains and caused ten status/DMA mismatches; restricting the
  exception to `OWrite` preserves the actual order, without tolerances.

Observed narrow checks with those fixes: stall first 442 operations,
6,240 cycles, 0 mismatches; strips first 198 operations, two frames,
98,304 pixels, 0 mismatches. An earlier full overflow rerun with the scanner
fix compared 17,861 operations, three frames and 147,456 pixels with
0 mismatches. The final default chip-only acceptance is recorded below;
no unrelated full pixel suite was rerun. Import-time versus corrected-source
hashes and the historical generated-RTL/board limits are recorded in
[`docs/GPU3D_CLASH.md`](../docs/GPU3D_CLASH.md).

### Free-running burst reference contract

The first post-raster-fix default run (`/tmp/nds-chip-final.log`) passed the
15 non-burst directed cases, then failed burst/random status/DMA assertions.
Its first burst divergence was op 98: synthetic per-op entries `0x31` versus
`0x7`, DMA `0x1a` versus `0x5`. That reference froze geometry between `+`
accesses while the actual hardware kept running, and the checker omitted
command/DMA pulses outside its drain phase. It was not a valid burst clock
schedule; the stopped run is not acceptance evidence.

`ChipHwReference` now advances independent FIFO, geometry and polygon models
on the actual transaction schedule. Every accepted command **and parameter**
must match the independently queued head; every offered/transferred geometry
event is compared before the expected event reaches the polygon model.
Accepted-input/consumed/residual conservation is checked, including packed
NOP/zero iterations and deferred FIFO-full writes. IRQ/check/DMA pulses and
physical FIFO levels are independently scheduled over all phases; the
dedicated `FIFO_LT_HALF` level is checked every clock. IF samples that
physical timeline, with IF acknowledgement taking priority over a coincident
refill check. Terminal processing drains commands, events, reads, render work
and delayed pulses, except an independently established swap/power block.

Defined in-flight MMIO and display events retain their schedule. Only
documented undefined-busy geometry result ports are fenced. An overlapping
`RAM_COUNT` read must linearize monotonically to independently computed
old/new event-prefix states, including pending VBlank; stable values must
match exactly. Geometry test/stack status and results follow independently
predicted commands and verified control/event progress with bounded
liveness. This is **transaction-level geometry coherence, not an independent
proof of exact geometry microcycle latency**; no DUT status bit supplies its
own expected value.

Observed focused checks: the final geometry-schedule standalone check passed;
the terminal-burst prefix (97 ops), first RAM-count prefix (425 ops), and
packed-overflow/trailing-zero case (266 ops) each reported 0 mismatches.
With `IF_EVERY_CYCLE=1`, real input acknowledgements exercise every refill
clock: mode 1 at FIFO 128 and mode 2 at 1→0, including check-pulse coincidence.
The two cases report 151 operations, 141 GX entries, 73 DMA triggers,
1,988 cycles, 0 mismatches. Their fixtures are `/tmp/nds-if-mode{1,2}.txt`;
the packed case is `/tmp/nds-packed-zero.txt`.

Full directed burst with the final checker: **3,889 operations, 3,288 burst
operations, 3,289 GX entries, 1,951 DMA triggers, 12 frames, 589,824 pixels,
4,132,157 cycles, 0 mismatches**. Log: `/tmp/nds-burst-final.log`.

The affected 15 non-burst directed cases were then rerun once with that same
final checker: `tiny basic strips translucent effects clear stall power
overflow abort stack noswap regs carry dot`. They report **42,233 operations,
32,093 GX entries, 31,111 DMA triggers, 78 rendered frames, 4,423,680
compared pixel words, 28,920,400 cycles, 0 mismatches**. Together with the
disjoint burst case, all 16 default directed cases pass. The final directed
log is `/tmp/nds-chip-directed-final.log`; no earlier-checker result is
substituted for this affected-contract rerun.

The remaining-default batch initially passed all 16 random and seven fuzz
cases, then found two real `CLIPMTX_RESULT` reads returning zero in `fuzz8`
(ops 2,090 and 2,376). `GeometryHw.geoResultOut` had gated result RAM with
architectural GXSTAT busy, which includes a quiescent SWAP wait. The final
fix gates only unfinished control/tag/event work through
`geoTransactionIdle`; completed matrix results remain readable during swap
wait. A nonzero-matrix regression (26 ops / 708 cycles) gives exactly two
mismatches with the old binary and zero with the fix, preserving `0x4444`
and `0xbbbb` across SWAP. Logs: `/tmp/nds-swap-result-{before,after}.log`;
original fuzz failure: `/tmp/nds-fuzz8-before-resultgate.log`.

### Final M3 chip-only acceptance

**All 40 default cases pass: 16 directed, 16 seeded random and 8 fuzz;
0 mismatches.** They were observed in disjoint batches with the final
transaction checker, not by rerunning the entire pixel suite. The last fuzz
case was rerun after the localized completed-result/SWAP-wait fix; the other
39 accepted cases were preserved.

```text
144401 operations (141200 writes, 2011 reads)
116556 GX entries; 98634 DMA triggers; 23838 burst operations
215 rendered frames; 10665984 compared pixel words
24 aborted; 37 operations ending stalled; 33440 IRQ observations
8119 bus-wait cycles; 87463785 total cycles; 82991029 render cycles
40 cases, 0 mismatches
```

Evidence: `/tmp/nds-chip-directed-final.log` (15),
`/tmp/nds-burst-final.log` (1), and the first 23 passing cases in
`/tmp/nds-chip-remaining.log`, followed by
`/tmp/nds-fuzz8-result-final.log` (the corrected final case: 2,487 ops,
7 frames, 245,760 pixel words, 0 mismatches).
`/tmp/nds-chip-acceptance-summary.txt` aggregates those exact 40 records.
The remaining-batch log deliberately retains its original two fuzz8 failures;
it is not presented as a wholly green run.

The remaining default batch used
`KINDS=' ' REUSE=1 SEQS=16 FUZZ=8 STOP_ON_FAIL=1
clash/tests/run_chip_hw_check.sh`; the 15 named directed cases and burst
were run separately through the same checker. A fresh complete reproduction
is `clash/tests/run_chip_hw_check.sh`. No further check, Quartus/board run,
full pixel-suite rerun or generated composed-HDL update followed acceptance.

## v12 raw 3D replay and composition

v12 is opt-in (`--trace2d-raw3d` / `SetTrace2DRaw3DInputs(true)`); the v9
default and v11 records are unchanged. It adds ordered GPU3D power, RenderXPos,
VCount abort, VBlank, frame-end, render-start snapshots (VRAMCNT plus texture
and texture-palette mappings, preceded by changed memory deltas, with an
initial snapshot that never renders) and raw accepted GX bus writes (type 26).
The Haskell decoder delivers all of these in stream order with their 64-bit
timestamps and exact memory snapshot; `renderTraceDisplays` accepts an explicit
3D line and never reads the recorded oracle line itself.

Observed with the independent gate:

```sh
MELONDS_DIR=$PWD/third_party/melonDS clash/tests/run_m4_check.sh /tmp/nds-v12c/ntr-v12.nsd2
```

reported `type3 768 lines, 0 3D mismatches; screen 23808 lines, 0 screen
mismatches`. The production-C++ re-render of the same raw stream reported
`768 recorded lines compared, 0 mismatched, 0 skipped`. The directed/seeded
3D scene composition gate reported 6,720/6,720 3D lines and 6,720/6,720 screen
lines exact. The expanded 2D composition oracle reported 1,897 valid lines,
0 failures, plus 3 explicit mode-7 rejections (1,900 oracle lines total);
the BG oracle reported 177 cases, 0 mismatches, and capture 220 cases,
0 mismatches. The composition matrix includes both engines, four BGs, OBJ,
windows, priorities, blending, brightness and mosaic across full frames.
These are independent production-renderer comparisons, not exhaustive DS
state-space or cycle-level proof.

The focused production consumer `nds_gpu_replay` was migrated to accept both
v11 and v12 and reject unknown record types instead of skipping them. Both real
traces completed with 196,608/196,608 recorded 3D pixels, 12,189,696/12,189,696
framebuffer pixels and zero geometry-count mismatches. The live HGS encoder
remains v9-only and now fails closed with an explicit error on v10+ records
(`v10_rejection: passed` in the direct encoder test).

### Measured TARDIS work on a real trace

`clash/test/TraceTardisFull.hs` replays v12 and measures every line whose
engine-A BG0 is not 3D, including OBJ, windows, mosaic, display mode/brightness
and capture state through explicit sprite/window/capture/display tokens. On the
NTR trace through frame 123, 120 of 124 frames qualified (768 3D-active lines
were excluded and counted) and every one of 23,040 measured lines was
pixel-identical between the speculative and reference paths:

```sh
/tmp/nds-trace-tardis-full /tmp/nds-v12c/ntr-v12.nsd2 123
eligible frames=120 excluded_3d_lines=768
speculative: hits=23040 misses=0 fixups=0 prefetch=14025 demand=0 invalidated=13833 total_renders=14025
reference:   ... demand=23040 total_renders=23040
hit_rate=1.0
output_equal=True
wall_ms: speculative=6850.2 reference=10807.3
```

So on that slice the speculative path performed 14,025 line renders instead of
23,040 (39% fewer) and ran in 6.85 s versus 10.81 s (1.58x). The remaining
exclusion is 3D-active lines: their independent Haskell 3D cost is measured
separately by the M4 gate, not folded into this 2D cache number.

The independent M5 harness (public API, both engines, provider tokens from the
Haskell 3D line and composition) reports all 47,616 of 47,616 lines of the same
v12 trace pixel-exact, 29,586 renders versus 47,616, 100% hit rate and 29,202
evictions. Its 101-check stress suite passes, including
capacity/LRU/stale-plan rejection, key sensitivity for every memory, epoch,
register, latch, engine, line and the sprite/window/capture/display/3D tokens.
Our engine-A harness excludes 3D-active lines; the independent harness includes
them through `lk3D` tokens, and both agree on every measured line. Random
memory/register mutations,
missing/extra/wrong capture writes and same-bank feedback are covered by
`TraceCheck.hs`; sprite/window/capture/display token sensitivity is exercised
by the independent M5 harness.

Final M5 wall-clock comparison uses separate processes from trace-open
through fully forced output, including decoding, raw Chip replay, sprite and
capture preparation, hashing and GC. The exact variant skips cache-only
provider tokens; cached timing includes key/token work, planning, all
prefetch and demand rendering, and cache maintenance:

```sh
SPECULATE_MODE=cache clash/tests/run_speculate_measure.sh /tmp/nds-v12c/ntr-v12.nsd2 124
SPECULATE_MODE=exact clash/tests/run_speculate_measure.sh /tmp/nds-v12c/ntr-v12.nsd2 124
```

Observed: **36.129108 s cached versus 43.973591 s exact (1.21712x)**.
Both process all 124 frames / 47,616 lines and force 768 actual Haskell
Chip 3D lines. Cached work is 29,586 prefetch + 0 demand renders versus
47,616 exact renders (37.9% fewer), with 47,616 hits, 0 misses/fixups and
29,202 evictions. Diagnostic render-pass times are 14.339584 s cached /
21.904817 s exact; preparation components are not substituted for whole-run
time. Logs: `/tmp/spec-measure-cache-e2e.log` and
`/tmp/spec-measure-exact-e2e.log`.

Both independent runs produce `outputHash=147193483`; that hash is a
probabilistic cross-run check, **not** the pixel-exact proof. The separate
prepared-input comparison above checked all 47,616 lines bitwise. This is one
run per variant on one real trace, not a statistical benchmark or a claim of
parallel prefetch. The former unforced 0.000023 s 3D timer is invalid, the
older 1.51x is renderer-only, and shared-preparation arithmetic was not an
end-to-end measurement. No Quartus fit, regenerated composed HDL or board
result is established by these host checks.

These are **historical, pre-M6 measurements**, not a remeasurement of the
current tree. M6 corrected `TraceMemory` equality to compare complete immutable
regions after its identity fast filter: two `applyDelta` branches of one
parent must not alias an existing M5 `MemoryKey`. The original M5 cache/store
APIs remain; the current 11-case `SpeculateCheck` includes a red/blue palette
fork through the actual cached-pixel consumer. The benchmark was not rerun.

## Visible host viewer (closed-loop Haskell GPU)

```sh
tools/hs_gpu_view/run.sh CART.nds [FRAMES]
# Optional continuous diagnostic PNG, not enabled by default:
NDS_VIEW_SNAPSHOT=/tmp/hs-shown.png tools/hs_gpu_view/run.sh CART.nds
```

The default is **closed-loop Haskell GPU; melonDS CPUs/non-GPU peripherals**,
not a standalone Haskell SoC. `FRAMES` defaults to 1,000,000. The pipeline is:

```text
melonDS ARM interpreters / DMA / non-GPU peripherals
  <-> synchronous ABI2 <-> Nds.Gpu.Live / Gpu3D.Timed / Chip / Gpu2D
  -> actual Haskell pixels (NDSF/NDSE) -> native nds-view
```

Haskell owns GPU registers/results, FIFO/PIPE progress, GXSTAT/RAM_COUNT,
LCD/geometry deadlines, IRQ/DMA effects, all physical GPU memory and VRAM
mapping, palette/OAM, capture/FIFO and both displays. C++ GPU accesses route
to that authority; runtime guards reject stock GPU execution in this mode.
The independent stock renderer is an oracle in separate runs only.

`Gpu3D.Timed` is a timed **functional** executor, not `chipRun` drained at
each MMIO operation and not synthesized `ChipHw`. The host orders the two
interpreters' actual reported instruction timestamps and DMA accesses.
ABI timestamps are 33,513,982-Hz system cycles; every due deadline is serviced
at its exact timestamp before a same-time access. Coincident GX/LCD
deadlines require separate calls at the same time. Borrowed pixels/errors
are copied before applying potentially reentrant DMA effects.
Contract: [`sim/melonds_tracer/HsGpuAbi.h`](../sim/melonds_tracer/HsGpuAbi.h).
This is not a physical sub-instruction bus or independently exhaustive
geometry-microcycle proof, generated HDL or board acceptance.

ABI2 retains the eight-word request/sixteen-word reply and uses the last
request word as `instructionScope`. A real ARM9 handler's ordinary word
command write must first cause the observed stall. Only its remaining word
GX writes, with that same scope and exact raw core clock, can use operation 9
`IO_CONTINUE` at the unchanged instruction timestamp. Entries join the existing
front-end pending FIFO; register writes retain their normal decoder effects.
DMA/new instructions cannot use it, and ordinary stalled writes still fail.
The handler finishes before the next instruction is blocked; no new CPU
microcycle model, retiming, spill capacity or per-MMIO drain is introduced.

Closed-loop frames have **no inline oracle comparison**; the window says
Haskell is authoritative, never that `0/0` lines prove equality. Explicit
diagnostics remain separate:

- `run.sh --open-loop CART.nds [FRAMES]`: old raw NSD2 stream through
  `TraceView`; the CPU sees the stock GPU. Not closed loop.
- `run.sh --replay TRACE.nsd2`: recorded input, input disabled, not live.

The launcher builds the service at a distinct path per launch, never
overwrites a mapped library, and fails on build/service/protocol errors.
Unsupported modes (including JIT, DSi, firmware execution, savestates and
sleep) fail explicitly rather than selecting a stock-GPU fallback.
Only complete actual frames are emitted. A fatal or missing/truncated
terminal record, including an invalid UTF-8 terminal message, leaves the
last actual frame visible as **STOPPED, NOT LIVE / STOPPED (ERROR)**.
Closing the window ends the producer; its resulting broken-pipe diagnostic
is not a GPU-model failure.

Use `OUT=/tmp/hs-live` to choose the launcher's build/log directory.
It contains `build.log`, `melonds.log`, `nds-view.log` and
`service-path.txt` (plus `trace-view.log` in diagnostics).
Continuous PNG encoding/writing and CPU clock logs are **not** normal-viewer
work: PNG publication is opt-in through the existing `NDS_VIEW_SNAPSHOT`
environment variable; timing fixtures invoke `melonds_fbdump --clock-log`
explicitly. `FBDUMP` and `HS_GPU_LIBRARY` can select already built binaries.

### M6 observed scope

Independent state-authority fixtures match 69 stock-C++ records, then actual
LCD/IRQ/capture histories and four complete both-screen frames. A capture
request written after line0 survives line192 and really writes `0x801F` to
CPU-visible VRAM on the next frame, not merely a register-bit check.
The real service regression covers coincident GX/LCD time1584, CPU
GXSTAT/DISPSTAT/VCOUNT, IRQ/DMA, that late capture, and terminal/reset errors.

The v5 direct path compared 200 NTR frames (both screens) and all 4 MiB main
RAM with an independent stock-GPU control, with zero differences; that
control also matched the original stock schedule. A real ARM cartridge
alternating palette red/green every VBlank matched for 120 frames and its
CPU counter reached 120. Thirty-two directed real ARM bus/DMA/ARM7 variants
also matched. These are finite comparisons, not all cartridges or all
timing histories. Artifacts: `/tmp/m6-final/`, `/tmp/m6-run/`,
`/tmp/nds-m6-state-oracle/`; final scope is in
[`docs/MILESTONES.md`](../docs/MILESTONES.md#m6-closed-loop-pairing).

Whole-process timing in `/tmp/m6-final/drive.out` includes startup/output:
NTR 200: **16.1 s**; active-cart 120: **4.6 s** (about 26 fps).
The producer's internal totals were 15.91488 s and about 4.55 s; those are
not the complete process wall. NTR frame phases were approximately 64–91 ms
and the headless active scene approximately 36 ms/frame.
The slower new live-cache experiment (18.6 s / 6.6 s whole process) was
deleted, not shipped as an unused switch; original M5 TARDIS remains.
The retained improvement is linear line composition/3D-row construction.
No 60 fps or universal-gameplay claim follows from these measurements.

Actual native AX and the app-produced bitmap showed NTR
`PROGRESS[018/058]`, `[07-01] 3D ATTR FARCLIP`, `RESULT:FAIL TOTAL:FAIL`,
bottom white: the existing independent baseline failure was not hidden.
Native keyboard X (DS A) reached the real CPU input API as `FFE` at frame 1770,
then release `FFF` at 1772, acknowledged sequence 4.
A same-source own-window AppKit event fixture also drove touch
press (64,48), drag (192,144), release through a **single** production
`InputChannel` writer and the real closed-loop producer, with sequences 2/4/6
all acknowledged. This is programmatic event evidence, not a physical
pointer/DS4-button claim. Current GameController enumeration was
**no game controller detected**; existing mapping/notification code is
preserved. The normal-status-0 stream with its final message byte removed
produced an actual `STOPPED (ERROR)` window; all 98,304 visible RGB pixels
still equalled its last real frame 5.

The normal native active-input fixture, with no PNG/clock/profile/frame-file
diagnostics, completed 40 frames in **3.582 s** including startup and display
transport (about **11.2 fps**). Press/drag/release input-sampling ACKs were
67.464/191.405/128.511 ms, observed by a 10 ms polling fixture. With continuous
PNG plus clock diagnostics the earlier run was 3.74 s, with 162–168 ms
acknowledgements. These single runs do not establish a statistical speedup
or a PNG-root-cause claim; **27 fps is not a native-GUI measurement**.
Logs: `/tmp/nds-m6-ui-touch-direct/{harness,producer,wall}.log`.
These are producer sampling/apply acknowledgements, not measured physical
cartridge or visible-screen response latency.

The complete cartridge/performance runs used immutable v5
`f4283979e59f50fcac8eb821871d2d56f096d22df9b1d84651cac85df98ad664`
(direct, cache off). The pre-continuation cleanup ABI1 service is
`d80dd4d25a2432d07922e5560ec9fe1c02a9b4883c0cccb92e079bf1e5361c7b`;
after removing the failed experiment it passed the focused service,
11-case M5/fork and native/input checks. The 200/120-frame gates were not
repeated for that cleanup. Private ROM input was the requested
`__AAAA01_00.nds`, 2,696,840 bytes, not the older unsupported 8 MiB summary;
the source file was not modified.
Current scoped-continuation ABI2 service (local run artefact, built from
`clash/test/GpuService.hs` as `tools/hs_gpu_view/run.sh` builds it), SHA256
`fc8f9c9a4619519b0d569d9bb3c32c845f6d1d98b23fa3ca07e2ec4daec02d70`.
The targeted service selector also checks five admission guards and compares
pending POS/PUSH refill flags/results with the standalone chip. Timed status
preserves both retiring-command flags and newly asserted refill flags; shared
standalone counters still increment only when pending entries reach FIFO/PIPE.
The throughput figures above predate this narrow ABI2 correction; they were
not rebenchmarked.

Final ABI2 real-instruction proof: unchanged
`/tmp/m6-scen/atomic-watch.nds` crosses the full FIFO under SWAP with one STM.
Its original bit 0/14 polling remains. **Exit 0, all 44 RAM words stock-equal**:
GXSTAT `09000000` before / `06000100` settled; POS_RESULT
`1111,2222,3333,1000`; one matrix push. ARM7's VCOUNT 64 observer records
post-STM marker 0 plus `DECAFBAD`, then post-VBlank markers appear.
The four beats retain scope 263 / system 15302 / raw ARM9 clock 30604:
ordinary `400=71`, ordinary `404=22221111` asserts stall, authenticated
continuations `408=3333`, `40C=11`. No dropped/duplicated beat, new-instruction
retirement during stall, or instruction retiming is hidden by the witness.
Actual `/tmp/m6-scen/atomic-watch.final.{out,err,txn}` compares with
`atomic-watch.stock.out`; sources `atomic.s`/`atomic-watch7.s` are retained.
This is the new targeted ABI2 proof, separate from the prior v5 200-frame run.

Rebuild/run only the narrow permanent scope/refill/standalone guard check:

```sh
cd clash
mkdir -p /tmp/hs-continuation-check
stack --resolver lts-22.43 ghc -- -O2 -dynamic -fPIC -threaded -isrc -itest \
  -outputdir /tmp/hs-continuation-check test/GpuServiceCheck.hs \
  -o /tmp/hs-continuation-check/check
/tmp/hs-continuation-check/check --continuation-only
```


### Controls and acknowledgement

- GameController pad: east/south/north/west = DS A/B/X/Y (Nintendo layout),
  LB/LT = L, RB/RT = R, Menu = Start, Options = Select, d-pad/left stick =
  directions. The connected name/profile is shown in the window.
- Keyboard: arrows, X=A, Z=B, S=X, A=Y, Q=L, W=R, Return=Start,
  right Shift=Select.
- Mouse on the bottom screen = touch, aspect-fit pixels0–255/0–191.
  Drags clamp; release, view exit, focus loss and closing release touch.
  Top-screen clicks are ignored.

The 16-byte little-endian control record is `"NDSI"`, active-low 12-bit
`SetKeyMask` keys, touch (bit 31 pressed, x bits 0–7, y bits 8–15), sequence.
The producer calls actual `SetKeyMask`/`TouchScreen`/`ReleaseScreen` before
each frame, then acknowledges the latched/applied sequence at byte 16.
It has copied that frame's input, so clearing the viewer's short-input
latch cannot change the emulator input until its next frame poll.
This is a sampling acknowledgement, not completed-frame or game-response
evidence; short taps still cannot disappear between frame polls.
