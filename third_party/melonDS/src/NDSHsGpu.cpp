// SPDX-License-Identifier: GPL-3.0-or-later
/*
    NDS4MiSTer closed-loop Haskell GPU backend: CPU/DMA coordinator.

    When NDS::HsGpu is set, this machine owns only the CPUs, cartridge and every
    non-GPU device. All GPU registers, VRAM/palette/OAM, scanline/capture/render
    timing, display FIFO, geometry FIFO and the GPU interrupt/DMA requests belong
    to the device behind HsGpuAbi.h. Nothing here computes a GPU result; it
    orders bus transactions in time and applies the device's CPU-side effects.

    Time model (the existing interpreter's, not bus micro-cycles):
      * ARM.cpp adds an instruction's cycles to NDS.ARM9Timestamp/ARM7Timestamp
        only after the whole instruction. Every bus access of that instruction
        (code fetch, LDM/STM beats, STRD...) therefore observes the unchanged
        instruction-start clock, which is that access's time.
      * DMA is the only master that moves its clock BEFORE its access (DMA.cpp
        unit wait, then read+write). Its access time is the post-wait clock.
      * A transaction's stamp is always the transacting CPU's own clock in
        system cycles (ARM9Timestamp >> ARM9ClockShift, or ARM7Timestamp).

    Ordering rule R: a GPU transaction at stamp t is issued only while
    t <= the other CPU's clock and t < the device's next deadline D. R makes
    stamps monotone across both CPUs without any clamping: the other CPU's past
    stamps were <= this CPU's earlier clock, its future stamps are >= its clock.
    Min-clock-first stepping guarantees R for instructions, DMA units that touch
    the GPU are gated (HsDMAGate) so their wait may be split but their access
    time never changes, and HsBus asserts R/monotonicity on every transaction.
    Deadlines are serviced at their exact time (ADVANCE(D)), never at a later
    time, before any transaction at a stamp >= D.
*/

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstring>

#include "NDS.h"
#include "HsGpu.h"
#include "Platform.h"

