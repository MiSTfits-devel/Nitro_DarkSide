// SPDX-License-Identifier: GPL-3.0-or-later
/*
    NDS4MiSTer closed-loop Haskell GPU transport. See HsGpu.h.
*/

#include "HsGpu.h"

#include <dlfcn.h>

#include <cstdlib>
#include <chrono>
#include <cstdio>
#include <cstring>

namespace melonDS
{

namespace
{
template <typename T>
bool Resolve(void* library, const char* name, T& out, std::string& error)
{
    void* symbol = dlsym(library, name);
    if (!symbol)
    {
        error = std::string("missing export ") + name;
        return false;
    }
    std::memcpy(&out, &symbol, sizeof(out));
    return true;
}
}

std::unique_ptr<HsGpuClient> HsGpuClient::Open(const char* library, std::string& error)
{
    const uint32_t probe = 1;
    if (sizeof(void*) != 8 || *reinterpret_cast<const uint8_t*>(&probe) != 1)
    {
        error = "hs gpu ABI v1 requires a little-endian 64-bit host";
        return nullptr;
    }

    std::unique_ptr<HsGpuClient> client(new HsGpuClient());
    client->Library = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!client->Library)
    {
        const char* why = dlerror();
        error = std::string("cannot load ") + library + ": " + (why ? why : "unknown error");
        return nullptr;
    }

    void (*hsInit)(int*, char***) = nullptr;
    void (*hsExit)() = nullptr;
    void* (*create)() = nullptr;
    if (!Resolve(client->Library, "hs_init", hsInit, error) ||
        !Resolve(client->Library, "hs_exit", hsExit, error) ||
        !Resolve(client->Library, "nds_hs_gpu_create", create, error) ||
        !Resolve(client->Library, "nds_hs_gpu_call", client->CallFn, error) ||
        !Resolve(client->Library, "nds_hs_gpu_destroy", client->DestroyFn, error))
    {
        error = std::string(library) + ": " + error;
        return nullptr;
    }

    static char arg0[] = "melonds_fbdump";
    static char* argvStorage[] = { arg0, nullptr };
    static int argc = 1;
    char** argv = argvStorage;
    hsInit(&argc, &argv);
    client->HsExit = hsExit;

    client->Device = create();
    if (!client->Device)
    {
        error = std::string(library) + ": nds_hs_gpu_create returned NULL";
        // The RTS is up; shut it down before the client goes away.
        client->HsExit();
        client->HsExit = nullptr;
        return nullptr;
    }
    return client;
}

HsGpuClient::~HsGpuClient()
{
    // Device first, then the RTS. The library is deliberately never dlclosed:
    // a GHC runtime cannot be unloaded and every borrowed pointer dies here.
    if (Device && DestroyFn) DestroyFn(Device);
    Device = nullptr;
    if (HsExit) HsExit();
    HsExit = nullptr;
}

bool HsGpuClient::Call(const NdsHsGpuRequest& request, NdsHsGpuReply& reply)
{
    std::memset(&reply, 0, sizeof(reply));
    if (Terminal) return false;

    int rc;
    if (Profile)
    {
        OpProfile& p = Prof[request.op < 16 ? request.op : 15];
        p.calls++;
        // Every ADVANCE (LCD/geometry deadline) is timed exactly: 1/256 sampling can alias the
        // HBlank/line pattern. Bus ops stay 1/256 sampled.
        if (request.op == NDS_HS_GPU_ADVANCE || (Calls & 255) == 0)
        {
            const auto t0 = std::chrono::steady_clock::now();
            rc = CallFn(Device, &request, &reply);
            const auto t1 = std::chrono::steady_clock::now();
            p.sampled++;
            p.sampledNs += (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
        }
        else
            rc = CallFn(Device, &request, &reply);
    }
    else
        rc = CallFn(Device, &request, &reply);
    Calls++;

    if (rc == 0 && reply.status == 0 && reply.version == NDS_HS_GPU_ABI_VERSION)
        return true;

    char context[192];
    std::snprintf(context, sizeof(context),
        "hs gpu call failed (req-version %llu op %llu ts %llu cpu %llu addr %08llX width %llu value %llX rc %d status %llu reply-version %llu)",
        (unsigned long long)request.version, (unsigned long long)request.op,
        (unsigned long long)request.timestamp, (unsigned long long)request.cpu,
        (unsigned long long)request.address, (unsigned long long)request.width,
        (unsigned long long)request.value, rc,
        (unsigned long long)reply.status, (unsigned long long)reply.version);
    LastError = context;
    if (reply.errorText)
    {
        const char* text = reinterpret_cast<const char*>(static_cast<uintptr_t>(reply.errorText));
        LastError += ": ";
        LastError += text;
    }
    Terminal = true;
    std::memset(&reply, 0, sizeof(reply));
    return false;
}

[[noreturn]] void HsStockGpuForbidden(const char* entryPoint)
{
    std::fprintf(stderr, "hs-gpu FATAL: stock GPU entry point reached under the closed-loop backend: %s\n", entryPoint);
    std::fflush(stderr);
    std::abort();
}

}
