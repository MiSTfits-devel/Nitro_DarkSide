{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Exact NDS edge-walk arithmetic, transcribed from the production
-- rasteriser in @melonDS\/src\/GPU3D_Soft.h@ (@SoftRenderer3D::Slope@).
--
-- This is the first Clash-owned 3D block. It is deliberately a pure model:
-- the native checker sweeps it against the vendored melonDS class, and the
-- same equations are wrapped by 'Nds.Gpu3D.Top' for synthesis.
--
-- All arithmetic is 32-bit two's complement with explicit widening, because
-- the DS rasteriser relies on wrap-around at several points and C++ signed
-- overflow is not something a Haskell model may ignore.
module Nds.Gpu3D.Slope
  ( Slope (..)
  , setupSlope
  , setupSlopeFlat
  , setupDummy
  , edgeParams
  , stepSlope
  , stepSlopeDepth
  , slopeXVal
  , magicDiv
  , reciprocal18
  , reciprocal18Tab
  , divideByXLen
  ) where

import Prelude hiding (map, (!!))

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Int (Int32, Int64)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)

import Clash.Prelude (NFDataX, Vec)
import Clash.Sized.Vector (iterateI, map, (!!))

import Nds.Gpu3D.Depth (Interp, setX, setupInterp)

-- | One rasterised polygon edge. Field meanings follow melonDS exactly:
--
-- * 'slopeX0' is the vertex X the edge starts from.
-- * 'slopeDx' is the 18-bit-fractional distance walked so far.
-- * 'slopeXMin'\/'slopeXMax' clamp the sampled X to the edge span.
-- * 'slopeInc' is the per-scanline X increment, 18 fractional bits.
-- * 'slopeXLenRecip' is the reciprocal used by AA coverage maths.
-- * 'slopeXCovIncr' is the per-pixel coverage increment.
data Slope = Slope
  { slopeX0        :: !Int32
  , slopeXMin      :: !Int32
  , slopeXMax      :: !Int32
  , slopeXLen      :: !Int32
  , slopeYLen      :: !Int32
  , slopeInc       :: !Int32
  , slopeDx        :: !Int32
  , slopeY         :: !Int32
  , slopeNegative  :: !Bool
  , slopeXMajor    :: !Bool
  , slopeSide      :: !Bool
  , slopeXLenRecip :: !Word32
  , slopeXCovIncr  :: !Int32
  , slopeInterp    :: !(Maybe Interp)
  }
  deriving (Eq, Generic, Show, NFDataX)

-- | Wrap an 'Int64' into the 32-bit two's-complement value C++ holds.
w32 :: Int64 -> Int32
w32 = fromIntegral

-- | Floor reciprocal table entry used by the edge walk:
-- @2^18 \/ d@ for @1 <= d <= 0x200@, and the same truncating division
-- above the table.
reciprocal18 :: Int32 -> Int32
reciprocal18 d
  | d <= 0x0  = 0x0
  | otherwise = 0x40000 `quot` d

-- | The same floor reciprocal for the common on-screen denominators. The table
-- is a constant, so Quartus folds it into LUTs; taller edges fall back to the
-- exact divider so no visible span is ever discarded.
reciprocal18Tab :: Int32 -> Int32
reciprocal18Tab d
  | d <= 0x0 = 0x0
  | d <= 0x100 = recipTable !! (fromIntegral d :: Int)
  | otherwise = reciprocal18 d

recipTable :: Vec 257 Int32
recipTable =
  map (\d -> if d <= 0x0 then 0x0 else 0x40000 `quot` d) (iterateI (+ 0x1) 0)

-- | Ceiling reciprocal used for AA coverage: @ceil(2^32 \/ d)@.
magicDiv :: Int32 -> Word32
magicDiv d
  | d <= 0x1 = 0x0
  | otherwise =
      let ud = fromIntegral d :: Word64
          q  = 0xFFFFFFFF `quot` ud
          r  = 0xFFFFFFFF - q * ud
      in fromIntegral (q + if r == ud - 0x1 then 0x1 else 0x0)

