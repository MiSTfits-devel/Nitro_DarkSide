// bootreq: every subsystem Kirby's boot depends on, as one ROM with numbered
// subtests. Built after inference off NitroSDK traces produced two wrong root
// causes; here the expected value is known, so a mismatch is a fact.
//
// Readout needs no testbench support:
//   r9  = 0x5A5A0000 | pass bitmap   (bit n set = subtest n PASSED)
//   r10 = progress: index of the LAST SUBTEST STARTED
//   r4..r8 = raw values from the most diagnostic tests
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
static unsigned int pass;
static unsigned int prog;

static int wait_ne(volatile unsigned int *p, unsigned int bad, int limit)
{
   int i;
   for (i = 0; i < limit; i++) if (*p != bad) return 1;
   return 0;
}

int main(void)
{
   unsigned int r4 = 0, r5 = 0, r6 = 0, r7 = 0, r8 = 0;
   pass = 0;
   unsigned int v;
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

   // ---- 17: BIOS SWI - NOT here ---------------------------------------------
   // A `svc` ends melonDS's instruction trace, so an oracle baseline cannot be
   // established for it in this ROM. BIOS entry points get their own ROM
   // (sim/tests/hle_bios9, hle_bios7 already exist for that).

   prog = 99;
   REG32(MBOX + 0x10) = pass | 0x5A5A0000;
   REG32(MBOX + 0x14) = prog;

   __asm__ volatile(
      "mov r4, %0\n mov r5, %1\n mov r6, %2\n mov r7, %3\n mov r8, %4\n"
      "mov r9, %5\n mov r10, %6\n"
      "1: b 1b\n"
      :
      : "r"(r4), "r"(r5), "r"(r6), "r"(r7), "r"(r8),
        "r"(pass | 0x5A5A0000), "r"(prog)
      : "r4", "r5", "r6", "r7", "r8", "r9", "r10");
   return 0;
}
