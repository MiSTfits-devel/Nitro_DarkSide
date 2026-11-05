// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Truffle
//
// Differential oracle for the Clash edge-walk model.
//
// Includes the production melonDS header and exposes the private Slope class to
// this test-only translation unit. No melonDS source is modified. Emits a
// deterministic case stream on stdout; the Haskell checker consumes it.
#include <algorithm>
#include <atomic>
#include <thread>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#define private public
#include "GPU3D_Soft.h"
#include "NDS4MiSTer_GXClipMath.h"
#undef private

using melonDS::s32;
using melonDS::u32;

static uint64_t rngState = 0x9E3779B97F4A7C15ULL;

static uint64_t nextRand()
{
    uint64_t x = rngState;
    x ^= x << 0xD;
    x ^= x >> 0x7;
    x ^= x << 0x11;
    rngState = x;
    return x;
}

static s32 randCoord(s32 lo, s32 hi)
{
    const uint32_t span = static_cast<uint32_t>(hi - lo + 0x1);
    return lo + static_cast<s32>(nextRand() % span);
}

template <int Side>
static void runDepthCase(s32 x0, s32 x1, s32 y0, s32 y1, s32 y,
                         s32 w0, s32 w1, s32 z0, s32 z1, bool wbuffer)
{
    if (y1 <= y0) return;
    melonDS::SoftRenderer3D::Slope<Side> slope;
    const s32 ylo = y0 < y1 ? y0 : y1;
    const s32 yhi = y0 < y1 ? y1 : y0;
    const s32 sy = y < ylo ? ylo : (y > yhi ? yhi : y);
    slope.Setup(x0, x1, y0, y1, w0, w1, sy, wbuffer);

    const s32 ymin = y0 < y1 ? y0 : y1;
    const s32 ymax = (y0 < y1 ? y1 : y0) - ((y0 < y1 || y1 < y0) ? 0x1 : 0x0);
    const s32 ix0 = slope.Interp.x0;
    const s32 ix1 = slope.Interp.x1;
    std::printf("DEPTH %d %d %d %d %d %d %d %d %d %d %d %d %d",
        Side, x0, x1, y0, y1, w0, w1, y, wbuffer ? 0x1 : 0x0,
        z0, z1, ix0, ix1);
    for (unsigned i = 0; i < 0x8; ++i)
    {
        const s32 sy = ymin + ((ymax - ymin) * static_cast<s32>(i)) / 0x7;
        slope.Interp.SetX(sy);
        const s32 z = slope.Interp.InterpolateZ(z0, z1);
        std::printf(" %d", z);
    }
    std::printf("\n");
}

template <int Side>
static void runCase(s32 x0, s32 x1, s32 y0, s32 y1, s32 y)
{
    melonDS::SoftRenderer3D::Slope<Side> slope;
    const s32 x = slope.Setup(x0, x1, y0, y1, 0x0, 0x0, y, false);
    s32 l0, c0, l1, c1;
    slope.template EdgeParams<false>(&l0, &c0);
    slope.template EdgeParams<true>(&l1, &c1);
    std::printf(
        "CASE %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %u %d %d %d %d %d\n",
        Side, x0, x1, y0, y1, y, x, slope.Increment, slope.dx,
        slope.Negative ? 0x1 : 0x0, slope.XMajor ? 0x1 : 0x0,
        slope.xmin, slope.xmax, slope.xlen, slope.ylen,
        static_cast<unsigned>(slope.xlen_reciprocal), slope.xcov_incr,
        l0, c0, l1, c1);
    for (unsigned step = 0; step < 0x8; ++step)
    {
        const s32 sx = slope.Step();
        std::printf("STEP %d %d\n", slope.dx, sx);
    }
}