-- | Reproduce @Slope::DivideByXLen@.
divideByXLen :: Slope -> Int32 -> Int32
divideByXLen s numerator
  | slopeXLen s == 0x1 = numerator
  | numerator >= 0x0 =
      let dividend = fromIntegral numerator :: Word64
          xrecip   = fromIntegral (slopeXLenRecip s) :: Word64
          quotient = (dividend * xrecip) `shiftR` 0x20 :: Word64
          xlen     = fromIntegral (slopeXLen s) :: Word64
          remainder = dividend - quotient * xlen
          adjusted = quotient + if remainder >= xlen then 0x1 else 0x0
      in fromIntegral adjusted
  | otherwise = numerator `quot` slopeXLen s

-- | Reproduce @Slope::Setup@. The first 'Bool' is the edge side:
-- 'True' is the right edge, 'False' the left. The final 'Bool' is the
-- W-buffer flag; it only affects interpolation state, not the X walk.
setupSlope
  :: Bool -> Int32 -> Int32 -> Int32 -> Int32
  -> Int32 -> Int32 -> Int32 -> Bool -> (Int32, Slope)
setupSlope side x0 x1 y0 y1 w0 w1 y wbuffer =
  let s0 = setupSlopeCore side x0 x1 y0 y1 y
      s1 = s0
        { slopeXLenRecip =
            if slopeXMajor s0 && slopeXLen s0 > 0x1
              then magicDiv (slopeXLen s0) else 0x0
        }
      s2 = s1
        { slopeXCovIncr =
            if slopeXMajor s1
              then divideByXLen s1 (slopeYLen s1 `shiftL` 0xA) else 0x0
        }
      interpoffset = slopeInc s2 >= 0x40000 && side /= slopeNegative s2
      -- Production calls Interp.SetX(y) straight after Interp.Setup; with
      -- interpoffset the first row's offset is 1, not 0.
      interp = setX y (setupInterp True (y0 - if interpoffset then 0x1 else 0x0)
                         (y1 - if interpoffset then 0x1 else 0x0)
                         w0 w1 wbuffer)
      s3 = s2 { slopeInterp = Just interp }
  in (slopeXVal s3, s3)

-- | The same edge setup without the reciprocal and coverage increments. The
-- flat opaque path never reads either field, so this avoids two dividers.
setupSlopeFlat
  :: Bool -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> (Int32, Slope)
setupSlopeFlat side x0 x1 y0 y1 y =
  let s = setupSlopeCoreTab side x0 x1 y0 y1 y
  in (slopeXVal s, s)

setupSlopeCore
  :: Bool -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Slope
setupSlopeCore = setupSlopeCoreWith reciprocal18Exact

setupSlopeCoreTab
  :: Bool -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Slope
setupSlopeCoreTab = setupSlopeCoreWith reciprocal18Tab

reciprocal18Exact :: Int32 -> Int32
reciprocal18Exact d
  | d > 0x0 && d <= 0x200 = reciprocal18 d
  | otherwise = (0x1 `shiftL` 0x12) `quot` d

setupSlopeCoreWith
  :: (Int32 -> Int32)
  -> Bool -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Slope
setupSlopeCoreWith recipFn side x0 x1 y0 y1 y =
  let (xmin, xmax, negative)
        | x1 > x0   = (x0, x1 - 0x1, False)
        | x1 < x0   = (x1, x0 - 0x1, True)
        | otherwise = (x0, x0, False)
      xlen = xmax + 0x1 - xmin
      ylen = y1 - y0
      inc
        | ylen == 0x0 = 0x0
        | ylen == xlen && xlen /= 0x1 = 0x40000
        | otherwise =
            let yrecip = recipFn ylen
            in abs (w32 (fromIntegral (x1 - x0) * fromIntegral yrecip))
      xmajor = inc > 0x40000
      baseDx
        | side =
            if xmajor
              then if negative then 0x20000 + 0x40000 else inc - 0x20000
              else if inc /= 0x0 then (if negative then 0x40000 else 0x0) else 0x0
        | otherwise =
            if xmajor
              then if negative then (inc - 0x20000) + 0x40000 else 0x20000
              else if inc /= 0x0 then (if negative then 0x40000 else 0x0) else 0x0
      dx = w32 (fromIntegral baseDx + fromIntegral (y - y0) * fromIntegral inc)
  in Slope
    { slopeX0        = x0
    , slopeXMin      = xmin
    , slopeXMax      = xmax
    , slopeXLen      = xlen
    , slopeYLen      = ylen
    , slopeInc       = inc
    , slopeDx        = dx
    , slopeY         = y
    , slopeNegative  = negative
    , slopeXMajor    = xmajor
    , slopeSide      = side
    , slopeXLenRecip = 0x0
    , slopeXCovIncr = 0x0
    , slopeInterp = Nothing
    }

