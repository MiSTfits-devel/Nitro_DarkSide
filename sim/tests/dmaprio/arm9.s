@ Minimal repro of the NITRO Tester's [04-02] DMA PRIORITY test (progress
@ 011/058), which is where the cart halts on this core.
@
@ What the cart's test does, disassembled from the dump at 0x0201a13c:
@
@   TimerStart(3, 0xffff, 0)  ->  TM3CNT_L = ~0xffff = 0, TM3CNT_H = 0xC0
@                                 (enable + IRQ, prescaler /1 = one tick per
@                                 33.513982 MHz bus cycle)
@   ch N   : SAD = 0x0400010C (TM3CNT_L, FIXED), DAD = 0x06861000, 8 units,
@            16-bit, start = HBLANK
@   ch N+1 : SAD = 0x0400010C (TM3CNT_L, FIXED), DAD = 0x06860000, 2048 units,
@            16-bit, start = IMMEDIATE
@
@ Both channels therefore fill VRAM bank D with snapshots of a free-running
@ counter. The checker then walks the 2048-entry buffer of the LOW-priority
@ channel and requires it to be EXACTLY t, t+2, t+4, ... - one 16-bit DMA unit
@ is one read plus one write, i.e. two bus cycles, on real hardware. Where that
@ sequence breaks, the 8 missing counter values must be sitting in the
@ high-priority channel's buffer: proof that it preempted mid-transfer.
@
@ So the test measures DMA throughput in bus cycles, not just channel ordering.
@ This ROM reproduces it without the other 57 tests in front of it: run it
@ under tb_top_frame with DUMP_STATE=1 and read the two buffers out of
@ rtl_state_banks.hex (bank D starts at word 98304).
@
@ Markers written by the CPU, so "the program ran" and "VRAM D is writable" are
@ distinguishable from a wrong cadence:
@   0x06862000 = DEADBEEF  before the transfers
@   0x06862004 = C0DE0001  after channel N+1 reports done
@   0x06862008 = TM3CNT_L at that moment
@   0x0686200C = number of poll iterations spent waiting for done

   .arch armv5te
   .arm
   .global _start
   .section .crt0, "ax"

_start:
   mov  r0, #0x20
   mcr  p15, 0, r0, c9, c1, 1  @ ITCM: 32 MB virtual
   ldr  r0, =0x027E000A
   mcr  p15, 0, r0, c9, c1, 0  @ DTCM at 0x027E0000, 16 KB
   ldr  r0, =0x04000033        @ region 0: IO/palette/VRAM/OAM, 64 MB
   mcr  p15, 0, r0, c6, c0, 0
   ldr  r0, =0x0200002B        @ region 1: main RAM 4 MB, cachable
   mcr  p15, 0, r0, c6, c1, 0
   ldr  r0, =0x02C0002B        @ region 2: main-RAM mirror (mailbox), uncached
   mcr  p15, 0, r0, c6, c2, 0
   ldr  r0, =0x027E001B        @ region 3: DTCM window, 16 KB
   mcr  p15, 0, r0, c6, c3, 0
   mov  r0, #0x02
   mcr  p15, 0, r0, c2, c0, 0
   mcr  p15, 0, r0, c2, c0, 1
   mcr  p15, 0, r0, c3, c0, 0
   ldr  r0, =0x33333333
   mcr  p15, 0, r0, c5, c0, 2
   mcr  p15, 0, r0, c5, c0, 3
   ldr  r0, =0x0005107D        @ PU + I/D caches + ITCM + DTCM
   mcr  p15, 0, r0, c1, c0, 0
   ldr  sp, =0x027E3F80        @ stack in DTCM

   bl   dmatest
2: b    2b

   .ltorg

