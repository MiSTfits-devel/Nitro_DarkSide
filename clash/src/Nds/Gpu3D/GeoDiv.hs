{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | The geometry engine's divider and the two divisions it serves, for
-- 'Nds.Gpu3D.GeoMatrix'. The divider is 'Nds.Gpu3D.GeometryHw''s (radix-4
-- restoring, 64-bit dividend, 32-bit divisor; a step that would only produce
-- zero quotient digits brings down 16 or 8 dividend bits at once), kept here
-- as its own module so that one copy survives that engine; the geometry gate
-- checks it against 'Nds.Gpu3D.GeometryHw''s on random and edge operands.
--
-- Two commands need a division:
--
-- * @BOX_TEST@: every interpolation of the face clipping is
--   @vin + (vout - vin) * num / den@ ('Nds.Gpu3D.Polygon.Clip'), a 64 / 32
--   division with the NDS4MiSTer fork's widened denominator (exactly
--   @+-2^32@, a shift). This is the command that needs the divider.
-- * @LIGHT_VECTOR@: the specular reciprocal @2^18 / den@ (@den@ in
--   [-511, 1536]), which shares it.
module Nds.Gpu3D.GeoDiv
  ( -- * Divider
    DivSt (..)
  , divIdle
  , divStart
  , divDone
  , divStep
    -- * LIGHT_VECTOR
  , divRecip
  , divSigned
    -- * Box-test interpolation
  , ClipQ (..)
  , clipQ
  , segOpA
  , segOpB
  , segProduct
  , segQNeg
  , segDiv
  , segResult
  ) where

import Clash.Prelude

-- | Divider state: 'dvWork' holds the dividend bits not yet brought down,
-- MSB first; 'dvQuo' the low 32 quotient bits.
data DivSt = DivSt
  { dvRem    :: !(Unsigned 32)
  , dvWork   :: !(Unsigned 64)
  , dvDigits :: !(Unsigned 6)
  , dvQuo    :: !(Unsigned 32)
  , dvDen    :: !(Unsigned 32)
  , dvDen3   :: !(Unsigned 34)
  , dvBusy   :: !Bool
  , dvValid  :: !Bool
  , dvNeg    :: !Bool
  } deriving (Eq, Show, Generic, NFDataX)

divIdle :: DivSt
divIdle = DivSt 0 0 0 0 0 0 False False False

-- | Divide the top @2 * nd@ bits of @work@ by @den@ (non-zero); @neg@ is
-- carried to the result.
divStart :: Unsigned 64 -> Unsigned 6 -> Unsigned 32 -> Bool -> DivSt
divStart work nd den neg = DivSt
  { dvRem = 0, dvWork = work, dvDigits = nd, dvQuo = 0, dvDen = den
  , dvDen3 = resize den + (resize den `shiftL` 1), dvBusy = True, dvValid = False, dvNeg = neg }

-- | A result known without dividing.
divDone :: Unsigned 32 -> DivSt
divDone q = DivSt 0 0 0 q 0 0 False True False

-- | One cycle.
divStep :: DivSt -> DivSt
divStep d
  | not (dvBusy d) = d
  | otherwise =
      let top16 = truncateB (dvWork d `shiftR` 48) :: Unsigned 16
          x48 = (resize (dvRem d) `shiftL` 16) .|. resize top16 :: Unsigned 48
          skip = dvDigits d >= 8 && x48 < resize (dvDen d)
          top8 = truncateB (dvWork d `shiftR` 56) :: Unsigned 8
          x40 = (resize (dvRem d) `shiftL` 8) .|. resize top8 :: Unsigned 40
          skip8 = dvDigits d >= 4 && x40 < resize (dvDen d)
          top2 = truncateB (dvWork d `shiftR` 62) :: Unsigned 2
          x = (resize (dvRem d) `shiftL` 2) .|. resize top2 :: Unsigned 34
          dn1 = resize (dvDen d) :: Unsigned 34
          dn2 = dn1 `shiftL` 1
          (q, r) | x >= dvDen3 d = (3, x - dvDen3 d)
                 | x >= dn2 = (2, x - dn2)
                 | x >= dn1 = (1, x - dn1)
                 | otherwise = (0 :: Unsigned 2, x)
          digits' | skip = dvDigits d - 8
                  | skip8 = dvDigits d - 4
                  | otherwise = dvDigits d - 1
          d' | skip = d { dvRem = truncateB x48, dvWork = dvWork d `shiftL` 16
                        , dvQuo = dvQuo d `shiftL` 16, dvDigits = digits' }
             | skip8 = d { dvRem = truncateB x40, dvWork = dvWork d `shiftL` 8
                         , dvQuo = dvQuo d `shiftL` 8, dvDigits = digits' }
             | otherwise = d { dvRem = truncateB r, dvWork = dvWork d `shiftL` 2
                             , dvQuo = (dvQuo d `shiftL` 2) .|. resize q, dvDigits = digits' }
      in if digits' == 0 then d' { dvBusy = False, dvValid = True } else d'

-- | @LIGHT_VECTOR@'s @(1 << 18) / den@, 0 when @den@ is 0 (melonDS's
-- 'Nds.Gpu3D.Geometry.Lighting.lightVector').
divRecip :: Signed 12 -> DivSt
divRecip den
  | den == 0 = divDone 0
  | otherwise = divStart (1 `shiftL` 62) 10 (unpack (resize (pack (abs den)))) (den < 0)

-- | The signed quotient of a finished 'divRecip'.
divSigned :: DivSt -> Signed 32
divSigned d = let q = unpack (pack (dvQuo d)) in if dvNeg d then negate q else q

-- | The factors of one clip intersection, as magnitudes and signs
-- ('Nds.Gpu3D.Polygon.Clip.clipFactors'): the numerator (vin's plane
-- distance), the denominator (vin's distance minus vout's) and whether the
-- fork's 64-bit fallback was taken (the 32-bit denominator wrapped to 0; the
-- true one is then exactly @+-2^32@ and the division is a shift).
data ClipQ = ClipQ
  { cqNumMag :: !(Unsigned 33)
  , cqDenMag :: !(Unsigned 32)
  , cqNumNeg :: !Bool
  , cqDenNeg :: !Bool
  , cqWide   :: !Bool
  } deriving (Eq, Show, Generic, NFDataX)

