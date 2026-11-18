-- | The geometry engine's lighting arithmetic, exactly as melonDS's
-- @LIGHT_VECTOR@ (GPU3D.cpp @case 0x32@) and @CalculateLighting@.
--
-- melonDS builds its core with @-fwrapv@, so every signed 32-bit product,
-- sum and left shift below wraps; 'Int32' arithmetic in Haskell does the
-- same. The 32-bit products here are deliberate: unlike the matrix unit,
-- the normal and light-vector transforms are @int@ products in the C++, not
-- @s64@ ones.
module Nds.Gpu3D.Geometry.Lighting
  ( Rgb5
  , V3
  , Light (..)
  , Material (..)
  , noLight
  , noMaterial
  , sext10
  , rgb5
  , lightVector
  , normalTransform
  , lightColour
  ) where

import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits (shiftL, shiftR, testBit, (.&.))
import Data.Int (Int16, Int32)
import Data.Word (Word32, Word8)

import Nds.Gpu3D.Geometry.Matrix (Mat, (!.))

-- | Three 5-bit channels.
type Rgb5 = (Word8, Word8, Word8)

-- | Three signed components.
type V3 = (Int16, Int16, Int16)

-- | One light: @LightDirection[i]@ (11-bit signed components),
-- @SpecRecip[i]@ and @LightColor[i]@.
data Light = Light
  { lDir       :: !V3
  , lSpecRecip :: !Int32
  , lColor     :: !Rgb5
  } deriving (Eq, Show)

-- | The material registers: @MatDiffuse@, @MatAmbient@, @MatSpecular@,
-- @MatEmission@, @UseShininessTable@ and the 128-entry @ShininessTable@.
data Material = Material
  { mDiffuse      :: !Rgb5
  , mAmbient      :: !Rgb5
  , mSpecular     :: !Rgb5
  , mEmission     :: !Rgb5
  , mUseShininess :: !Bool
  , mShininess    :: !(UArray Int Word8)
  } deriving (Eq, Show)

-- | A light after reset.
noLight :: Light
noLight = Light (0, 0, 0) 0 (0, 0, 0)

-- | The material registers after reset.
noMaterial :: Material
noMaterial = Material (0, 0, 0) (0, 0, 0) (0, 0, 0) (0, 0, 0) False
  (listArray (0, 127) (replicate 128 0))

-- | The three 10-bit signed fields of a @NORMAL@, @LIGHT_VECTOR@,
-- @VEC_TEST@ or @VTX_DIFF@ word: @(s16)((p & 0x3FF) << 6) >> 6@ and the
-- like for bits 10-19 and 20-29.
sext10 :: Word32 -> V3
sext10 p = (f (p `shiftL` 6), f (p `shiftR` 4), f (p `shiftR` 14))
  where
    f x = (fromIntegral x :: Int16) `shiftR` 6

-- | The three 5-bit fields of a colour word (bits 0-4, 5-9, 10-14 after
-- shifting right by @sh@).
rgb5 :: Int -> Word32 -> Rgb5
rgb5 sh p = (c 0, c 5, c 10)
  where
    c k = fromIntegral ((p `shiftR` (sh + k)) .&. 0x1F)

i32 :: Integral a => a -> Int32
i32 = fromIntegral

-- | One column of @dir * VecMatrix@ (rows 0-2), an @int@ dot product.
-- Three 32-bit multiply-accumulates.
vecDot :: Mat -> V3 -> Int -> Int32
vecDot vec (d0, d1, d2) c =
  i32 d0 * vec !. c + i32 d1 * vec !. (4 + c) + i32 d2 * vec !. (8 + c)

