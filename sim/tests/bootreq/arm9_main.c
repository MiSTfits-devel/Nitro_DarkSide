// bootreq: every subsystem Kirby's boot depends on, as one ROM with numbered
// subtests. Built after inference off NitroSDK traces produced two wrong root
// causes; here the expected value is known, so a mismatch is a fact.
//
// Readout needs no testbench support:
//   r9  = 0x5A5A0000 | (pass bitmap & 0x1FFFF)   subtests 0..16
//   r10 = progress: index of the LAST SUBTEST STARTED
//   r11 = 0xFC000000 | (pass bitmap >> 16)       subtests 16..24, the IPC IRQ
//         block. Its own word because the 0x5A5A tag overlaps bits 17/19/20/22.
//   r1  = the four bytes subtest 25 read back out of a four-deep FIFO
//   r4..r8 = raw values from the most diagnostic tests
//   r12 = (IPCFIFOCNT while the recv FIFO was full) << 16 | (CNT after an
//         empty read)   -- subtests 18 and 22
//   r14 = the word IPCFIFORECV returned when read empty (subtest 22); melonDS
//         and the RTL legitimately differ here, so it is reported, not asserted
// then a `b .` spin, so the final trace line is the whole report. r10 matters as
// much as r9: if a subtest hangs, r10 names it. Several bugs this session
// presented as hangs, and a hang with no progress marker is indistinguishable
// from a different bug entirely.
//
// The mailbox lives in the UNCACHED main-RAM mirror (0x02FFxxxx, PU region 2 per
// arm9_crt0.s). Using a cacheable address silently breaks every cross-CPU test:
// the ARM9 serves the read from its own D-cache and never sees the ARM7's write.
// That cost a run to learn - the first version of this ROM used 0x02300000.

#define REG32(a) (*(volatile unsigned int *)(a))
#define REG16(a) (*(volatile unsigned short *)(a))
#define REG8(a)  (*(volatile unsigned char  *)(a))

#define IPCSYNC   0x04000180
#define IPCFIFOCNT 0x04000184
#define IPCFIFOSEND 0x04000188
#define IPCFIFORECV 0x04100000
#define IME       0x04000208
#define IE        0x04000210
#define IF        0x04000214
#define DISPCNT   0x04000000
#define DISPSTAT  0x04000004
#define VCOUNT    0x04000006
#define POWCNT1   0x04000304
#define VRAMCNT_A 0x04000240
#define WRAMCNT   0x04000247
#define TM0CNT_L  0x04000100
#define TM0CNT_H  0x04000102
#define DMA0SAD   0x040000B0
#define DMA0DAD   0x040000B4
#define DMA0CNT   0x040000B8

// uncached mirror (PU region 2). ANDs down to main-RAM offset 0x3FFxxx - the top
// of the 4 MB window, clear of the code linked at 0x02000000.
#define MBOX      0x02FFFF00
#define M_ARM7    REG32(MBOX + 0x00)   // ARM7 -> ARM9 report
#define M_READY   REG32(MBOX + 0x04)   // ARM9 -> ARM7 go flag
#define M_FIFO    REG32(MBOX + 0x08)   // ARM7's FIFO echo report
// +0x10/+0x14: the pass/prog report, written at the end
#define M_CMD     REG32(MBOX + 0x18)   // ARM9 -> ARM7 command (0 = idle)
#define M_DONE    REG32(MBOX + 0x1C)   // ARM7 -> ARM9 command ack (echoes cmd)
#define M_IF7     REG32(MBOX + 0x20)   // ARM7's IF7 verdict, 0x1F70000n
#define M_WORD    REG32(MBOX + 0x24)   // payload for command 1
#define M_R7RECV  REG32(MBOX + 0x28)   // word the ARM7 popped in command 2
#define M_IRQCNT  REG32(MBOX + 0x30)   // nds_ipc_irq_handler: times entered
#define M_IRQWORD REG32(MBOX + 0x34)   // nds_ipc_irq_handler: word it received
#define M_IRQIF   REG32(MBOX + 0x38)   // nds_ipc_irq_handler: IF on entry
#define M_SCRATCH (MBOX + 0x40)

#define CACHED_SCRATCH 0x02380000      // cacheable view, well clear of code

