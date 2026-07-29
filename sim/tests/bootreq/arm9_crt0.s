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
   ldr  r0, =0x0000003F        @ region 0: 0..4 GB catch-all
                               @ NOTE: this used to be 0x2F, whose size field is
                               @ 23 - a 16 MB region, not the 4 GB the comment
                               @ claimed. Everything above 0x01000000 that no
                               @ other region covered therefore data-aborted,
                               @ including the BIOS's own abort-handler stack at
                               @ 0x027FFD9C, which turned one abort into an
                               @ endless one.
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
   @ region 6: the BIOS / high-vector window, 32 KB - the same value melonDS's
   @ own direct boot programs. Region 0 is documented above as a "4 GB
   @ catch-all" but 0x2F is a size field of 23, i.e. 16 MB, so nothing covered
   @ 0xFFFF0000: taking ANY exception with high vectors enabled prefetch-aborted
   @ on the vector itself, and melonDS answers that with
   @ "EXCEPTION REGION NOT EXECUTABLE" and stops the console. That is why no
   @ earlier ROM here could take an interrupt.
   ldr  r0, =0xFFFF001D
   mcr  p15, 0, r0, c6, c6, 0
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

   @ IRQ-mode stack. The ARM9 BIOS IRQ dispatcher at 0xFFFF0274 does
   @ `push {r0-r3,ip,lr}` before it jumps to the user handler, and nothing else
   @ initialises SP_irq - it is 0 out of reset, so the push data-aborts and the
   @ interrupt never reaches the handler. Done here rather than from C because
   @ r14 is BANKED: the obvious inline-asm version let GCC pick `lr` to carry the
   @ address, and in IRQ mode that reads r14_irq (0), so `mov sp, lr` set SP_irq
   @ to 0 and looked exactly like never having run at all.
   mrs  r1, cpsr
   bic  r2, r1, #0x1F
   orr  r2, r2, #0xD2          @ IRQ mode, IRQ and FIQ still masked
   msr  cpsr_c, r2
   ldr  sp, =0x027E3B00        @ 1 KB clear of the SVC stack, inside DTCM
   msr  cpsr_c, r1

   ldr  r0, =__bss_start__     @ clear BSS
   ldr  r1, =__bss_end__
   mov  r2, #0
1: cmp  r0, r1
   strlo r2, [r0], #4
   blo  1b

   bl   main
2: b    2b

   .ltorg

@ ---------------------------------------------------------------------------
@ IPC recv-FIFO IRQ handler (subtest 24). Entered from the ARM9 BIOS IRQ
@ dispatcher, which has already pushed {r0-r3,ip,lr} onto SP_irq and loaded
@ its own return address into lr, then jumped to [DTCM_base + 0x4000 - 4].
@ main() plants this address there.
@
@ It reports into the UNCACHED mailbox mirror rather than a .bss global so
@ main() can read the result with no cache maintenance, and it uses only
@ r0-r3 (all saved by the BIOS) - in particular it must not touch r9/r10,
@ which carry the live pass/prog report (see -ffixed-r9/-ffixed-r10 in
@ build.sh). No pushes, so it needs no stack of its own; the BIOS's push
@ still does, which is why main() initialises SP_irq.
@
@   0x02FFFF30  call count
@   0x02FFFF34  word read from IPCFIFORECV
@   0x02FFFF38  IF as seen on entry
@ ---------------------------------------------------------------------------
   .global nds_ipc_irq_handler
   .type nds_ipc_irq_handler, %function
nds_ipc_irq_handler:
   ldr  r0, =0x04000214        @ IF
   ldr  r1, [r0]
   ldr  r2, =0x02FFFF30
   str  r1, [r2, #8]           @ +0x38 = IF snapshot (bit 18 is the question)
   ldr  r3, =0x04100000        @ IPCFIFORECV
   ldr  r3, [r3]
   str  r3, [r2, #4]           @ +0x34 = word received
   ldr  r3, [r2]
   add  r3, r3, #1
   str  r3, [r2]               @ +0x30 = call count (written last)
   mov  r1, #0x00040000
   str  r1, [r0]               @ ack IF bit 18
   bx   lr

   .ltorg
