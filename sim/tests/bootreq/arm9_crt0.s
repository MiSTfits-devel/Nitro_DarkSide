@ Minimal ARM9 crt0 for the sdk2d sample: the arm9_2d.s CP15 bring-up
@ (SDK-style PU regions, caches, DTCM stack) followed by BSS clear and a
@ call into C main. Replaces the libnds/calico crt0 - the calico kernel
@ needs ARM7 IRQ dispatch through the BIOS, which the RTL HLE boot does
@ not provide yet (no BIOS, no DMA; see sim/readme.md). Rules per the
@ melonDS notes in arm9_2d.s: explicit PU regions (no 4 GB catch-all),
@ DTCM covered, POWCNT before palette/OAM writes (main's job).

   .arch armv5te
   .arm
   .global _start
   .section .crt0, "ax"

_start:
   mov  r0, #0x20
   mcr  p15, 0, r0, c9, c1, 1  @ ITCM: 32 MB virtual
   ldr  r0, =0x027E000A
   mcr  p15, 0, r0, c9, c1, 0  @ DTCM at 0x027E0000, 16 KB
   @ PU regions. A test ROM wants a permissive map: region 0 is a 4 GB catch-all
   @ so nothing data-aborts merely for lacking a region (each missing region cost
   @ a whole iteration to discover - ITCM and shared WRAM both aborted this way).
   @ Higher-numbered regions win on overlap, so the specific ones below still
   @ decide cacheability, which is what the coherency subtest depends on.
   ldr  r0, =0x0000002F        @ region 0: 0..4 GB catch-all
   mcr  p15, 0, r0, c6, c0, 0
   ldr  r0, =0x0200002B        @ region 1: main RAM 4 MB - the ONLY cacheable one
   mcr  p15, 0, r0, c6, c1, 0
   ldr  r0, =0x02C0002B        @ region 2: main-RAM mirror, uncached (mailbox)
   mcr  p15, 0, r0, c6, c2, 0
   ldr  r0, =0x027E001B        @ region 3: DTCM window, 16 KB
   mcr  p15, 0, r0, c6, c3, 0
   ldr  r0, =0x0300001B        @ region 4: shared WRAM, 16 KB
   mcr  p15, 0, r0, c6, c4, 0
   ldr  r0, =0x04000033        @ region 5: IO / palette / VRAM / OAM, 64 MB
   mcr  p15, 0, r0, c6, c5, 0
   mov  r0, #0x02
   mcr  p15, 0, r0, c2, c0, 0
   mcr  p15, 0, r0, c2, c0, 1
   mcr  p15, 0, r0, c3, c0, 0
   ldr  r0, =0x33333333
   mcr  p15, 0, r0, c5, c0, 2
   mcr  p15, 0, r0, c5, c0, 3
   ldr  r0, =0x0005307D        @ PU + I/D caches + ITCM + DTCM + V (high vectors:
                               @ exceptions to 0xFFFF0000 BIOS, as the real
                               @ boot ROM leaves it - with V=0 the vectors sit
                               @ at 0x0 inside ITCM, uninitialised, so any SWI
                               @ or abort jumps into garbage)
   mcr  p15, 0, r0, c1, c0, 0
   ldr  sp, =0x027E3F80        @ stack in DTCM

   ldr  r0, =__bss_start__     @ clear BSS
   ldr  r1, =__bss_end__
   mov  r2, #0
1: cmp  r0, r1
   strlo r2, [r0], #4
   blo  1b

   bl   main
2: b    2b

   .ltorg