int main(int argc, char** argv)
{
    unsigned cases = 0x1000;
    if (argc > 0x1) cases = static_cast<unsigned>(std::strtoul(argv[0x1], nullptr, 0x0));

    // Deliberate corner cases first: zero-height, square, one-pixel, negative,
    // X-major, and lengths on both sides of the reciprocal-table bound.
    runCase<0>(0x0, 0x0, 0x0, 0x0, 0x0);
    runCase<1>(0x0, 0x0, 0x0, 0x0, 0x0);
    runCase<0>(0x0, 0x0, 0x0, 0x20, 0x10);
    runCase<1>(0x0, 0x0, 0x0, 0x20, 0x10);
    runCase<0>(0x0, 0x20, 0x0, 0x20, 0x10);
    runCase<1>(0x0, 0x20, 0x0, 0x20, 0x10);
    runCase<0>(0x20, 0x0, 0x0, 0x20, 0x10);
    runCase<1>(0x20, 0x0, 0x0, 0x20, 0x10);
    runCase<0>(0x0, 0x1, 0x0, 0x20, 0x10);
    runCase<1>(0x0, 0x1, 0x0, 0x20, 0x10);
    runCase<0>(0x0, 0x201, 0x0, 0x20, 0x10);
    runCase<1>(0x0, 0x201, 0x0, 0x20, 0x10);
    runCase<0>(0x0, 0x200, 0x0, 0x200, 0x100);
    runCase<1>(0x0, 0x200, 0x0, 0x200, 0x100);
    runCase<0>(0x0, 0x201, 0x0, 0x201, 0x100);
    runCase<1>(0x0, 0x201, 0x0, 0x201, 0x100);
    runCase<0>(-0x800, 0x7FF, -0x100, 0x100, 0x0);
    runCase<1>(-0x800, 0x7FF, -0x100, 0x100, 0x0);

    for (unsigned i = 0; i < cases; ++i)
    {
        const s32 wx0 = randCoord(0x1, 0xFFFF);
        const s32 wx1 = randCoord(0x1, 0xFFFF);
        const s32 wz0 = randCoord(0x0, 0xFFFFFF);
        const s32 wz1 = randCoord(0x0, 0xFFFFFF);
        const bool wbuf = (i & 0x2) != 0;
        if ((i & 0x1) != 0)
            runDepthCase<1>(randCoord(-0x1000, 0x1000), randCoord(-0x1000, 0x1000),
                randCoord(-0x100, 0x100), randCoord(-0x100, 0x100), randCoord(-0x110, 0x110),
                wx0, wx1, wz0, wz1, wbuf);
        else
            runDepthCase<0>(randCoord(-0x1000, 0x1000), randCoord(-0x1000, 0x1000),
                randCoord(-0x100, 0x100), randCoord(-0x100, 0x100), randCoord(-0x110, 0x110),
                wx0, wx1, wz0, wz1, wbuf);
    }

    for (unsigned i = 0; i < cases; ++i)
    {
        const u32 w = static_cast<u32>(randCoord(0x0, 0x7FFFFFFF));
        const s32 z = randCoord(-0xFFFFFF, 0xFFFFFF);
        const u32 wsize = melonDS::NDS4MiSTerGXNormalizedWSize(w);
        s32 wnorm;
        if (wsize < 0x10)
        {
            const u32 ww = w << (0x10 - wsize);
            wnorm = static_cast<s32>(ww >> (0x10 - wsize));
        }
        else
        {
            const u32 ww = w >> (wsize - 0x10);
            wnorm = static_cast<s32>(ww << (wsize - 0x10));
        }
        const s32 zz = melonDS::NDS4MiSTerGXDivideZ(z, w);
        std::printf("NORM %u %d %u %d %d\n", w, z, wsize, wnorm, zz);
    }

    for (unsigned i = 0; i < cases; ++i)
    {
        const s32 x0 = randCoord(-0x1000, 0x1000);
        const s32 x1 = randCoord(-0x1000, 0x1000);
        const s32 y0 = randCoord(-0x100, 0x100);
        const s32 y1 = randCoord(-0x100, 0x100);
        const s32 yLo = (y0 < y1 ? y0 : y1) - 0x10;
        const s32 yHi = (y0 < y1 ? y1 : y0) + 0x10;
        const s32 y = randCoord(yLo, yHi);
        if ((i & 0x1) != 0)
            runCase<1>(x0, x1, y0, y1, y);
        else
            runCase<0>(x0, x1, y0, y1, y);
    }
    return 0;
}
