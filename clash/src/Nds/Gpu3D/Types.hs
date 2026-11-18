-- | The data that crosses block boundaries inside the 3D chip.
--
-- Every type here mirrors a melonDS structure field for field, so each block's
-- model can be gated against the production code at its own boundary:
--
-- * 'CmdEntry' is @GPU3D::CmdFIFOEntry@, what the GX front end hands the
--   geometry engine (one entry per parameter word; a parameterless command is
--   one entry with parameter 0).
-- * 'GeoEvent' is the boundary between the vertex transform
--   (@SubmitVertex@ up to the @Clipped = false@ store) and polygon assembly
--   (the @PolygonMode@ switch, @SubmitPolygon@, the polygon and vertex RAM and
--   the @SWAP_BUFFERS@ sort).
-- * 'GxVertex' and 'GxPolygon' are the @Vertex@ and @Polygon@ fields the
--   software renderer reads, and 'RenderRegs' is the @Render*@ state latched
--   at the swap. A 'RenderFrame' is exactly what @SoftRenderer3D::RenderFrame@
--   consumes.
--
-- These are the pure-model types. Hardware blocks choose their own bit-level
-- encodings and convert at their gates.
module Nds.Gpu3D.Types
  ( CmdEntry (..)
  , ClipVertex (..)
  , PolyState (..)
  , GeoEvent (..)
  , GxVertex (..)
  , GxPolygon (..)
  , RenderRegs (..)
  , RenderFrame (..)
  , GeoStatus (..)
  , PipeStatus (..)
  , cmdNumParams
  ) where

import Prelude

import Data.Int (Int16, Int32)
import Data.Word (Word16, Word32, Word8)

-- | @GPU3D::CmdFIFOEntry@.
data CmdEntry = CmdEntry
  { ceCmd   :: !Word8
  , ceParam :: !Word32
  } deriving (Eq, Show)

-- | A vertex as @SubmitVertex@ stores it in @TempVertexBuffer@: clip-space
-- @Position@ (clip matrix times the vertex), @Color@ (@(VertexColor << 12) +
-- 0xFFF@) and the possibly vertex-transformed @TexCoords@.
data ClipVertex = ClipVertex
  { cvX, cvY, cvZ, cvW :: !Int32
  , cvR, cvG, cvB      :: !Int32
  , cvS, cvT           :: !Int16
  } deriving (Eq, Show)

-- | The command state @SubmitPolygon@ reads at the moment a polygon
-- completes: the attribute latched by @BEGIN_VTXS@ (@CurPolygonAttr@), the
-- current @TexParam@ and @TexPalette@, the raw @VIEWPORT@ values
-- (@Viewport[0..5]@ as melonDS derives them) and @DISP_1DOT_DEPTH@
-- (@ZeroDotWLimit@).
data PolyState = PolyState
  { psAttr       :: !Word32
  , psTexParam   :: !Word32
  , psTexPalette :: !Word32
  , psViewport   :: !(Word32, Word32, Word32, Word32, Word32, Word32)
  , psZeroDotW   :: !Word32
  } deriving (Eq, Show)

-- | What the vertex transform hands polygon assembly, in command order.
data GeoEvent
  = GeBegin !Word32
    -- ^ @BEGIN_VTXS@ with its parameter (the polygon mode and the attribute
    -- latch happen in polygon assembly).
  | GeVertex !ClipVertex !PolyState
    -- ^ one @SubmitVertex@
  | GeEnd
    -- ^ @END_VTXS@
  | GeSwap !Word32
    -- ^ @SWAP_BUFFERS@ with its parameter, taking effect at the next VBlank
  deriving (Eq, Show)

-- | The fields of a melonDS @Vertex@ the software renderer reads.
data GxVertex = GxVertex
  { gvX, gvY       :: !Int32   -- ^ @FinalPosition@
  , gvR, gvG, gvB  :: !Int32   -- ^ @FinalColor@
  , gvS, gvT       :: !Int16   -- ^ @TexCoords@
  } deriving (Eq, Show)