@ ---------------------------------------------------------------------------
dmatest:
   ldr  r12, =0x04000000

   ldr  r0, =0x0000820F        @ POWCNT1: LCDs + both engines
   str  r0, [r12, #0x304]
   mov  r0, #0x80              @ VRAMCNT_D = LCDC, so 0x06860000 is plain RAM
   strb r0, [r12, #0x243]
   strb r0, [r12, #0x244]      @ VRAMCNT_E = LCDC: 0x06880000, but BRAM-backed
   ldr  r0, =0x00010000        @ DISPCNT: display mode 1, BG mode 0
   str  r0, [r12]
   ldr  r11, =0x04000208       @ halfword offsets are only 8-bit: hold IME
   mov  r0, #0                 @ IME off, exactly as the cart's test does
   strh r0, [r11]

   ldr  r1, =0x06862000        @ marker: the CPU can reach VRAM D at all
   ldr  r0, =0xDEADBEEF
   str  r0, [r1]

   @ TimerStart(3, 0xffff, 0)
   ldr  r3, =0x0400010C        @ TM3CNT_L; also the DMA source below
   mov  r0, #0
   strh r0, [r3]               @ TM3CNT_L reload = ~0xffff = 0
   mov  r0, #0x80              @ enable, prescaler /1 (cart also sets IRQ; IME=0)
   strh r0, [r3, #2]

   @ sync to the VCOUNT 262 -> 0 wrap, like the cart, so a full frame of
   @ headroom follows and an HBLANK is guaranteed inside the long transfer
   ldr  r2, =0x00000106
1: ldrh r1, [r12, #0x006]
   cmp  r1, r2
   bne  1b
1: ldrh r1, [r12, #0x006]
   cmp  r1, r2
   beq  1b

   @ r3 still holds 0x0400010C - both channels read TM3CNT_L, FIXED source

   @ channel 0: 8 units, 16-bit, HBLANK start, dest 0x06861000
   str  r3, [r12, #0x0B0]
   ldr  r0, =0x06861000
   str  r0, [r12, #0x0B4]
   ldr  r0, =0x91000008
   str  r0, [r12, #0x0B8]

   ldr  r0, [r12, #0x0B0]      @ the cart's two dummy reads of DMA0SAD
   ldr  r0, [r12, #0x0B0]

   @ channel 1: 2048 units, 16-bit, IMMEDIATE start, dest 0x06860000
   str  r3, [r12, #0x0BC]
   ldr  r0, =0x06860000
   str  r0, [r12, #0x0C0]
   ldr  r0, =0x81000800
   str  r0, [r12, #0x0C4]

   @ wait for channel 1 to clear its enable bit (bounded, so a wedge still dumps)
   mov  r4, #0
   ldr  r5, =2000000
1: ldr  r0, [r12, #0x0C4]
   tst  r0, #0x80000000
   beq  2f
   add  r4, r4, #1
   cmp  r4, r5
   blo  1b
2:
   ldrh r6, [r3]               @ counter at completion

   @ let the HBLANK-triggered channel 0 land too, then post the markers. Its
   @ pend was latched during the long transfer and the CPU stays paused while
   @ the DMA runs, so this only has to outlast the 8 units.
   mov  r7, #0
   ldr  r5, =2000
1: add  r7, r7, #1
   cmp  r7, r5
   blo  1b

   @ ---- cost decomposition: same source and same DMA, cheaper destinations ----
   @ The 2048-unit transfer above measures (DMA FSM + IO read + VRAM A..D write),
   @ where A..D leave the chip over the vsrv channel. Repeat it into the two
   @ faster destinations to find out which term dominates, since that decides
   @ whether the two-cycles-per-unit the test wants is reachable at all:
   @   palette  - membus9 T_PAL retires in FINISH, the lowest-latency write there is
   @   VRAM E   - BRAM inside nds_vram, no off-chip round trip
   @ 64 units each, on channel 2 (channels 0/1 disabled themselves above).
   str  r3, [r12, #0x0C8]      @ DMA2SAD = TM3CNT_L, FIXED
   ldr  r0, =0x05000000
   str  r0, [r12, #0x0CC]      @ DMA2DAD = BG palette A
   ldr  r0, =0x81000040        @ 64 units, 16-bit, immediate, src fixed, dst inc
   str  r0, [r12, #0x0D0]

   str  r3, [r12, #0x0C8]
   ldr  r0, =0x06880000
   str  r0, [r12, #0x0CC]      @ DMA2DAD = VRAM E
   ldr  r0, =0x81000040
   str  r0, [r12, #0x0D0]

   mov  r0, #0                 @ TimerStop(3)
   strh r0, [r3, #2]

   ldr  r1, =0x06862004
   ldr  r0, =0xC0DE0001
   str  r0, [r1]
   str  r6, [r1, #4]
   str  r4, [r1, #8]

   ldr  r2, =0x06880000        @ VRAM E is uncached here, so read it directly
   ldrh r0, [r2]
   str  r0, [r1, #12]
   ldrh r0, [r2, #2]
   str  r0, [r1, #16]
   ldrh r0, [r2, #4]
   str  r0, [r1, #20]
   ldrh r0, [r2, #6]
   str  r0, [r1, #24]
   bx   lr

   .ltorg
