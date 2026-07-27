/* sdk2d ARM9: everything in main RAM at 0x02000000, crt0 first. */
OUTPUT_FORMAT("elf32-littlearm")
OUTPUT_ARCH(arm)
ENTRY(_start)

MEMORY {
   ram : ORIGIN = 0x02000000, LENGTH = 4M
}

SECTIONS {
   .text : {
      *(.crt0)
      *(.text*)
      *(.rodata*)
      . = ALIGN(4);
   } > ram

   .data : {
      *(.data*)
      . = ALIGN(4);
   } > ram

   .bss (NOLOAD) : {
      __bss_start__ = .;
      *(.bss*)
      *(COMMON)
      . = ALIGN(4);
      __bss_end__ = .;
   } > ram
}
