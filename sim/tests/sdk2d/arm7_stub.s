@ sdk2d ARM7 stub: linked at 0x037F8000 (ARM7-private WRAM, where real
@ SDK ARM7 binaries live). Posts the done word and idles - no calico
@ kernel (its IRQ dispatch needs the BIOS trampoline the RTL lacks).

   .arch armv4t
   .arm
   .global _start
   .text

_start:
   ldr  sp, =0x0380FF00        @ stack at the top of ARM7 WRAM
   ldr  r10, =0x02FFFF10
   mov  r9, #1
   str  r9, [r10]
   ldr  r1, =0xBEEF7777
   str  r1, [r10, #4]
hang:
   b    hang

   .ltorg
