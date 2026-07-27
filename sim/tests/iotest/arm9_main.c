// iotest ARM9: does an ARM9 IO access actually work?
//
// Written because three sessions of inference off NitroSDK traces produced two
// wrong root causes. With our own ROM the expected value is known exactly, so a
// mismatch is a fact rather than an interpretation.
//
// Readout needs NO testbench support: each result is parked in a fixed register
// and the ARM9 then spins forever, so the last line of the trace shows every
// result at once (TRACE_DIFF prints r0..r14). On hardware the same values are
// also written to 0x02300000.. where mailbox PEEK can read them (PEEK works for
// 0x02xxxxxx; it cannot read IO - that is why the ROM reads IO itself).
//
//   r4 = IPCSYNC  after writing nibble 0xA to bits[11:8]   expect (r4>>8)&0xF == 0xA
//   r5 = IE       after writing 0x00003FFF                 expect 0x00003FFF
//   r6 = DISPCNT  after writing 0x00010000                 expect 0x00010000
//   r7 = what the ARM7 reported seeing of the ARM9 nibble   expect 0x5EED000A
//   r8 = POWCNT1  after writing 0x0000820F                  expect low bits set
//   r9 = pass/fail bitmap, bit n set = test n PASSED
//
// Every wait is bounded: a broken IO path must show as a recorded timeout, never
// as a hang that looks like a different bug.

#define REG32(a) (*(volatile unsigned int *)(a))
#define REG16(a) (*(volatile unsigned short *)(a))

#define IPCSYNC  0x04000180
#define IE       0x04000210
#define IME      0x04000208
#define DISPCNT  0x04000000
#define POWCNT1  0x04000304

// shared block, uncached mirror region set up by arm9_crt0.s region 2
#define SHARED   0x02300000
#define ARM7_REPORT REG32(SHARED + 0x00)
#define ARM9_READY  REG32(SHARED + 0x04)

int main(void)
{
   unsigned int r_sync, r_ie, r_dispcnt, r_powcnt, r_arm7, pass = 0;
   int i;

   ARM7_REPORT = 0;
   ARM9_READY  = 0;

   // interrupts stay masked: IE is then a plain 32-bit scratch register with no
   // side effects, which makes it the cleanest possible write/read probe
   REG32(IME) = 0;

   // ---- test 0: IPCSYNC write then read back our own nibble -----------------
   REG16(IPCSYNC) = 0x0A00;
   r_sync = REG32(IPCSYNC);
   if (((r_sync >> 8) & 0xF) == 0xA) pass |= 1u << 0;

   // ---- test 1: IE, a fully writable 32-bit IO register ---------------------
   REG32(IE) = 0x00003FFF;
   r_ie = REG32(IE);
   if (r_ie == 0x00003FFF) pass |= 1u << 1;

   // ---- test 2: DISPCNT - the register whose loss is literally a white screen
   REG32(DISPCNT) = 0x00010000;
   r_dispcnt = REG32(DISPCNT);
   if (r_dispcnt == 0x00010000) pass |= 1u << 2;

   // ---- test 3: POWCNT1 ----------------------------------------------------
   REG16(POWCNT1) = 0x820F;
   r_powcnt = REG32(POWCNT1);
   if ((r_powcnt & 0x000F) == 0x000F) pass |= 1u << 3;

   // ---- test 4: can the ARM7 see our nibble? cross-CPU IO visibility --------
   // Re-post 0xA (the tests above may have been clobbered) and let the ARM7 look.
   REG16(IPCSYNC) = 0x0A00;
   ARM9_READY = 0x600D0000;
   r_arm7 = 0xDEAD0000;               // distinct "ARM7 never answered" marker
   for (i = 0; i < 100000; i++) {
      unsigned int v = ARM7_REPORT;
      if (v != 0) { r_arm7 = v; break; }
   }
   if (r_arm7 == 0x5EED000A) pass |= 1u << 4;

   // persist for hardware PEEK as well as the trace
   REG32(SHARED + 0x10) = r_sync;
   REG32(SHARED + 0x14) = r_ie;
   REG32(SHARED + 0x18) = r_dispcnt;
   REG32(SHARED + 0x1C) = r_powcnt;
   REG32(SHARED + 0x20) = r_arm7;
   REG32(SHARED + 0x24) = pass | 0x5A5A0000;

   // Park each result in a known register and spin. The final trace line is the
   // whole report; no tb plumbing, no framebuffer, no timing assumptions.
   __asm__ volatile(
      "mov r4, %0\n"
      "mov r5, %1\n"
      "mov r6, %2\n"
      "mov r7, %3\n"
      "mov r8, %4\n"
      "mov r9, %5\n"
      "1: b 1b\n"
      :
      : "r"(r_sync), "r"(r_ie), "r"(r_dispcnt), "r"(r_arm7), "r"(r_powcnt),
        "r"(pass | 0x5A5A0000)
      : "r4", "r5", "r6", "r7", "r8", "r9");

   return 0;
}
