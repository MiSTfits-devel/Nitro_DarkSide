{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | The hardware encoding of 'GeoEvent', the stream from the geometry engine
-- ('Nds.Gpu3D.GeometryHw') to the polygon pipeline. It carries exactly what
-- polygon assembly reads:
--
-- * 'HeBegin' / 'HeSwap' keep @p & 3@ of the command parameter (the polygon
--   model reads @PolygonMode = p & 3@ and @FlushAttributes = p & 3@ only);
-- * 'HwVertex' keeps @VertexColor@ (5 bits per channel): the 'ClipVertex'
--   colour is always @(c << 12) + 0xFFF@;
-- * 'HwPolyState' keeps every 'PolyState' field at its real width
--   (@TexPalette@ is 13 bits, the viewport 8/9 bits, @ZeroDotWLimit@ 24).
--
-- 'toHwEvent' and 'fromHwEvent' convert at gates. @fromHwEvent . toHwEvent@
-- is the identity on every event the geometry model emits except for the
-- dropped high parameter bits of 'GeBegin'/'GeSwap', which no consumer reads.
module Nds.Gpu3D.GeometryHw.Event
  ( HwVertex (..)
  , HwPolyState (..)
  , HwGeoEvent (..)
  , toHwVertex
  , fromHwVertex
  , toHwPolyState
  , fromHwPolyState
  , toHwEvent
  , fromHwEvent
  ) where

import Prelude

import Data.Bits (shiftL, shiftR, (.&.))
import Data.Int (Int16, Int32)
import Data.Word (Word32)
import GHC.Generics (Generic)

import Clash.Prelude (BitPack, BitVector, NFDataX, Signed, Unsigned)

import Nds.Gpu3D.Types

-- | A 'ClipVertex': clip-space position, @VertexColor@, texture coordinates.
data HwVertex = HwVertex
  { hvX, hvY, hvZ, hvW :: !(Signed 32)
  , hvR, hvG, hvB      :: !(Unsigned 5)
  , hvS, hvT           :: !(Signed 16)
  } deriving (Eq, Show, Generic, NFDataX, BitPack)

-- | A 'PolyState': @CurPolygonAttr@, @TexParam@, @TexPalette@, @Viewport[0..5]@,
-- @ZeroDotWLimit@.
data HwPolyState = HwPolyState
  { hpAttr       :: !(BitVector 32)
  , hpTexParam   :: !(BitVector 32)
  , hpTexPalette :: !(BitVector 13)
  , hpVpX0       :: !(Unsigned 8)
  , hpVpY0       :: !(Unsigned 8)
  , hpVpX1       :: !(Unsigned 8)
  , hpVpY1       :: !(Unsigned 8)
  , hpVpW        :: !(Unsigned 9)
  , hpVpH        :: !(Unsigned 8)
  , hpZeroDotW   :: !(Unsigned 24)
  } deriving (Eq, Show, Generic, NFDataX, BitPack)

-- | One 'GeoEvent'.
data HwGeoEvent
  = HeBegin !(BitVector 2)               -- ^ @BEGIN_VTXS@, @p & 3@
  | HeVertex !HwVertex !HwPolyState      -- ^ one @SubmitVertex@
  | HeEnd                                -- ^ @END_VTXS@
  | HeSwap !(BitVector 2)                -- ^ @SWAP_BUFFERS@, @p & 3@
  deriving (Eq, Show, Generic, NFDataX)

toHwVertex :: ClipVertex -> HwVertex
toHwVertex cv = HwVertex
  { hvX = s32 (cvX cv), hvY = s32 (cvY cv), hvZ = s32 (cvZ cv), hvW = s32 (cvW cv)
  , hvR = col (cvR cv), hvG = col (cvG cv), hvB = col (cvB cv)
  , hvS = fromIntegral (cvS cv), hvT = fromIntegral (cvT cv)
  }
  where
    s32 :: Int32 -> Signed 32
    s32 = fromIntegral
    col c = fromIntegral ((c `shiftR` 12) .&. 0x1F)

fromHwVertex :: HwVertex -> ClipVertex
fromHwVertex v = ClipVertex
  { cvX = i32 (hvX v), cvY = i32 (hvY v), cvZ = i32 (hvZ v), cvW = i32 (hvW v)
  , cvR = col (hvR v), cvG = col (hvG v), cvB = col (hvB v)
  , cvS = i16 (hvS v), cvT = i16 (hvT v)
  }
  where
    i32 :: Signed 32 -> Int32
    i32 = fromIntegral
    i16 :: Signed 16 -> Int16
    i16 = fromIntegral
    col c = (fromIntegral c `shiftL` 12) + 0xFFF

toHwPolyState :: PolyState -> HwPolyState
toHwPolyState ps = HwPolyState
  { hpAttr = fromIntegral (psAttr ps)
  , hpTexParam = fromIntegral (psTexParam ps)
  , hpTexPalette = fromIntegral (psTexPalette ps)
  , hpVpX0 = fromIntegral v0, hpVpY0 = fromIntegral v1
  , hpVpX1 = fromIntegral v2, hpVpY1 = fromIntegral v3
  , hpVpW = fromIntegral v4, hpVpH = fromIntegral v5
  , hpZeroDotW = fromIntegral (psZeroDotW ps)
  }
  where
    (v0, v1, v2, v3, v4, v5) = psViewport ps

fromHwPolyState :: HwPolyState -> PolyState
fromHwPolyState h = PolyState
  { psAttr = fromIntegral (hpAttr h)
  , psTexParam = fromIntegral (hpTexParam h)
  , psTexPalette = fromIntegral (hpTexPalette h)
  , psViewport = ( w (hpVpX0 h), w (hpVpY0 h), w (hpVpX1 h), w (hpVpY1 h)
                 , fromIntegral (hpVpW h), w (hpVpH h) )
  , psZeroDotW = fromIntegral (hpZeroDotW h)
  }
  where
    w :: Unsigned 8 -> Word32
    w = fromIntegral

toHwEvent :: GeoEvent -> HwGeoEvent
toHwEvent ev = case ev of
  GeBegin p -> HeBegin (fromIntegral (p .&. 3))
  GeVertex cv ps -> HeVertex (toHwVertex cv) (toHwPolyState ps)
  GeEnd -> HeEnd
  GeSwap p -> HeSwap (fromIntegral (p .&. 3))

fromHwEvent :: HwGeoEvent -> GeoEvent
fromHwEvent ev = case ev of
  HeBegin p -> GeBegin (fromIntegral p)
  HeVertex v ps -> GeVertex (fromHwVertex v) (fromHwPolyState ps)
  HeEnd -> GeEnd
  HeSwap p -> GeSwap (fromIntegral p)
