@ ARM9 cache test (roadmap M3): self-checking exercise of nds_cache9 through
@ real CP15 sequences. Runs as the boot ROM at 0xFFFF0000 (uncached region),
@ reporting to the island mailbox at 0x02FFFF00 (kept uncachable by PU
@ region 3 so the testbench snoop sees the writes).
@
@ PU map: region0 = 4GB uncachable, region1 = main RAM 4MB I+D cachable,
@ region2 = the 0x02400000 mirror uncachable (an uncached window onto the
@ same physical RAM - what the write-back tests observe memory through),
@ region3 = the 0x02C00000 mirror uncachable (mailbox + stack).
@
@ Tests:
@   1  D-cache fill + write-back is lazy (memory unchanged until clean)
@   2  clean D line MVA pushes the dirty line to memory
@   3  invalidate D line MVA drops dirty data (memory value wins)
@   4  clean+invalidate D line MVA
@   5  dirty eviction: 5th line in a set writes back the round-robin victim
@   6  I-cache holds stale code until invalidated (the classic JIT flush)
@   7  clean+invalidate D by set/index loop (full flush) + inv I all
@ Build: sim/tests/build_arm9_cache.sh (checked-in hex).

   .arch armv5te
   .arm
   .section .text
   .global _start

_start:
   b  reset
   b  hang
   b  hang
   b  hang
   b  hang
   b  hang
   b  hang
   b  hang

@ uncached alias offset: +0x00400000 (region 2)
.equ ALIAS, 0x00400000

reset:
   msr  cpsr_c, #0xDF          @ system mode, I+F set
   ldr  sp, =0x02D00E00        @ stack in the uncachable mirror (region 3)

   ldr  r10, =0x02FFFF00       @ mailbox (uncachable via region 3)
   mov  r9, #0                 @ result bitmask

@ ---- PU + cache setup ----
   ldr  r0, =0x0000003F        @ region 0: base 0, 4GB (size code 31), enable
   mcr  p15, 0, r0, c6, c0, 0
   ldr  r0, =0x0200002B        @ region 1: 0x02000000, 4MB (code 21), enable
   mcr  p15, 0, r0, c6, c1, 0
   ldr  r0, =0x0240002B        @ region 2: 0x02400000, 4MB, enable (uncachable)
   mcr  p15, 0, r0, c6, c2, 0
   ldr  r0, =0x02C0002B        @ region 3: 0x02C00000, 4MB, enable (uncachable)
   mcr  p15, 0, r0, c6, c3, 0
   mov  r0, #0x02              @ cachability bitmap: region 1 only
   mcr  p15, 0, r0, c2, c0, 0  @ D cachable
   mcr  p15, 0, r0, c2, c0, 1  @ I cachable
   mcr  p15, 0, r0, c3, c0, 0  @ D bufferable
   ldr  r0, =0x33333333        @ full access everywhere
   mcr  p15, 0, r0, c5, c0, 2
   mcr  p15, 0, r0, c5, c0, 3
   ldr  r0, =0x0000117D        @ base 0x78 | PU | dcache | icache
   mcr  p15, 0, r0, c1, c0, 0

@ ---- test 1: fill + lazy write-back ----
   ldr  r0, =0x02210000        @ X (cached)
   ldr  r1, =0x02610000        @ Y = uncached alias of X
   ldr  r2, =0xA11A5EED
   str  r2, [r1]               @ seed memory through the uncached window
   ldr  r3, [r0]               @ cached read: fills the line
   cmp  r3, r2
   bne  report_fail
   ldr  r4, =0xB22B5EED
   str  r4, [r0]               @ cached write: dirty, memory must keep old value
   ldr  r3, [r1]               @ uncached read of the same word
   cmp  r3, r2
   bne  report_fail            @ write-through would give B22B5EED here
   ldr  r3, [r0]               @ cached read sees the new value
   cmp  r3, r4
   bne  report_fail
   orr  r9, r9, #1
   str  r9, [r10]

@ ---- test 2: clean D line MVA ----
   mcr  p15, 0, r0, c7, c10, 1 @ clean D line (X)
   ldr  r3, [r1]
   cmp  r3, r4                 @ memory now has the dirty value
   bne  report_fail
   orr  r9, r9, #2
   str  r9, [r10]

@ ---- test 3: invalidate D line drops dirty data ----
   ldr  r5, =0xC33C5EED
   str  r5, [r0]               @ dirty again (cache = C33C, memory = B22B)
   mcr  p15, 0, r0, c7, c6, 1  @ invalidate D line (no clean!)
   ldr  r3, [r0]               @ refills from memory
   cmp  r3, r4                 @ dirty C33C is gone, B22B remains
   bne  report_fail
   ldr  r3, [r1]
   cmp  r3, r4
   bne  report_fail
   orr  r9, r9, #4
   str  r9, [r10]

