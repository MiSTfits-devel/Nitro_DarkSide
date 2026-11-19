# ARM9 timing cartridge

This is a standalone DS-mode homebrew ROM, built from these sources with devkitPro's open-source libnds and Calico ARM7 runtime; it requires no BIOS, firmware, retail ROM, or other proprietary inputs to build. It does not write to the card or console. Use a DS flashcart such as an R4 on DS, or your usual CFW homebrew launcher on DSi. Copy `nds-timing-probe.nds` to the SD card, launch it as **DS/DSi-compatible homebrew in DS mode**, and photograph the complete results screen. Include which console model was used. Repeat on both consoles; START takes another set. Power off or use your launcher's normal exit when finished.

## Interpretation

Each of eight rows reports raw 16-bit timer 0 counts, not subtracted or averaged: an empty ARM function call baseline, a 1024-iteration ARM `subs`/`bne` loop in ITCM, and the identical instruction sequence in main RAM. Timer 0 uses the ARM9 bus clock divided by one (nominally 33.5 MHz in DS mode), not ARM9 CPU cycles. A count includes timer setup/read and function-call overhead, which the empty call characterizes approximately; timing and call targets differ. Interrupts are disabled only while the measurements are collected. The loop bodies are warmed before collection. The screen shows code addresses and the ARM9 CP15 control register, including global I/D-cache enable bits; the probe leaves the runtime's cache/MPU configuration unchanged. Cache enable alone does not establish per-region cacheability. Counts are raw and emulator behavior is not hardware evidence.

## Build

With devkitPro installed, run:

```sh
export DEVKITPRO=/opt/devkitpro
export DEVKITARM=$DEVKITPRO/devkitARM
export PATH=$DEVKITPRO/tools/bin:$DEVKITARM/bin:$PATH
make -C tools/nds-timing-probe
```

The generated `tools/nds-timing-probe/nds-timing-probe.nds` is the portable cartridge image. The toolchain supplies its own redistributable default icon and ARM7 binary; see devkitPro's installed license files.
