/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <nds.h>
#include <stdint.h>
#include <stdio.h>

#define ITERATIONS 1024
#define SAMPLES 8
#define IME (*(volatile uint32_t *)0x04000208)

typedef void (*loop_fn)(unsigned);
extern void loop_itcm(unsigned);
extern void loop_ram(unsigned);
extern void loop_empty(unsigned);

static uint16_t sample(loop_fn fn)
{
    TIMER0_CR = 0;
    TIMER0_DATA = 0;
    TIMER0_CR = TIMER_ENABLE | TIMER_DIV_1;
    fn(ITERATIONS);
    uint16_t count = TIMER0_DATA;
    TIMER0_CR = 0;
    return count;
}

static uint32_t control_register(void)
{
    uint32_t value;
    __asm__ volatile ("mrc p15, 0, %0, c1, c0, 0" : "=r"(value));
    return value;
}

static void run_samples(void)
{
    uint16_t base[SAMPLES], itcm[SAMPLES], ram[SAMPLES];
    consoleClear();
    /* Warm both loops before sampling; no cache policy changes. */
    loop_itcm(ITERATIONS);
    loop_ram(ITERATIONS);
    uint32_t control = control_register();
    uint32_t old_ime = IME;
    IME = 0;
    for (unsigned i = 0; i < SAMPLES; ++i) {
        base[i] = sample(loop_empty);
        itcm[i] = sample(loop_itcm);
        ram[i] = sample(loop_ram);
    }
    IME = old_ime;

    iprintf("ARM9 TIMING PROBE v1\n");
    iprintf("NDS mode / timer0 / div 1\n");
    iprintf("1024 ARM subs+bne loops\n");
    iprintf("CP15 ctrl %08lX\n", (unsigned long)control);
    iprintf("I-cache %s  D-cache %s\n", control & (1u << 12) ? "ON" : "OFF", control & (1u << 2) ? "ON" : "OFF");
    iprintf("ITCM %08lX\n", (unsigned long)(uintptr_t)loop_itcm);
    iprintf("RAM  %08lX\n", (unsigned long)(uintptr_t)loop_ram);
    iprintf("raw ticks: empty ITCM RAM\n");
    for (unsigned i = 0; i < SAMPLES; ++i)
        iprintf("%u %5u %5u %5u\n", i + 1, base[i], itcm[i], ram[i]);
    iprintf("Photo this screen please!\n");
    iprintf("START: resample\n");
}

int main(void)
{
    consoleDemoInit();
    run_samples();
    while (pmMainLoop()) {
        swiWaitForVBlank();
        scanKeys();
        if (keysDown() & KEY_START) run_samples();
    }
    return 0;
}
