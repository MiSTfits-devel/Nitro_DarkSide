#ifndef NDS4MISTER_2DTRACE_H
#define NDS4MISTER_2DTRACE_H

#include <stddef.h>

#include "types.h"

namespace melonDS
{
class GPU;

namespace NDS4MiSTer
{

constexpr u32 Trace2DMagic = 0x3244534E; // "NSD2", little-endian
constexpr u16 Trace2DLegacyVersion = 9;
constexpr u16 Trace2DVersion = 10;
constexpr u16 Trace2DCaptureVersion = 11;
constexpr u16 Trace2DRaw3DVersion = 12;

enum class Trace2DRecordType : u16
{
    Scanline = 1,
    MemoryDelta = 2,
    Renderer3DScanline = 3,
    ExtendedPaletteMap = 4,
    GeometryCommand = 5,
    GeometryFrame = 6,
    GeometryRegister = 7,
    FramebufferScanline = 8,
    Internal2DLatch = 9,
    OBJBufferHash = 10,
    OBJInputHash = 11,
    SpritePhase = 12,
    DisplayState = 13,
    EngineScanline = 14,
    CaptureBegin = 15,
    CaptureDelta = 16,
    CaptureEnd = 17,
    CaptureLifecycleStart = 18,
    CaptureLifecycleEnd = 19,
    Gpu3DPower = 20,
    Gpu3DXPos = 21,
    Gpu3DAbort = 22,
    Gpu3DRenderStart = 23,
    Gpu3DFrameEnd = 24,
    Gpu3DVBlank = 25,
    Gpu3DGxWrite = 26,
};

enum class Trace2DMemoryRegion : u8
{
    Palette = 0,
    OAM = 1,
    VRAMA = 2,
    VRAMB = 3,
    VRAMC = 4,
    VRAMD = 5,
    VRAME = 6,
    VRAMF = 7,
    VRAMG = 8,
    VRAMH = 9,
    VRAMI = 10,
    FlatAOBJ = 11,
    FlatBOBJ = 12,
};

#pragma pack(push, 1)
struct Trace2DFileHeader
{
    u32 Magic;
    u16 Version;
    u16 HeaderSize;
    u32 PacketSize;
    u32 Reserved;
};

struct Trace2DRecordHeader
{
    u16 Type;
    u16 Size;
};

struct Trace2DMemoryDeltaHeader
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 Line;
    u8 Region;
    u8 Reserved;
    u32 Offset;
};

struct Trace2DRenderer3DHeader
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 Line;
    u16 PixelCount;
};

struct Trace2DExtendedPaletteMapPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 Line;
    u16 Reserved;
    u32 ABG[4];
    u32 AOBJ;
    u32 BBG[4];
    u32 BOBJ;
};

struct Trace2DGeometryCommandPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u64 Timestamp;
    u8 Command;
    u8 Reserved[3];
    u32 Parameter;
};

struct Trace2DGeometryFramePacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u64 Timestamp;
    u32 Vertices;
    u32 Polygons;
    u32 FlushAttributes;
};

struct Trace2DGeometryRegisterPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u64 Timestamp;
    u32 Address;
    u32 Value;
    u8 Width;
    u8 Reserved[3];
};

struct Trace2DFramebufferScanlinePacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 Line;
    u16 PixelCount;
    u32 Top[256];
    u32 Bottom[256];
};

struct Trace2DInternal2DEngine
{
    s32 BGXRefInternal[2]; s32 BGYRefInternal[2];
    u8 BGMosaicY; u8 BGMosaicYMax; u8 OBJMosaicY; u8 Flags;
    u32 BGMosaicLine; u32 OBJMosaicLine;
};

struct Trace2DInternal2DLatchPacket
{
    Trace2DRecordHeader Record; u32 Frame; u16 Line; u16 Reserved;
    Trace2DInternal2DEngine Engine[2];
};

struct Trace2DOBJBufferHashPacket
{
    Trace2DRecordHeader Record; u32 Frame; u16 Line; u16 Reserved;
    u64 Hashes[4]; // A line, A window, B line, B window
};

struct Trace2DOBJInputHashPacket
{
    Trace2DRecordHeader Record; u32 Frame; u16 Line; u16 Reserved;
    u64 OAMA; u64 OAMB; u64 FlatAOBJ; u64 FlatBOBJ;
};

struct Trace2DEngine
{
    u32 DispCnt;
    u8 LayerEnable;
    u8 OBJEnable;
    u8 ForcedBlank;
    u8 Reserved0;
    u16 BGCnt[4];
    u16 BGXPos[4];
    u16 BGYPos[4];
    s32 BGXRef[2];
    s32 BGYRef[2];
    s16 BGRotA[2];
    s16 BGRotB[2];
    s16 BGRotC[2];
    s16 BGRotD[2];
    u8 Win0Coords[4];
    u8 Win1Coords[4];
    u8 WinCnt[4];
    u8 Win0Active;
    u8 Win1Active;
    u8 BGMosaicSize[2];
    u8 OBJMosaicSize[2];
    u16 BlendCnt;
    u16 BlendAlpha;
    u8 EVA;
    u8 EVB;
    u8 EVY;
    u8 Reserved1;
};