-- | Reproduce @Slope::SetupDummy@. Used for a zero-height polygon, where
-- the edge is a single column and never stepped.
setupDummy :: Int32 -> Bool -> Slope
setupDummy x0 _wbuffer =
  Slope
    { slopeX0        = x0
    , slopeXMin      = x0
    , slopeXMax      = x0
    , slopeXLen      = 0x0
    , slopeYLen      = 0x0
    , slopeInc       = 0x0
    , slopeDx        = 0x0
    , slopeY         = 0x0
    , slopeNegative  = False
    , slopeXMajor    = False
    , slopeSide      = False
    , slopeXLenRecip = 0x0
    , slopeXCovIncr  = 0x0
    , slopeInterp    = Nothing
    }

-- | Reproduce @Slope::EdgeParams@. The 'Bool' selects the swapped
-- (backwards) render path. Returns @(length, coverage)@ exactly as the
-- rasteriser's fill rules consume them.
edgeParams :: Bool -> Slope -> (Int32, Int32)
edgeParams swapped s
  | slopeXMajor s = edgeParamsXMajor (slopeSide s) swapped s
  | otherwise     = edgeParamsYMajor (slopeSide s) swapped s

edgeParamsXMajor :: Bool -> Bool -> Slope -> (Int32, Int32)
edgeParamsXMajor side swapped s =
  let inc = slopeInc s
      dx  = slopeDx s
      negative = slopeNegative s
      lenCalc
        | not swapped || side =
            if side /= negative
              then (dx `shiftR` 0x12) - ((dx - inc) `shiftR` 0x12)
              else ((dx + inc) `shiftR` 0x12) - (dx `shiftR` 0x12)
        | otherwise = 0x0
      startx0 = dx `shiftR` 0x12
      startx1 = if negative then slopeXLen s - startx0 else startx0
      startx = if side then startx1 - lenCalc + 0x1 else startx1
      startcov = divideByXLen s
        (w32 ((fromIntegral (startx `shiftL` 0xA) + 0x1FF)
              * fromIntegral (slopeYLen s)))
      coverage = (0x1 `shiftL` 0x1F)
        .|. ((startcov .&. 0x3FF) `shiftL` 0xC)
        .|. (slopeXCovIncr s .&. 0x3FF)
      len = if swapped then 0x1 else lenCalc
  in (len, coverage)

edgeParamsYMajor :: Bool -> Bool -> Slope -> (Int32, Int32)
edgeParamsYMajor side swapped s =
  let inc = slopeInc s
      dx = slopeDx s
      negative = slopeNegative s
      coverage
        | inc == 0x0 = if swapped then 0x0 else 0x1F
        | otherwise =
            let cov0 = ((dx `shiftR` 0x9) + (inc `shiftR` 0xA)) `shiftR` 0x4
                cov1 = if (cov0 `shiftR` 0x5) /= (dx `shiftR` 0x12)
                         then 0x1F else cov0
                cov2 = cov1 .&. 0x1F
                flipped
                  | swapped = if side /= negative then 0x1F - cov2 else cov2
                  | side == negative = 0x1F - cov2
                  | otherwise = cov2
            in flipped
  in (0x1, coverage)

-- | Sample the edge at its current scanline.
slopeXVal :: Slope -> Int32
slopeXVal s =
  let raw
        | slopeNegative s = slopeX0 s - (slopeDx s `shiftR` 0x12)
        | otherwise       = slopeX0 s + (slopeDx s `shiftR` 0x12)
  in max (slopeXMin s) (min (slopeXMax s) raw)

-- | Walk one scanline down.
stepSlope :: Slope -> (Int32, Slope)
stepSlope s =
  let s' = s
        { slopeDx = w32 (fromIntegral (slopeDx s) + fromIntegral (slopeInc s))
        , slopeY  = slopeY s + 0x1
        }
  in (slopeXVal s', s')

-- | Step one scanline and refresh the edge depth interpolator.
stepSlopeDepth :: Slope -> (Int32, Slope)
stepSlopeDepth s =
  let (x, s') = stepSlope s
      s'' = s' { slopeInterp = fmap (setX (slopeY s')) (slopeInterp s') }
  in (x, s'')
