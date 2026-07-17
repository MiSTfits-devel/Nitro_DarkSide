@ sdk2d ARM7 stub: linked at 0x037F8000 (ARM7-private WRAM, where real
@ SDK ARM7 binaries live). M7: exercises the HLE BIOS the way calico
@ does — SWIs from both ARM state (like the calico bootstub) and Thumb
@ state (like the calico wrappers), then a svcHalt vblank loop whose
@ IRQs dispatch through the BIOS vector at [0x0380FFFC].
@
@ Proof word for the ARM9 (0x02FFFF20): svcGetCRC16 over a fixed
@ 32-byte pattern, xor svcIsDebugger()<<16 (retail -> 0), xor
@ 0x5EED0000 — posted only after the first BIOS-dispatched vblank IRQ
@ has run the handler. The ARM9 blocks on the exact value, so a broken
@ dispatch/SWI shows as a sim timeout, a wrong CRC as a stuck ARM9.

   .arch armv4t
   .arm
   .global _start
   .text

_start:
   msr  cpsr_c, #0xD2          @ IRQ mode: stack for the BIOS 6-word frame
   ldr  sp, =0x0380FEC0
   msr  cpsr_c, #0xD3          @ SVC mode: stack for the BIOS SWI handler
   ldr  sp, =0x0380FE80
   msr  cpsr_c, #0xDF          @ system mode (IRQs still off)
   ldr  sp, =0x0380FF00

   @ fixed pattern at 0x0380FD00: b[i] = (i*7 + 3) & 0xFF, i = 0..31
   ldr  r0, =0x0380FD00
   mov  r1, #0
   mov  r2, #3
1: strb r2, [r0, r1]
   add  r2, r2, #7
   and  r2, r2, #0xFF
   add  r1, r1, #1
   cmp  r1, #32
   blt  1b

   @ svcGetCRC16(0xFFFF, pattern, 32) from ARM state (imm24 decode)
   ldr  r0, =0xFFFF
   ldr  r1, =0x0380FD00
   mov  r2, #32
   swi  0x0E0000
   mov  r7, r0

   @ svcIsDebugger + svcWaitByLoop from Thumb state (imm8 decode)
   ldr  r3, =thumb_swis
   orr  r3, r3, #1
   mov  lr, pc
   bx   r3
   orr  r7, r7, r0, lsl #16    @ retail 0 keeps the CRC clean
   ldr  r1, =0x5EED0000
   eor  r7, r7, r1

   @ BIOS IRQ dispatch target + vblank counter
   ldr  r0, =irq_handler
   ldr  r1, =0x0380FFFC
   str  r0, [r1]
   ldr  r1, =0x0380FF80
   mov  r0, #0
   str  r0, [r1]

   mov  r0, #0x04000000
   mov  r2, #0x08
   strh r2, [r0, #0x04]        @ DISPSTAT7: vblank IRQ enable
   mov  r2, #1
   str  r2, [r0, #0x210]       @ IE = vblank
   mvn  r2, #0
   str  r2, [r0, #0x214]       @ IF = ack everything
   mov  r2, #1
   str  r2, [r0, #0x208]       @ IME = 1

   @ arm7-alive words (pre-BIOS behavior, kept for debugging)
   ldr  r10, =0x02FFFF10
   mov  r9, #1
   str  r9, [r10]
   ldr  r1, =0xBEEF7777
   str  r1, [r10, #4]

   msr  cpsr_c, #0x1F          @ IRQs on

mainloop:
   swi  0x060000               @ svcHalt until IE & IF != 0
   ldr  r1, =0x0380FF80
   ldr  r2, [r1]
   cmp  r2, #0                 @ handler ran at least once?
   beq  mainloop
   ldr  r1, =0x02FFFF20
   str  r7, [r1]               @ proof word (same value every frame)
   str  r2, [r1, #4]           @ vblank IRQ count (debug only)
   b    mainloop

@ entered via the BIOS trampoline: IRQ mode, {r0-r3,r12,lr} saved by
@ the BIOS, return with bx lr into the BIOS restore
irq_handler:
   mov  r0, #0x04000000
   mov  r1, #1
   str  r1, [r0, #0x214]       @ ack vblank in IF
   ldr  r2, =0x0380FF80
   ldr  r3, [r2]
   add  r3, r3, #1
   str  r3, [r2]
   bx   lr

   .ltorg

   .thumb
   .align 1
thumb_swis:
   swi  0x0F                   @ IsDebugger -> r0 (retail: 0)
   mov  r4, r0
   mov  r0, #0x40
   swi  0x03                   @ WaitByLoop(64)
   mov  r0, r4
   bx   lr