struct Trace2DScanlinePacket
{
    u32 Frame;
    u16 Line;
    u16 VCount;
    u8 ScreensEnabled;
    u8 ScreenSwap;
    u8 CaptureEnable;
    u8 Reserved0;
    u16 MasterBrightnessA;
    u16 MasterBrightnessB;
    u8 VRAMCNT[9];
    u8 Reserved1[3];
    u32 VRAMMapABG[0x20];
    u32 VRAMMapAOBJ[0x10];
    u32 VRAMMapBBG[0x8];
    u32 VRAMMapBOBJ[0x8];
    u32 OAMDirty;
    u32 PaletteDirty;
    Trace2DEngine Engine[2];
};

// Version 10: immediately preceding a SpritePhase or Scanline record, after
// the phase's memory deltas and internal-latch record. FIFOBuffer is the
// sampled 256-pixel line, distinct from the 16-entry FIFO and its pointers.
struct Trace2DDisplayStatePacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 VCount;
    u8 EngineEnabled[2];
    u32 CaptureCnt;
    u32 VRAMMapLCDC;
    u16 FIFO[16];
    u8 FIFOReadPtr;
    u8 FIFOWritePtr;
    u16 FIFOBuffer[256];
};

// SpritePhase carries the same register/map snapshot as Scanline, but Line
// is the sprite target and VCount is the hardware phase at which it was drawn.
// In particular target line 0 is prepared at VCount 262 of the prior frame.
struct Trace2DSpritePhasePacket
{
    Trace2DRecordHeader Record;
    Trace2DScanlinePacket State;
};

// Oracle-only Output2D after colour effects, before display mode and master
// brightness. It is never an input to the Haskell renderer.
struct Trace2DEngineScanlinePacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 Line;
    u8 Engine;
    u8 Reserved;
    u32 Pixels[256];
};

// Version 11 capture provenance. These records are emitted only when
// SetTrace2DCaptureProvenance(true) was selected before the header. CaptureDelta
// is EXPECTED-ONLY: a consumer must never apply it to renderer input memory.
struct Trace2DCaptureBeginPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 Line;
    u16 Reserved;
    u32 CaptureCnt;
    u32 DispCntA;
    u32 VRAMMapLCDC;
    u8 SrcSelector;
    u8 Reserved2[3];
};

struct Trace2DCaptureDeltaPacket
{
    Trace2DMemoryDeltaHeader Header; // Type=CaptureDelta; Region=VRAMA+dstbank
};

struct Trace2DCaptureEndPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 Line;
    u16 Reserved;
    u16 Flags[16];
    u8 Active;
    u8 Reserved2[3];
};

struct Trace2DCaptureLifecyclePacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 VCount;
    u16 Reserved;
    u32 CaptureCnt;
    u32 VRAMMapLCDC;
    u16 Flags[16];
    u8 Active;
    u8 Reserved2[3];
};

// Version 12 raw 3D inputs. These records carry no renderer pixels: power,
// RenderXPos, VCount abort, exact render-start memory/mapping and VBlank /
// frame-end timing. Type23 Flags bit0=1 is the initial recorder snapshot and
// must never trigger a render; bit0=0 is a real scanline-215 render start.
struct Trace2DGpu3DPowerPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u64 Timestamp;
    u8 GeometryEnabled;
    u8 RenderingEnabled;
    u16 Reserved;
    u32 POWCNT1;
};

struct Trace2DGpu3DXPosPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u64 Timestamp;
    u16 XPos;
    u16 Reserved;
};

struct Trace2DGpu3DAbortPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u64 Timestamp;
    u32 Active;
    u32 Reserved;
};

struct Trace2DGpu3DRenderStartPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 VCount;
    u16 Reserved;
    u64 Timestamp;
    u16 XPos;
    u8 GeometryEnabled;
    u8 RenderingEnabled;
    u8 Flags;
    u8 Reserved1;
    u8 VRAMCNT[9];
    u8 Reserved2[3];
    u32 VRAMMapTexture[4];
    u32 VRAMMapTexPal[8];
};

struct Trace2DGpu3DFrameEndPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 VCount;
    u16 Reserved;
    u64 Timestamp;
};

struct Trace2DGpu3DVBlankPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 VCount;
    u16 Reserved;
    u64 Timestamp;
};

// One accepted ARM9 write to the GPU3D register/FIFO/command space, before
// the write's side effects. Replaying these in order at their timestamps
// reproduces GPU3D's command packing, FIFO stall queue and SWAP timing
// exactly; normalized type-5 records cannot.
struct Trace2DGpu3DGxWritePacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u64 Timestamp;
    u32 Address;
    u32 Value;
    u8 Width;
    u8 Reserved[3];
};
#pragma pack(pop)

using Trace2DSink = void (*)(const void* data, size_t size, void* userdata);
using CompositeLineSink = void (*)(u32 frame, u16 line, u8 engine, bool screenSwap,
    const u32* top, const u32* second, const u8* windowMask,
    u16 blendCnt, u8 eva, u8 evb, u8 evy, u8 displayMode,
    u16 masterBrightness, void* userdata);