-- | @LIGHT_VECTOR@: the light index (bits 30-31), the transformed direction
-- (@(-(dot >> 12) << 21) >> 21@ per component) and the specular reciprocal
-- (@(1 << 18) / (512 - ((dot_z << 9) >> 21))@, 0 when that is 0).
-- Nine 32-bit multiply-accumulates and one division.
lightVector :: Mat -> Word32 -> (Int, V3, Int32)
lightVector vec p =
  let dir = sext10 p
      dot = vecDot vec dir
      comp c = fromIntegral ((negate (dot c `shiftR` 12) `shiftL` 21) `shiftR` 21) :: Int16
      den = negate ((dot 2 `shiftL` 9) `shiftR` 21) + (1 `shiftL` 9)
      recipr = if den == 0 then 0 else (1 `shiftL` 18) `quot` den
  in (fromIntegral (p `shiftR` 30), (comp 0, comp 1, comp 2), recipr)

-- | @CalculateLighting@'s @normaltrans@: @((n * VecMatrix) << 9) >> 21@ per
-- component, 32-bit. Nine 32-bit multiply-accumulates.
normalTransform :: Mat -> V3 -> (Int32, Int32, Int32)
normalTransform vec n =
  let c k = (vecDot vec n k `shiftL` 9) `shiftR` 21
  in (c 0, c 1, c 2)

-- | The lit vertex colour of @CalculateLighting@ for the lights enabled in
-- @attr@ bits 0-3 (melonDS reads the attribute latched by @BEGIN_VTXS@).
-- Per enabled light: 3 multiplies for the dot product, 1 for the specular
-- square, 1 for the reciprocal product, and per channel 2 for diffuse and 2
-- for specular/ambient (17 multiplies, plus a shininess-table read).
lightColour :: Word32 -> [Light] -> Material -> (Int32, Int32, Int32) -> Rgb5
lightColour attr lights mat (n0, n1, n2) =
  let (er, eg, eb) = mEmission mat
      w8 :: Word8 -> Word32
      w8 = fromIntegral
      start = (w8 er `shiftL` 14, w8 eg `shiftL` 14, w8 eb `shiftL` 14)
      enabled = [l | (i, l) <- zip [0 ..] lights, testBit attr i]
      final = foldl (applyLight mat (n0, n1, n2)) start enabled
      clamp v = if v `shiftR` 14 > 31 then 31 else fromIntegral (v `shiftR` 14)
      (fr, fg, fb) = final
  in (clamp fr, clamp fg, clamp fb)

-- | Accumulate one enabled light into the 32-bit colour buffer.
applyLight :: Material -> (Int32, Int32, Int32) -> (Word32, Word32, Word32) -> Light
           -> (Word32, Word32, Word32)
applyLight mat (n0, n1, n2) (br, bg, bb) l =
  let (l0, l1, l2) = lDir l
      dot = ((i32 l0 * n0) `shiftR` 9) + ((i32 l1 * n1) `shiftR` 9) + ((i32 l2 * n2) `shiftR` 9)
      (lr, lg, lb) = lColor l
      (dr, dg, db) = mDiffuse mat
      (sr, sg, sb) = mSpecular mat
      (ar, ag, ab) = mAmbient mat
      lit = dot > 0
      diffdot = (dot `shiftL` 21) `shiftR` 21
      diff md lc
        | lit = fromIntegral ((i32 md * i32 lc * diffdot) .&. 0xFFFFF) :: Word32
        | otherwise = 0
      shine0
        | lit =
            let d1 = ((dot + n2) `shiftL` 21) `shiftR` 21
                d2 = ((d1 * d1) `shiftR` 10) .&. 0x3FF
                s = ((d2 * lSpecRecip l) `shiftR` 8) - (1 `shiftL` 9)
            in if s < 0 then 0
               else let e = (s `shiftL` 18) `shiftR` 18
                    in if e < 0 then 0 else if e > 0x1FF then 0x1FF else e
        | otherwise = 0
      shine
        | mUseShininess mat =
            i32 (mShininess mat ! fromIntegral (shine0 `shiftR` 2)) `shiftL` 1
        | otherwise = shine0
      spec ms ma lc = fromIntegral ((i32 ms * shine + (i32 ma `shiftL` 9)) * i32 lc) :: Word32
  in ( br + diff dr lr + spec sr ar lr
     , bg + diff dg lg + spec sg ag lg
     , bb + diff db lb + spec sb ab lb )