namespace melonDS
{

namespace
{

constexpr u64 kNoDeadline = NDS_HS_GPU_NO_DEADLINE;

// ARM9 IO registers the device owns. Ranges are [lo, hi) in bytes; an access is
// owned only if all of its bytes are inside one range.
struct IORange { u32 lo, hi; };
constexpr IORange kOwned9[] =
{
    {0x04000000, 0x04000070},   // engine A: DISPCNT.. DISPSTAT/VCOUNT.. DISPCAPCNT.. MASTER_BRIGHT
    {0x04001000, 0x04001070},   // engine B
    {0x04000240, 0x04000247},   // VRAMCNT A-G (0x247 is WRAMCNT: CPU side)
    {0x04000248, 0x0400024A},   // VRAMCNT H-I
    {0x04000304, 0x04000306},   // POWCNT1
    {0x04000320, 0x040006A4},   // 3D engine incl. GXFIFO
};

bool Owned9(u32 addr, u32 width)
{
    const u64 end = (u64)addr + width;
    for (const IORange& r : kOwned9)
        if (addr >= r.lo && end <= r.hi) return true;
    return false;
}

bool Owned9Overlaps(u32 addr)
{
    // Any byte of an aligned 32-bit access starting here may belong to the device.
    const u32 base = addr & ~3u;
    for (const IORange& r : kOwned9)
        if (base < r.hi && base + 4 > r.lo) return true;
    return false;
}

constexpr u32 kGPUIRQMask = (1u << IRQ_VBlank) | (1u << IRQ_HBlank) | (1u << IRQ_VCount) | (1u << IRQ_GXFIFO);

NdsHsGpuRequest MakeRequest(u64 op, u64 timestamp)
{
    NdsHsGpuRequest request {};
    request.version = NDS_HS_GPU_ABI_VERSION;
    request.op = op;
    request.timestamp = timestamp;
    return request;
}

}

bool NDS::AttachHsGpu(HsGpuClient* client, std::string& error)
{
    if (!client) { error = "hs gpu: null client"; return false; }
    if (ConsoleType != 0) { error = "hs gpu: DSi mode is unsupported"; return false; }
    if (IsJITEnabled()) { error = "hs gpu: JIT is unsupported (interpreter only)"; return false; }
    HsGpu = client;
    HsState = HsGpuState();
    HsState.Frame.assign(256 * 384, 0);
    // The device's next deadline is installed as Event_LCD; the stock LCD
    // callbacks must never run, so the GPU's registration is replaced.
    RegisterEventFuncs(Event_LCD, this, { MakeEventThunk(NDS, HsProxyEvent) });
    return true;
}

void NDS::HsFail(const char* fmt, ...)
{
    if (HsState.Failed) return;
    char text[512];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(text, sizeof(text), fmt, ap);
    va_end(ap);
    HsState.Failed = true;
    HsState.Error = text;
    std::fprintf(stderr, "hs-gpu FATAL: %s\n", text);
    std::fflush(stderr);
    Running = false;
}

bool NDS::HsCall(const NdsHsGpuRequest& request, NdsHsGpuReply& reply)
{
    if (HsState.Failed) return false;
    if (!HsGpu->Call(request, reply))
    {
        HsFail("%s", HsGpu->Error().c_str());
        return false;
    }
    return true;
}

bool NDS::HsGpuOwnsAddr(u32 cpu, u32 addr) const noexcept
{
    if (cpu == 0)
    {
        const u32 page = addr >> 24;
        if (page >= 5 && page <= 7) return true;
        return page == 4 && Owned9Overlaps(addr);
    }
    if ((addr >> 24) == 6) return true;
    return (addr >= 0x04000004 && addr < 0x04000008) || (addr & ~1u) == 0x04000240;
}

void NDS::HsReset()
{
    HsState.Failed = false;
    HsState.Error.clear();
    HsState.InStep = false;
    HsState.InARM9Instruction = false;
    HsState.InstructionGXStalled = false;
    HsState.InstructionClock = 0;
    HsState.InstructionScope = 0;
    HsState.NextInstructionScope = 0;
    HsState.BootDone = false;
    HsState.FrameDone = false;
    HsState.FrameValid = false;
    HsState.FetchPending = false;
    HsState.FrameStartIssued = false;
    HsState.LastStamp = 0;
    HsState.Deadline = kNoDeadline;
    HsState.GXStalled = false;
    HsState.FifoLtHalf = true;
    HsState.DMABlocked = false;
    HsState.Transactions = 0;
    HsState.Services = 0;
    HsState.SameDeadlineRepeats = 0;

    NdsHsGpuRequest request = MakeRequest(NDS_HS_GPU_RESET, 0);
    NdsHsGpuReply reply {};
    if (!HsCall(request, reply)) return;
    HsApplyReply(request, reply, 0);
}

void NDS::HsApplyReply(const NdsHsGpuRequest& request, const NdsHsGpuReply& reply, u32 cpu)
{
    if (HsState.Failed) return;

    if (reply.nextDeadline != kNoDeadline && reply.nextDeadline < request.timestamp)
    {
        HsFail("device deadline %llu precedes request stamp %llu (op %llu)",
            (unsigned long long)reply.nextDeadline, (unsigned long long)request.timestamp,
            (unsigned long long)request.op);
        return;
    }
    if ((reply.irqSet9 | reply.irqClear9 | reply.irqSet7 | reply.irqClear7) >> 32)
    {
        HsFail("device returned an IRQ mask above bit 31");
        return;
    }
    if ((reply.irqSet9 & reply.irqClear9) || (reply.irqSet7 & reply.irqClear7))
    {
        HsFail("device returned overlapping IRQ set/clear masks");
        return;
    }
    if (((reply.irqSet9 | reply.irqClear9 | reply.irqSet7 | reply.irqClear7) & ~(u64)kGPUIRQMask) != 0)
    {
        HsFail("device changed a non-GPU IRQ bit (set9 %llX clr9 %llX set7 %llX clr7 %llX)",
            (unsigned long long)reply.irqSet9, (unsigned long long)reply.irqClear9,
            (unsigned long long)reply.irqSet7, (unsigned long long)reply.irqClear7);
        return;
    }

    const bool completed = (reply.flags & NDS_HS_GPU_FRAME_COMPLETED) != 0;
    // The borrowed frame is consumed before any effect is applied.
    if (completed)
    {
        HsState.FrameDone = true;
        HsState.FrameNumber = (u32)reply.frame;
        if ((reply.flags & NDS_HS_GPU_PIXELS_VALID) && reply.bytes == NDS_HS_GPU_FRAME_BYTES && reply.pixels)
        {
            std::memcpy(HsState.Frame.data(),
                reinterpret_cast<const void*>(static_cast<uintptr_t>(reply.pixels)),
                NDS_HS_GPU_FRAME_BYTES);
            HsState.FrameValid = true;
            HsState.FetchPending = false;
        }
        else
            HsState.FetchPending = true;
    }

    // Next device event as the Event_LCD proxy, exact and absolute.
    if (reply.nextDeadline == HsState.Deadline && reply.nextDeadline != kNoDeadline &&
        request.op == NDS_HS_GPU_ADVANCE && request.timestamp == reply.nextDeadline)
    {
        if (++HsState.SameDeadlineRepeats > 4096)
        {
            HsFail("device re-armed deadline %llu without progress", (unsigned long long)reply.nextDeadline);
            return;
        }
    }
    else
        HsState.SameDeadlineRepeats = 0;
    HsState.Deadline = reply.nextDeadline;
    if (reply.nextDeadline == kNoDeadline)
        SchedListMask &= ~(1u << Event_LCD);
    else
    {
        SchedList[Event_LCD].Timestamp = reply.nextDeadline;
        SchedList[Event_LCD].FuncID = 0;
        SchedList[Event_LCD].Param = 0;
        SchedListMask |= 1u << Event_LCD;
        Reschedule(reply.nextDeadline);
    }

    // CPU-side effects, after the call has returned: clears then sets; DMA
    // stops then starts; GX stall level last.
    if (reply.irqClear9) ClearIRQMask(0, (u32)reply.irqClear9);
    if (reply.irqClear7) ClearIRQMask(1, (u32)reply.irqClear7);
    for (u32 bit = 0; bit < 32; bit++)
        if ((reply.irqSet9 >> bit) & 1) SetIRQ(0, bit);
    for (u32 bit = 0; bit < 32; bit++)
        if ((reply.irqSet7 >> bit) & 1) SetIRQ(1, bit);

    for (u32 target = 0; target < 2; target++)
    {
        const u64 modes = target == 0 ? reply.dmaModes9 : reply.dmaModes7;
        for (u32 mode = 0; mode < 32; mode++)
            if ((modes >> (32 + mode)) & 1) StopDMAs(target, mode);
    }
    for (u32 target = 0; target < 2; target++)
    {
        const u64 modes = target == 0 ? reply.dmaModes9 : reply.dmaModes7;
        for (u32 mode = 0; mode < 32; mode++)
            if ((modes >> mode) & 1) CheckDMAs(target, mode);
    }

    const bool stalled = (reply.flags & NDS_HS_GPU_GX_STALLED) != 0;
    if (stalled && !(CPUStop & CPUStop_GXStall))
    {
        const int saved = CurCPU;
        CurCPU = (int)cpu;
        GXFIFOStall();
        CurCPU = saved;
    }
    else if (!stalled && (CPUStop & CPUStop_GXStall))
        GXFIFOUnstall();
    HsState.GXStalled = stalled;
    HsState.FifoLtHalf = (reply.flags & NDS_HS_GPU_FIFO_LT_HALF) != 0;

    if (completed)
    {
        if (HsState.FetchPending) HsFetchFrame(request.timestamp);
        // The next machine frame begins at the completion time, before any
        // further transaction can be stamped.
        HsFrameStart(request.timestamp);
    }
}

void NDS::HsFetchFrame(u64 stamp)
{
    if (HsState.Failed || !HsState.FetchPending) return;
    NdsHsGpuRequest request = MakeRequest(NDS_HS_GPU_FRAME, stamp);
    NdsHsGpuReply reply {};
    if (!HsCall(request, reply)) return;
    if (reply.bytes != NDS_HS_GPU_FRAME_BYTES || !reply.pixels)
    {
        HsFail("FRAME returned no pixels after a completion pulse");
        return;
    }
    std::memcpy(HsState.Frame.data(),
        reinterpret_cast<const void*>(static_cast<uintptr_t>(reply.pixels)), NDS_HS_GPU_FRAME_BYTES);
    HsState.FrameValid = true;
    HsState.FrameNumber = (u32)reply.frame;
    HsState.FetchPending = false;
    HsApplyReply(request, reply, 0);
}

void NDS::HsFrameStart(u64 stamp)
{
    if (HsState.Failed) return;
    if (stamp < HsState.LastStamp)
    {
        HsFail("FRAME_START stamp %llu precedes last stamp %llu",
            (unsigned long long)stamp, (unsigned long long)HsState.LastStamp);
        return;
    }
    u64 armed = 0;
    for (u32 mode = 0; mode < 8; mode++)
        if (DMAsInMode(0, mode)) armed |= 1ull << mode;
    NdsHsGpuRequest request = MakeRequest(NDS_HS_GPU_FRAME_START, stamp);
    NdsHsGpuReply reply {};
    request.value = armed;
    HsState.FrameStartIssued = true;
    if (!HsCall(request, reply)) return;
    HsState.LastStamp = stamp;
    HsState.Services++;
    if (HsState.TxnLog)
        std::fprintf(HsState.TxnLog, "frame-start stamp=%llu dma-armed=%02llX\n",
            (unsigned long long)stamp, (unsigned long long)armed);
    HsApplyReply(request, reply, 0);
}

void NDS::HsServiceDeadlines(u64 through)
{
    while (!HsState.Failed && HsState.Deadline != kNoDeadline && HsState.Deadline <= through)
    {
        const u64 deadline = HsState.Deadline;
        const u64 c9 = ARM9Timestamp >> ARM9ClockShift;
        if (deadline > std::min(c9, (u64)ARM7Timestamp))
        {
            HsFail("deadline %llu serviced before both CPUs reached it (arm9 %llu arm7 %llu)",
                (unsigned long long)deadline, (unsigned long long)c9, (unsigned long long)ARM7Timestamp);
            return;
        }
        if (deadline < HsState.LastStamp)
        {
            HsFail("deadline %llu precedes last stamp %llu", (unsigned long long)deadline,
                (unsigned long long)HsState.LastStamp);
            return;
        }
        NdsHsGpuRequest request = MakeRequest(NDS_HS_GPU_ADVANCE, deadline);
        NdsHsGpuReply reply {};
        if (!HsCall(request, reply)) return;
        HsState.LastStamp = deadline;
        HsState.Services++;
        if (HsState.TxnLog)
            std::fprintf(HsState.TxnLog, "service deadline=%llu clk9=%llu clk7=%llu next=%llu set9=%llX clr9=%llX set7=%llX clr7=%llX dma9=%llX dma7=%llX fl=%llX\n",
                (unsigned long long)deadline, (unsigned long long)ARM9Timestamp,
                (unsigned long long)ARM7Timestamp, (unsigned long long)reply.nextDeadline,
                (unsigned long long)reply.irqSet9, (unsigned long long)reply.irqClear9, (unsigned long long)reply.irqSet7,
                (unsigned long long)reply.irqClear7, (unsigned long long)reply.dmaModes9, (unsigned long long)reply.dmaModes7,
                (unsigned long long)reply.flags);
        HsApplyReply(request, reply, 0);
    }
}

void NDS::HsProxyEvent(u32)
{
    HsServiceDeadlines(SysTimestamp);
}

u32 NDS::HsBus(u32 op, u32 cpu, u32 addr, u32 width, u32 value)
{
    if (HsState.Failed) return 0;

    // The transacting master's actual clock (see the file comment).
    const u64 stamp = cpu == 0 ? (ARM9Timestamp >> ARM9ClockShift) : ARM7Timestamp;
    const u64 other = cpu == 0 ? ARM7Timestamp : (ARM9Timestamp >> ARM9ClockShift);

    if (!HsState.InStep && HsState.BootDone)
    {
        HsFail("GPU bus access outside a CPU/DMA step (cpu %u op %u addr %08X): debug bus access to GPU state is unsupported in hs mode",
            cpu, op, addr);
        return 0;
    }
    if (stamp < HsState.LastStamp)
    {
        HsFail("GPU transaction order violation: cpu %u op %u addr %08X stamp %llu < last %llu",
            cpu, op, addr, (unsigned long long)stamp, (unsigned long long)HsState.LastStamp);
        return 0;
    }
    if (stamp > other)
    {
        HsFail("GPU transaction rule R violation: cpu %u op %u addr %08X stamp %llu > other CPU clock %llu",
            cpu, op, addr, (unsigned long long)stamp, (unsigned long long)other);
        return 0;
    }
    // Scheduled device events at T run before a bus transaction at T.
    HsServiceDeadlines(stamp);
    if (HsState.Failed) return 0;
    if (HsState.Deadline != kNoDeadline && HsState.Deadline <= stamp)
    {
        HsFail("unserviced deadline %llu at transaction stamp %llu", (unsigned long long)HsState.Deadline,
            (unsigned long long)stamp);
        return 0;
    }

    NdsHsGpuRequest request = MakeRequest(op, stamp);
    NdsHsGpuReply reply {};
    request.cpu = cpu;
    request.address = addr;
    request.width = width;
    request.value = value;
    if (cpu == 0 && op == NDS_HS_GPU_IO_WRITE && width == 4 &&
        HsState.InARM9Instruction && HsState.InstructionClock == ARM9Timestamp)
    {
        const bool command = addr >= 0x04000400 && addr < 0x040005CC;
        if (HsState.GXStalled)
        {
            const bool gxIO = addr == 0x04000060 ||
                (addr >= 0x04000320 && addr < 0x040006A4);
            if (!HsState.InstructionGXStalled || !HsState.InstructionScope || !gxIO)
            {
                HsFail("unsupported stalled ARM9 GPU write at %08X outside its originating GX instruction", addr);
                return 0;
            }
            op = NDS_HS_GPU_IO_CONTINUE;
            request.op = op;
            request.instructionScope = HsState.InstructionScope;
        }
        else if (command)
        {
            if (!HsState.InstructionScope)
            {
                if (++HsState.NextInstructionScope == 0)
                {
                    HsFail("ARM9 GX instruction scope counter exhausted");
                    return 0;
                }
                HsState.InstructionScope = HsState.NextInstructionScope;
            }
            request.instructionScope = HsState.InstructionScope;
        }
    }
    if (!HsCall(request, reply)) return 0;
    HsState.LastStamp = stamp;
    HsState.Transactions++;
    if (HsState.TxnLog)
        std::fprintf(HsState.TxnLog, "txn op=%u cpu=%u addr=%08X w=%u val=%08X scope=%llu stamp=%llu clk9=%llu clk7=%llu next=%llu ret=%llX set9=%llX clr9=%llX set7=%llX clr7=%llX dma9=%llX dma7=%llX fl=%llX\n",
            op, cpu, addr, width, value, (unsigned long long)request.instructionScope, (unsigned long long)stamp, (unsigned long long)ARM9Timestamp,
            (unsigned long long)ARM7Timestamp, (unsigned long long)reply.nextDeadline, (unsigned long long)reply.value,
            (unsigned long long)reply.irqSet9, (unsigned long long)reply.irqClear9, (unsigned long long)reply.irqSet7,
            (unsigned long long)reply.irqClear7, (unsigned long long)reply.dmaModes9, (unsigned long long)reply.dmaModes7,
            (unsigned long long)reply.flags);
    // Eligibility belongs to this exact interpreter instruction, not merely a
    // coarse system timestamp (two ARM9 tick values can have the same stamp).
    if (!HsState.GXStalled && (reply.flags & NDS_HS_GPU_GX_STALLED) &&
        HsState.InARM9Instruction && cpu == 0 && op == NDS_HS_GPU_IO_WRITE &&
        width == 4 && addr >= 0x04000400 && addr < 0x040005CC &&
        HsState.InstructionClock == ARM9Timestamp)
        HsState.InstructionGXStalled = true;
    HsApplyReply(request, reply, cpu);

    const u32 mask = width >= 4 ? 0xFFFFFFFFu : ((1u << (width * 8)) - 1);
    return (u32)reply.value & mask;
}

void NDS::HsIFAck(u32 cpu, u32 mask)
{
    HsBus(NDS_HS_GPU_IF_ACK, cpu, 0x04000214, 4, mask);
}

void NDS::CheckGXFIFODMA()
{
    if (!HsGpu)
    {
        GPU.GPU3D.CheckFIFODMA();
        return;
    }
    if (HsState.Failed) return;

    // The device owns the FIFO level. Bring it to this master's clock (a pure
    // catch-up below the pending deadline) and use the level in the reply.
    const u64 stamp = ARM9Timestamp >> ARM9ClockShift;
    if (!HsState.InStep && HsState.BootDone)
    {
        HsFail("GXFIFO DMA check outside a CPU/DMA step");
        return;
    }
    if (stamp < HsState.LastStamp || stamp > ARM7Timestamp)
    {
        HsFail("GXFIFO DMA check stamp %llu violates ordering (last %llu, arm7 %llu)",
            (unsigned long long)stamp, (unsigned long long)HsState.LastStamp, (unsigned long long)ARM7Timestamp);
        return;
    }
    HsServiceDeadlines(stamp);
    if (HsState.Failed) return;

    NdsHsGpuRequest request = MakeRequest(NDS_HS_GPU_ADVANCE, stamp);
    NdsHsGpuReply reply {};
    if (!HsCall(request, reply)) return;
    HsState.LastStamp = stamp;
    HsState.Services++;
    if (HsState.TxnLog)
        std::fprintf(HsState.TxnLog, "gxfifo-dma-check stamp=%llu clk9=%llu\n",
            (unsigned long long)stamp, (unsigned long long)ARM9Timestamp);
    HsApplyReply(request, reply, 0);
    if (!HsState.Failed && HsState.FifoLtHalf)
        CheckDMAs(0, 0x07);
}

bool NDS::HsDMAGate(u32 cpu, u64& waitTicks)
{
    if (HsState.Failed) { waitTicks = 0; return true; }

    const u32 shift = cpu == 0 ? ARM9ClockShift : 0;
    u64& clock = cpu == 0 ? ARM9Timestamp : ARM7Timestamp;
    const u64 other = cpu == 0 ? ARM7Timestamp : (ARM9Timestamp >> ARM9ClockShift);
    const u64 deadline = HsState.Deadline;
    const u64 deadlineTicks = deadline == kNoDeadline ? kNoDeadline : (deadline << shift);

    // Wait progress is independent of transfer permission: consume the unit's
    // wait, but never past the exact deadline (it must be serviced when both
    // CPUs are there) and never past the unit's own access time.
    const u64 access = clock + waitTicks;
    const u64 advanceTo = std::min(access, deadlineTicks);
    if (advanceTo > clock)
    {
        waitTicks -= advanceTo - clock;
        clock = advanceTo;
    }
    if (waitTicks != 0)
    {
        HsState.DMABlocked = true;
        if (HsState.TxnLog)
            std::fprintf(HsState.TxnLog, "dma-wait-split cpu=%u clock=%llu deadline=%llu remaining-ticks=%llu\n", cpu,
                (unsigned long long)(clock >> shift), (unsigned long long)deadline, (unsigned long long)waitTicks);
        return false;
    }

    // The access happens at the original post-wait clock, only when rule R and
    // event-before-bus hold; otherwise the unit waits unchanged.
    const u64 stamp = clock >> shift;
    if ((deadline != kNoDeadline && stamp >= deadline) || stamp > other)
    {
        HsState.DMABlocked = true;
        if (HsState.TxnLog)
            std::fprintf(HsState.TxnLog, "dma-deferred cpu=%u access-stamp=%llu deadline=%llu other=%llu\n", cpu,
                (unsigned long long)stamp, (unsigned long long)deadline, (unsigned long long)other);
        return false;
    }
    return true;
}

void NDS::HsStep(u32 cpu, u64 target)
{
    HsState.InStep = true;
    HsState.BootDone = true;
    CurCPU = (int)cpu;
    if (cpu == 0)
    {
        ARM9Target = target;
        if (CPUStop & CPUStop_GXStall)
        {
            // The device owns the GX FIFO: ARM9 (and its DMA) is blocked until
            // the device lowers the stall level at one of its own events, which
            // can never be earlier than this target.
            ARM9Timestamp = target;
        }
        else if (CPUStop & CPUStop_DMA9)
        {
            // Stock never preempts a unit between its wait and its access. A unit
            // whose wait was split at a device deadline is still in flight, so its
            // channel resumes first even if a higher channel was just started.
            int first = 0;
            for (int i = 0; i < 4; i++)
                if (DMAs[i].HsPendingUnit()) { first = i; break; }
            for (int i = first; i < 4; i++)
            {
                if (HsState.DMABlocked || (i > first && (CPUStop & CPUStop_GXStall))) break;
                DMAs[i].Run();
            }
        }
        else
            ARM9.Execute<CPUExecuteMode::Interpreter>();
        RunTimers(0);
    }
    else
    {
        ARM7Target = target;
        if (CPUStop & CPUStop_DMA7)
        {
            // A unit whose wait was split at a device deadline is in flight: it
            // finishes before any higher channel started by that deadline's effects.
            int first = 4;
            for (int i = 4; i < 8; i++)
                if (DMAs[i].HsPendingUnit()) { first = i; break; }
            for (int i = first; i < 8; i++)
            {
                if (HsState.DMABlocked) break;
                DMAs[i].Run();
            }
        }
        else
            ARM7.Execute<CPUExecuteMode::Interpreter>();
        RunTimers(1);
    }
    HsState.InStep = false;
}

u32 NDS::RunFrameHs()
{
    Current = this;
    if (HsState.Failed || !Running) return 263;
    if (CPUStop & CPUStop_Sleep)
    {
        HsFail("sleep mode is unsupported with the hs gpu backend");
        return 263;
    }

    FrameStartTimestamp = SysTimestamp;
    LagFrameFlag = true;
    HsState.FrameDone = false;
    if (!HsState.FrameStartIssued) HsFrameStart(HsState.LastStamp);

    u32 idle = 0;
    while (Running && !HsState.Failed && !HsState.FrameDone)
    {
        if (CPUStop & CPUStop_Sleep)
        {
            // ARM7 requested sleep (HALTCNT) during this frame: the sleep path drives the stock
            // GPU/LCD, which this backend does not support. Stop before any further event or CPU runs.
            HsFail("sleep mode (HALTCNT) requested during the frame is unsupported with the hs gpu backend");
            break;
        }
        const u64 c9s = ARM9Timestamp >> ARM9ClockShift;
        const u64 sys = std::min(c9s, (u64)ARM7Timestamp);
        // Events whose time both CPUs have reached: the device's deadline is
        // serviced at its exact time first (id 0), then the other devices.
        CurCPU = 1;
        RunSystem(sys);
        if (!Running || HsState.Failed || HsState.FrameDone) break;

        const u64 quantum = NextTarget();
        const u64 quantum9 = quantum << ARM9ClockShift;
        const u64 c9 = ARM9Timestamp, c7 = ARM7Timestamp;
        const bool can9 = c9 < quantum9;
        const bool can7 = c7 < quantum;
        if (!can9 && !can7)
        {
            if (++idle > 1000)
                HsFail("hs scheduler made no progress at arm9 %llu arm7 %llu", (unsigned long long)c9, (unsigned long long)c7);
            continue;
        }

        u32 cpu;
        if (can9 && can7) cpu = ((c9 >> ARM9ClockShift) <= c7) ? 0 : 1;
        else cpu = can9 ? 0 : 1;
        u64 target;
        if (cpu == 0) target = can7 ? std::min(quantum9, (c7 + 1) << ARM9ClockShift) : quantum9;
        else          target = can9 ? std::min(quantum, (c9 >> ARM9ClockShift) + 1) : quantum;

        HsState.DMABlocked = false;
        HsStep(cpu, target);

        if (ARM9Timestamp == c9 && ARM7Timestamp == c7)
        {
            if (++idle > 1000)
                HsFail("hs scheduler step made no progress (cpu %u arm9 %llu arm7 %llu)", cpu,
                    (unsigned long long)c9, (unsigned long long)c7);
        }
        else
            idle = 0;
    }

    SPU.BufferAudio();
    NumFrames++;
    if (LagFrameFlag) NumLagFrames++;
    return 263;
}

bool NDS::HsIORead9(u32 addr, u32 width, u32& out)
{
    // Mixed words: VRAMCNT bytes stay with the device, WRAMCNT (0x247) stays here.
    if (width == 4 && addr == 0x04000244)
    {
        const u32 lo = HsBus(NDS_HS_GPU_IO_READ, 0, 0x04000244, 2, 0);
        const u32 g = HsBus(NDS_HS_GPU_IO_READ, 0, 0x04000246, 1, 0);
        out = lo | (g << 16) | ((u32)WRAMCnt << 24);
        return true;
    }
    if (width == 2 && addr == 0x04000246)
    {
        out = HsBus(NDS_HS_GPU_IO_READ, 0, 0x04000246, 1, 0) | ((u32)WRAMCnt << 8);
        return true;
    }
    if (width == 4 && (addr == 0x04000248 || addr == 0x04000304))
    {
        // Stock zero-extends these 16-bit registers in a word read.
        out = HsBus(NDS_HS_GPU_IO_READ, 0, addr, 2, 0);
        return true;
    }
    if (!Owned9(addr, width)) return false;
    out = HsBus(NDS_HS_GPU_IO_READ, 0, addr, width, 0);
    return true;
}

bool NDS::HsIOWrite9(u32 addr, u32 width, u32 val)
{
    if (width == 4 && addr == 0x04000244)
    {
        HsBus(NDS_HS_GPU_IO_WRITE, 0, 0x04000244, 2, val & 0xFFFF);
        HsBus(NDS_HS_GPU_IO_WRITE, 0, 0x04000246, 1, (val >> 16) & 0xFF);
        MapSharedWRAM(val >> 24);
        return true;
    }
    if (width == 2 && addr == 0x04000246)
    {
        HsBus(NDS_HS_GPU_IO_WRITE, 0, 0x04000246, 1, val & 0xFF);
        MapSharedWRAM(val >> 8);
        return true;
    }
    if (width == 4 && (addr == 0x04000248 || addr == 0x04000304))
    {
        HsBus(NDS_HS_GPU_IO_WRITE, 0, addr, 2, val & 0xFFFF);
        return true;
    }
    if (!Owned9(addr, width)) return false;
    HsBus(NDS_HS_GPU_IO_WRITE, 0, addr, width, val);
    return true;
}

bool NDS::HsIORead7(u32 addr, u32 width, u32& out)
{
    const bool dispstat = addr >= 0x04000004 && (u64)addr + width <= 0x04000008;
    if (!dispstat && !(width == 1 && addr == 0x04000240)) return false;
    out = HsBus(NDS_HS_GPU_IO_READ, 1, addr, width, 0);
    return true;
}

bool NDS::HsIOWrite7(u32 addr, u32 width, u32 val)
{
    if (!(addr >= 0x04000004 && (u64)addr + width <= 0x04000008)) return false;
    HsBus(NDS_HS_GPU_IO_WRITE, 1, addr, width, val);
    return true;
}

// Control scheduler: identical step selection/targets to RunFrameHs, but every GPU
// decision is made by the stock melonDS GPU (its events run through RunSystem,
// GPU3D::Run after each ARM9 step as stock does after each slice).
u32 NDS::RunFrameInterleaved()
{
    Current = this;
    if (!Running) return 263;
    if (CPUStop & CPUStop_Sleep)
    {
        Platform::Log(Platform::LogLevel::Error, "interleaved control scheduler: sleep unsupported\n");
        return 263;
    }

    FrameStartTimestamp = SysTimestamp;
    GPU.TotalScanlines = 0;
    LagFrameFlag = true;
    GPU.StartFrame();

    u32 idle = 0;
    while (Running && GPU.TotalScanlines == 0)
    {
        const u64 c9s = ARM9Timestamp >> ARM9ClockShift;
        CurCPU = 1;
        RunSystem(std::min(c9s, (u64)ARM7Timestamp));
        if (GPU.TotalScanlines != 0) break;

        const u64 quantum = NextTarget();
        const u64 quantum9 = quantum << ARM9ClockShift;
        const u64 c9 = ARM9Timestamp, c7 = ARM7Timestamp;
        const bool can9 = c9 < quantum9;
        const bool can7 = c7 < quantum;
        if (!can9 && !can7)
        {
            if (++idle > 100000) { Platform::Log(Platform::LogLevel::Error, "interleaved control: no progress\n"); Running = false; }
            continue;
        }
        u32 cpu;
        if (can9 && can7) cpu = ((c9 >> ARM9ClockShift) <= c7) ? 0 : 1;
        else cpu = can9 ? 0 : 1;
        u64 target;
        if (cpu == 0) target = can7 ? std::min(quantum9, (c7 + 1) << ARM9ClockShift) : quantum9;
        else          target = can9 ? std::min(quantum, (c9 >> ARM9ClockShift) + 1) : quantum;

        if (cpu == 0)
        {
            CurCPU = 0;
            ARM9Target = target;
            if (CPUStop & CPUStop_GXStall)
            {
                const s32 cycles = GPU.GPU3D.CyclesToRunFor();
                ARM9Timestamp = std::min(ARM9Target, ARM9Timestamp + ((u64)cycles << ARM9ClockShift));
            }
            else if (CPUStop & CPUStop_DMA9)
            {
                DMAs[0].Run();
                if (!(CPUStop & CPUStop_GXStall)) DMAs[1].Run();
                if (!(CPUStop & CPUStop_GXStall)) DMAs[2].Run();
                if (!(CPUStop & CPUStop_GXStall)) DMAs[3].Run();
            }
            else
                ARM9.Execute<CPUExecuteMode::Interpreter>();
            RunTimers(0);
            GPU.GPU3D.Run();
        }
        else
        {
            CurCPU = 1;
            ARM7Target = target;
            if (CPUStop & CPUStop_DMA7)
            {
                DMAs[4].Run(); DMAs[5].Run(); DMAs[6].Run(); DMAs[7].Run();
            }
            else
                ARM7.Execute<CPUExecuteMode::Interpreter>();
            RunTimers(1);
        }
        if (ARM9Timestamp == c9 && ARM7Timestamp == c7)
        {
            if (++idle > 100000) { Platform::Log(Platform::LogLevel::Error, "interleaved control: step made no progress\n"); Running = false; }
        }
        else
            idle = 0;
    }

    SPU.BufferAudio();
    NumFrames++;
    if (LagFrameFlag) NumLagFrames++;
    return Running ? GPU.TotalScanlines : 263;
}

}