using OutputLineSink = void (*)(u32 frame, u16 line, const u32* top,
    const u32* bottom, void* userdata);
using VBlankSink = void (*)(u32 frame, void* userdata);
using PreDrawScrollSink = void (*)(u32 frame, u16 line, u16 bg1hofs,
    u16 bg2hofs, void* userdata);

extern bool Trace2DActive;
extern thread_local bool Trace2DThreadSuppressed;
Trace2DFileHeader MakeTrace2DFileHeader() noexcept;
// Select before attaching a sink and writing its header. Returns false if a
// sink is already attached, so a stream's format cannot change mid-recording.
bool SetTrace2DExtensions(bool enabled) noexcept;
// Select v11 capture-provenance records. Must be called before the header and
// sink are attached; returns false if a sink is already attached. Enabling it
// also enables the v10 phase/display records that v11 carries.
bool SetTrace2DCaptureProvenance(bool enabled) noexcept;
bool CaptureProvenanceEnabled() noexcept;
// Select v12 raw 3D inputs (types20-25). Must be called before the header and
// sink; enabling also enables the v10 phase/display records. Returns false if
// a sink is already attached.
bool SetTrace2DRaw3DInputs(bool enabled) noexcept;
bool Raw3DInputsEnabled() noexcept;
void EmitTrace3DInitialState(GPU& gpu) noexcept;
void EmitTrace3DPower(u32 frame, u64 timestamp, bool geometry, bool rendering, u32 powcnt1) noexcept;
void EmitTrace3DXPos(u32 frame, u64 timestamp, u16 xpos) noexcept;
void EmitTrace3DAbort(u32 frame, u64 timestamp, bool active) noexcept;
void EmitTrace3DRenderStart(GPU& gpu, u32 frame, u16 vcount, u64 timestamp, bool initial) noexcept;
void EmitTrace3DFrameEnd(u32 frame, u16 vcount, u64 timestamp) noexcept;
void EmitTrace3DVBlank(u32 frame, u16 vcount, u64 timestamp) noexcept;
void EmitTrace3DGxWrite(u32 frame, u64 timestamp, u32 address, u32 value, u8 width) noexcept;
void EmitCaptureBegin(u32 frame, u16 line, u32 captureCnt, u32 dispCntA,
    u32 vramMapLCDC, u8 srcSelector) noexcept;
void EmitCaptureDeltas(u32 frame, u16 line, u32 dstbank, const u8* before,
    const u8* after, u32 size) noexcept;
void EmitCaptureEnd(u32 frame, u16 line, u8 active, const u16* flags) noexcept;
void EmitCaptureLifecycle(u32 frame, u16 vcount, u32 captureCnt, u32 vramMapLCDC,
    const u16* flags, u32 active) noexcept;
void SetTrace2DSink(Trace2DSink sink, void* userdata) noexcept;
void SetCompositeLineSink(CompositeLineSink sink, void* userdata) noexcept;
void SetCompositeLineBypass(bool enabled) noexcept;
void SetOutputLineSink(OutputLineSink sink, void* userdata) noexcept;
void SetVBlankSink(VBlankSink sink, void* userdata) noexcept;
void SetPreDrawScrollSink(PreDrawScrollSink sink, void* userdata) noexcept;
bool CompositeLineEnabled() noexcept;
bool CompositeLineBypassEnabled() noexcept;
void EmitCompositeLine(u32 frame, u16 line, u8 engine, bool screenSwap,
    const u32* top, const u32* second, const u8* windowMask,
    u16 blendCnt, u8 eva, u8 evb, u8 evy, u8 displayMode,
    u16 masterBrightness) noexcept;
void EmitOutputLine(u32 frame, u16 line, const u32* top, const u32* bottom) noexcept;
void EmitVBlank(u32 frame) noexcept;
void EmitPreDrawScroll(u32 frame, u16 line, u16 bg1hofs, u16 bg2hofs) noexcept;
inline bool Trace2DEnabled() noexcept { return Trace2DActive && !Trace2DThreadSuppressed; }
void EmitTrace2DScanline(GPU& gpu, u32 line) noexcept;
void EmitTrace2DSpritePhase(GPU& gpu, u32 targetLine) noexcept;
void EmitTrace3DCommand(u32 frame, u64 timestamp, u8 command, u32 parameter) noexcept;
void EmitTrace3DFrame(u32 frame, u64 timestamp, u32 vertices, u32 polygons, u32 flushAttributes) noexcept;
void EmitTrace3DRegister(u32 frame, u64 timestamp, u32 address, u32 value, u8 width) noexcept;
void EmitTraceFramebufferScanline(u32 frame, u16 line, const u32* top, const u32* bottom) noexcept;
void EmitTraceEngineScanline(u32 frame, u16 line, u8 engine, const u32* pixels) noexcept;

} // namespace NDS4MiSTer
} // namespace melonDS

#endif