// Pinned to fixed registers for the whole run. TRACE_DIFF prints r0..r14 on every
// retired instruction, so with these two live the report is readable from ANY
// line - including inside the BIOS abort handler. Parking results only at the end
// meant one faulting subtest discarded all 18 results, which is how the first two
// runs of this ROM told me nothing.
// NOTE: pinning these to r10/r11 via `register ... asm()` was tried and does NOT
// hold - both are callee-saved and GCC does not honour the binding across calls,
// so the bitmap read as stale and prog read as 0. Results are parked explicitly at
// the end instead, which means the run must not abort before it gets there: the
// two TCM subtests that data-abort (no PU region covers the ITCM window in this
// crt0) are therefore left out of this ROM and belong in their own.
//
// UPDATE: build.sh now compiles this file with -ffixed-r9 -ffixed-r10, which
// takes both registers out of GCC's allocator entirely. REPORT() then parks the
// running totals after every subtest and they actually STAY there, so a subtest
// that hangs or aborts no longer discards the results of the ones before it.
// The explicit park at the end is kept as well (it also loads r4..r8).
static unsigned int pass;
static unsigned int prog;
static unsigned int park[8];

//
// The 0x5A5A0000 tag can only carry subtests 0..16: 0x5A5A0000 itself has bits
// 17, 19, 20, 22, 25, 27, 28 and 30 set, so any pass bit above 16 that lands in
// the tag is unreadable - it reads as set whether the subtest ran or not. The
// IPC subtests therefore get their own word in r11, tagged 0xFC000000, which
// occupies bits 26..31 only. r9 keeps exactly its old value so the documented
// bootreq reference (pass=0x5A5BDE7F) still means what it did.
#define REPORT() __asm__ volatile("mov r9, %0\n\tmov r10, %1\n\tmov r11, %2\n" \
                                  :: "r"((pass & 0x0001FFFFu) | 0x5A5A0000u),  \
                                     "r"(prog),                                \
                                     "r"(0xFC000000u | (pass >> 16)))

static int wait_ne(volatile unsigned int *p, unsigned int bad, int limit)
{
   int i;
   for (i = 0; i < limit; i++) if (*p != bad) return 1;
   return 0;
}

extern void nds_ipc_irq_handler(void);

// IRQ source bits (both CPUs): 18 = "receive FIFO not empty".
#define IRQ_IPCRECV  0x00040000u

// IPCFIFOCNT bits. CNT_RIRQ (bit 10) is the one bootreq never used to set, and
// the one Kirby's ARM9 has set on real hardware while IF bit 18 stays 0.
#define CNT_EN       0x8000u
#define CNT_ERRACK   0x4000u
#define CNT_RIRQ     0x0400u
#define CNT_RECVEMP  0x0100u
#define CNT_SENDCLR  0x0008u
#define CNT_ERR      0x4000u

// Post a command to the ARM7 script and wait (bounded) for its ack. Commands:
//   1 = send M_WORD to the ARM9 over the FIFO, then ack
//   2 = arm an IF7 recv-IRQ observation (clear IF7, enable recv IRQ), ack
//       IMMEDIATELY, then poll IF7 and report into M_IF7 / M_R7RECV
//   3 = push four tagged words back to back, then ack
static int arm7_cmd(unsigned int cmd)
{
   M_DONE = 0;
   M_CMD  = cmd;
   return wait_ne(&M_DONE, 0, 400000);
}

