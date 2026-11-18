{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Types shared by the rasteriser hardware ("Nds.Gpu3D.RasterHw"): the
-- latched register block, the line-buffer and external pixel packing, the
-- span job the setup engine hands the pixel engine, and the reciprocal ROM.
module Nds.Gpu3D.RasterHw.Types
  ( -- * Frame inputs
    RegsHw (..)
  , regsHw
  , Bases (..)
    -- * Pixel packing
  , LayerPx
  , packLayer
  , unpackLayer
  , packColour23
  , unpackColour23
  , packAttr24
  , unpackAttr24
  , packCA
  , unpackCA
  , pxOfLayers
  , layersOfPx
    -- * Span jobs
  , Range (..)
  , inRange
  , ZJob (..)
  , ChJob (..)
  , SpanJob (..)
  , emptyJob
    -- * Reciprocals
  , recipRom
  , recipOf
  ) where

import Prelude

import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.))
import Data.Int (Int32)
import Data.Word (Word16, Word32, Word8)
import GHC.Generics (Generic)

import Clash.Prelude
  ( BitVector, NFDataX, Signed, Unsigned, Vec, (++#), listToVecTH, pack, resize, slice, unpack )
import qualified Clash.Prelude as C
import Clash.Sized.Vector (unsafeFromList)

import Nds.Gpu3D.Depth (DepthMode (..))
import Nds.Gpu3D.Mem (MemAddr)
import Nds.Gpu3D.Render (Px (..))
import Nds.Gpu3D.Types (RenderRegs (..))

------------------------------------------------------------------------------
-- Frame inputs

-- | The latched @Render*@ registers in hardware form: the scalar registers
-- as in 'RenderRegs' and the three tables as register vectors.
data RegsHw = RegsHw
  { rhDispCnt  :: !Word32
  , rhAlphaRef :: !Word8
  , rhClear1   :: !Word32
  , rhClear2   :: !Word32
  , rhFogColor :: !Word32
  , rhFogOffset :: !Word32
  , rhFogShift :: !Word32
  , rhFogTable :: !(Vec 34 Word8)
  , rhEdgeTable :: !(Vec 8 Word16)
  , rhToonTable :: !(Vec 32 Word16)
  , rhXPos     :: !Word16
  } deriving (Eq, Generic, Show, NFDataX)

-- | Encode the model's registers (tables padded with zeros as the model
-- reads them).
regsHw :: RenderRegs -> RegsHw
regsHw r = RegsHw
  { rhDispCnt = rrDispCnt r
  , rhAlphaRef = rrAlphaRef r
  , rhClear1 = rrClearAttr1 r
  , rhClear2 = rrClearAttr2 r
  , rhFogColor = rrFogColor r
  , rhFogOffset = rrFogOffset r
  , rhFogShift = rrFogShift r
  , rhFogTable = unsafeFromList (take 34 (rrFogDensity r ++ repeat 0))
  , rhEdgeTable = unsafeFromList (take 8 (rrEdgeTable r ++ repeat 0))
  , rhToonTable = unsafeFromList (take 32 (rrToonTable r ++ repeat 0))
  , rhXPos = rrXPos r
  }

-- | Where the frame's data lives in the 28-bit external address space.
data Bases = Bases
  { bPoly  :: !MemAddr  -- ^ polygon RAM window ("Nds.Gpu3D.PolyRam")
  , bTex   :: !MemAddr  -- ^ texture slots 0-3 (512 KiB)
  , bPal   :: !MemAddr  -- ^ texture palette slots 0-7 (128 KiB)
  , bLower :: !MemAddr  -- ^ lower layer (192 x 3072 B)
  , bOut   :: !MemAddr  -- ^ output lines (192 x 1024 B)
  } deriving (Eq, Generic, Show, NFDataX)

------------------------------------------------------------------------------
-- Pixel packing

-- | One layer at one pixel as the line buffers hold it: colour (23 bits),
-- depth (24 bits), attribute (24 bits).
type LayerPx = BitVector 71

-- | The colour word's used bits: R 0-5, G 8-13, B 16-21, alpha 24-28.
packColour23 :: Word32 -> BitVector 23
packColour23 c =
  let b = pack c
  in slice C.d28 C.d24 b ++# slice C.d21 C.d16 b ++# slice C.d13 C.d8 b ++# slice C.d5 C.d0 b

unpackColour23 :: BitVector 23 -> Word32
unpackColour23 v =
  let f :: Int -> Int -> Word32
      f lo n = (unpack (resize v) `shiftR` lo) .&. ((1 `shiftL` n) - 1)
  in f 0 6 .|. (f 6 6 `shiftL` 8) .|. (f 12 6 `shiftL` 16) .|. (f 18 5 `shiftL` 24)

-- | The attribute word's used bits: 0-4, 8-12, 15, 16-22, 24-29.
packAttr24 :: Word32 -> BitVector 24
packAttr24 a =
  let b = pack a
  in slice C.d29 C.d24 b ++# slice C.d22 C.d15 b ++# slice C.d12 C.d8 b ++# slice C.d4 C.d0 b

unpackAttr24 :: BitVector 24 -> Word32
unpackAttr24 v =
  let f :: Int -> Int -> Word32
      f lo n = (unpack (resize v) `shiftR` lo) .&. ((1 `shiftL` n) - 1)
  in f 0 5 .|. (f 5 5 `shiftL` 8) .|. (f 10 8 `shiftL` 15) .|. (f 18 6 `shiftL` 24)

packLayer :: Word32 -> Word32 -> Word32 -> LayerPx
packLayer c d a = packColour23 c ++# slice C.d23 C.d0 (pack d) ++# packAttr24 a

unpackLayer :: LayerPx -> (Word32, Word32, Word32)
unpackLayer v =
  ( unpackColour23 (slice C.d70 C.d48 v)
  , unpack (resize (slice C.d47 C.d24 v))
  , unpackAttr24 (slice C.d23 C.d0 v) )

-- | Colour and attribute of one lower-layer pixel in an external word.
packCA :: Word32 -> Word32 -> BitVector 64
packCA c a = resize (packColour23 c ++# packAttr24 a)

unpackCA :: BitVector 64 -> (Word32, Word32)
unpackCA w = (unpackColour23 (slice C.d46 C.d24 w), unpackAttr24 (slice C.d23 C.d0 w))

pxOfLayers :: LayerPx -> LayerPx -> Px
pxOfLayers t l =
  let (c, d, a) = unpackLayer t
      (lc, ld, la) = unpackLayer l
  in Px c d a lc ld la

layersOfPx :: Px -> (LayerPx, LayerPx)
layersOfPx p = (packLayer (pxC p) (pxD p) (pxA p), packLayer (pxLC p) (pxLD p) (pxLA p))

------------------------------------------------------------------------------
-- Span jobs

-- | An inclusive X range of one piece, 'rValid' false when empty.
data Range = Range
  { rValid :: !Bool
  , rLo    :: !(Unsigned 9)
  , rHi    :: !(Unsigned 9)
  } deriving (Eq, Generic, Show, NFDataX)

inRange :: Range -> Unsigned 9 -> Bool
inRange r x = rValid r && x >= rLo r && x <= rHi r

-- | How the pixel engine forms the span depth.
data ZJob
  = ZConst !Word32
    -- ^ equal ends: the start-edge value
  | ZLin !Word32 !(Unsigned 38) !(Unsigned 38) !Bool
    -- ^ Z-buffer: base, @K = (disp >> 9) * xrecip@, accumulator at the first
    -- position (0 or @K * xdiff@, at most @disp << 13@), counting up ('True')
    -- or down
  | ZPersp !Word32 !(Unsigned 24) !Bool
    -- ^ W-buffer: base, delta, start below end ('True': factor @yf@,
    -- otherwise @256 - yf@)
  deriving (Eq, Generic, Show, NFDataX)

-- | How the pixel engine forms one attribute, modulo 2^16 (S and T are 16
-- bits; R, G and B are read through @c6@, bits 3-10).
data ChJob
  = ChConst !(Unsigned 16)
  | ChPersp !(Unsigned 16) !(Unsigned 24) !Bool
    -- ^ base, delta (low 24 bits), start below end
  | ChLin !(Unsigned 16) !Bool !(Unsigned 16) !(Unsigned 10) !Bool !(Unsigned 16)
    -- ^ base, negative difference, @|delta| div xdiff@ (low 16 bits),
    -- @|delta| mod xdiff@, start below end, quotient at the first position
    -- (0, or @|delta|@ when counting down)
  deriving (Eq, Generic, Show, NFDataX)

-- | Everything the pixel engine needs for one polygon scanline.
data SpanJob = SpanJob
  { sjY        :: !(Unsigned 8)
  , sjMask     :: !Bool          -- ^ shadow mask polygon
  , sjDraw     :: !Bool          -- ^ the pixel loops run (false for an alpha-rejected mask)
  , sjShadow   :: !Bool
  , sjMode     :: !DepthMode
  , sjAttr     :: !Word32
  , sjTexParam :: !Word32
  , sjTexPal   :: !Word32
  , sjFacing   :: !Bool
  , sjX0       :: !(Unsigned 9)  -- ^ span start (@srStart@): position 0 of the interpolator
  , sjXDiff    :: !(Unsigned 10) -- ^ 1..512
  , sjLast     :: !(Unsigned 9)  -- ^ last position the loops visit
  , sjLeft, sjInner, sjRight :: !Range
  , sjYEdge    :: !Word32
  , sjLCov, sjRCov :: !Int32
  , sjNumStep  :: !Word32        -- ^ @wA@: the numerator is @(x' * wA mod 2^24) << 8@
  , sjDen0     :: !(Unsigned 25) -- ^ @xdiff * w1@
  , sjDenStep  :: !(Signed 18)   -- ^ @w0 - w1@
  , sjZ        :: !ZJob
  , sjCh       :: !(Vec 5 ChJob) -- ^ R, G, B, S, T
  } deriving (Eq, Generic, Show, NFDataX)

emptyJob :: SpanJob
emptyJob = SpanJob
  { sjY = 0, sjMask = False, sjDraw = False, sjShadow = False, sjMode = DepthLess
  , sjAttr = 0, sjTexParam = 0, sjTexPal = 0, sjFacing = False
  , sjX0 = 0, sjXDiff = 1, sjLast = 0
  , sjLeft = noRange, sjInner = noRange, sjRight = noRange
  , sjYEdge = 0, sjLCov = 0, sjRCov = 0
  , sjNumStep = 0, sjDen0 = 0, sjDenStep = 0
  , sjZ = ZConst 0, sjCh = C.repeat (ChConst 0)
  }
  where
    noRange = Range False 0 0

------------------------------------------------------------------------------
-- Reciprocals

-- | @floor (2^32 / d)@ for @d = 1 .. 512@ at index @d - 1@ (33 bits: 2^32 at
-- d = 1). Every reciprocal the renderer uses is a right shift of it:
-- @floor (2^k / d) = floor (floor (2^32 / d) / 2^(32-k))@ for k <= 32.
recipRom :: Vec 512 (Unsigned 33)
recipRom = $(listToVecTH [ fromInteger (2 ^ (32 :: Int) `quot` d) :: Unsigned 33 | d <- [1 .. 512 :: Integer] ])

-- | The ROM's function (for checks): @floor (2^32 / d)@, 0 for d = 0.
recipOf :: Integer -> Integer
recipOf d = if d <= 0 then 0 else 2 ^ (32 :: Int) `quot` d
