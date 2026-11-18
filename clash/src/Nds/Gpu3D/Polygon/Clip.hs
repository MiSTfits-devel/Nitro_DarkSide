{-# LANGUAGE BangPatterns #-}

-- | Exact melonDS polygon clipping: @ClipSegment@, @ClipAgainstPlane@ and
-- @ClipPolygon\<true\>@ from @GPU3D.cpp@ (the NDS4MiSTer fork's version, which
-- is what the oracle runs; see 'clipFactors' for the one place it differs
-- from upstream melonDS).
--
-- The clipper works on melonDS's ten-slot vertex array ('ClipBuf'), not on a
-- list, because the array outlives the vertex count: when the far plane
-- rejects a strip polygon whose first two vertices were reused
-- (@clipstart == 2@), the Z pass returns 0 but slots 0 and 1 still hold the
-- reused vertices, and the Y pass, starting again from @clipstart@, returns
-- 2. The polygon survives with two vertices. A list model would lose that.
module Nds.Gpu3D.Polygon.Clip
  ( -- * Working vertex
    Vtx (..)
  , zeroVtx
  , vtxComp
  , setVtxComp
  , normaliseColour
    -- * One clip intersection
  , ClipFactors (..)
  , clipFactors
  , interpolate32
  , interpolate16
  , clipSegment
    -- * Polygon clipping
  , ClipBuf
  , ClipStats (..)
  , noClipStats
  , maxClipVertices
  , clipAgainstPlane
  , clipPolygon
  ) where

import Data.Bits (complement, testBit, (.&.))
import Data.Int (Int16, Int32, Int64)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Word (Word32)

-- | A melonDS @Vertex@, minus @HiresPosition@ (only the OpenGL and compute
-- renderers read it).
data Vtx = Vtx
  { vX, vY, vZ, vW    :: !Int32  -- ^ @Position[0..3]@ (clip space)
  , vR, vG, vB        :: !Int32  -- ^ @Color[0..2]@ (@(c << 12) + 0xFFF@)
  , vS, vT            :: !Int16  -- ^ @TexCoords@
  , vClipped          :: !Bool   -- ^ produced by 'clipSegment'
  , vFX, vFY          :: !Int32  -- ^ @FinalPosition@
  , vFR, vFG, vFB     :: !Int32  -- ^ @FinalColor@
  } deriving (Eq, Show)

-- | An all-zero vertex (melonDS's zero-initialised RAM).
zeroVtx :: Vtx
zeroVtx = Vtx 0 0 0 0 0 0 0 0 0 False 0 0 0 0 0

-- | @Position[comp]@.
vtxComp :: Int -> Vtx -> Int32
vtxComp 0 = vX
vtxComp 1 = vY
vtxComp 2 = vZ
vtxComp _ = vW

-- | Write @Position[comp]@.
setVtxComp :: Int -> Int32 -> Vtx -> Vtx
setVtxComp 0 a v = v { vX = a }
setVtxComp 1 a v = v { vY = a }
setVtxComp 2 a v = v { vZ = a }
setVtxComp _ a v = v { vW = a }

-- | The end-of-pass colour fix-up: @Color &= ~0xFFF; Color += 0xFFF@.
normaliseColour :: Vtx -> Vtx
normaliseColour v = v { vR = f (vR v), vG = f (vG v), vB = f (vB v) }
  where
    f c = (c .&. complement 0xFFF) + 0xFFF

-- | The interpolation factor of one clip intersection, as
-- @NDS4MiSTerResolveGXClipFactors@ computes it.
--
-- The plane distances are @W - plane*comp@, evaluated in 32 bits with
-- wrap-around exactly as upstream melonDS does. When the two wrapped
-- distances are equal (a 32-bit denominator of zero, which upstream divides
-- by), the fork recomputes both in 64 bits; the denominator is then exactly
-- @+-2^32@ ('cfWide'). Upstream also forms the attribute difference
-- @vout - vin@ in 32 bits; the fork forms it in 64 bits ('interpolate32').
data ClipFactors = ClipFactors
  { cfNum  :: !Int64  -- ^ vin's plane distance
  , cfDen  :: !Int64  -- ^ vin's distance minus vout's
  , cfWide :: !Bool   -- ^ the 64-bit fallback was taken
  } deriving (Eq, Show)

-- | Factors for clipping the segment from @vin@ (outside) towards @vout@
-- (inside) against plane @comp = plane * W@, @plane@ being 1 or -1.
clipFactors :: Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> ClipFactors
clipFactors plane vinC vinW voutC voutW
  | legacyDen /= 0 = ClipFactors (fromIntegral legacyNum) (fromIntegral legacyDen) False
  | otherwise = ClipFactors wideIn (wideIn - wideOut) True
  where
    wrapped :: Int32 -> Int32 -> Word32
    wrapped c w
      | plane == 1 = fromIntegral w - fromIntegral c
      | otherwise = fromIntegral w + fromIntegral c
    dIn = wrapped vinC vinW
    dOut = wrapped voutC voutW
    legacyNum = fromIntegral dIn :: Int32
    legacyDen = fromIntegral (dIn - dOut) :: Int32
    wide :: Int32 -> Int32 -> Int64
    wide c w = fromIntegral w - fromIntegral plane * fromIntegral c
    wideIn = wide vinC vinW
    wideOut = wide voutC voutW

-- | @vin + (vout - vin) * num / den@: the difference in 64 bits, the product
-- exact (it can need 64 magnitude bits in the wide case), the quotient
-- truncated toward zero, the sum wrapped to 32 bits.
interpolate32 :: ClipFactors -> Int32 -> Int32 -> Int32
interpolate32 f a b = fromInteger (interpolateWide f (toInteger a) (toInteger b))

-- | 'interpolate32' for the 16-bit texture coordinates (sum wrapped to 16).
interpolate16 :: ClipFactors -> Int16 -> Int16 -> Int16
interpolate16 f a b = fromInteger (interpolateWide f (toInteger a) (toInteger b))

interpolateWide :: ClipFactors -> Integer -> Integer -> Integer
interpolateWide f a b = a + ((b - a) * toInteger (cfNum f)) `quot` toInteger (cfDen f)

-- | @ClipSegment\<comp, plane, true\>(outbuf, vin, vout)@. The output starts
-- from @vin@ only so that its unwritten fields (@FinalPosition@,
-- @FinalColor@) are defined; melonDS leaves them stale and always rewrites
-- them before reading. Also returns 'cfWide'.
clipSegment :: Int -> Int32 -> Vtx -> Vtx -> (Vtx, Bool)
clipSegment comp plane vin vout = (setVtxComp comp (plane * w') interpolated, cfWide f)
  where
    f = clipFactors plane (vtxComp comp vin) (vW vin) (vtxComp comp vout) (vW vout)
    i32 sel = interpolate32 f (sel vin) (sel vout)
    i16 sel = interpolate16 f (sel vin) (sel vout)
    w' = i32 vW
    interpolated = vin
      { vX = i32 vX, vY = i32 vY, vZ = i32 vZ, vW = w'
      , vR = i32 vR, vG = i32 vG, vB = i32 vB
      , vS = i16 vS, vT = i16 vT
      , vClipped = True
      }

-- | melonDS's ten-entry vertex arrays (@clippedvertices@, @temp@). Always
-- exactly 'maxClipVertices' slots.
type ClipBuf = Seq Vtx

-- | @MaxClipVertices@: excess intersections of a twisted quad are dropped.
maxClipVertices :: Int
maxClipVertices = 10

-- | What one polygon's clipping did, for statistics and for the hardware
-- cost model.
data ClipStats = ClipStats
  { csSegments  :: !Int   -- ^ 'clipSegment' calls
  , csWide      :: !Int   -- ^ of which took the 64-bit factor fallback
  , csDropped   :: !Int   -- ^ vertices dropped at 'maxClipVertices'
  , csFarReject :: !Bool  -- ^ the far plane returned 0
  } deriving (Eq, Show)

noClipStats :: ClipStats
noClipStats = ClipStats 0 0 0 False

addSeg :: Bool -> ClipStats -> ClipStats
addSeg wide s = s { csSegments = csSegments s + 1
                  , csWide = csWide s + (if wide then 1 else 0) }

addDrop :: ClipStats -> ClipStats
addDrop s = s { csDropped = csDropped s + 1 }

-- | @ClipAgainstPlane\<comp, true\>@: the @+W@ half (outside when
-- @comp > W@; for Z without attribute bit 12 that rejects the polygon), then
-- the @-W@ half (outside when @comp < -W@), then the colour fix-up of every
-- output vertex. Returns the array and the new vertex count.
clipAgainstPlane :: Int -> Word32 -> Int -> (ClipBuf, Int, ClipStats) -> (ClipBuf, Int, ClipStats)
clipAgainstPlane comp attr clipstart (vertices, nverts, stats0) =
  case positivePass of
    Nothing -> (vertices, 0, stats0 { csFarReject = True })
    Just (temp, ntemp, stats1) ->
      let (out, c, stats2) = negativePass temp ntemp stats1
          fixed = foldl (\buf i -> Seq.adjust' normaliseColour i buf) out [0 .. c - 1]
      in (fixed, c, stats2)
  where
    -- temp[0..1] = vertices[0..1] when clipstart == 2; the rest of temp is
    -- written before it is read.
    temp0 = if clipstart == 2 then vertices else Seq.replicate maxClipVertices zeroVtx

    positivePass = goPos clipstart temp0 clipstart stats0
    goPos !i temp !c stats
      | i >= nverts = Just (temp, c, stats)
      | outsidePos vtx =
          if comp == 2 && not (testBit attr 12)
            then Nothing
            else
              let vprev = at vertices (prevOf nverts i)
                  vnext = at vertices (nextOf nverts i)
                  (temp1, c1, s1) = emitIf (insidePos vprev) 1 vtx vprev (temp, c, stats)
                  (temp2, c2, s2) = emitIf (insidePos vnext) 1 vtx vnext (temp1, c1, s1)
              in goPos (i + 1) temp2 c2 s2
      | c < maxClipVertices = goPos (i + 1) (Seq.update c vtx temp) (c + 1) stats
      | otherwise = goPos (i + 1) temp c (addDrop stats)
      where
        vtx = at vertices i

    negativePass temp ntemp stats = goNeg clipstart vertices clipstart stats
      where
        goNeg !i out !c s
          | i >= ntemp = (out, c, s)
          | outsideNeg vtx =
              let vprev = at temp (prevOf ntemp i)
                  vnext = at temp (nextOf ntemp i)
                  (out1, c1, s1) = emitIf (insideNeg vprev) (-1) vtx vprev (out, c, s)
                  (out2, c2, s2) = emitIf (insideNeg vnext) (-1) vtx vnext (out1, c1, s1)
              in goNeg (i + 1) out2 c2 s2
          | c < maxClipVertices = goNeg (i + 1) (Seq.update c vtx out) (c + 1) s
          | otherwise = goNeg (i + 1) out c (addDrop s)
          where
            vtx = at temp i

    emitIf cond plane vin vout (buf, c, s)
      | cond && c < maxClipVertices =
          let (v, wide) = clipSegment comp plane vin vout
          in (Seq.update c v buf, c + 1, addSeg wide s)
      | cond = (buf, c, addDrop s)
      | otherwise = (buf, c, s)

    outsidePos v = vtxComp comp v > vW v
    insidePos v = vtxComp comp v <= vW v
    outsideNeg v = vtxComp comp v < negate (vW v)
    insideNeg v = vtxComp comp v >= negate (vW v)

    at buf i = Seq.index buf i
    prevOf n i = if i - 1 < 0 then n - 1 else i - 1
    nextOf n i = if i + 1 >= n then 0 else i + 1

-- | @ClipPolygon\<true\>@: Z, then Y, then X, each pass fed the previous
-- pass's count with no early exit (see the module header for why that
-- matters). The fork's "already inside" fast path is omitted: it is taken
-- only when the full clipper would return its input unchanged.
clipPolygon :: Word32 -> Int -> ClipBuf -> Int -> (ClipBuf, Int, ClipStats)
clipPolygon attr clipstart buf nverts =
  clipAgainstPlane 0 attr clipstart
    (clipAgainstPlane 1 attr clipstart
      (clipAgainstPlane 2 attr clipstart (buf, nverts, noClipStats)))
