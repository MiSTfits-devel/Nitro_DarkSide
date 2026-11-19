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
equivalent AL-condition ARM opcode for the one shared decode/shift/ALU path, with
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
behaviours (BLX forms, CLZ, interworking loads), the vector base and the I/O
map sit behind one record, `Arch` in `Arm9Slice` (`armV5`, `vectorBase`,
`ioMap`): `arm9Arch` is this slice, and `arm7Arch` is the ARMv4T/ARM7TDMI
configuration of the [two-CPU system](#two-cpu-system-arm7-ipc-and-shared-ram).

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
VCOUNT (`0x04000006-07`, reads only), the engine A background, scroll,
window and blend registers (`0x04000008-6F`), TM0CNT-TM3CNT (`0x04000100-0F`),
AUXSPICNT (`0x040001A0-A1`), ROMCTRL and the game-card command bytes
(`0x040001A4-AF`), IME (`0x04000208-0B`), IE and IF (`0x04000210-17`),
IPCSYNC, IPCFIFOCNT and IPCFIFOSEND (`0x04000180-8B`), POWCNT1
halfword/word, entirely GPU-owned VRAMCNT byte spans, the engine B
display registers (`0x04001000-6F`), IPCFIFORECV (`0x04100000-03`), the
game-card data port (`0x04100010-13`), palettes (`0x05000000-7FF`) and OAM
(`0x07000000-7FF`); every access must lie wholly inside one span. Timers,
IME/IE/IF, IPC and the game-card registers are not GPU registers: they are
routed for the devices `Arm9Soc` and `DualSoc` put in front of the GPU, and
a target that does not implement an address must reply with an error (the
[CPU + VRAM display prototype](../fpga/mister_hs_gfx_slice/README.md)
replies fault to all of them and to DISPSTAT, the engine A/B registers,
palettes and OAM; its gate checks those four kinds and IPCSYNC/IPCFIFORECV).
LDM/STM never use the link:
every beat is route-checked before the first one issues, and a block with a
beat outside the boot ROM (reads) or local RAM faults 3 at that beat's
address with nothing transferred, so no burst or GXFIFO-style atomic scope
is implied. A request holds its original byte address, byte count, lane mask
and right-justified data until `GPU_REQ_VALID && GPU_REQ_READY`; only one
beat may be in flight. The target holds its right-justified reply until
`GPU_REPLY_VALID && GPU_REPLY_READY`; a write must also return a reply.
Transfers and observation pulses count only with `EN` high and `RST` low.
Reset clears CPU/link state, not RAM: neither the local RAM nor the
register file (R0-R14, banked R13/R14, SPSRs; zero at power-up in the pure
model and the generated Verilog alike) is cleared by `RST`, and no fixture
reads a register before writing it after a reset. Any adapter must discard pre-reset
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
those builds, the full ISA build, 28 variants that must fault exactly (each
hazard above, NV condition, misaligned PC and LDM base, SWP,
VCOUNT write, LDM/STM past RAM, into the link, into OAM or onto the ROM,
the first word past the engine A registers and past the palettes) with no
store after the mailbox, and 11 that must hold one exact link offer
(DISPCNT write, VCOUNT read, post-index and register-writeback transfers, a
timer write, an IE read, a DISPSTAT write, and the last halfword, word or
byte of the engine A, engine B, palette and OAM spans).

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
(`--link-read`, `--store-irq ADDR MASK`, `--irq-before PC MASK`) and fails
unless each one fired. `--irq-before` makes the IRQ line first high in the
first cycle in which the instruction at PC is the oldest uncommitted one,
placed from the retire stream rather than from pipeline timing: a probe run
without that source finds the cycle in which the instruction just before PC
is reported retired (retire is reported the cycle after commit, in order,
so PC is still uncommitted then); the real run raises IF one cycle earlier,
because IF is a register, and then requires that same retire at that cycle
and the IRQ vector as the very next retire.

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
and an IF bit the harness raises with `--irq-before` at the BL suffix (the
second halfword of the Thumb BL at `bl_prefix`) is taken between prefix and
suffix, after which the suffix still links and lands correctly. The same
trigger passes on the frozen staged slice too; placing it before the
prefix instead gives R14_irq − `bl_prefix` = 4, not 6, so the mailbox
value forces the split to happen. The product `nds_cpu9` (no I/O for the first two, timers and
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

### Microarchitecture, measured size, clock and throughput

Register file: R0-R14, the banked R13/R14 (User/System, SVC, IRQ) and
SPSR_svc/SPSR_irq are 23 rows of a 32-word register file held in two block
RAMs with one shared write port (two synchronous read ports by
duplication). The row follows the mode register, so a mode change (MSR,
exception entry or return) swaps no data. PC and the CPSR fields are
flip-flops. Both copies power up zero in the pure model and in the
generated Verilog (a 32-word `initial`, which Quartus 17 accepts; the
4 KiB local RAM already uses the same form). The design never reads and
writes the same row in one cycle, so the RAMs' read-during-write behaviour
never matters. The pure `sliceStep` turns a violation into an error, which
fails every pure gate. It also forces its next state each step, so long
pure runs hold one state.

Instructions overlap in a pipeline of token stages, each a function from
its own input record to its own output record with a valid bit:

fetch → (Thumb expand) → decode → E1 → E2 → mem → retire

- decode classifies the (Thumb-expanded) opcode and presents register reads;
- E1 collects the operands and runs the one barrel shifter;
- E2 is the commit point: condition, the one adder/logic unit, flags, the
  register write, branches and PSR transfers;
- mem handles memory routes and beats, base writeback, the LDM^ restore,
  multiply accumulate and the SWI link.

Instructions commit in order, at most one per cycle, either in E2 or at
the end of the mem stage; E2 waits while the mem stage is busy, so LDM/STM,
multiplies and link waits hold the pipe. The hazard rules:
- **Fetch-ahead:** sequential prediction, one word per cycle from the boot ROM
  (unless a ROM load holds the port) and from local RAM through its
  synchronous port. A misaligned or unrouted fetch PC becomes a fault token,
  which faults only if it reaches commit.
- **Flushes:** a passed branch, BX/BLX, data processing to R15 (exception
  returns included) or any MSR in E2, and a load to R15, an LDM^ restore or
  SWI entry in the mem stage, redirect fetch and drop every younger token. The
  redirect follows from the class and condition. The target is never
  compared with the next PC: that compare after the adder was the critical
  path of the first pipelined fit.
- **Store into fetched code:** a local-RAM store whose word matches the PC
  of any fetched token or of the fetch in flight refetches from the
  instruction after the store.
- **Forwarding:** operands not yet read take a register-file write to their
  row, including one made in the same cycle (the register file reads one
  cycle ahead).
- **Interlocks:** E1 waits for:
  - an operand still owed by the mem stage (load-use, writeback, multiply,
    LDM) or by an E2 token that writes it only later;
  - a shifter operand that E2 is about to write;
  - flags still pending, for RRX.
- **IRQ:** sampled at the oldest uncommitted instruction (in E2, with the mem
  stage empty). Taking it drops that instruction and everything younger,
  writes SPSR_irq in that cycle and R14_irq (its address + 4) in the next,
  then fetches the vector. Nothing younger has committed by then.

Standalone Quartus 17.0.2 fits on 5CSEBA6U23I7 (no pins, all ports
virtual, fresh Clash netlists). This was a local run, not reproducible from
the repo: the fit used a local variant of `clash/tests/remote_quartus_block.sh`
with an added case for these tops. Worst setup and hold over the four corners:

| Top, constraint | ALMs | Registers | M10K (bits) | DSP | Worst setup | Worst hold |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| slice before, 33.51 MHz | 5,235 | 1,154 | 4 (32,768) | 3 | +4.434 ns | +0.138 ns |
| slice before, 67.03 MHz | 5,287 | 1,154 | 4 (32,768) | 3 | **−8.287 ns** | +0.134 ns |
| soc before, 33.51 MHz | 6,132 | 1,682 | 4 (32,768) | 3 | +4.816 ns | +0.164 ns |
| soc before, 67.03 MHz | 6,168 | 1,682 | 4 (32,768) | 3 | **−8.256 ns** | +0.154 ns |
| slice staged, 33.51 MHz | 2,432 | 1,183 | 6 (34,816) | 3 | +13.282 ns | +0.127 ns |
| slice staged, 67.03 MHz | 2,473 | 1,183 | 6 (34,816) | 3 | +1.737 ns | +0.144 ns |
| soc staged, 33.51 MHz | 3,432 | 1,711 | 6 (34,816) | 3 | +12.454 ns | +0.124 ns |
| soc staged, 67.03 MHz | 3,442 | 1,711 | 6 (34,816) | 3 | +1.008 ns | +0.152 ns |
| slice pipelined, 33.51 MHz | 3,275 | 1,360 | 6 (34,816) | 3 | +11.301 ns | +0.149 ns |
| slice pipelined, 67.03 MHz | 3,338 | 1,360 | 6 (34,816) | 3 | +0.828 ns | +0.164 ns |
| soc pipelined, 33.51 MHz | 4,254 | 1,888 | 6 (34,816) | 3 | +10.306 ns | +0.149 ns |
| soc pipelined, 67.03 MHz | 4,341 | 1,888 | 6 (34,816) | 3 | +0.859 ns | +0.164 ns |

Notes on the fits:
- **Timing:** every corner of the staged and pipelined fits has positive
  setup and hold slack at both clocks.
- **Memory:** the 4 KiB local RAM is four M10K blocks and the register file
  two. The multiplier is three DSP blocks.
- **Before:** the critical path was opcode → decode → register-file read
  mux → barrel shifter → ALU adders → register-file write mux, 21 logic
  levels in one cycle.
- **Staged:** the worst 67.03 MHz path ran from the decode token's class
  field through the shift-amount select and the barrel shifter into the
  shift token's operand register (10 levels).
- **Pipelined, first fit:** 3,444 / 4,522 ALMs, but **−0.323 / −0.643 ns** at
  67.03 MHz. The path ran from the E2 adder through a target ≠ next-PC compare into the
  flush of every younger stage. Deciding redirects from the class and
  condition instead (above) removed it without changing a single cycle of
  the differential test.
- **Pipelined, final:** the slice's worst 67.03 MHz path (14 levels) runs
  from the E2 token's class through its deferred-destination hazard
  vector, E1's advance and fetch's accept into the fetch register. The
  SoC's worst path (10 levels) is in the timers' register-write logic.
- **Store-into-fetched-code compare:** not on the critical path. It is
  absent from the 20 worst setup paths of both 67.03 MHz fits, which end at
  +1.047 ns (slice) and +1.190 ns (SoC). A scratch fit of the slice without
  it is 3,190 ALMs at +0.719 ns, so the compare costs about 150 ALMs and no
  clock speed.
- **For scale:** the product `nds_cpu9` core row in the integrated product fit
  (`artifacts/zero-arm-graphics/stage0-fit/NDS4MiSTer.fit.rpt`) is 4,164
  ALMs, 3,404 registers and 9 DSP. Its caches (`nds_cache9`) add 1,954 ALMs
  and 24 M10K, and the product ARM7 (`gba_cpu`) is 2,952 ALMs. The product
  cores implement far more: caches, CP15, the full ARMv5TE ISA,
  pipelining and savestates.

Pipelining changes no behaviour. The retire, store, link-offer and fault
streams are the staged core's. Every gate passes with every fixture `.S`
and `.expected` unmodified: all mailbox, fault, link-offer, card-address
and RAM-retirement checks, including the IRQ fixture's
free-running-timer slots. Two harness triggers that assumed the one-token
core's timing changed:
- **Thumb IRQ fixture:** its BL split now uses `--irq-before` (above).
- **Witness RTL harness:** it took the requesting instruction's PC from
  `BOOT_ADDR`, which now shows the fetch-ahead PC. It now takes that PC from
  the retire stream.

`run.sh --soc 10` now displays buffers 0..8 in its 10 frames (staged 0..3).
Its polling loops run at CPU speed, and every acceptance check passes.
The staged restructure added [`hs_arm9_banks.S`](../sim/tests/hs_arm9_banks.S)
(14 words: both SPSRs and all three R13/R14 banks live at once, RRX
carry-out from bit 0, matched by the product `nds_cpu9`) after two of 16
banking, writeback and flag mutants survived the earlier fixtures; all 16
fail the pure fixtures.

`sim/run_clash_arm9_pipediff.sh` is the randomized differential gate
([`Arm9PipeDiff.hs`](test/Arm9PipeDiff.hs)). It runs the pipelined
`sliceStep` against the frozen staged step
([`Arm9SliceStaged.hs`](test/Arm9SliceStaged.hs), commit fbb32bd, whose link
spans track the product's) on seeded boot-ROM programs. The programs mix:
- every data-processing and shift form, with conditions and flag writes;
- multiplies, CLZ, MRS/MSR (flags, mode switches, SPSR write then read);
- loads and stores in every addressing form, LDM/STM, link transfers and
  loads to PC;
- branches over blocks, BX/BLX into Thumb blocks with Thumb BL/BLX pairs;
- SWI from both states, with SUBS/MOVS or LDM^ exception returns;
- local-RAM code whose STR, STM beat or Thumb STRH rewrites the next one to
  three instructions;
- trampolines in the last ROM and RAM words, whose prefetch runs off the
  end (a wrong-path fetch fault that must not fault);
- in some seeds, a real-path fault: misaligned or unrouted target,
  undefined instruction, link reply error.

Both cores see random link stalls. On the pipelined core the IRQ line
rises at random cycles, and in half the seeds at every Thumb BL/BLX prefix
retire. Every entry must be legal:
- the line was high and CPSR.I clear in that cycle;
- the line was never low at entry;
- entry came within 200 cycles of the line being high and unmasked.

The oracle then takes each IRQ at the same instruction boundary. Retire,
store and link streams, IRQ boundaries and faults must match exactly.
Memory stays bounded at about 2 MB peak.

1,000 seeds pass: 478,810 instructions in 1,139,117 cycles, 34,356 of them
retired from local RAM, 1,306 Thumb BL/BLX pairs, 2,351 IRQs (676 between
BL halves; worst latency 48 cycles) and 151 seeds ending in a fault. The
gate fails unless a batch has IRQs between BL halves and local-RAM code.

Nine pipeline mutants each fail it (failing seeds out of 1,000):

| Mutant | Failing seeds | Also killed by fixtures |
| --- | ---: | --- |
| wrong forwarding source (A forwarded on D's row) | 1,000 | all |
| no flush after a branch | 1,000 | all |
| no flush after an exception return (E2 and LDM^) | 856 | interwork, irq, thumb-irq |
| store-into-fetched-code flush dropped | 815 | none |
| IRQ taken after the interrupted instruction committed | 711 | irq, thumb-irq |
| wrong-path fetch fault not flushed | 606 | none |
| IRQ only with an empty pipe, starving behind committing instructions (caught by the latency bound) | 552 | irq, thumb-irq |
| no load-use stall | 111 | isa, mem, thumb, interwork, irq, thumb-irq |
| no flush after MSR | 55 | interwork, banks, irq |

On the earlier design, an MSR flush only on mode changes survived
everything: SPSR readers forward from the write bus. The flush on every
MSR stays as specified.

Yosys 0.71 generic counts of `nds_arm9_slice` (`hierarchy; proc; flatten;
opt; memory -nomap; opt; techmap; opt -fast; abc; stat`, RAMs kept as
memories): 49,746 cells before the Thumb/mode/multiply work, 99,644 after
it and 30,239 after the staged restructure (not re-counted for the
pipeline).

Cycles per retired instruction, from the pure model. Rows cover the ISA,
memory, Thumb and interwork fixtures, the direct-boot card loader and
`run.sh --soc 10`. Link costs include the harness targets' reply latency.
Before and staged count each instruction from the previous retirement to
its own, since one instruction was in flight. Pipelined charges each cycle
to the oldest instruction in E2 or the mem stage. When both are empty
(refill after a redirect, fetch stall), the cycle goes to the instruction
that retired last, so a taken branch carries its refill and a load its
load-use interlock. Averages are cycles over instructions in every column.

| Class (ARM, fetched from the boot ROM unless noted) | Before | Staged | Pipelined | ARM946E-S, melonDS accounting, cached |
| --- | ---: | ---: | ---: | ---: |
| data processing | 3 | 5 | 1.20 (1.00 on the boot loader) | 1 |
| condition failed, branch not taken | 3 | 5 | 1.0 | 1 |
| branch taken / data processing to PC | 3 | 5 | 4.0 / 4.25 | 5 |
| multiply / long multiply | 3 / 3 | 6 / 7 | 2.5 / 3 | 2 |
| SWI | 3 | 6 | 5 | 5 |
| load from boot ROM | 4 | 7 | 4.0 | 3 |
| load / store local RAM | 5 / 5 | 8.5 / 8.2 | 5.4 / 4.2 | 3 |
| load I/O over the link | 5 | 8 | 5.0 | 8 |
| store VRAM over the link | 5.5 | 8.3 | 5.0 | 10 |
| LDM / STM, per beat | 5.0 / 5.3 | 5.9 / 6.4 | 4.9 / 4.8 | 1.7 / 1.8 |
| Thumb data processing, BL prefix | 3 | 6 | 1.15 / 1.0 | 1 |
| Thumb branch taken | 3 | 6 | 4.3 | 5 |
| Thumb load / store local RAM | 5 | 9 | 4.7 / 4.0 | 3 |
| any instruction fetched from local RAM instead | +2 | +2 | +0 | +0 |
| **average, boot loader (15,023 instructions)** | **3.10** | **5.17** | **1.82** | **2.03** |
| **average, native `--soc 10`** | **3.37** | **5.30** | **2.11** | **2.61** (pipelined mix) |

The ARM946E-S column assumes cached code and data, applying the rules of
melonDS's `ARMv5` class:
- a data-processing instruction costs 1 cycle;
- a branch adds a refill: 3 cycles for the target line, then 1;
- a load or store costs `max(C + D − 6, max(C, D))` with cached data 3;
- I/O and VRAM costs follow `SetARM9RegionTimings`: 32-bit I/O 8 and
  16-bit-bus VRAM 10 cycles at the ARM9 clock;
- multiplies cost 1 + 1.

Native's instruction mix depends on CPU speed, because the polling loops
run more often on a faster core. In the same 11.2 million cycles, 3.32
million instructions retire before, 2.12 million staged and 5.31 million
pipelined. That accounting puts the three mixes at 3.02, 2.13 and 2.61.

**How far from real time.** The boot loader's fixed work costs 30,469
cycles under that accounting: 455 µs on a real DS ARM9 at 67.03 MHz.

| Core | Clock | Time | vs a real DS ARM9 |
| --- | ---: | ---: | ---: |
| Before | 33.51 MHz (fails 67.03) | 1,388 µs | 3.05× slower |
| Staged | 67.03 MHz | 1,158 µs | 2.55× slower |
| Staged | 33.51 MHz | 2,317 µs | 5.10× slower |
| Pipelined | 67.03 MHz | 408 µs | 0.90× (on par) |
| Pipelined | 33.51 MHz | 817 µs | 1.80× slower |

The pipelined core is on par with that estimate rather than truly faster.
On the boot work, its taken branches cost 4 against the estimate's 5 and
its link I/O loads 5 against the DS bus's 8. Together these outweigh its
boot-ROM loads (4 against cached 3). The estimate is an accounting, not a
measured DS. Data processing and not-taken branches now take 1 cycle from
the boot ROM, as on the real core. A taken branch costs 4, the refill
through fetch, decode, E1 and E2.

Heap caps: every ARM9 and graphics runner compiles with `+RTS -M3g` and
links its checkers with `-with-rtsopts=-M3g`. `tools/hs_native_slice/run.sh`
(not an ARM9 runner) has no cap; its `--soc 10` evidence above comes from
running it through a local `stack` wrapper that adds the same flags.
`GfxSliceCheck` forces its per-tick state and log lines (strictness only).
Unforced, it ran out of a 3 GB heap even on the earlier slice; forced, its
peak residency was 126 MB.

## Two-CPU system: ARM7, IPC and shared RAM

This is a finite gate on the way to milestone M7, which stays **not
accepted**: a second CPU and the first two-processor system. It runs two
synthetic guests, not a game.

### The ARM7 configuration

`arm7Arch` (ARMv4T, ARM7TDMI) differs from `arm9Arch` in exactly these
points, all behind the `Arch` record:

- **No ARMv5 instructions.** BLX register and immediate, Thumb `BLX Rm`,
  the Thumb BLX suffix (`H = 01`) and CLZ fault 1, as undefined
  instructions.
- **No interworking loads.** LDR pc, LDM `{.., pc}` and Thumb POP `{pc}`
  keep the state and clear bit 0, as melonDS's `A_LDR`, `A_LDM` and `T_POP`
  do for the ARM7. In ARM state a target with bit 1 set then faults 2 at
  fetch. BX still interworks. Thumb BL is the v4T prefix/suffix pair.
- **Vectors at 0.** Reset is at 0x00000000, SWI at 0x08 and IRQ at 0x18;
  the 4 KiB boot ROM window starts at 0.
- **I/O map (`Arm7Map`).** The link carries the ARM7's timers, IME/IE/IF
  and IPC. DISPSTAT, VRAM, palettes, OAM, the engine registers and the
  game card are ARM9-only and fault 3.
- **Multiply flags.** MULS keeps C, as the product `gba_cpu` does
  (`mulboth`). melonDS clears C on the ARM7, and ARMv4 leaves C
  unpredictable, so no fixture reads C after an ARM7 multiply.

Everything else is shared with the ARM9: pipeline, register file, modes,
IRQ and SWI entry, fault codes, and unaligned accesses failing closed with
fault 2. [`Nds.WholeCore.Arm7Slice`](src/Nds/WholeCore/Arm7Slice.hs)
(`nds_arm7_slice`) has the same ports as `nds_arm9_slice`; `Arm9Slice`,
`Arm9Soc` and `Arm9Io` keep their ports.

**ARM9 unchanged by the split.** The `nds_arm9_slice` netlists from just
before and just after the split were run in lockstep under Verilator on
identical random inputs. The inputs were the seven ARM9 fixture images and
their 73 `.ifdef` variants, two seeds each, with random link timing, data
and faults, random IRQ, EN and resets, and every output was compared every
cycle. Over 160 runs (57.8 million cycles, 16.0 million retired
instructions, 52,997 link transfers, 2.57 million stores, 34,616 faults,
each followed by a reset) no output ever differed. This is a co-simulation
argument, not a proof: a yosys `equiv_simple` run, with the block RAMs
abstracted to ports, did not finish within 50 minutes.

The one deliberate ARM9 behaviour change in this step is the IPC spans in
the link map (above). Because of it the graphics prototype now replies
fault 4 to IPCSYNC and IPCFIFORECV, which two new negatives in
`sim/run_clash_gfx_soc.sh` check.

**ARM7 verification** (`sim/run_clash_arm7_isa.sh`):

- **Fixtures, three models.** Each runs on the product `gba_cpu` (with the
  product `nds_membus7`, `sim/tb_arm7_isa_oracle.vhd`), on the pure
  `sliceStep7` and on fresh `nds_arm7_slice` Verilog:
  - `hs_arm7_v4t.S`, 18 hand-derived words: SWI from ARM and Thumb landing
    at 0x08, LDR pc and LDM `{pc}` with bit 0 set staying in ARM, POP
    `{pc}` with bit 0 clear staying in Thumb, BX both ways, the Thumb BL
    pair and Thumb MOV pc;
  - `hs_arm9_mem.S` built with `--defsym ROM=0`, 46 words;
  - the register-bank fixture, 14 words.
- **Negative builds.** Five builds (BLX register, BLX immediate, CLZ,
  Thumb BLX register, Thumb BLX suffix) must fault 1 at the instruction,
  on the pure core and the RTL.
- **Link offers on the ARM7 map.** IPCSYNC, IPCFIFORECV, a timer and IE are
  offered on the link; DISPSTAT, VRAM `06800010` and OAM fault 3.
- **Differential run.** `sim/tests/hs_arm7_v4t_gen.py` generates 40 seeded
  programs that mix the v4T/v5 differences with ordinary ARM and Thumb
  code. The product `gba_cpu`'s mailbox for each program is the
  expectation, independent of this decoder. The pure core and the RTL equal
  it on all 40. The same programs on the ARMv5 slice fail all 40: every
  program's first case separates v4T from v5 by construction.

Mutants of `arm7Arch`, each a single change, were run against the v4T
fixture, the five negative builds and 20 generated seeds:

| Mutant | v4T fixture | Negatives faulting | Generated seeds failing |
| --- | --- | --- | --- |
| ARM LDR/LDM pc interworks | killed | 5/5 | 20/20 |
| Thumb POP pc interworks | killed | 5/5 | 19/20 |
| reset vector high | killed | 5/5 | 20/20 |
| SWI vector high | killed | 5/5 | 0/20 |
| Thumb BL suffix decoded as BLX | killed | 5/5 | 19/20 |
| BLX register allowed | passes | 2/5 (killed) | 0/20 |
| BLX immediate allowed | passes | 1/5 (killed) | 0/20 |
| CLZ allowed | passes | 1/5 (killed) | 0/20 |
| Thumb BLX suffix allowed | passes | 1/5 (killed) | 0/20 |

All nine are killed. "Negatives faulting" below 5/5 kills the mutant,
because each negative build must fault.

### `Nds.WholeCore.DualSoc`

[`DualSoc`](src/Nds/WholeCore/DualSoc.hs) (`nds_dual_soc`) puts the two
cores side by side, each with its own I/O router (timers and IME/IE/IF from
`Arm9Io`, so each CPU has its own IE/IF/IME). The two routers share
[`Nds.WholeCore.Ipc`](src/Nds/WholeCore/Ipc.hs). The game card sits on the
ARM9 side, and both cores reach one main RAM port.

**Clocking.** There is one 67.03 MHz clock. The ARM9 may step every cycle;
the ARM7 steps only on `ce7`, a phase bit that toggles every cycle, which
gives a fixed 2:1 ratio and 33.51 MHz. Both routers, the IPC block and the
arbiter run every cycle. Both CPUs' timers tick on `ce7`: melonDS runs the
ARM9's timers from `ARM9Timestamp >> ARM9ClockShift` with
`ARM9ClockShift = 1` on the DS (`NDS::RunTimers`), so they count at
33.51 MHz too. (`Arm9Soc` on its own is unchanged and still ticks every
cycle.)

Why one clock: the DS derives both CPU clocks from one oscillator at a
fixed 2:1, so there is no clock-domain crossing to model. One clock also
keeps the whole system a single pure step function, which the checker, the
generated Verilog and the arbiter's wait bound all rely on. The cost is
timing: ARM7 paths are timed at 14.9 ns, not 29.8 ns (see the fits below).

**Main RAM port and arbiter.** The memory sits outside the SoC behind one
port: `MEM_REQ_{VALID,WRITE,ADDR,LANES,DATA}` / `MEM_REQ_READY` for
requests and `MEM_RESP_{VALID,DATA}` for responses.

- A core issues at most two transactions per step, its read and then its
  write, and only after every transaction of its earlier steps has been
  answered.
- One request is granted per cycle. A request offered and not accepted is
  held unchanged until accepted. On contention the core not granted last
  wins (round robin), so a waiting core sees at most one grant to the
  other.
- Responses come back in order, at least one cycle later; a 4-entry queue
  tracks which core and kind each belongs to.
- Writes carry byte lanes. A byte or halfword store reads the word in one
  step and writes only its lanes in the next, so the other CPU's bytes in
  that word survive.
- Main RAM is 4 KiB at 0x02000000; any other address faults 3.
- Not provided: cross-CPU code coherence (one CPU rewriting code the other
  is running), and atomics (SWP faults 1 on both CPUs).

**IPC.** `Ipc` implements IPCSYNC, IPCFIFOCNT, IPCFIFOSEND and IPCFIFORECV
for both CPUs, with two 16-word FIFOs, the empty/full/error flags, and the
IRQs IF.16 (sync), IF.17 (send FIFO empty) and IF.18 (receive FIFO not
empty).

- **References.** It follows melonDS (`NDS::ARM9IOWrite16` and
  `ARM7IOWrite16` at 0x180 and 0x184, `ARM9IOWrite32` and `ARM7IOWrite32`
  at 0x188, `ARM9IORead16` and `ARM7IORead16` at 0x184, `ARM9IORead32` and
  `ARM7IORead32` at 0x4100000, `FIFO<u32,16>` in `FIFO.h`) and GBATEK ("DS
  Inter Process Communication").
- **Where they differ, GBATEK wins.** An empty receive returns the last
  received word, or 0 after the other side clears its FIFO; melonDS
  returns `FIFO::Peek()`. Clearing a non-empty send FIFO while CNT.2 is
  already set raises IF.17 by the edge rule; melonDS raises it only when
  the same write sets CNT.2.
- **Accesses with no defined result.** Byte accesses, and halfword
  accesses to SEND or RECV, get an error reply (fault 4) rather than a
  guess.
- **Same-cycle accesses.** When both CPUs access IPC in one cycle, the
  ARM9's access takes effect first.

`sim/run_clash_ipc_check.sh` compares `ipcStep` with the product `nds_ipc`
on random operation streams from both sides: 40 seeds, 54,746 operations,
no difference. It steers
around four documented differences:

- the product sets the error flag on a send while the FIFO is disabled;
- after a clear, an empty read on the product returns the last popped
  word;
- an ARM9 read while the FIFO is disabled presents the last popped word;
- a clear that turns the send-empty IRQ off in the same write still raises
  IF.17 on the product.

### Guests, oracle and results

`sim/run_clash_dual_soc.sh` builds a synthetic DS image
(`sim/tests/hs_dual_oracle.py image`) holding two binaries:

- the ARM9 guest `hs_dual_arm9.S`, at ROM 0x8000 and RAM 0x02000400;
- the ARM7 guest `hs_dual_arm7.S`, at RAM 0x02000900.

Boot runs through the card path:

1. The ARM9 boot ROM `hs_dual_boot9.S` checks the header CRC16 and fields
   (handed over at 0xFFFF0E00, as in the single-CPU loader).
2. It copies both binaries through the card with B7 reads.
3. It stores the ARM7 entry at 0x02000F00 and handshakes over IPCSYNC with
   the ARM7 boot ROM `hs_dual_boot7.S` at 0.
4. Both CPUs jump to their guests. IRQs dispatch through the RAM words
   0x02000F08 (ARM9) and 0x02000F04 (ARM7).

Each phase starts when the other CPU's IPCSYNC output reaches an agreed
value, so every recorded word is independent of memory timing:

- **A:** IPCSYNC IRQs both ways.
- **B:** 16 words ARM9 → ARM7 with the receiver's IRQ off, giving FIFO
  full; a 17th send sets the error flag. The ARM7 then drains under the
  receive IRQ, and the ARM9's send-empty IRQ fires.
- **C:** 8 words ARM7 → ARM9 drained under IRQ. An empty read sets the
  error flag, and a cleared FIFO reads 0.
- **D:** a 32-word buffer through shared RAM, then concurrent byte stores
  to the same words.
- **E:** a 64-word stream with flow control on the full flag.
- **F:** both CPUs increment their own byte of the same two words at once,
  with no handshake. A variable delay on the ARM9 sweeps their relative
  phase. Without it, the round-robin arbiter locks the two loops into a
  phase where no store's read-to-write window ever holds the other CPU's
  write.

The oracle is the Python script's own model of IPC (GBATEK rules) and of
the phases; it does not use the Clash code. It expects 27 ARM9 and 15 ARM7
mailbox words.

`clash/test/DualSocCheck.hs` (pure) and `sim/clash_dual_soc.cpp` (fresh
Verilog) each supply the memory with random latency and stalls. Both
assert:

- the memory protocol;
- bounded wait: at most one grant to the other core while one waits;
- mailbox order;
- that at least one byte write carried stale bytes outside its lanes, so
  the lane merge was really exercised;
- that the guests keep making progress.

Results on the final guests (`sim/run_clash_dual_soc.sh`). The pure
checker and fresh `nds_dual_soc` Verilog give identical cycle, step and
request counts in every setting:

| Memory setting | Cycles | ARM9 / ARM7 steps | Requests | Stale-byte writes kept |
| --- | --- | --- | --- | --- |
| latency 1 | 79,812 | 60,459 / 39,515 | 39,573 | 3 |
| latency 1–4, 30 % stalls | 110,614 | 59,256 / 39,581 | 37,370 | 5 |
| latency 2–12, 50 % stalls | 207,692 | 58,573 / 41,558 | 35,906 | 3 |
| latency 8–30, 60 % stalls | 439,195 | 58,239 / 48,151 | 35,333 | 5 |

Every run: 27 ARM9 and 15 ARM7 mailbox words equal the oracle, and at most
1 grant to the other core while one waited.

**melonDS as a second oracle.** `sim/melonds_tracer/main_dual.cpp`
(`melonds_dual`) installs the two boot ROMs as melonDS's BIOS images, so
IRQs dispatch through them. It places both binaries as the loader would
leave them and runs the system with melonDS's own scheduler. ARM9 slots
6–26 and ARM7 slots 0–14 equal the oracle. The card loader itself is not
run under melonDS: melonDS models the real cartridge protocol, not this
fixture's direct-boot strap.

**Mutants**, each a one-line change to the Clash source, under the pure
checker at latency 1 and at random latency 2–12 with stalls:

| Mutant | Change | Latency 1 | Random latency |
| --- | --- | --- | --- |
| arbiter starvation | contention always goes to the ARM9 | killed: the ARM7 waited through 2 ARM9 grants | killed (same) |
| lost FIFO word | a push into an IPC FIFO holding 5 words is not stored | killed: ARM7 slot 5 | killed: ARM7 slot 5 |
| wrong IRQ source | receive-not-empty raises IF.17, not IF.18 | killed: no progress, ARM9 11/27, ARM7 3/15 | killed (same) |
| stale shared-RAM read | each core takes its latched word instead of the response arriving that cycle | killed: ARM9 fault 1 at 0xFFFF0E04 | killed (same) |
| whole-word writes | stores ignore byte lanes | killed: ARM9 slot 22 (phase F) | killed: ARM7 slot 13 |

### Fits

These are scratch-copy fits with `clash/tests/remote_quartus_block.sh`
(5CSEBA6U23I7, isolated blocks with virtual pins, not a board build).
"Slow" is the 1100 mV model; the two numbers are 100 °C / −40 °C.

| Block | Clock | ALMs | Registers | M10K | DSP | Setup slack, slow (ns) | Hold slack (ns) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `nds_arm7_slice` | 33.51 MHz | 3,253 | 1,358 | 6 | 3 | +10.255 / +10.543 | +0.146 |
| `nds_arm7_slice` | 67.03 MHz | 3,291 | 1,358 | 6 | 3 | +1.307 / +1.266 | +0.156 |
| `nds_dual_soc` | 33.51 MHz | 9,060 | 4,878 | 4 | 6 | +10.079 / +9.972 | +0.163 |
| `nds_dual_soc` | 67.03 MHz (DS clocks) | 9,169 | 4,878 | 4 | 6 | +0.934 / +0.881 | +0.158 |
| product ARM7 `gba_cpu` (integrated product fit) | — | 2,952 | | | | | |

Notes on the table:

- **The ARM7's M10K** are its register file (2) and its 4 KiB local RAM
  (4). In the dual SoC main RAM is outside the block, so its 4 M10K are the
  two register files.
- **Virtual pins.** The dual SoC's ALMs include 597 that hold its 1,192
  virtual pins, which are mostly observation ports. Its registers include
  both IPC FIFOs, 1,024 bits held in flip-flops.
- **Against the product ARM7.** The Clash ARM7 is about 300–340 ALMs
  larger than `gba_cpu`. That figure includes its link, local-RAM and
  boot-ROM logic.
- **Critical paths at 67.03 MHz.**
  - Dual SoC: the worst path (11 levels, +0.934 ns) runs from the ARM9
    core's state through its IPC offer and the IPC accept (`take9`) into a
    FIFO entry. The worst ARM7 paths (+0.984 ns) run from the ARM7 core's
    state into the router/IPC reply registers.
  - ARM7 alone: the worst path (9 levels, +1.307 ns) is the pipeline's
    issue logic, state to state.
- **The ARM7 as timed.** In the dual SoC the ARM7 is timed at the 67.03 MHz
  period, 14.9 ns, though it steps only every other cycle. It closes there
  alone (+1.27 ns) and in the system (+0.98 ns on its worst paths).
- **What a multicycle constraint on `ce7` would be worth** (not applied).
  - A 2-cycle exception is valid only from `ce7`-enabled ARM7 registers to
    `ce7`-enabled ARM7 registers, on paths that do not pass through
    full-rate state (the arriving memory word, router replies). On those
    paths it adds one period, 14.9 ns of budget: the standalone ARM7 timed
    at 29.8 ns closes with +10.3 ns.
  - It would not raise the dual SoC's worst slack. None of the 20 worst
    paths is ARM7-internal: they are ARM9 paths, or ARM7 paths into
    registers that capture every cycle (router/IPC replies). Relaxing the
    latter would rest on the `ce7` gating of the ARM7's offers, which
    needs a per-path argument.

### Directed FIFO retirement boundary

[`sim/run_retire_boundary.sh`](../sim/run_retire_boundary.sh) runs the public
[`hs_retire_boundary.S`](../sim/tests/hs_retire_boundary.S) two-CPU fixture
on both wide and instruction-line-buffered generated SoCs. It takes a directory
containing both generated tops and never runs Clash itself. For example, from
the repository root, generate the tops from the checkout being tested:

```sh
out=$(mktemp -d)
(cd clash && GHCRTS=-M3g stack exec clash -- +RTS -M3g -RTS \
  --verilog -isrc -fclash-no-escaped-identifiers -outputdir "$out" \
  src/Nds/WholeCore/DualSoc.hs)
sim/run_retire_boundary.sh "$out"
```

The ARM7 queues three distinct words in the real IPC FIFO. The ARM9 executes
a condition-failed `IPCFIFORECV` load and branches over another, then consumes
the three words. The monitor requires the failed conditional to retire without
a pop, the skipped load never to retire, exactly three accepted receive
requests and retirements, and all three sentinel values in order. It raises
the external IF input once before the first receive while IRQ is masked, and
again after the second receive is accepted. The guest enables IRQ, handles and
acknowledges it, and records `LR_irq`; the monitor checks that the first
exception precedes the first receive, the second follows the second receive's
retirement, and both restart addresses are exact.

The test also requires a main-RAM instruction fetch of the line containing
the branch-skipped load before the branch retires: instruction read-ahead is
allowed, whereas the side-effecting IPC read is not. On the retimed snapshots
tested locally, wide and buffered both passed with one-cycle memory and with
nine-cycle responses plus request stalls. The stalled runs saw 3,870 and 273
held-request cycles respectively; the skipped instruction's line had four and
two accepted fetches before branch retirement. These are directed observations,
not a general proof of speculation or all interrupt timings; the IRQ source is
the host's `EXT_IRQ_SET`, not a guest-programmed timer.

The latest measured tops were generated from an **uncommitted** source snapshot
including shared-WRAM, retiming, instruction/data invalidation and drain, not
a published commit. Their SHA-256 hashes were
`ff721dc397934d8c8556468f1aaaa0db61cf0f8983ded578786e392dd6f89fde`
(wide) and `280308ca2ad4627616a6f22bc282ccbf92e3e615e78f0ca013326a4721118f53`
(buffered). The command above tests the selected checkout; it does not recreate
those hashes unless that exact source is available. Regenerate and rerun the
gate on the eventual clean-history candidate before attributing these results
to it.

The runner builds each Verilator model serially (`-j 1`). It caps native
process address space at 3 GiB where `RLIMIT_AS` is supported and checks the
simulator's peak resident memory against 3 GiB. Darwin does not support that
native address-space limit, so its compiler is not OS-capped; the peak-RSS
check is a monitored ceiling, not a hard OS limit.

### First retail direct-boot handoff: bounded Kirby probe

[`sim/run_clash_direct_handoff.sh`](../sim/run_clash_direct_handoff.sh)
runs a stock-loader start and a host-preloaded start against generated
Verilog. The legacy `nds_dual_soc` and both stand-alone CPUs keep their
original 4 KiB RAM windows and port contracts.
With no arguments it needs only the redistributable assembly fixture.

The local Kirby reference (`AKWE`) has these header ranges (ends exclusive):

| CPU | Cartridge offset | Main RAM section | Entry |
|---|---|---|---|
| ARM9 | `00004000` | `02000000..021886d8` | `02000800` |
| ARM7 | `00222a00` | `02380000..023a86a0` | `02380000` |

**First divergence:** with that header at `ffff0e00`, the unmodified
`hs_dual_boot9.S` computes and accepts the CRC, then writes **`e002`** to
`02000008` at cycle 24,227: ARM9 ROM offset below `8000`. Neither image
was read. This is a loader rejection, not an ISA fault. Lowering the
guard is not sufficient: main-mode B7 redirects addresses below `8000`
to `8000 + (address & 1ff)`. The stock loader also assumes a 1.25 KiB
destination window per guest, and the legacy CPU RAM decoder covers only 4 KiB.

**Requirement implemented in the host harness:** stage the *post-firmware*
sections by the header's actual offsets and lengths into a 4 MiB backing
store before releasing the CPUs, including the already-decoded ARM9 prefix.
This is the preload boundary in `sim/tb_top_frame.vhd::preload_main`;
melonDS [`NDS::SetupDirectBoot`](../third_party/melonDS/src/NDS.cpp)
materializes a 2 KiB decrypted prefix, then copies the remaining raw words
and the ARM7 section. The probe accepts an explicitly post-firmware image
with the two marker words, rejects a missing marker, and uses **no** BIOS
keys, KEY1 implementation, or B7 exception. The trampoline sets the visible
entry r12/sp/lr, writes WRAMCNT=3 and uses a real MCR to set ARM9 c1 to
`00012078` before branching. That value matches the local TRACE-enabled
reference build; the vendored `NDS::SetupDirectBoot` uses `00052078`.
Neither profile is a BIOS boot. The public fixture checks all 512 prefix words.

**Measured intermediate frontiers:** melonDS direct-boot traces start at
both header entries. After staging on **legacy** `nds_dual_soc`, ARM9 retired
three guest instructions matching the reference, then faulted 1 at
`02000a5c` (cycle 27) on its first CP15 control read. ARM7 faulted 3 at
`02380000` (cycle 31), before retiring a guest instruction: the host had
the bytes but the CPU could not route that address. With the wide CPU map
and before adding private WRAM, ARM7 fetched the actual word at `02380000`,
retired nine guest instructions and faulted 3 on `03800000` (cycle 71).
These are instruction-level checkpoints, not a firmware boot or a frame.

With a privileged ARM9 MRC/MCR c1 implementation (reset `2078`, not a
hardwired MRC result), the measured private run reached `02000a70` after
eight retirements: the **separate** MCR c7,c5,0 instruction-cache
maintenance operation. Nine ARM9 reference records matched including
the faulting word. Public controls cover writable and reserved bits,
MRC to NZCV, condition checks, low SWI vectors, privilege, invalid register
selects, ARM7 rejection and rejection of unsupported big-endian mode.
Architectural I/D cache contents and TCM mapping are not implemented.

MCR `p15,0,Rd,c7,c5,0` invalidates **only** the ARM9 instruction line,
prevents older outstanding fills from reinstating it, discards younger
fetched words and restarts at the following PC. A two-call public program
returns to a known resident physical line: a condition-failed MCR hits;
a condition-passed MCR causes a new demand. Independent `FetchLineCheck`
cases cover outstanding-fill invalidations, ARM7 isolation, DMA snoops
and reset. The following private frontier was fault 1 at `02000a74`
(`c7,c6,0` D-cache invalidate), nine prior retirements, ten matching records.

`c7,c6,0` can now retire under the explicit **D disabled, no resident
data** invariant. Every load reads its device or memory, there is no
dirty data to discard and `MCR c1` with C=1 faults. It does not evict the
instruction line. `c7,c10,4` drains the write buffer: this in-order core
has no posted writes and cannot enter commit past an unanswered store.
Specifically the RAM arbiter waits for the ordered **response**, not the
request grant; `Fabric` waits for the final `sdDone` on external stores.
An I/O store must complete its reply handshake in the memory stage. A
separate public guest delays visibility and acknowledgement of a byte
store for 41 clocks and an I/O halfword store for 29, then checks both
drain retirements, one write per target and a reread after an independent
data change. Other c7 selectors remain unsupported.
In the intermediate pre-MPU build the next fault was the MCR for
protection region 0 (`c6,c0,0`) at `02000a80`, after 12 guest retirements.

**ARM946 memory protection.** With c1.M=1, instruction, data and block
beats are checked against the eight programmed virtual-address regions
before issuing a request. Highest matching region wins; a miss grants
nothing. Legacy/extended c5 I/D permissions distinguish user from
privileged accesses. Changing active permissions or the MPU enable refetches
younger instructions; a page execute grant never crosses a privilege change
without rechecking. This is separate from the physical instruction-line
buffer. Cache attributes are readable configuration, not support for
turning on the unimplemented architectural caches. The model rejects
unpredictable enabled descriptors rather than silently granting access.

A denied fetch takes a prefetch abort only when its token reaches commit.
A denied data beat never reaches RAM or I/O. The core saves SPSR_abt and
banked LR_abt, enters ARM abort mode, and vectors via c1.V at offset `0c`
or `10`. Completed earlier block beats are preserved without committing
final writeback. [`hs_arm9_mpu.S`](../sim/tests/hs_arm9_mpu.S) checks
overlapping regions, denied MMIO, revoking the currently executing page,
read-only/user permissions, precise ARM/Thumb return addresses and CPSR
restoration. `test/Arm9MpuCheck.hs` separately checks selector decoding,
region masks, priority and the permission tables.
Both variants now retire all eight region writes and match the first 31
reference PC/opcodes including the rejected instruction. The **post-firmware**
frontier is ARM9 fault 1 on the ITCM configuration write (`c9,c1,1`) at
`02000ac8` after 30 guest retirements (cycle 191 bypass, 344 buffered).
With the functional SWI fixture ARM7 remained fault-free at four million
clocks: 737 entries/736 returns bypass, 694/693 buffered. These are not
native BIOS or firmware boot results.

**Wide memory configuration:** `dualWideSoc` drives the full aligned ARM
byte address on MEM_REQ_ADDR. Both CPUs may fetch/load/store anywhere in
`02xxxxxx`; the Fabric folds main RAM every 4 MiB. Wide WRAM occupies
`03xxxxxx` (see below). ARM7 `06xxxxxx` and byte reads of VRAMSTAT/WRAMSTAT
at `04000240/1` use the memory path, not the graphics link. Wider status
reads and writes are rejected. Bank ownership and VRAM mirroring are Fabric
decisions. MEM_ARM7 identifies
the presented request even while stalled; MEM_FETCH marks instruction
reads for measurement. Stores carry positioned data and byte enables. ARM9
graphics and VRAMCNT still use the qualified IO9 link.
The wide ARM9 link accepts VRAMCNT/WRAMCNT companion lanes through
`04000249` inclusive; a word starting at `04000248` crosses the bound.

**Instruction-line experiment.** `dualBufferedSoc` wraps the wide CPU
port. On each accepted main-RAM demand read, the same response carries
the aligned 8-byte line. A physical-address tag per CPU reuses both ARM
words or four Thumb halfwords, including through 4 MiB mirrors. Data,
WRAM, VRAM and I/O do not populate or hit the buffer. It issues no adjacent
read. CPU stores and matching DMA write snoops invalidate partial or full
overlaps; an invalidated outstanding fill still answers its original
request, but does not become resident. External and CPU reset together.
This is not an ARM946 cache timing model.

**Critical-path retime.** The original worst path was `state[34]` → ARM9
request arbitration → line lookup/ready → `en9` → device register:
14 levels, 15.969 ns routed data delay. One non-fall-through admission
register holds accepted address/lanes/data/owner/I-D. Resolving hits there
removes line lookup from the CPU-enable path. This adds **one clock minimum**
to hits and misses and caps admission at one request per two clocks. No
register rename or reorder buffer: all stores and I/O retain program order.

With the **same** shared-WRAM/CP15 public guest and six-clock ordered memory
model, through both completion stores:

| Fixed work | Bypass | Buffered before retime | Retimed |
|---|---:|---:|---:|
| Elapsed clocks | 97,752 | 63,748 | 68,114 |
| Accepted main RAM instruction / data reads | 14,084 / 558 | 7,994 / 558 | 7,998 / 558 |
| ARM9 disabled: instruction service / data service / other grant / remaining | 34,080 / 2,660 / 7,342 / 46,283 | 18,265 / 2,660 / 7,340 / 28,096 | 18,263 / 2,660 / 3,189 / 36,615 |
| ARM7 eligible disabled, same breakdown | 14,544 / 76 / 7,100 / 19,787 | 8,686 / 76 / 3,428 / 12,317 | 11,165 / 93 / 1,670 / 13,754 |

“Service” is an accepted request still awaiting its delayed answer; “other
grant” means the CPU requested while the other CPU won. Remaining includes
admission, backpressure and hit delivery. These are not physical SDRAM
commands. Both CPU PC/opcode traces to their own completion stores matched
byte-for-byte and both IF→vector→ack sequences passed. The early-finishing
CPU keeps looping until the other finishes; its post-mailbox demand count
can vary. The retime cost 4,366 clocks versus the first buffer while saving
29,638 versus bypass. A separate operand witness saw only 64 missing-operand
steps per payload versus 50.2% / 89.1% externally disabled CPU clocks:
no register cache was added.

**Fixed-time board simulation is a different denominator.** Over 10 frames
(11,203,801 master clocks) with shared/private WRAM, the tile accelerator
and both foregrounds in SDRAM, pin READ/WRITE commands changed from
800,827/13,810 (bypass) to 735,413/20,712 (retimed instruction buffer).
Each guest word write uses two WRITE commands on the 16-bit pins. ARM9/7
retirements changed from 261,116/139,029 to 361,140/248,908; both completed
20,082 GPU transactions, ten IPC exchanges and missed zero deadlines.
These are pre-DQ-phase pin simulation totals under equal elapsed time,
not commands per identical retired guest workload.

The initial isolated A/B fit (`tests/fit_fetch_line.sh`, virtual pins,
Quartus 17.0.2, Cyclone V 5CSEBA6U23I7, 14.919 ns; before WRAM/CP15)
measured 9,268→9,296 ALMs, 4,878→5,080 registers, unchanged 4 RAM blocks
and 6 DSP blocks. Slow 100°C setup slack was +0.842→**−1.649 ns**:
the first buffered design **did not meet the target clock** (slow
Fmax 71.04→60.36 MHz). Worst hold was +0.150→+0.112 ns. These figures
are CPU probes, not full-board fits.

To compare locally, pass `--postfirmware-nds /path/to/local.nds` (or
`--postfirmware-hex /path/to/local-card-words.hex`), with `MELONDS_TRACE`
naming the patched, `TRACE9`/`TRACE7`-capable `melonds_fbdump`. The runner
runs stock for 16 reference frames to collect a bounded instruction trace.
It removes private scratch images and traces at exit; it does not publish
them. Stock BIOS code is not linked into the generated machine.

### Native reset from private BIOS storage

`dualFirmwareSoc clk rst en input sys7 line snoop` is a separate hardware
configuration, not the staged cartridge experiment above. ARM9 resets to
`ffff0000` (4 KiB private ROM), ARM7 to `00000000` (16 KiB); both start in
ARM/SVC with I/F masked. ARM9 c1 resets to `2078`. Each read port samples
its aligned BOOT_ADDR word index every master-clock rising edge; the CPU
uses the returned word only after the requested index has been sampled.
A ROM miss holds just that core: timers, pending memory responses and
the other CPU keep running. ARM7 BIOSPROT reads/writes and protected data
reads are CPU-local. Board integration must hold reset until private uploads
and the native firmware lifecycle permit release; no direct header, HLE
trampoline or substitute BIOS is selected here. Native unclaimed IO goes
to each CPU's own external responder; IPC, interrupt and timer registers
remain internal. There is no success/default-data responder for missing IO.

Run `sim/run_clash_native_reset.sh GENERATED_HDL` on the generated
`nds_dual_soc_firmware` to check two resets, the final instruction word
and literal lanes of both BIOSes, ARM7's write-once protection threshold,
and delayed independent IO replies with public assembly. For the private
CPU-only comparison, add `--bios-bin BIOS9 BIOS7`, `NATIVE_FIRMWARE` and
`NATIVE_REF_BUILD` (the stock tracer-patched `melonds_fbdump` build tree).
The reference starts without a cartridge or SetupDirectBoot. Only bounded
PC lists reach ephemeral scratch; private images and full trace records
remain in memory. The CPU alone retires **4 ARM9 / 5 ARM7** instructions
matching stock before both require a byte read of POSTFLG at `04000300`
(master clocks 28/39 including reset; last PCs `ffff0118` / `00002cd8`).
The socket stops instead of fabricating the register: this is neither a
firmware menu nor a retail-game boot.

### Wide CPU WRAM

The wide and buffered CPU tops use the same [`CpuWram`](src/Nds/WholeCore/CpuWram.hs)
between the CPU arbiter and external memory. ARM7 has 64 KiB of private
RAM, repeated every `0x10000` from `03800000` to `03ffffff`. Both CPUs
also address a single 32 KiB shared RAM according to the following map.
Each bank is 16 KiB; the assigned size repeats throughout each window.

| WRAMCNT (ARM9 `04000247`) | ARM9 `03000000..03ffffff` | ARM7 `03000000..037fffff` |
| --- | --- | --- |
| 0 (reset) | both banks: low, then high | private 64 KiB alias |
| 1 | high bank | low bank |
| 2 | low bank | high bank |
| 3 (direct boot) | no bank | both banks: low, then high |

Thus ARM7 `037f8000` and `037fc000` are distinct in mode 3 and mirror
the same bank in modes 1/2. The unassigned ARM9 window ignores writes
and reads zero, following melonDS, not an electrical open-bus model.
ARM/Thumb fetch and data share these RAMs and four byte enables preserve
unwritten bytes. CPU reset discards pending transactions but does not
clear RAM. There is no WRAM backing in the host harness or narrow CPU.

Only an **accepted** ARM9 link write enabling byte `247` changes the
two-bit register. A simultaneous RAM handshake uses the pre-edge mode;
a later grant sees the new mode. The companion VRAMCNT bytes go to the
graphics fabric, including on mixed `244` word and `246` halfword access.
ARM7 byte reads of `04000241` report the mode sampled at acceptance;
`04000240` still reports VRAMSTAT. The mapping does not flush already
prefetched instructions: branch to code after transferring ownership.
No DMA/other-master access is claimed.

`test/CpuWramCheck.hs` covers all 16,384 private and 8,192 shared words,
mirror aliases, remaps, status snapshots and external/local reply
ordering. `sim/run_arm7_wram_oracle.sh`
(with `MELONDS_FBDUMP` pointing to a current `--ram-dump`-capable tracer)
runs the public mirror/byte-lane and ARM→Thumb private-code probe on stock
melonDS: ARM7 stored the expected `0000002B` in the main-RAM mailbox.
`sim/run_clash_direct_handoff.sh` passed those same operations in the
generated wide and buffered machines, retiring four ARM instructions and
two Thumb instructions from private WRAM on each.

`sim/run_shared_wram_guest.sh` runs a separate public two-CPU handshake
on stock melonDS direct boot. ARM9 programs WRAMCNT through its byte,
halfword and word views; ARM7 observes WRAMSTAT, patches code for ARM9
and executes code previously installed by ARM9. Both also execute that
code on the generated machines (six ARM9 and eight ARM7 shared-code
retirements). Stock produced `9999CAFE` and `7777BEEF` in main RAM.

**Private-only checkpoint:** the local post-firmware Kirby handoff advanced
from ARM7 fault 3 at `03800000` after 9 guest retires to fault 3 at
`037f8000` after **49,384** (cycle 395,207), before shared WRAM was added.
The first 16 ARM7 retirements matched melonDS; the rest were not
reference-traced. This is guest progress, not a game boot.

**Shared WRAM exposed a missing ARM7 BIOS vector, not a bad RAM pointer.**
On both generated machines, every one of **230,817 guest PC/opcode pairs**
through the Thumb `SWI 03` at `03804294` matched the local melonDS
reference. In the reference, the next instruction is the ARM SWI vector at
`00000008`, which branches to `00001080`. In the original direct-entry
shim, the empty vector fell through to the test-only IRQ handler: after
retiring `0000002c`, its public instruction at `00000030` (`E58BA000`,
`STR r10,[r11]`) attempted a store to zero. There is no displacement.
Stock's R11 was also zero throughout those 230,817 records. A trap-only
build now stops at vector 8 itself. Nothing special-cases address zero.

**Functional service.** The default direct-entry shim handles only
[NDS7 WaitByLoop, SWI 03](https://problemkaputt.de/gbatek-bios-misc-functions.htm).
The core performs normal exception entry; ARM code at vector 8 dispatches
on the service byte at `LR_svc−2` for either caller ISA. It saves SVC
LR/SPSR and the scratch register, runs a signed decrement/branch loop in
System mode with the caller's IRQ/FIQ masks, then restores SPSR and uses
`MOVS pc,lr` to return. Other SWIs hit an explicit undefined-instruction
trap. This is a functional instruction sequence, not a calibrated BIOS
delay, a full BIOS or a firmware boot. The public shared-WRAM guest also
calls SWI 03 from ARM and Thumb, checking flags, mode/masks, banked SP/LR,
scratch preservation and return; the HDL monitor counts its 3+5 actual
decrements and two exception returns.

In the bounded Kirby run the first call decremented R0 **250** times and
returned to Thumb PC `03804296`, as on stock. Both variants matched all
230,817 guest PC/opcodes through the call and the next 32 after return;
the different BIOS bodies were not compared. At the four-million-clock
limit, ARM7 had **no fault**: wide retired 290,433 guest instructions and
completed 736 calls; buffered retired 286,950 and completed 693. Both
were executing another delay. This is not a claim that the remaining
guest trace matches or that the cart boots. ARM9 independently stops
at the ITCM configuration write described above.

### What separates this from booting a commercial game

- **BIOS and KEY1.** No ARM9/ARM7 BIOS, no firmware boot, no KEY1/KEY2
  card encryption or secure area. The loader is a stand-in that reads a
  direct-boot synthetic image.
- **Bus and memory maps.** No full DS bus. Missing: shared WRAM and WRAMCNT
  banking, ARM7 WRAM, the VRAM banks the ARM7 can map, the full I/O maps of
  both CPUs, EXMEMCNT card/slot ownership, and the GBA slot. Main RAM is
  4 KiB, not 4 MiB, with no mirrors.
- **Real memory.** No SDRAM/DDR controller, no DS access timings or wait
  states, and no caches or CP15 on the ARM9.
- **DMA.** No DMA on either CPU.
- **Sound.** No sound channels, capture or mixer.
- **SPI.** No SPI bus: no firmware flash, touchscreen or power management;
  no card backup SPI.
- **RTC.** No real-time clock.
- **Input, display.** No KEYINPUT/EXTKEYIN and no DS LCD schedule in this
  system (the GPU rows above are separate gates).
- **Unaligned accesses on both CPUs.** These fail closed with fault 2. On
  hardware an unaligned LDR returns the aligned word rotated right by
  8 × (address & 3), and STR, STRH, LDM and STM ignore the low address
  bits. An unaligned LDRH is force-aligned on the ARM9 but rotated on the
  ARM7, and the ARM7's LDRSH at an odd address acts as LDRSB. Code written
  for the hardware may depend on any of these.
- **Missing ISA and exceptions.** No SWP/SWPB (atomics), no FIQ, abort or
  undefined-instruction exceptions, and no ARMv5TE DSP extensions,
  LDRD/STRD, PLD or coprocessor instructions on the ARM9.
- **Coherence.** No cross-CPU code coherence.

Reproduce with `sim/run_clash_arm7_isa.sh`, `sim/run_clash_dual_soc.sh`
(with `MELONDS_DUAL=sim/melonds_tracer/build-vendored/melonds_dual` for the
second oracle), `sim/run_clash_ipc_check.sh` and
`sim/run_clash_gfx_soc.sh`. All of them compile with `+RTS -M3g`.
`DualSocCheck` forces its state every cycle (peak residency about 5 MB).

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
