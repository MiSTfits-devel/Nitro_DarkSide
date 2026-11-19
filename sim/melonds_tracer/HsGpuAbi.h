// SPDX-License-Identifier: GPL-3.0-or-later
// Synchronous CPU <-> Haskell GPU service, version 2.
// This header is the shared contract, not an alternate GPU implementation.
#ifndef NDS_HS_GPU_ABI_H
#define NDS_HS_GPU_ABI_H
#include <stdint.h>
#include <stddef.h>

#define NDS_HS_GPU_ABI_VERSION UINT64_C(2)
#define NDS_HS_GPU_NO_DEADLINE UINT64_MAX
#define NDS_HS_GPU_FRAME_BYTES (256u * 384u * 4u)

enum NdsHsGpuOp {
    NDS_HS_GPU_ADVANCE = 0,
    NDS_HS_GPU_IO_READ = 1,
    NDS_HS_GPU_IO_WRITE = 2,
    NDS_HS_GPU_MEM_READ = 3,
    NDS_HS_GPU_MEM_WRITE = 4,
    NDS_HS_GPU_RESET = 5,
    NDS_HS_GPU_IF_ACK = 6,
    NDS_HS_GPU_FRAME = 7,
    NDS_HS_GPU_FRAME_START = 8,
    NDS_HS_GPU_IO_CONTINUE = 9
};

enum NdsHsGpuFlags {
    NDS_HS_GPU_GX_STALLED = 1u << 0,
    NDS_HS_GPU_FIFO_LT_HALF = 1u << 1,
    NDS_HS_GPU_FRAME_COMPLETED = 1u << 2,
    NDS_HS_GPU_PIXELS_VALID = 1u << 3
};

// Every field is exactly one native-endian uint64_t. Version 2 requires a
// little-endian, 64-bit host; startup rejects any unsupported ABI. No packed
// struct or Haskell object layout crosses the boundary.
//
// Time is an absolute count of 33,513,982 Hz system cycles, i.e. melonDS
// ARM9Timestamp >> ARM9ClockShift, NOT ARM9 fast-clock ticks or wall time.
// Requests are serialized. Timestamps may be equal, never decrease except at
// RESET. The CPU coordinator must order both CPUs' GPU transactions by this
// clock; clamping a stale timestamp is not permitted. Scheduled GPU events at
// time T run before a bus transaction at T. Service every exact due deadline
// before later-timestamp GPU accesses or subsequent CPU/DMA work. Interpreter
// handlers retain the stock instruction-start timestamps; this contract does
// not add sub-instruction microcycle progression. ADVANCE services a deadline;
// it does not fabricate CPU bus transactions.
//
// The interpreter timestamps all beats of one instruction at its unchanged
// core clock. A word GX command write in an actual ARM9 instruction handler
// carries a unique nonzero instructionScope. If that ordinary IO_WRITE first
// asserts GX_STALLED, the host records that instruction and exact raw ARM9
// core clock as the stall origin. Only later word GX MMIO writes of that SAME
// still-executing handler, at that SAME raw core clock, may use IO_CONTINUE
// with the same scope and system timestamp. Haskell separately requires the
// observed ordinary-write stall origin and current stall. Command entries
// append to the existing GxFront pending FIFO in issue order; non-command GX
// writes retain their normal decoder effects. No new spill queue or capacity.
// Word GX MMIO is 0x04000060 or aligned 0x04000320..0x040006A0 inclusive;
// only command ports 0x04000400..0x040005C8 enqueue commands.
//
// DMA, a new instruction, a changed raw core clock, reads, byte/halfword or
// memory accesses cannot use this continuation. Ordinary stalled bus writes
// remain rejected. The host finishes only the current interpreter handler,
// then stops before the next instruction while GX_STALLED remains asserted.
// No retiming, stale-clock clamping, per-MMIO engine drain or fabricated
// instruction acceptance is permitted.
//
// IO/MEM address is the original physical CPU bus address, cpu is 0 (ARM9) or
// 1 (ARM7), width is 1/2/4 bytes; value is right-justified. Natural alignment
// follows the CPU bus. GPU memory includes palette, OAM, mapped VRAM and all
// aliases. Haskell owns both the physical bytes and all GPU mappings/capture
// writes: no melonDS GPU memory, readback, register or renderer may answer an
// access in this mode. IF_ACK carries the independently executed CPU IF write
// in value; Haskell re-evaluates only its GPU interrupt sources. CPU IF storage
// and all non-GPU device state remain in the CPU coordinator.
//
// RESET is the only time-origin reset and clears all GPU state; LCD remains
// idle until FRAME_START. FRAME only observes a completed
// Haskell frame; it neither advances time nor substitutes an oracle framebuffer.
// FRAME_START begins one machine frame after boot setup / the previous frame
// completion. value supplies the CPU DMA controller's armed ARM9 start-mode
// mask (bit4 participates in the display-FIFO latch). Haskell derives all LCD
// phases/deadlines. RESET leaves LCD idle until this explicit start; no power
// or display state is latched before the machine finishes boot setup.
// instructionScope must be zero except on ordinary ARM9 word GX command
// IO_WRITE and authenticated IO_CONTINUE requests. Malformed, unsupported or
// out-of-order requests fail closed and make the device terminal until reset.
struct NdsHsGpuRequest {
    uint64_t version;
    uint64_t op;
    uint64_t timestamp;
    uint64_t cpu;
    uint64_t address;
    uint64_t width;
    uint64_t value;
    uint64_t instructionScope;
};