-- | Factors for clipping from @vin@ (component @vc@, @vw@; outside) towards
-- @vout@ (@oc@, @ow@; inside) against the @+W@ (@pos@) or @-W@ plane.
clipQ :: Bool -> Signed 32 -> Signed 32 -> Signed 32 -> Signed 32 -> ClipQ
clipQ pos vc vw oc ow = ClipQ (mag34 numS) denMag (numS < 0) denNeg isWide
  where
    dist c w = if pos then w - c else w + c
    wide :: Signed 32 -> Signed 32 -> Signed 34
    wide c w = if pos then resize w - resize c else resize w + resize c
    dIn = dist vc vw
    legDen = dIn - dist oc ow
    isWide = legDen == 0
    numS = if isWide then wide vc vw else resize dIn
    denNeg = if isWide then wide vc vw < wide oc ow else legDen < 0
    mag34 x = unpack (truncateB (pack (if x < 0 then negate x else x))) :: Unsigned 33
    denMag = unpack (pack (if legDen < 0 then negate legDen else legDen)) :: Unsigned 32

-- | The difference @b - a@ of one interpolated component as a 33-bit value.
segDiff :: Signed 32 -> Signed 32 -> Signed 33
segDiff a b = resize b - resize a

-- | The multiplier operands of @|num| * |b - a|@, four partial products
-- (high x high, high x low, low x high, low x low; 17 x 16 and 16 x 16
-- bits) so the 33 x 32-bit product needs no wider multiplier: the
-- numerator halves ...
segOpA :: ClipQ -> Vec 4 (Signed 32)
segOpA q =
  let n = cqNumMag q
      nH = u2s32 (n `shiftR` 16)
      nL = u2s32 (n .&. 0xFFFF)
  in nH :> nH :> nL :> nL :> Nil

-- | ... and the difference halves. (Two functions, never a pair: see
-- 'Nds.Gpu3D.GeoMatrix.litA'.)
segOpB :: Signed 32 -> Signed 32 -> Vec 4 (Signed 32)
segOpB a b =
  let d = segDiff a b
      dMag = unpack (truncateB (pack (if d < 0 then negate d else d))) :: Unsigned 32
      dH = u2s32 (dMag `shiftR` 16)
      dL = u2s32 (dMag .&. 0xFFFF)
  in dH :> dL :> dH :> dL :> Nil

u2s32 :: KnownNat m => Unsigned m -> Signed 32
u2s32 x = unpack (resize (pack x))

-- | The 64-bit product from the four partial products of 'segOpA' x
-- 'segOpB'.
segProduct :: Vec 4 (Signed 44) -> Unsigned 64
segProduct ps =
  let u :: Signed 44 -> Unsigned 64
      u x = unpack (resize (pack x))
  in (u (ps !! (0 :: Int)) `shiftL` 32) + ((u (ps !! (1 :: Int)) + u (ps !! (2 :: Int))) `shiftL` 16)
     + u (ps !! (3 :: Int))

-- | Whether the interpolation step @(b - a) * num / den@ is negative.
segQNeg :: ClipQ -> Signed 32 -> Signed 32 -> Bool
segQNeg q a b = (segDiff a b < 0) /= (cqNumNeg q /= cqDenNeg q)

-- | The division of one interpolation (the wide denominator is a shift).
segDiv :: ClipQ -> Unsigned 64 -> DivSt
segDiv q prod
  | cqWide q = divDone (truncateB (prod `shiftR` 32))
  | otherwise = divStart prod 32 (cqDenMag q) False

-- | @a@ plus the signed quotient, wrapped to 32 bits.
segResult :: Signed 32 -> Bool -> Unsigned 32 -> Signed 32
segResult a qneg quo = let q = unpack (pack quo) in a + (if qneg then negate q else q)
