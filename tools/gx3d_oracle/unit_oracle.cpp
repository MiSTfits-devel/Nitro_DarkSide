// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Truffle
//
// Unit oracles for the textured/translucent pixel path. Each mode drives one
// production SoftRenderer3D piece directly and writes self-describing binary
// records (little-endian u32) to stdout; the Haskell checkers recompute every
// record. No melonDS source is modified; private members are exposed to this
// translation unit only.
//
//   attr SETUPS      Interpolator<0>/<1>: SetX over consecutive and scattered
//                    X, then Interpolate (colour, texcoord, W) and InterpolateZ.
//   texel CASES IMG  TextureLookup over every format; IMG receives the random
//                    VRAM image (512 KiB texture + 128 KiB palette).
//   shade            RenderPixel exhaustively over blend mode, texture alpha,
//                    polygon alpha and one channel's texel/vertex colour pair.
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

#include "NDS.h"
#include "GPU.h"
#include "GPU3D.h"
#include "GPU3D_Texcache.h"
#include "NDS4MiSTer_FastDivide.h"
#include "Platform.h"
#define private public
#include "GPU3D_Soft.h"
#undef private
#include "GPU_Soft.h"

using namespace melonDS;

namespace
{

uint64_t rngState = 0x2545F4914F6CDD1DULL;

uint32_t nextRand()
{
    uint64_t x = rngState;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    rngState = x;
    return static_cast<uint32_t>(x >> 16);
}

s32 range(s32 lo, s32 hi)
{
    return lo + static_cast<s32>(nextRand() % static_cast<uint32_t>(hi - lo + 1));
}

void put(u32 v) { std::fwrite(&v, sizeof v, 1, stdout); }

using PixelState = SoftRenderer3D::RendererPolygon::PixelShaderState;

// Mirror SoftRenderer3D::SetupPolygon's pixel-state derivation.
PixelState stateFor(u32 texparam, u32 texpal, u32 attr, u32 dispcnt)
{
    PixelState st {};
    const u32 fmt = (texparam >> 26) & 0x7;
    st.TextureBase = (texparam & 0xFFFF) << 3;
    st.TextureWidth = 8 << ((texparam >> 20) & 0x7);
    st.TextureHeight = 8 << ((texparam >> 23) & 0x7);
    st.TextureWidthMask = st.TextureWidth - 1;
    st.TextureHeightMask = st.TextureHeight - 1;
    st.TextureWidthShift = static_cast<u8>(3 + ((texparam >> 20) & 0x7));
    st.TextureFormat = static_cast<u8>(fmt);
    st.TextureWrapFlags = static_cast<u8>((texparam >> 16) & 0xF);
    st.TexturePaletteBase = texpal << (fmt == 2 ? 3 : 4);
    st.BlendMode = static_cast<u8>((attr >> 4) & 0x3);
    st.PolyAlpha = static_cast<u8>((attr >> 16) & 0x1F);
    st.Alpha0 = (texparam & (1 << 29)) ? 0 : 31;
    st.TextureEnabled = (dispcnt & 1) && fmt != 0;
    st.TexturePixels = nullptr;
    st.Highlight = st.BlendMode == 2 && (dispcnt & (1 << 1));
    st.Wireframe = st.PolyAlpha == 0;
    return st;
}

s32 randW()
{
    switch (nextRand() % 16)
    {
    case 0: return 0;
    case 1: case 2: return range(1, 0x1FF) << 7;   // aligned: linear when equal
    default: return range(1, 0xFFFF);
    }
}

template <int Dir>
void attrSetup()
{
    s32 x0, x1;
    if (Dir == 0)
    {
        x0 = range(0, 256);
        x1 = x0 + range(0, 257);
    }
    else
    {
        x0 = range(-1, 191);
        x1 = x0 + range(0, 192);
    }
    s32 w0 = randW();
    s32 w1 = (nextRand() % 4 == 0) ? w0 : randW();
    const bool wbuffer = nextRand() & 1;
    const s32 ya0 = range(0, 511), ya1 = (nextRand() % 8 == 0) ? ya0 : range(0, 511);
    const s32 yb0 = range(-32768, 32767), yb1 = range(-32768, 32767);
    const s32 yc0 = range(0, 0xFFFF), yc1 = range(0, 0xFFFF);
    const s32 z0 = range(0, 0xFFFFFF), z1 = range(0, 0xFFFFFF);

    std::vector<s32> xs;
    const s32 last = Dir == 0 ? x1 - 1 : x1;
    for (s32 x = x0; x <= last; ++x) xs.push_back(x);
    for (int k = 0; k < 8 && last >= x0; ++k) xs.push_back(range(x0, last));

    SoftRenderer3D::Interpolator<Dir> it(x0, x1, w0, w1, wbuffer);
    put(static_cast<u32>(Dir) | (wbuffer ? 2u : 0u));
    put(x0); put(x1); put(w0); put(w1);
    put(ya0); put(ya1); put(yb0); put(yb1); put(yc0); put(yc1); put(z0); put(z1);
    put(static_cast<u32>(xs.size()));
    for (s32 x : xs)
    {
        it.SetX(x);
        put(x);
        put(it.Interpolate(ya0, ya1));
        put(it.Interpolate(yb0, yb1));
        put(it.Interpolate(yc0, yc1));
        put(it.InterpolateZ(z0, z1));
    }
}

int runAttr(unsigned setups)
{
    for (unsigned i = 0; i < setups; ++i)
    {
        if (i & 1) attrSetup<1>();
        else attrSetup<0>();
    }
    return 0;
}

struct Renderer
{
    std::unique_ptr<NDS> nds = std::make_unique<NDS>();
    std::unique_ptr<SoftRenderer> soft = std::make_unique<SoftRenderer>(*nds);
    SoftRenderer3D* r3d = soft->Get3DRenderer();
};

void texelCase(Renderer& rd, u32 texparam, u32 texpal, s16 s, s16 t)
{
    PixelState st = stateFor(texparam, texpal, 0, 1);
    u16 color = 0;
    u8 alpha = 0;
    rd.r3d->TextureLookup(st, s, t, &color, &alpha);
    put(texparam);
    put(texpal);
    put(static_cast<u16>(s) | (static_cast<u32>(static_cast<u16>(t)) << 16));
    put(color | (static_cast<u32>(alpha) << 16));
}

s16 randCoord(s32 size)
{
    // Texel units: mostly near the texture's own range and its wrap/flip
    // boundaries, sometimes anywhere in the s16 12.4 range.
    if (nextRand() % 8 == 0) return static_cast<s16>(range(-32768, 32767));
    const s32 texel = range(-3 * size, 3 * size);
    return static_cast<s16>((texel << 4) | range(0, 15));
}

int runTexel(unsigned cases, const char* imagePath)
{
    Renderer rd;
    GPU& gpu = rd.nds->GPU;
    for (u32 i = 0; i < sizeof gpu.VRAMFlat_Texture; ++i)
        gpu.VRAMFlat_Texture[i] = static_cast<u8>(nextRand());
    for (u32 i = 0; i < sizeof gpu.VRAMFlat_TexPal; ++i)
        gpu.VRAMFlat_TexPal[i] = static_cast<u8>(nextRand());
    std::FILE* f = std::fopen(imagePath, "wb");
    if (!f) return 1;
    std::fwrite(gpu.VRAMFlat_Texture, 1, sizeof gpu.VRAMFlat_Texture, f);
    std::fwrite(gpu.VRAMFlat_TexPal, 1, sizeof gpu.VRAMFlat_TexPal, f);
    std::fclose(f);

    // Exhaustive: every 8x8 format, wrap/flip/alpha0 combination, every texel
    // position from three textures left/above to four right/below.
    for (u32 fmt = 1; fmt <= 7; ++fmt)
        for (u32 wrap = 0; wrap < 16; ++wrap)
            for (u32 a0 = 0; a0 < 2; ++a0)
            {
                const u32 base = static_cast<u32>(range(0, 0xFFFF));
                const u32 texparam = base | (wrap << 16) | (fmt << 26) | (a0 << 29);
                const u32 texpal = static_cast<u32>(range(0, 0x1FFF));
                for (s32 tt = -24; tt < 32; ++tt)
                    for (s32 ss = -24; ss < 32; ++ss)
                        texelCase(rd, texparam, texpal,
                            static_cast<s16>((ss << 4) | range(0, 15)),
                            static_cast<s16>((tt << 4) | range(0, 15)));
            }
    // Random: every size, base, palette and coordinate.
    for (unsigned i = 0; i < cases; ++i)
    {
        const u32 fmt = static_cast<u32>(range(1, 7));
        const u32 sw = static_cast<u32>(range(0, 7));
        const u32 sh = static_cast<u32>(range(0, 7));
        const u32 texparam = static_cast<u32>(range(0, 0xFFFF))
            | (static_cast<u32>(range(0, 15)) << 16) | (sw << 20) | (sh << 23)
            | (fmt << 26) | (static_cast<u32>(range(0, 1)) << 29)
            | (static_cast<u32>(range(0, 3)) << 30);
        const u32 texpal = static_cast<u32>(range(0, 0x1FFF));
        texelCase(rd, texparam, texpal, randCoord(8 << sw), randCoord(8 << sh));
    }
    return 0;
}

// Variant bits: 0-1 blend mode, 2 highlight (DISP3DCNT bit 1), 3 texture
// enabled, 4 direct VRAM lookup instead of a decoded texel.
void shadeCase(Renderer& rd, u32 variant, u32 vcol, u32 texel, u32 polyalpha)
{
    const u32 attr = ((variant & 3) << 4) | (polyalpha << 16);
    const u32 dispcnt = ((variant >> 2) & 1) << 1 | ((variant >> 3) & 1);
    const bool direct = variant & 0x10;
    // Direct: an 8x8 direct-colour texture at slot 0 whose texel (0,0) holds
    // the RGB555 value. Decoded: an 8x8 cached texture whose first texel is it.
    const u32 texparam = (7u << 26);
    PixelState st = stateFor(texparam, 0, attr, dispcnt);
    const u32 cached[1] = {texel};
    if (direct)
    {
        rd.nds->GPU.VRAMFlat_Texture[0] = static_cast<u8>(texel);
        rd.nds->GPU.VRAMFlat_Texture[1] = static_cast<u8>(texel >> 8);
    }
    else
        st.TexturePixels = cached;
    const u32 out = rd.r3d->RenderPixel(st, static_cast<u8>(vcol & 0x3F),
        static_cast<u8>((vcol >> 8) & 0x3F), static_cast<u8>((vcol >> 16) & 0x3F), 0, 0);
    put(variant); put(vcol); put(texel); put(polyalpha); put(out);
}

int runShade()
{
    Renderer rd;
    for (u32 i = 0; i < 32; ++i)
        rd.nds->GPU.GPU3D.RenderToonTable[i] = static_cast<u16>(nextRand() & 0x7FFF);
    rd.nds->GPU.GPU3D.RenderToonTable[31] = 0x7FFF;   // saturates highlight
    for (u32 i = 0; i < 32; ++i) put(rd.nds->GPU.GPU3D.RenderToonTable[i]);

    // Colour: every (texel, vertex) pair on the red channel for each variant;
    // green and blue walk other pairs. Texture alpha sweeps fully for decal.
    for (u32 variant = 0; variant < 16; ++variant)
    {
        if ((variant & 4) && (variant & 3) != 2) continue;
        const bool decal = (variant & 1) && (variant & 8);
        for (u32 ta = 0; ta < 32; ++ta)
        {
            if (!decal && ta != 0 && ta != 17 && ta != 31) continue;
            for (u32 tr = 0; tr < 64; ++tr)
                for (u32 vr = 0; vr < 64; ++vr)
                {
                    if (!(variant & 8) && tr != 0) continue;
                    const u32 tg = (tr * 37 + 11) & 63, tb = (tr * 13 + vr) & 63;
                    const u32 vg = (vr * 29 + tr) & 63, vb = (vr * 5 + 50) & 63;
                    shadeCase(rd, variant, vr | (vg << 8) | (vb << 16),
                        tr | (tg << 8) | (tb << 16) | (ta << 24), 31);
                }
        }
    }
    // Alpha: every texture alpha against every polygon alpha (0 = wireframe).
    for (u32 variant = 0; variant < 16; ++variant)
    {
        if ((variant & 4) && (variant & 3) != 2) continue;
        for (u32 ta = 0; ta < 32; ++ta)
            for (u32 pa = 0; pa < 32; ++pa)
                shadeCase(rd, variant, 0x2A1503, 0x15233F | (ta << 24), pa);
    }
    // Direct VRAM path: every RGB555 texel colour with alpha bit set and clear,
    // through modulate, decal and toon, so the 5-to-6-bit expansion is covered.
    for (u32 variant : {0x18u, 0x19u, 0x1Au, 0x1Eu})
        for (u32 c = 0; c < 0x10000; ++c)
            shadeCase(rd, variant, (c * 7) & 0x3F3F3F, c, 31);
    return 0;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc >= 3 && std::strcmp(argv[1], "attr") == 0)
        return runAttr(static_cast<unsigned>(std::strtoul(argv[2], nullptr, 0)));
    if (argc >= 4 && std::strcmp(argv[1], "texel") == 0)
        return runTexel(static_cast<unsigned>(std::strtoul(argv[2], nullptr, 0)), argv[3]);
    if (argc >= 2 && std::strcmp(argv[1], "shade") == 0)
        return runShade();
    std::fprintf(stderr, "usage: unit_oracle attr N | texel N IMAGE | shade\n");
    return 2;
}
