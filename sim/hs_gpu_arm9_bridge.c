// SPDX-License-Identifier: GPL-3.0-or-later
// NVC VHPIDIRECT host for the reset-idle ARM9 island witness.
#include "melonds_tracer/HsGpuAbi.h"

#include <dlfcn.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

static void *library, *gpu;
static void (*rts_exit)(void);
static void (*gpu_destroy)(void *);
static int (*gpu_call)(void *, const struct NdsHsGpuRequest *, struct NdsHsGpuReply *);

static void *symbol(const char *name)
{
    void *sym = dlsym(library, name);
    if (!sym) {
        fprintf(stderr, "ARM9 Haskell bridge: cannot resolve %s: %s\n", name, dlerror());
        exit(EXIT_FAILURE);
    }
    return sym;
}

static uint64_t call(uint64_t op, uint64_t tick, uint32_t address, uint64_t width, uint32_t value)
{
    const struct NdsHsGpuRequest request = {
        .version = NDS_HS_GPU_ABI_VERSION, .op = op, .timestamp = tick,
        .cpu = 0, .address = address, .width = width, .value = value
    };
    struct NdsHsGpuReply reply = {0};
    int result = gpu_call(gpu, &request, &reply);
    if (result || reply.status || reply.version != NDS_HS_GPU_ABI_VERSION) {
        const char *error = reply.errorText ? (const char *)(uintptr_t)reply.errorText : "bad ABI reply";
        fprintf(stderr, "ARM9 Haskell bridge: GPU call op=%" PRIu64 " cycle=%" PRIu64
                        " addr=%08" PRIx32 ": %s\n", op, tick, address, error);
        exit(EXIT_FAILURE);
    }
    // This console slice has no owner for scheduled work, IRQs, DMA or frames.
    // FIFO<128 is a level, not a DMA pulse. Everything else must be idle.
    if (reply.nextDeadline != NDS_HS_GPU_NO_DEADLINE ||
        (reply.flags & ~(uint64_t)NDS_HS_GPU_FIFO_LT_HALF) ||
        reply.irqSet9 || reply.irqClear9 || reply.irqSet7 || reply.irqClear7 ||
        reply.dmaModes9 || reply.dmaModes7 || reply.frame || reply.pixels || reply.bytes) {
        fprintf(stderr, "ARM9 Haskell bridge: unsupported GPU effect op=%" PRIu64
                        " cycle=%" PRIu64 " addr=%08" PRIx32 "\n", op, tick, address);
        exit(EXIT_FAILURE);
    }
    return reply.value;
}

void arm9_gpu_start(void)
{
    const char *path = getenv("HS_GPU_LIBRARY");
    if (!path || !(library = dlopen(path, RTLD_NOW | RTLD_LOCAL))) {
        fprintf(stderr, "ARM9 Haskell bridge: cannot load GPU library: %s\n",
                path ? dlerror() : "HS_GPU_LIBRARY is not set");
        exit(EXIT_FAILURE);
    }
    void (*rts_init)(int *, char ***) = (void (*)(int *, char ***))symbol("hs_init");
    rts_exit = (void (*)(void))symbol("hs_exit");
    void *(*gpu_create)(void) = (void *(*)(void))symbol("nds_hs_gpu_create");
    gpu_destroy = (void (*)(void *))symbol("nds_hs_gpu_destroy");
    gpu_call = (int (*)(void *, const struct NdsHsGpuRequest *, struct NdsHsGpuReply *))symbol("nds_hs_gpu_call");
    char arg0[] = "arm9-haskell-cosim";
    char *args[] = {arg0, NULL};
    char **argv = args;
    int argc = 1;
    rts_init(&argc, &argv);
    if (!(gpu = gpu_create())) {
        fputs("ARM9 Haskell bridge: GPU creation failed\n", stderr);
        exit(EXIT_FAILURE);
    }
    call(NDS_HS_GPU_RESET, 0, 0, 0, 0);
}

// Reset the device alongside the CPU/link; any queued adapter reply is the
// caller's responsibility and must be discarded separately.
void arm9_gpu_reset(void)
{
    call(NDS_HS_GPU_RESET, 0, 0, 0, 0);
}

int32_t arm9_gpu_transfer(int32_t cycle, int32_t physical, int32_t width,
                          int32_t is_write, int32_t data)
{
    uint32_t addr = (uint32_t)physical;
    uint32_t value = (uint32_t)data;
    uint64_t op;
    if ((addr >> 24) == 6) {
        op = is_write ? NDS_HS_GPU_MEM_WRITE : NDS_HS_GPU_MEM_READ;
    } else if ((addr == 0x04000304 && (width == 2 || width == 4)) ||
               (addr >= 0x04000240 && addr + width <= 0x04000247) ||
               (addr >= 0x04000248 && addr + width <= 0x0400024a)) {
        op = is_write ? NDS_HS_GPU_IO_WRITE : NDS_HS_GPU_IO_READ;
    } else {
        fprintf(stderr, "ARM9 Haskell bridge: unsupported ARM9 I/O %08" PRIx32 "/%" PRId32 "\n", addr, width);
        exit(EXIT_FAILURE);
    }
    uint32_t reply = (uint32_t)call(op, cycle, addr, width, value);
    printf("ARM9 -> Haskell cycle=%" PRId32 " %s%" PRId32 " %08" PRIx32 " %08" PRIx32 "\n",
           cycle, is_write ? "W" : "R", width, addr, is_write ? value : reply);
    return (int32_t)reply;
}

void arm9_gpu_stop(void)
{
    gpu_destroy(gpu);
    rts_exit();
    dlclose(library);
}