@ ---- test 4: clean+invalidate D line MVA ----
   ldr  r5, =0xD44D5EED
   str  r5, [r0]               @ dirty (line resident from test 3 refill)
   mcr  p15, 0, r0, c7, c14, 1 @ clean+invalidate
   ldr  r3, [r1]
   cmp  r3, r5                 @ memory updated...
   bne  report_fail
   ldr  r3, [r0]               @ ...and the refill agrees
   cmp  r3, r5
   bne  report_fail
   orr  r9, r9, #8
   str  r9, [r10]

@ ---- test 5: dirty eviction via round-robin victim ----
@ five addresses in the same D set (1 KB stride), read-allocate + dirty each;
@ the fifth fill evicts the first (round-robin), writing it back
   ldr  r0, =0x02220000
   ldr  r6, =0xE0000001
   mov  r7, #5
1: ldr  r3, [r0]               @ allocate
   str  r6, [r0]               @ dirty
   add  r0, r0, #0x400         @ next line, same set
   add  r6, r6, #1
   subs r7, r7, #1
   bne  1b
   ldr  r1, =0x02620000        @ uncached alias of the first line
   ldr  r3, [r1]
   ldr  r6, =0xE0000001
   cmp  r3, r6                 @ evicted dirty line reached memory
   bne  report_fail
   orr  r9, r9, #16
   str  r9, [r10]

@ ---- test 6: I-cache staleness + invalidate ----
   ldr  r0, =0x02230000        @ F: code location (cached I+D)
   ldr  r1, =0x02630000        @ uncached alias of F
   ldr  r2, =0xE3A00001        @ mov r0, #1
   ldr  r3, =0xE12FFF1E        @ bx lr
   str  r2, [r1]               @ write code through the UNCACHED window
   str  r3, [r1, #4]           @ (no D-cache involvement at all)
   mcr  p15, 0, r0, c7, c5, 1  @ invalidate I line (paranoia: cold anyway)
   mov  lr, pc
   ldr  pc, =0x02230000        @ call F: fetches through I-cache, caches it
   cmp  r0, #1
   bne  report_fail
   ldr  r2, =0xE3A00002        @ mov r0, #2
   ldr  r0, =0x02230000
   str  r2, [r1]               @ patch the code in memory (uncached window)
   mov  lr, pc
   ldr  pc, =0x02230000        @ I-cache NOT invalidated: must run stale code
   cmp  r0, #1
   bne  report_fail
   ldr  r0, =0x02230000
   mcr  p15, 0, r0, c7, c5, 1  @ invalidate I line
   mov  lr, pc
   ldr  pc, =0x02230000        @ now the new code is fetched
   cmp  r0, #2
   bne  report_fail
   orr  r9, r9, #32
   str  r9, [r10]

@ ---- test 7: full D flush by set/index + inv I all ----
   ldr  r0, =0x02240000
   ldr  r4, =0xF00D0000
   mov  r7, #8                 @ dirty 8 lines across sets
1: ldr  r3, [r0]
   str  r4, [r0]
   add  r0, r0, #32
   add  r4, r4, #1
   subs r7, r7, #1
   bne  1b
   mov  r5, #0                 @ way index 0..3 in bits 31:30
2: mov  r6, #0                 @ set index 0..31 in bits 9:5
3: orr  r0, r5, r6
   mcr  p15, 0, r0, c7, c14, 2 @ clean+invalidate D by index
   add  r6, r6, #32            @ next set (bit 5)
   cmp  r6, #1024
   blt  3b
   add  r5, r5, #0x40000000    @ next way (bit 30)
   cmp  r5, #0
   bne  2b
   mcr  p15, 0, r0, c7, c5, 0  @ invalidate I all
   ldr  r0, =0x02640000        @ uncached alias: all 8 dirty lines in memory
   ldr  r4, =0xF00D0000
   mov  r7, #8
4: ldr  r3, [r0]
   cmp  r3, r4
   bne  report_fail
   add  r0, r0, #32
   add  r4, r4, #1
   subs r7, r7, #1
   bne  4b
   orr  r9, r9, #64
   str  r9, [r10]

@ ---- all passed ----
   ldr  r1, =0xCAFEBABE
   str  r1, [r10, #4]
hang:
   b    hang

report_fail:
   ldr  r10, =0x02FFFF00
   ldr  r1, =0xBADBAD00
   str  r1, [r10, #4]
9: b    9b

   .ltorg
