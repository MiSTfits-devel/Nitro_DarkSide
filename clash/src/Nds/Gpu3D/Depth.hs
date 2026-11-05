{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Exact melonDS depth interpolation.
--
-- This is the production @SoftRenderer3D::Interpolator@ math, separated from
-- colour and texture so it can be gated against the vendored class directly.
-- It is a pure model: no 'Signal', no clock, no framebuffer.
module Nds.Gpu3D.Depth
  ( Interp (..)
  , setupInterp
  , setupInterpWith
  , setX
  , setXLinear
  , interpolateZ
  , divideZ
  , normalizedWSize
  , normalizeW
  , finalW
  , finalZ
  , DepthMode (..)
  , depthPass
  , clearDepth
  ) where

import Prelude hiding ((&&), (||))

import Data.Bits (complement, countLeadingZeros, shiftL, shiftR, (.&.))
import Data.Int (Int32, Int64)
import Data.Word (Word32)
import GHC.Generics (Generic)

import Clash.Prelude (NFDataX, (&&), (||))

-- | The production interpolator state.
data Interp = Interp
  { interpDir      :: !Bool
  , interpX0       :: !Int32
  , interpX1       :: !Int32
  , interpXDiff    :: !Int32
  , interpX        :: !Int32
  , interpShift    :: !Int
  , interpLinear   :: !Bool
  , interpWBuf      :: !Bool
  , interpXRecipZ  :: !Int32
  , interpW0n      :: !Int32
  , interpW0d      :: !Int32
  , interpW1d      :: !Int32
  , interpYFactor :: !Word32
  } deriving (Eq, Generic, Show, NFDataX)

-- | Reproduce @Interpolator::Setup@.
setupInterp :: Bool -> Int32 -> Int32 -> Int32 -> Int32 -> Bool -> Interp
setupInterp = setupInterpWith (\d -> if d /= 0 then 0x400000 `quot` d else 0)

-- | 'setupInterp' with the @0x400000 / xdiff@ reciprocal supplied by the
-- caller, so hardware can use a table over its reachable span lengths.
setupInterpWith
  :: (Int32 -> Int32) -> Bool -> Int32 -> Int32 -> Int32 -> Int32 -> Bool -> Interp
setupInterpWith recipOf dir x0 x1 w0 w1 wbuffer =
  let xdiff = x1 - x0
      xrecip = recipOf xdiff
      mask = if dir then 0x7E else 0x7F
      linear = w0 == w1 && (w0 .&. mask) == 0 && (w1 .&. mask) == 0
      (w0n, w0d, w1d, shift)
        | dir =
            ( w0 `shiftR` 1
            , (w0 + ((w0 .&. complement w1) .&. 1)) `shiftR` 1
            , w1 `shiftR` 1
            , 9 )
        | otherwise = (w0, w0, w1, 8)
  in Interp
    { interpDir = dir
    , interpX0 = x0
    , interpX1 = x1
    , interpXDiff = xdiff
    , interpX = 0
    , interpShift = shift
    , interpLinear = linear
    , interpWBuf = wbuffer
    , interpXRecipZ = xrecip
    , interpW0n = w0n
    , interpW0d = w0d
    , interpW1d = w1d
    , interpYFactor = 0
    }

-- | Reproduce @Interpolator::SetX@.
setX :: Int32 -> Interp -> Interp
setX x i0 =
  let x' = x - interpX0 i0
      i1 = i0 { interpX = x' }
  in if interpXDiff i0 /= 0 && (not (interpLinear i0) || interpWBuf i0)
       then
         let num = fromIntegral (x' * interpW0n i0) `shiftL` interpShift i0 :: Word32
             den = fromIntegral (x' * interpW0d i0 + (interpXDiff i0 - x') * interpW1d i0) :: Word32
             yfac = if den == 0 then 0 else num `quot` den
         in i1 { interpYFactor = yfac }
       else i1

-- | 'setX' without the perspective factor. 'interpolateZ' in Z-buffer mode
-- reads only 'interpX', 'interpXDiff', 'interpXRecipZ' and 'interpDir';
-- 'setX' writes only 'interpX' and 'interpYFactor', so for a non-W-buffer
-- interpolator the two give the same depth and this one needs no divider.
setXLinear :: Int32 -> Interp -> Interp
setXLinear x i0 = i0 { interpX = x - interpX0 i0 }

-- | Reproduce @Interpolator::InterpolateZ@.
interpolateZ :: Int32 -> Int32 -> Interp -> Int32
interpolateZ z0 z1 i
  | interpXDiff i == 0 || z0 == z1 = z0
  | interpWBuf i =
      let delta = fromIntegral (if z0 < z1 then z1 - z0 else z0 - z1) :: Int64
          factor = fromIntegral (if z0 < z1
                                 then interpYFactor i
                                 else (0x1 `shiftL` interpShift i) - interpYFactor i) :: Int64
          base = if z0 < z1 then z0 else z1
      in base + fromIntegral ((delta * factor) `shiftR` interpShift i)
  | otherwise =
      let (base, disp, factor)
            | z0 < z1 = (z0, z1 - z0, interpX i)
            | otherwise = (z1, z0 - z1, interpXDiff i - interpX i)
          (disp', shift)
            | interpDir i = (disp `shiftR` shiftAmt, shiftAmt)
            | otherwise = (disp `shiftR` 9, 0)
          shiftAmt = max 0 (32 - countLeadingZeros disp - 10)
          prod = fromIntegral disp' * fromIntegral factor * fromIntegral (interpXRecipZ i) :: Int64
          adj :: Int64
          adj
            | interpDir i = (prod `shiftR` 22) `shiftL` shift
            | otherwise = prod `shiftR` 13
      in base + fromIntegral adj

-- | Normalize W to sixteen bits, reproducing @SubmitPolygon@.
normalizeW :: Word32 -> Int32
normalizeW w
  | wsize < 16 =
      let s = fromIntegral (16 - wsize) :: Int
      in fromIntegral ((w `shiftL` s) `shiftR` s)
  | otherwise =
      let s = fromIntegral (wsize - 16) :: Int
      in fromIntegral ((w `shiftR` s) `shiftL` s)
  where
    wsize = normalizedWSize w

-- | The four production depth-test modes. Which one a polygon uses is chosen in
-- @SetupPolygon@: equal-depth when its attribute asks for it, otherwise
-- 'DepthLessFront' for front-facing polygons and 'DepthLess' for back-facing.
data DepthMode
  = DepthLess
  | DepthLessFront
  | DepthEqualZ
  | DepthEqualW
  deriving (Eq, Generic, Show, NFDataX)

-- | Reproduce the production depth comparators. The 'Bool' says whether the
-- destination pixel was written by an opaque back-facing polygon
-- (@dstattr & 0x400010 == 0x10@); only the front-facing test reads it, letting
-- a front face win a Z tie against a back face but not against another front
-- face.
depthPass :: DepthMode -> Bool -> Int32 -> Int32 -> Bool
depthPass DepthLess _ dstz z = z < dstz
depthPass DepthLessFront dstBack dstz z = z < dstz || (z == dstz && dstBack)
depthPass DepthEqualZ _ dstz z = (fromIntegral (dstz - z) + 0x200 :: Word32) <= 0x400
depthPass DepthEqualW _ dstz z = (fromIntegral (dstz - z) + 0xFF :: Word32) <= 0x1FE

-- | The production clear depth for @RenderClearAttr2 = 0@.
clearDepth :: Word32 -> Int32
clearDepth attr = fromIntegral (((attr .&. 0x7FFF) * 0x200) + 0x1FF)

-- | FinalW after polygon W normalization.
finalW :: Word32 -> Int32
finalW w
  | wsize < 16 = fromIntegral (w `shiftL` s)
  | otherwise = fromIntegral (w `shiftR` s)
  where
    wsize = normalizedWSize w
    s = fromIntegral (if wsize < 16 then 16 - wsize else wsize - 16) :: Int

-- | FinalZ for one vertex, including the W-buffer alternative.
finalZ :: Bool -> Int32 -> Word32 -> Int32
finalZ wbuffer z w
  | wbuffer = normalizeW w
  | otherwise =
      let q = divideZ z w
          v = (fromIntegral q + 0x3FFF) * 0x200 :: Int64
      in fromIntegral (max 0 (min 0xFFFFFF v))

-- | The native viewport depth transform.
divideZ :: Int32 -> Word32 -> Int32
divideZ z w
  | w == 0 = 0
  | otherwise =
      let numerator = fromIntegral z * 0x4000 :: Int64
      in fromIntegral (numerator `quot` fromIntegral w)

-- | Polygon W normalization rounds the widest W up to a four-bit boundary.
normalizedWSize :: Word32 -> Word32
normalizedWSize w
  | w == 0 = 0
  | otherwise = (bitWidth + 3) .&. complement 3
  where
    bitWidth = 32 - fromIntegral (countLeadingZeros w) :: Word32