// status == 0 is success. Any nonzero status / nonzero call return is terminal:
// report errorText and stop execution; do not fall back to melonDS's GPU.
// IRQ masks are independently generated effects of THIS call, not absolute IF
// snapshots. Set/clear for a CPU are disjoint; apply clears then sets after the
// FFI call has returned, before executing another CPU/GPU transaction. Bits are
// normal NDS IF bit positions. Only GPU-owned interrupt bits may be changed.
//
// DMA fields encode start modes in bits [0,31] and stop modes in [32,63]: bit m
// requests CheckDMAs(cpu,m), bit (32+m) requests StopDMAs(cpu,m). Modes are the
// actual NDS API mode numbers (including ARM7 0x11), not DMA channel numbers.
// Apply stops then starts after return. Each deadline is serviced separately,
// so repeated pulses at distinct times cannot collapse into a count/tolerance.
// Same-timestamp reentrant DMA writes are ordinary subsequent service calls.
//
// flags bit0 and bit1 are CURRENT levels (stall and FIFO<128); bit2 is a frame
// completion pulse from THIS call; bit3 says a complete frame is available.
// frame is the monotonically increasing sequence. pixels is a borrowed pointer
// to 256x384 little-endian BGRA8888
// bytes (physical top display followed by bottom), bytes is either 0 or
// NDS_HS_GPU_FRAME_BYTES. It is valid only until the next service call/reset/
// destroy. A consumer must copy/use it synchronously; no async retained pointer.
// errorText is a borrowed NUL-terminated UTF-8 message with the same lifetime.
// nextDeadline is an absolute system-cycle deadline >= timestamp, or
// NDS_HS_GPU_NO_DEADLINE if no GPU event is pending. Never reinterpret it as a
// relative delay, wall-clock delay or proof of quiescence of non-GPU devices.
struct NdsHsGpuReply {
    uint64_t version;
    uint64_t status;
    uint64_t value;
    uint64_t nextDeadline;
    uint64_t irqSet9;
    uint64_t irqClear9;
    uint64_t irqSet7;
    uint64_t irqClear7;
    uint64_t dmaModes9;
    uint64_t dmaModes7;
    uint64_t flags;
    uint64_t frame;
    uint64_t pixels;
    uint64_t bytes;
    uint64_t errorText;
    uint64_t reserved;
};

// Load the library once. Resolve and call hs_init(int*,char***) before create;
// never call into an uninitialized RTS. One opaque device per paired machine,
// no concurrent calls. destroy every device before the matching hs_exit().
// Calls catch Haskell exceptions and return an explicit error reply rather
// than unwinding through C++. create returning NULL is fatal. All library
// function pointers and borrowed memory become invalid before dlclose.
#ifdef __cplusplus
extern "C" {
#endif
void* nds_hs_gpu_create(void);
int nds_hs_gpu_call(void* device, const struct NdsHsGpuRequest* request,
                    struct NdsHsGpuReply* reply);
void nds_hs_gpu_destroy(void* device);
#ifdef __cplusplus
}
static_assert(sizeof(NdsHsGpuRequest) == 8 * sizeof(uint64_t), "GPU request ABI");
static_assert(sizeof(NdsHsGpuReply) == 16 * sizeof(uint64_t), "GPU reply ABI");
#endif
#endif