int main(void)
{
   unsigned int r4 = 0, r5 = 0, r6 = 0, r7 = 0, r8 = 0;
   pass = 0;
   unsigned int v;
   unsigned int cnt_ne = 0, cnt_empty = 0, empty_rd = 0, fifo_seq = 0;
   int i;

   M_ARM7 = 0; M_READY = 0; M_FIFO = 0;
   REG32(IME) = 0;

   // ---- 0: IPCSYNC, our own data-out nibble reads back -----------------------
   prog = 0;
   REG16(IPCSYNC) = 0x0A00;
   r4 = REG32(IPCSYNC);
   if (((r4 >> 8) & 0xF) == 0xA) pass |= 1u << 0;

   // ---- 1: IE, a fully writable 32-bit IO register ---------------------------
   prog = 1;
   REG32(IE) = 0x00003FFF;
   r5 = REG32(IE);
   if (r5 == 0x00003FFF) pass |= 1u << 1;

   // ---- 2: DISPCNT - losing this register IS the white screen ----------------
   prog = 2;
   REG32(DISPCNT) = 0x00010000;
   r6 = REG32(DISPCNT);
   if (r6 == 0x00010000) pass |= 1u << 2;

   // ---- 3: POWCNT1 ----------------------------------------------------------
   prog = 3;
   REG16(POWCNT1) = 0x820F;
   if ((REG32(POWCNT1) & 0xF) == 0xF) pass |= 1u << 3;

   // ---- 4: main RAM word write/read (uncached path) --------------------------
   prog = 4;
   REG32(M_SCRATCH) = 0xC0FFEE01;
   if (REG32(M_SCRATCH) == 0xC0FFEE01) pass |= 1u << 4;

   // ---- 5: byte / halfword lanes --------------------------------------------
   prog = 5;
   REG32(M_SCRATCH + 4) = 0;
   REG8(M_SCRATCH + 4) = 0x11;
   REG8(M_SCRATCH + 7) = 0x44;
   REG16(M_SCRATCH + 10) = 0xBEEF;
   if (REG32(M_SCRATCH + 4) == 0x44000011 &&
       (REG32(M_SCRATCH + 8) >> 16) == 0xBEEF) pass |= 1u << 5;

   // ---- 6: D-cache coherency - cached write must reach memory ---------------
   // Write through the cacheable view, clean the line, then read the same
   // physical word through the uncached mirror. Exercises writeback + the
   // c7 maintenance op the SDK relies on.
   prog = 6;
   REG32(CACHED_SCRATCH) = 0xCACE0006;
   __asm__ volatile("mcr p15, 0, %0, c7, c10, 1" :: "r"(CACHED_SCRATCH));  // clean D line
   __asm__ volatile("mcr p15, 0, r0, c7, c10, 4" ::: "r0");                // drain write buffer
   if (REG32(0x02F80000) == 0xCACE0006) pass |= 1u << 6;   // 0x02F80000 -> same offset, uncached

   // ---- 9: shared WRAM, ARM9-only mapping (WRAMCNT=0) -----------------------
   prog = 9;
   REG8(WRAMCNT) = 0x00;
   REG32(0x03000000) = 0x5A410009;
   if (REG32(0x03000000) == 0x5A410009) pass |= 1u << 9;

   // ---- 10: VRAM bank A through the LCDC window ----------------------------
   prog = 10;
   REG8(VRAMCNT_A) = 0x80;              // enable, LCDC mode -> 0x06800000
   REG32(0x06800000) = 0x11AA000A;
   if (REG32(0x06800000) == 0x11AA000A) pass |= 1u << 10;

   // ---- 11: timer 0 actually counts ----------------------------------------
   prog = 11;
   REG16(TM0CNT_H) = 0x0000;
   REG16(TM0CNT_L) = 0x0000;
   REG16(TM0CNT_H) = 0x0080;            // enable, /1
   for (i = 0; i < 200; i++) __asm__ volatile("nop");
   r7 = REG16(TM0CNT_L);
   if (r7 != 0) pass |= 1u << 11;

   // ---- 12: VCOUNT advances (the video fabric is running) ------------------
   prog = 12;
   v = REG16(VCOUNT);
   for (i = 0; i < 20000; i++) if (REG16(VCOUNT) != v) { pass |= 1u << 12; break; }

   // ---- 13: VBlank reaches IF ---------------------------------------------
   prog = 13;
   REG16(DISPSTAT) = 0x0008;            // enable VBlank IRQ in DISPSTAT
   REG32(IE) = 0x00000001;              // VBlank
   REG32(IF) = 0xFFFFFFFF;              // clear
   // NOT spun on here: the first VBlank is up to a full frame away (~560k cycles,
   // ~800k retired instructions) which would dominate the whole suite and blow the
   // trace cap. Frame-timed checks belong in their own ROM; bit 13 stays 0 here.
   r8 = REG32(IF);

   // ---- 14: DMA0 main RAM -> main RAM --------------------------------------
   prog = 14;
   REG32(M_SCRATCH + 0x20) = 0xD00D0014;
   REG32(M_SCRATCH + 0x30) = 0;
   REG32(DMA0SAD) = M_SCRATCH + 0x20;
   REG32(DMA0DAD) = M_SCRATCH + 0x30;
   REG32(DMA0CNT) = 0x84000001;         // enable, immediate, 32-bit, 1 word
   for (i = 0; i < 10000; i++) if (!(REG32(DMA0CNT) & 0x80000000)) break;
   if (REG32(M_SCRATCH + 0x30) == 0xD00D0014) pass |= 1u << 14;

   // ---- 15: cross-CPU IPCSYNC - does the ARM7 see our nibble? -------------
   prog = 15;
   REG16(IPCSYNC) = 0x0A00;
   M_READY = 0x600D0000;
   if (wait_ne(&M_ARM7, 0, 50000) && M_ARM7 == 0x5EED000A) pass |= 1u << 15;

   // ---- 16: IPC FIFO round trip -------------------------------------------
   prog = 16;
   REG16(IPCFIFOCNT) = 0x8008;          // enable FIFO, flush send
   REG32(IPCFIFOSEND) = 0x1234ABCD;
   if (wait_ne(&M_FIFO, 0, 50000) && M_FIFO == 0x1234ABCD) pass |= 1u << 16;

   REPORT();

   // ==========================================================================
   // 17..24: the IRQ-driven IPC FIFO path, ARM7 -> ARM9.
   //
   // Subtest 16 above only proves ARM9 -> ARM7 by polling, with CNT = 0x8008:
   // bit 15 and bit 3, never bit 10. On real hardware Kirby's ARM9 sits forever
   // with IE9 = 0x00040001 (VBlank + IPC recv) and IF9 bit 18 NEVER set, while
   // the ARM7's IF7 bit 18 does latch. So the direction and the mechanism that
   // fail on hardware are exactly the ones subtest 16 does not touch.
   //
   // The ARM7 needs no interrupt path of its own for any of this: for
   // ARM7 -> ARM9 it only has to *send*, and for the reverse control it polls
   // its own IF7 with IRQs masked (IF latches independently of IE/IME on both
   // CPUs). That keeps the ARM7 script free of the BIOS IRQ dispatch that HLE
   // boot does not provide, so a failure here cannot be the ARM7's fault.
   //
   // Only subtest 24 takes an actual exception, and it is last for that reason.
   // ==========================================================================

   // ---- 17: does an ARM7 send raise IF bit 18 on the ARM9 at all? -----------
   // IME stays 0: this asks only whether the flag LATCHES, which is the precise
   // thing that is false on hardware. Handler dispatch is subtest 24's job.
   prog = 17;
   REPORT();
   REG32(IME) = 0;
   REG32(IE)  = IRQ_IPCRECV;
   REG16(IPCFIFOCNT) = CNT_EN | CNT_ERRACK | CNT_RIRQ | CNT_SENDCLR;
   REG32(IF) = 0xFFFFFFFF;
   M_WORD = 0xA7A70017;
   if (arm7_cmd(1)) {
      for (i = 0; i < 200000; i++) if (REG32(IF) & IRQ_IPCRECV) break;
      if (REG32(IF) & IRQ_IPCRECV) pass |= 1u << 17;
   }

   // ---- 18: the ARM9's own RECV port at 0x04100000 --------------------------
   // Never exercised before: subtest 16 had the ARM7 pop the word, so no ROM has
   // ever read 0x04100000 from the ARM9 side.
   prog = 18;
   REPORT();
   cnt_ne = REG16(IPCFIFOCNT);              // expect recv-empty (bit 8) == 0
   v = REG32(IPCFIFORECV);
   if (v == 0xA7A70017 && !(cnt_ne & CNT_RECVEMP) &&
       (REG16(IPCFIFOCNT) & CNT_RECVEMP)) pass |= 1u << 18;

   // ---- 19: arming bit 10 while the FIFO is ALREADY non-empty ---------------
   // melonDS raises the IRQ on the 0->1 transition of bit 10 when the receive
   // FIFO is not empty (NDS.cpp 0x04000184 write); nds_ipc.vhd gets there by a
   // different route, the rising edge of (cnt79 /= 0 AND rirq9). Same answer or
   // not, this is the case where those two descriptions could come apart.
   prog = 19;
   REPORT();
   REG16(IPCFIFOCNT) = CNT_EN | CNT_ERRACK;         // recv IRQ OFF
   REG32(IF) = 0xFFFFFFFF;
   M_WORD = 0xB7B70019;
   if (arm7_cmd(1)) {
      // with the IRQ disabled the arriving word must NOT set the flag...
      int quiet = (REG32(IF) & IRQ_IPCRECV) ? 0 : 1;
      REG16(IPCFIFOCNT) = CNT_EN | CNT_ERRACK | CNT_RIRQ;   // ...now arm it
      for (i = 0; i < 2000; i++) if (REG32(IF) & IRQ_IPCRECV) break;
      if (quiet && (REG32(IF) & IRQ_IPCRECV)) pass |= 1u << 19;
   }

   // ---- 20: drain, then refill - does a SECOND IRQ fire? -------------------
   // The specific hypothesis for the freeze. nds_ipc.vhd only pulses irq9_recv
   // on a RISING edge of (cnt79 /= 0 AND rirq9); if the conjunction never falls
   // between two messages the second interrupt is lost silently and the ARM9
   // blocks forever on a message that did arrive. Draining to empty is what is
   // supposed to re-arm it.
   prog = 20;
   REPORT();
   v = REG32(IPCFIFORECV);                  // drain to empty
   REG32(IF) = 0xFFFFFFFF;
   M_WORD = 0xC7C70020;
   if (arm7_cmd(1)) {
      for (i = 0; i < 200000; i++) if (REG32(IF) & IRQ_IPCRECV) break;
      if (v == 0xB7B70019 && (REG32(IF) & IRQ_IPCRECV)) pass |= 1u << 20;
   }

   // ---- 21: a second word while the FIFO is still NON-empty ----------------
   // Documented edge behaviour: no empty->non-empty transition, so no new IRQ.
   // PASS therefore means "the flag stayed clear". melonDS gates on `wasempty`,
   // nds_ipc.vhd on the same conjunction as above; both should be quiet here.
   prog = 21;
   REPORT();
   REG32(IF) = 0xFFFFFFFF;
   M_WORD = 0xD7D70021;
   if (arm7_cmd(1)) {
      for (i = 0; i < 20000; i++) if (REG32(IF) & IRQ_IPCRECV) break;
      if (!(REG32(IF) & IRQ_IPCRECV)) pass |= 1u << 21;
   }

   // ---- 22: FIFO order, and reading RECV when empty sets the error flag ----
   // The "returns the last value read" half of that rule is NOT asserted here:
   // melonDS returns FIFO::Peek() of an empty ring (a stale slot) while
   // nds_ipc.vhd returns its `last9` register, so the two disagree for a reason
   // that has nothing to do with interrupts. The raw value is parked in r12.
   prog = 22;
   REPORT();
   {
      unsigned int a = REG32(IPCFIFORECV);
      unsigned int b = REG32(IPCFIFORECV);
      REG16(IPCFIFOCNT) = CNT_EN | CNT_ERRACK | CNT_RIRQ;    // ack any error
      empty_rd  = REG32(IPCFIFORECV);                        // read while empty
      cnt_empty = REG16(IPCFIFOCNT);
      if (a == 0xC7C70020 && b == 0xD7D70021 && (cnt_empty & CNT_ERR))
         pass |= 1u << 22;
   }

   // ---- 23: control - ARM9 -> ARM7, does IF7 bit 18 latch? -----------------
   // The direction that demonstrably works on hardware. If 17 fails and 23
   // passes, the RTL has the same asymmetry the silicon shows.
   prog = 23;
   REPORT();
   M_IF7 = 0; M_R7RECV = 0;
   if (arm7_cmd(2)) {
      REG16(IPCFIFOCNT) = CNT_EN | CNT_ERRACK | CNT_RIRQ | CNT_SENDCLR;
      REG32(IPCFIFOSEND) = 0x97970023;
      if (wait_ne(&M_IF7, 0, 400000) && (M_IF7 & 1) && M_R7RECV == 0x97970023)
         pass |= 1u << 23;
   }

   // ---- 24: LAST - does the ARM9 actually take the interrupt? --------------
   // IME=1 plus the BIOS dispatcher at 0xFFFF0018, which jumps to
   // [DTCM_base + 0x4000 - 4] = 0x027E3FFC. Ordered last because it is the only
   // subtest that can hang the run: an unclearable IF bit 18 would loop in the
   // vector forever. r9/r10 already hold everything above (REPORT()), so a hang
   // here still reports 17..23.
   prog = 24;
   REPORT();
   M_IRQCNT = 0; M_IRQWORD = 0; M_IRQIF = 0;
   REG16(IPCFIFOCNT) = CNT_EN | CNT_ERRACK | CNT_RIRQ | CNT_SENDCLR;
   REG32(IF) = 0xFFFFFFFF;
   REG32(IE) = IRQ_IPCRECV;
   // SP_irq is set up in arm9_crt0.s, not here - see the comment there.
   REG32(0x027E3FFC) = (unsigned int)&nds_ipc_irq_handler;
   REG32(IME) = 1;
   // and unmask IRQs in the CPSR - boot leaves the I bit set on both the RTL
   // and melonDS, so without this the flag latches and is never delivered.
   __asm__ volatile("mrs %0, cpsr\n\t bic %0, %0, #0x80\n\t msr cpsr_c, %0\n"
                    : "=&r"(v) :: "cc");
   M_WORD = 0xE7E70024;
   if (arm7_cmd(1)) {
      for (i = 0; i < 400000; i++) if (M_IRQCNT != 0) break;
   }
   __asm__ volatile("mrs %0, cpsr\n\t orr %0, %0, #0x80\n\t msr cpsr_c, %0\n"
                    : "=&r"(v) :: "cc");
   REG32(IME) = 0;
   if (M_IRQCNT == 1 && M_IRQWORD == 0xE7E70024 && (M_IRQIF & IRQ_IPCRECV))
      pass |= 1u << 24;

   // ---- 25: FOUR words queued, read back in order --------------------------
   // Every subtest above reads the FIFO with at most two words in it, and one
   // word is the case a "return the last popped value" fallback can cover for.
   // Four words separates the two ways a read port can be wrong:
   //   correct                    -> 11 22 33 44
   //   read data sampled a cycle
   //   late (returns the entry
   //   AFTER the one popped)      -> 22 33 44 44
   //   each read pops twice       -> 22 44 44 44
   // The four bytes actually read are parked in r1 so the answer is legible
   // whichever way it comes out.
   prog = 25;
   REPORT();
   REG16(IPCFIFOCNT) = CNT_EN | CNT_ERRACK | CNT_RIRQ;
   {
      unsigned int q[4];
      if (arm7_cmd(3)) {
         q[0] = REG32(IPCFIFORECV);
         q[1] = REG32(IPCFIFORECV);
         q[2] = REG32(IPCFIFORECV);
         q[3] = REG32(IPCFIFORECV);
         fifo_seq = ((q[0] >> 24) << 24) | (((q[1] >> 24) & 0xFF) << 16) |
                    (((q[2] >> 24) & 0xFF) << 8) | ((q[3] >> 24) & 0xFF);
         if (q[0] == 0x11110025 && q[1] == 0x22220025 &&
             q[2] == 0x33330025 && q[3] == 0x44440025) pass |= 1u << 25;
      }
   }

   // ---- BIOS SWI - NOT here -------------------------------------------------
   // A `svc` ends melonDS's instruction trace, so an oracle baseline cannot be
   // established for it in this ROM. BIOS entry points get their own ROM
   // (sim/tests/hle_bios9, hle_bios7 already exist for that).

   prog = 99;
   REG32(MBOX + 0x10) = pass | 0x5A5A0000;
   REG32(MBOX + 0x14) = prog;

   // Nine values into r4..r12 in one go. A `mov`-per-value asm no longer fits:
   // with r9/r10 fixed and r4..r8 clobbered there are not enough registers left
   // to hold the inputs, so stage them in memory and ldm them out.
   park[0] = fifo_seq;
   park[1] = r4; park[2] = r5; park[3] = r6; park[4] = r7; park[5] = r8;
   park[6] = (cnt_ne << 16) | (cnt_empty & 0xFFFF); park[7] = empty_rd;
   REPORT();                        // r9 / r10 / r11
   __asm__ volatile(
      "mov r0, %0\n\t"
      "ldmia r0, {r1, r4-r8, r12, r14}\n"
      "1: b 1b\n"
      :
      : "r"(&park[0])
      : "memory");
   return 0;
}