-- | The fields of a melonDS @Polygon@ the software renderer reads. The
-- vertex list has @NumVertices@ entries (at most 10 after clipping); vertices
-- shared between strip polygons are duplicated here.
data GxPolygon = GxPolygon
  { gpVerts       :: ![GxVertex]
  , gpFinalZ      :: ![Int32]
  , gpFinalW      :: ![Int32]
  , gpWBuffer     :: !Bool
  , gpAttr        :: !Word32
  , gpTexParam    :: !Word32
  , gpTexPalette  :: !Word32
  , gpDegenerate  :: !Bool
  , gpFacingView  :: !Bool
  , gpTranslucent :: !Bool
  , gpShadowMask  :: !Bool
  , gpShadow      :: !Bool
  , gpType        :: !Int      -- ^ 0 regular, 1 line
  , gpVTop        :: !Int
  , gpVBottom     :: !Int
  , gpYTop        :: !Int32
  , gpYBottom     :: !Int32
  , gpXTop        :: !Int32
  , gpXBottom     :: !Int32
  , gpSortKey     :: !Word32
  } deriving (Eq, Show)

-- | The @Render*@ registers latched for one frame.
data RenderRegs = RenderRegs
  { rrDispCnt    :: !Word32
  , rrAlphaRef   :: !Word8
  , rrClearAttr1 :: !Word32
  , rrClearAttr2 :: !Word32
  , rrFogColor   :: !Word32
  , rrFogOffset  :: !Word32
  , rrFogShift   :: !Word32
  , rrFogDensity :: ![Word8]   -- ^ 34 entries, as @RenderFogDensityTable@
  , rrEdgeTable  :: ![Word16]  -- ^ 8 entries
  , rrToonTable  :: ![Word16]  -- ^ 32 entries
  , rrXPos       :: !Word16
  } deriving (Eq, Show)

-- | One frame as @SoftRenderer3D::RenderFrame@ consumes it: the latched
-- registers and @RenderPolygonRAM[0 .. RenderNumPolygons - 1]@ in sorted
-- order.
data RenderFrame = RenderFrame
  { rfRegs  :: !RenderRegs
  , rfPolys :: ![GxPolygon]
  } deriving (Eq, Show)

-- | The geometry-engine state @GXSTAT@ reports (bits 0, 1, 8-12, 13 and 15).
-- The front end composes @GXSTAT@ from this, its own FIFO state and the
-- busy signals; writing @GXSTAT@ bit 15 clears 'gsStackError' through the
-- geometry engine's acknowledge input.
data GeoStatus = GeoStatus
  { gsTestBusy   :: !Bool    -- ^ bit 0: a BOX/POS/VEC test is running
  , gsBoxResult  :: !Bool    -- ^ bit 1
  , gsPosStack   :: !Word8   -- ^ bits 8-12: position/vector stack level (0..31)
  , gsProjStack  :: !Bool    -- ^ bit 13: projection stack level
  , gsStackBusy  :: !Bool    -- ^ bit 14: a push/pop is running
  , gsStackError :: !Bool    -- ^ bit 15: matrix stack overflow/underflow
  , gsBusy       :: !Bool    -- ^ contributes to bit 27 (geometry busy)
  } deriving (Eq, Show)

-- | @RAM_COUNT@: polygons and vertices in the bank being built.
data PipeStatus = PipeStatus
  { pcPolygons :: !Word16
  , pcVertices :: !Word16
  } deriving (Eq, Show)

-- | @CmdNumParams@: parameter words per GX command (0 for unknown commands
-- and for the parameterless ones).
cmdNumParams :: Word8 -> Int
cmdNumParams c = case c of
  0x10 -> 1; 0x12 -> 1; 0x13 -> 1; 0x14 -> 1
  0x16 -> 16; 0x17 -> 12; 0x18 -> 16; 0x19 -> 12; 0x1A -> 9; 0x1B -> 3; 0x1C -> 3
  0x20 -> 1; 0x21 -> 1; 0x22 -> 1; 0x23 -> 2; 0x24 -> 1; 0x25 -> 1; 0x26 -> 1
  0x27 -> 1; 0x28 -> 1; 0x29 -> 1; 0x2A -> 1; 0x2B -> 1
  0x30 -> 1; 0x31 -> 1; 0x32 -> 1; 0x33 -> 1; 0x34 -> 32
  0x40 -> 1
  0x50 -> 1
  0x60 -> 1
  0x70 -> 3; 0x71 -> 2; 0x72 -> 1
  _ -> 0
