/*
    NDS4MiSTer closed-loop Haskell GPU transport.

    This is only the dlopen/FFI transport for the contract in
    sim/melonds_tracer/HsGpuAbi.h. It contains no GPU behavior: every register,
    memory, timing and interrupt decision lives behind nds_hs_gpu_call.
*/

#ifndef HSGPU_H
#define HSGPU_H

#include <cstdint>
#include <memory>
#include <string>

#include "HsGpuAbi.h"

namespace melonDS
{

class HsGpuClient
{
public:
    // Loads `library`, resolves the RTS and device exports, calls hs_init and
    // creates the device. On failure returns null and sets `error`.
    static std::unique_ptr<HsGpuClient> Open(const char* library, std::string& error);
    ~HsGpuClient();
    HsGpuClient(const HsGpuClient&) = delete;
    HsGpuClient& operator=(const HsGpuClient&) = delete;

    // One synchronous service call. False is terminal: Error() carries the
    // device message and every later call fails without touching the device.
    // reply.pixels/errorText are only valid until the next call.
    bool Call(const NdsHsGpuRequest& request, NdsHsGpuReply& reply);

    const std::string& Error() const noexcept { return LastError; }
    uint64_t CallCount() const noexcept { return Calls; }

    // Optional profiling: every 256th call is timed with steady_clock (two clock
    // reads), accumulated per ABI op. No effect on behavior or ordering.
    void EnableProfile() noexcept { Profile = true; }
    struct OpProfile { uint64_t calls = 0; uint64_t sampled = 0; uint64_t sampledNs = 0; };
    const OpProfile& ProfileOf(uint64_t op) const noexcept { return Prof[op < 16 ? op : 15]; }

private:
    HsGpuClient() = default;

    void* Library = nullptr;
    void* Device = nullptr;
    void (*HsExit)() = nullptr;
    int (*CallFn)(void*, const NdsHsGpuRequest*, NdsHsGpuReply*) = nullptr;
    void (*DestroyFn)(void*) = nullptr;
    std::string LastError;
    bool Terminal = false;
    uint64_t Calls = 0;
    bool Profile = false;
    OpProfile Prof[16] {};
};

// A stock melonDS GPU/GPU2D/GPU3D/Renderer state or timing entry point was reached
// while the closed-loop Haskell GPU owns every GPU decision. Reports and aborts;
// there is deliberately no fallback to the stock model.
[[noreturn]] void HsStockGpuForbidden(const char* entryPoint);

}

#endif // HSGPU_H
