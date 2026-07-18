// M7 stock-toolchain console test: built with the UNMODIFIED devkitPro
// example Makefile (calico crt0 + kernel, default ARM7, consoleDemoInit,
// libnds console + default font). Unlike the stock hello_world demo it
// prints no per-frame counters or touch reads, so the framebuffer is
// deterministic and pixel-diffable between the RTL and melonDS.
#include <nds.h>
#include <stdio.h>

static volatile int frame = 0;

static void Vblank() {
    frame++;
}

int main(void) {
    irqSet(IRQ_VBLANK, Vblank);

    consoleDemoInit();

    iprintf("      Hello DS dev'rs\n");
    iprintf("     \x1b[32mwww.devkitpro.org\n");
    iprintf("   \x1b[32;1mwww.drunkencoders.com\x1b[39m\n");
    iprintf("\x1b[41;1mNDS_MiSTfits\x1b[39m stock console\n");
    iprintf("\x1b[10;0Hcalico kernel, default arm7\n");

    while (pmMainLoop()) {
        swiWaitForVBlank();
        scanKeys();
        if (keysDown() & KEY_START) break;
    }

    return 0;
}
