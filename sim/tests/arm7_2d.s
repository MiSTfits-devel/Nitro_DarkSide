@ M5 exit test, ARM7 side: minimal companion for the 2D frame-dump scene.
@ Linked at 0x02380000 (main RAM). Posts its done word and idles - the
@ graphics sample needs no ARM7 services yet (no sound/SPI/RTC in scope).

   .arch armv4t
   .arm
   .global _start

_start:
   ldr  sp, =0x023A0000        @ stack in main RAM, well away from the ARM9
   ldr  r10, =0x02FFFF10       @ ARM7 mailbox
   mov  r9, #1
   str  r9, [r10]              @ bit 0: alive
   ldr  r1, =0xBEEF7777
   str  r1, [r10, #4]          @ done word
hang:
   b    hang

   .ltorg
