{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The span setup engine: one fetched polygon and one scanline in, one
-- 'SpanJob' out.
--
-- The engine is stateless across lines. A polygon's edge state on line @y@
-- is a function of its vertices and @y@ alone (see "Nds.Gpu3D.RasterHw"):
-- the cursors are the vertex walk from @VTop@ at @y@, and every 'Slope'
-- field is @Slope::Setup@ at @y@ (@dx@ after @k@ steps is
-- @baseDx + (y - y0) * inc@ in 32 bits, the edge interpolator is @SetX(y)@).
-- So nothing is stored per polygon; each active polygon line is set up from
-- its record.
--
-- Arithmetic is time-multiplexed over one 32x24-bit multiplier (product
-- registered, read in the next phase), one radix-8 restoring divider (three
-- quotient bits per cycle, full 32-bit divisor) and the reciprocal ROM
-- ('recipRom', registered read). Edge walks can run backwards in Y: signed
-- offsets, linear interpolation and depth products use magnitude operands
-- with explicit sign restoration. Perspective interpolation instead preserves
-- production's unsigned Word32 wrapping, including denominators wider than
-- 25 bits. Division retains the complete numerator and denominator.
module Nds.Gpu3D.RasterHw.Setup
  ( RecHdr (..)
  , recHdr0
  , JobMsg (..)
  , EdgeHw (..)
  , toSlope
  , DivReq
  , DivSt (..)
  , divInit
  , divStep
  , SetupIn (..)
  , SetupOut (..)
  , Su (..)
  , suInit
  , setupStep
  , setupEngine
  , recWordAddr
  ) where

import Prelude

import Data.Bits (complement, countLeadingZeros, shiftL, shiftR, testBit, (.&.), (.|.))
import Data.Int (Int32, Int64)
import Data.Word (Word32, Word8)
import GHC.Generics (Generic)

import Clash.Explicit.Prelude
  ( BitVector, Clock, Enable, Index, KnownDomain, NFDataX, Reset, Signal, Unsigned, Vec
  , blockRamPow2, bundle, register, resize, romPow2, unbundle, unpack )
import qualified Clash.Explicit.Prelude as C
import Clash.Explicit.Mealy (mealy)

import Nds.Gpu3D.Depth (DepthMode (..))
import Nds.Gpu3D.PolyRam (PolySlot (..), VertexRec (..), decodeSlot, decodeVertexRec)
import Nds.Gpu3D.Raster (RasterConfig (..), SpanRule (..), rightPullIn, spanPieces, spanRuleWith)
import Nds.Gpu3D.RasterHw.Types
import Nds.Gpu3D.Slope (Slope (..), edgeParamsWith, edgeStartX, slopeXVal)

------------------------------------------------------------------------------
-- Interface

-- | A fetched polygon (or a line-end token) as the front end hands it over.
-- The vertex words are in the record RAM ('recWordAddr'); the header and
-- the vertex X and Y are here.
data RecHdr = RecHdr
  { rhEntry   :: !(Unsigned 1)   -- ^ record RAM entry
  , rhEnd     :: !Bool           -- ^ line-end token: all polygons of 'rhLine' were handed over
  , rhLine    :: !(Unsigned 8)
  , rhAttr    :: !Word32
  , rhTexParam :: !Word32
  , rhTexPal  :: !Word32
  , rhN       :: !(Unsigned 4)
  , rhWBuf    :: !Bool
  , rhFacing  :: !Bool
  , rhMask    :: !Bool
  , rhShadow  :: !Bool
  , rhVTop    :: !(Unsigned 4)
  , rhVBot    :: !(Unsigned 4)
  , rhYTop    :: !(Unsigned 8)
  , rhYBot    :: !(Unsigned 8)
  , rhX       :: !(Vec 10 (Unsigned 9))
  , rhY       :: !(Vec 10 (Unsigned 8))
  } deriving (Eq, Generic, Show, NFDataX)

recHdr0 :: RecHdr
recHdr0 = RecHdr 0 False 0 0 0 0 0 False False False False 0 0 0 0 (C.repeat 0) (C.repeat 0)

-- | Record RAM word of vertex @k@ (word 0 slot, 1 V0, 2 V1) of an entry.
recWordAddr :: Unsigned 1 -> Unsigned 4 -> Unsigned 2 -> Unsigned 6
recWordAddr e k w = (resize e `shiftL` 5) + resize k * 3 + resize w

-- | What the setup engine hands the pixel engine.
data JobMsg
  = JobSpan !SpanJob
  | JobLineEnd !(Unsigned 8)
  deriving (Eq, Generic, Show, NFDataX)

-- | One edge at the current line: the 'Slope' fields the span rules read.
data EdgeHw = EdgeHw
  { ehX0     :: !Int32
  , ehXMin   :: !Int32
  , ehXMax   :: !Int32
  , ehXLen   :: !Int32
  , ehYLen   :: !Int32
  , ehInc    :: !Int32
  , ehDx     :: !Int32
  , ehNeg    :: !Bool
  , ehXMajor :: !Bool
  , ehSide   :: !Bool
  , ehXCov   :: !Int32
  } deriving (Eq, Generic, Show, NFDataX)

-- | The model 'Slope' of an edge (no interpolator: the hardware keeps its
-- values separately; no reciprocal: the hardware divides exactly).
toSlope :: EdgeHw -> Slope
toSlope e = Slope
  { slopeX0 = ehX0 e, slopeXMin = ehXMin e, slopeXMax = ehXMax e
  , slopeXLen = ehXLen e, slopeYLen = ehYLen e, slopeInc = ehInc e, slopeDx = ehDx e
  , slopeY = 0, slopeNegative = ehNeg e, slopeXMajor = ehXMajor e, slopeSide = ehSide e
  , slopeXLenRecip = 0, slopeXCovIncr = ehXCov e, slopeInterp = Nothing
  }

dummyEdge :: Int32 -> EdgeHw
dummyEdge x = EdgeHw x x x 0 0 0 0 False False False 0

------------------------------------------------------------------------------
-- Divider

-- | Dividend and divisor (non-zero).
type DivReq = (Unsigned 42, Unsigned 32)

data DivSt = DivSt
  { dsBusy :: !Bool
  , dsLeft :: !(Index 43)
  , dsN    :: !(Unsigned 42)   -- ^ dividend bits still to shift in, MSB first
  , dsR    :: !(Unsigned 33)
  , dsQ    :: !(Unsigned 42)
  , dsD    :: !(Unsigned 32)
  } deriving (Eq, Generic, Show, NFDataX)

divInit :: DivSt
divInit = DivSt False 0 0 0 0 1

-- | Radix-8 restoring division: three quotient bits per cycle, over the
-- quotient's bit length (@bitlen n - bitlen d + 1@, or none when @n < d@).
-- Outputs (busy, quotient, remainder); the result holds until the next
-- start.
divStep :: DivSt -> Maybe DivReq -> (DivSt, (Bool, Unsigned 42, Unsigned 32))
divStep s req = (s', (dsBusy s, dsQ s, resize (dsR s)))
  where
    s' = case req of
      Just (n, d) | not (dsBusy s) ->
        let bl :: C.KnownNat k => Unsigned k -> Int
            bl v = C.finiteBitSize v - C.countLeadingZeros v
            bits = if n < resize d then 0 else fromIntegral (bl n - bl d + 1) :: Index 43
        in DivSt (bits /= 0) bits (n `shiftL` (42 - fromIntegral bits)) (resize (n `shiftR` fromIntegral bits)) 0 d
      _ | dsBusy s -> let t = sub (sub (sub s)) in t { dsBusy = dsLeft t /= 0 }
        | otherwise -> s
    sub t
      | dsLeft t == 0 = t
      | otherwise =
          let r1 = (resize (dsR t) `shiftL` 1) .|. (if testBit (dsN t) 41 then 1 else 0) :: Unsigned 34
              ge = r1 >= resize (dsD t)
          in t { dsLeft = dsLeft t - 1
               , dsN = dsN t `shiftL` 1
               , dsR = resize (if ge then r1 - resize (dsD t) else r1)
               , dsQ = (dsQ t `shiftL` 1) .|. (if ge then 1 else 0) }

------------------------------------------------------------------------------
-- The engine

-- Input and output records are lazy (see "Nds.Gpu3D.RasterHw.Front").
data SetupIn = SetupIn
  { siRec      :: Maybe RecHdr    -- ^ head of the record queue
  , siRb       :: BitVector 64    -- ^ record RAM word read last cycle
  , siRom      :: Unsigned 33     -- ^ reciprocal read last cycle
  , siProd     :: Unsigned 56     -- ^ product of last cycle's operands
  , siDivBusy  :: Bool
  , siDivQ     :: Unsigned 42
  , siDivR     :: Unsigned 32
  , siJobReady :: Bool            -- ^ the pixel engine takes the offered job
  , siDisp     :: Word32
  , siAlphaRef :: Word8
  } deriving (Generic, NFDataX)

data SetupOut = SetupOut
  { soRbAddr  :: Unsigned 6
  , soRomAddr :: Unsigned 9
  , soMul     :: (Unsigned 32, Unsigned 24)
  , soDiv     :: Maybe DivReq
  , soTake    :: Bool             -- ^ pop the record queue
  , soJob     :: Maybe JobMsg
  } deriving (Generic, NFDataX)

data Ph
  = PIdle
  | PWalk
  | PLoad !(Index 7)
  | PS0 | PS1 | PS2 | PS3 | PS4 | PS5 | PS6 | PS7 | PS8
  | PV0 | PV1 | PV2 | PV3
  | PZ0 | PZ1 | PZ2 | PZ3
  | PC0 | PC1 | PC2
  | PRule
  | PP1 | PP2 | PP3 | PP4 | PP5
  | PH0 | PH1
  | PEmit
  deriving (Eq, Generic, Show, NFDataX)

-- | Engine state: the record being set up, the walk cursors, the edge being
-- computed, both finished edges and the job under construction.
data Su = Su
  { suPh     :: !Ph
  , suRec    :: !RecHdr
  , suCurL, suNextL, suCurR, suNextR :: !(Unsigned 4)
  , suKL, suKR :: !(Unsigned 4)
  , suE      :: !(Unsigned 1)               -- ^ edge being computed (0 left, 1 right)
  -- vertex values of the current edge, start (0) and next (1) vertex
  , suX0, suX1, suY0, suY1 :: !Int32
  , suW0, suW1, suZ0, suZ1 :: !Int32
  , suV0, suV1 :: !(Vec 5 Int32)            -- ^ R, G, B, S, T
  , suEdge   :: !EdgeHw
  , suBaseDx :: !Int32
  , suRecipE :: !Int32                      -- ^ @0x400000 / ydiff@
  , suXp     :: !Int32                      -- ^ edge interpolator X (@y - y0 + offset@)
  , suLinE   :: !Bool
  , suPerE   :: !Bool
  , suNum    :: !Word32
  , suT1     :: !Int32
  , suDen    :: !Word32
  , suYf     :: !Word32
  , suItem   :: !(Index 6)                  -- ^ 0 W, 1..5 R G B S T
  , suVals   :: !(Vec 6 Int32)
  , suBase   :: !Int32
  , suNeg    :: !Bool
  , suUp     :: !Bool
  , suSh     :: !Int
  , suEdges  :: !(Vec 2 EdgeHw)
  , suEX     :: !(Vec 2 Int32)              -- ^ edge X on this line
  , suEW, suEZ :: !(Vec 2 Int32)
  , suECh    :: !(Vec 2 (Vec 5 Int32))
  -- span
  , suCov    :: !(Vec 2 Int32)              -- ^ X-major coverage start quotients (L, R)
  , suK      :: !(Unsigned 1)
  , suSwap   :: !Bool
  , suXDiff  :: !Int32
  , suRecipS :: !Int32
  , suDispZ  :: !Int32
  , suXR     :: !Int32
  , suKz     :: !(Unsigned 56)
  , suCh     :: !(Index 5)
  , suJob    :: !SpanJob
  } deriving (Eq, Generic, Show, NFDataX)

suInit :: Su
suInit = Su
  { suPh = PIdle, suRec = recHdr0
  , suCurL = 0, suNextL = 0, suCurR = 0, suNextR = 0, suKL = 0, suKR = 0, suE = 0
  , suX0 = 0, suX1 = 0, suY0 = 0, suY1 = 0, suW0 = 0, suW1 = 0, suZ0 = 0, suZ1 = 0
  , suV0 = C.repeat 0, suV1 = C.repeat 0
  , suEdge = dummyEdge 0, suBaseDx = 0, suRecipE = 0, suXp = 0, suLinE = False, suPerE = False
  , suNum = 0, suT1 = 0, suDen = 0, suYf = 0, suItem = 0, suVals = C.repeat 0
  , suBase = 0, suNeg = False, suUp = False, suSh = 0
  , suEdges = C.repeat (dummyEdge 0), suEX = C.repeat 0, suEW = C.repeat 0, suEZ = C.repeat 0
  , suECh = C.repeat (C.repeat 0)
  , suCov = C.repeat 0, suK = 0, suSwap = False, suXDiff = 1, suRecipS = 0, suDispZ = 0
  , suXR = 0, suKz = 0, suCh = 0, suJob = emptyJob
  }

i32 :: Integral a => a -> Int32
i32 = fromIntegral

w32 :: Integral a => a -> Word32
w32 = fromIntegral

-- | Absolute value of a 32-bit difference as an unsigned magnitude.
mag :: Int32 -> Unsigned 32
mag v = if v < 0 then fromIntegral (negate (fromIntegral v :: Int64)) else fromIntegral v

wrapNext, wrapPrev :: Unsigned 4 -> Unsigned 4 -> Unsigned 4
wrapNext n i = if i + 1 >= n then 0 else i + 1
wrapPrev n i = if i == 0 then n - 1 else i - 1

idx10 :: Unsigned 4 -> Index 10
idx10 = fromIntegral

-- | Bit length of a positive 32-bit value.
bitLen :: Int32 -> Int
bitLen v = 32 - countLeadingZeros (fromIntegral v :: Word32)

noOut :: SetupOut
noOut = SetupOut 0 0 (0, 0) Nothing False Nothing

depthModeOf :: Word32 -> Bool -> Bool -> DepthMode
depthModeOf attr wbuf facing
  | testBit attr 14 = if wbuf then DepthEqualW else DepthEqualZ
  | facing = DepthLessFront
  | otherwise = DepthLess

-- | One cycle of the setup engine.
setupStep :: Su -> SetupIn -> (Su, SetupOut)
setupStep s i = case suPh s of
  PIdle -> case siRec i of
    Nothing -> (s, noOut)
    Just r
      | rhEnd r -> (s { suPh = PEmit, suRec = r }, noOut)
      | rhMask r && not maskDraws -> (s { suPh = PEmit, suRec = r, suJob = baseJob r False }, noOut)
      | rhYTop r == rhYBot r ->
          let x = rhX r
              pick better k cur = if better (x C.!! idx10 k) (x C.!! idx10 cur) then k else cur
              hl = pick (<) (rhN r - 1) (pick (<) 1 0)
              hr = pick (>) (rhN r - 1) (pick (>) 1 0)
          in ( s { suPh = PLoad 0, suRec = r, suE = 0, suCurL = hl, suNextL = hl, suCurR = hr, suNextR = hr }
             , noOut )
      | otherwise ->
          let n = rhN r
              v = rhVTop r
              (sl, sr) = if rhFacing r then (wrapNext n, wrapPrev n) else (wrapPrev n, wrapNext n)
          in ( s { suPh = PWalk, suRec = r, suCurL = v, suNextL = sl v, suCurR = v, suNextR = sr v
                 , suKL = n, suKR = n }
             , noOut )
      where
        alpha = (rhAttr r `shiftR` 16) .&. 0x1F
        alphaEff = if alpha == 0 then 31 else alpha
        maskDraws = alphaEff > fromIntegral (siAlphaRef i)

  PWalk ->
    let r = suRec s
        n = rhN r
        y = rhLine r
        ys = rhY r
        (sl, sr) = if rhFacing r then (wrapNext n, wrapPrev n) else (wrapPrev n, wrapNext n)
        goL = suKL s > 0 && y >= ys C.!! idx10 (suNextL s) && suCurL s /= rhVBot r
        goR = suKR s > 0 && y >= ys C.!! idx10 (suNextR s) && suCurR s /= rhVBot r
        s1 = s { suCurL = if goL then suNextL s else suCurL s
               , suNextL = if goL then sl (suNextL s) else suNextL s
               , suKL = if goL then suKL s - 1 else suKL s
               , suCurR = if goR then suNextR s else suCurR s
               , suNextR = if goR then sr (suNextR s) else suNextR s
               , suKR = if goR then suKR s - 1 else suKR s }
    in (if goL || goR then s1 else s { suPh = PLoad 0, suE = 0 }, noOut)

  -- Vertex words of the current edge: slot, V0, V1 of the start vertex,
  -- then of the next vertex (address in phase k, data in phase k + 1).
  PLoad k ->
    let r = suRec s
        (c, nx) = if suE s == 0 then (suCurL s, suNextL s) else (suCurR s, suNextR s)
        addrOf j = case j :: Index 7 of
          0 -> recWordAddr (rhEntry r) c 0
          1 -> recWordAddr (rhEntry r) c 1
          2 -> recWordAddr (rhEntry r) c 2
          3 -> recWordAddr (rhEntry r) nx 0
          4 -> recWordAddr (rhEntry r) nx 1
          _ -> recWordAddr (rhEntry r) nx 2
        d = siRb i
        slot = decodeSlot d
        vrec = decodeVertexRec d d
        vrec1 = decodeVertexRec 0 d
        s1 = case k of
          1 -> s { suZ0 = i32 (psFinalZ slot), suW0 = i32 (psFinalW slot) }
          2 -> s { suV0 = C.replace (3 :: Int) (i32 (vrS vrec)) (C.replace (4 :: Int) (i32 (vrT vrec)) (suV0 s)) }
          3 -> s { suV0 = C.replace (0 :: Int) (i32 (vrR vrec1)) (C.replace (1 :: Int) (i32 (vrG vrec1))
                            (C.replace (2 :: Int) (i32 (vrB vrec1)) (suV0 s))) }
          4 -> s { suZ1 = i32 (psFinalZ slot), suW1 = i32 (psFinalW slot) }
          5 -> s { suV1 = C.replace (3 :: Int) (i32 (vrS vrec)) (C.replace (4 :: Int) (i32 (vrT vrec)) (suV1 s)) }
          6 -> s { suV1 = C.replace (0 :: Int) (i32 (vrR vrec1)) (C.replace (1 :: Int) (i32 (vrG vrec1))
                            (C.replace (2 :: Int) (i32 (vrB vrec1)) (suV1 s))) }
          _ -> s
        xs = rhX r
        ys = rhY r
        s2 = s1 { suX0 = i32 (xs C.!! idx10 c), suX1 = i32 (xs C.!! idx10 nx)
                , suY0 = i32 (ys C.!! idx10 c), suY1 = i32 (ys C.!! idx10 nx) }
        horizontal = rhYTop r == rhYBot r
        lastK = if horizontal then 3 else 6
        s3
          | k == lastK && horizontal =
              -- A dummy edge yields its vertex's values.
              finishEdge s2 (dummyEdge (suX0 s2)) (suX0 s2) (suW0 s2) (suZ0 s2) (suV0 s2)
          | k == lastK = s2 { suPh = PS0 }
          | otherwise = s2 { suPh = PLoad (k + 1) }
    in (s3, noOut { soRbAddr = addrOf k })

  -- Slope::Setup at line y.
  PS0 -> (s { suPh = PS1 }, noOut { soRomAddr = romAddr (abs (suY1 s - suY0 s)) })
  PS1 ->
    let t = siRom i
        ylen = suY1 s - suY0 s
        r18 = if ylen == 0 then 0 else resize (t `shiftR` 14) :: Unsigned 24
        recipE = if ylen == 0 then 0
                 else let r = i32 (t `shiftR` 10)
                      in if ylen < 0 then negate r else r
    in ( s { suPh = PS2, suRecipE = recipE }
       , noOut { soMul = (mag (suX1 s - suX0 s), r18) } )
  PS2 ->
    let x0 = suX0 s
        x1 = suX1 s
        side = suE s == 1
        (xmin, xmax, neg)
          | x1 > x0 = (x0, x1 - 1, False)
          | x1 < x0 = (x1, x0 - 1, True)
          | otherwise = (x0, x0, False)
        xlen = xmax + 1 - xmin
        ylen = suY1 s - suY0 s
        inc
          | ylen == 0 = 0
          | ylen == xlen && xlen /= 1 = 0x40000
          | otherwise = i32 (siProd i)
        xmajor = inc > 0x40000
        baseDx
          | side =
              if xmajor
                then if neg then 0x20000 + 0x40000 else inc - 0x20000
                else if inc /= 0 then (if neg then 0x40000 else 0) else 0
          | otherwise =
              if xmajor
                then if neg then (inc - 0x20000) + 0x40000 else 0x20000
                else if inc /= 0 then (if neg then 0x40000 else 0) else 0
        e = EdgeHw x0 xmin xmax xlen ylen inc 0 neg xmajor side 0
    in ( s { suPh = PS3, suEdge = e, suBaseDx = baseDx }
       -- A clipped polygon can start above this edge's first vertex. Multiply
       -- the offset magnitude and restore its sign after the unsigned DSP.
       , noOut { soMul = (mag inc, resize (mag (i32 (rhLine (suRec s)) - suY0 s))) } )
  PS3 ->
    let e0 = suEdge s
        offset = i32 (rhLine (suRec s)) - suY0 s
        delta = i32 (siProd i)
        negativeProduct = (ehInc e0 < 0) /= (offset < 0)
        dx = suBaseDx s + if negativeProduct then negate delta else delta
        e = e0 { ehDx = dx }
        side = ehSide e
        off = if ehInc e >= 0x40000 && side /= ehNeg e then 1 else 0
        y = i32 (rhLine (suRec s))
        xp = y - (suY0 s - off)
        xdiff = ehYLen e
        w0 = suW0 s
        w1 = suW1 s
        linear = w0 == w1 && (w0 .&. 0x7E) == 0 && (w1 .&. 0x7E) == 0
        persp = xdiff /= 0 && (not linear || rhWBuf (suRec s))
        w0n = w0 `shiftR` 1
        divReq
          | ehXMajor e = Just (resize (mag (ehYLen e `shiftL` 10)), fromIntegral (ehXLen e))
          | otherwise = Nothing
    in ( s { suPh = PS4, suEdge = e, suXp = xp, suLinE = linear, suPerE = persp, suNeg = xp < 0 }
       , noOut { soMul = (fromIntegral w0n, resize (mag xp)), soDiv = divReq } )
  PS4 ->
    let w0 = suW0 s
        w0d = (w0 + ((w0 .&. complement (suW1 s)) .&. 1)) `shiftR` 1
        product0 = i32 (siProd i)
        signedProduct = if suNeg s then negate product0 else product0
    in ( s { suPh = PS5, suNum = w32 signedProduct `shiftL` 9, suNeg = suXp s < 0 }
       , noOut { soMul = (fromIntegral w0d, resize (mag (suXp s))) } )
  PS5 ->
    let w1d = suW1 s `shiftR` 1
        factor = ehYLen (suEdge s) - suXp s
        product0 = i32 (siProd i)
        signedProduct = if suNeg s then negate product0 else product0
    in ( s { suPh = PS6, suT1 = signedProduct, suNeg = factor < 0 }
       , noOut { soMul = (fromIntegral w1d, resize (mag factor)) } )
  PS6 ->
    let product0 = i32 (siProd i)
        signedProduct = if suNeg s then negate product0 else product0
    in (s { suPh = PS7, suDen = w32 (suT1 s + signedProduct) }, noOut)
  PS7
    | siDivBusy i -> (s, noOut)
    | otherwise ->
        let e = suEdge s
            cov = i32 (siDivQ i)
            e' = if ehXMajor e then e { ehXCov = if ehYLen e < 0 then negate cov else cov } else e
        in if suPerE s && suDen s /= 0
             then ( s { suPh = PS8, suEdge = e' }
                  , noOut { soDiv = Just (resize (fromIntegral (suNum s) :: Unsigned 32), resize (fromIntegral (suDen s) :: Unsigned 32)) } )
             else (startValues (s { suEdge = e', suYf = 0 }), noOut)
  PS8
    | siDivBusy i -> (s, noOut)
    | otherwise -> (startValues (s { suYf = fromIntegral (siDivQ i) }), noOut)

  -- Edge values: W, then R G B S T (masks skip them), then Z.
  PV0 ->
    let (v0, v1) = itemPair s (suItem s)
        xdiff = ehYLen (suEdge s)
        up = v0 < v1
        base = if up then v0 else v1
    in if xdiff == 0 || v0 == v1
         then (nextItem s v0, noOut)
         else if not (suLinE s)
           then let d = w32 (if up then v1 - v0 else v0 - v1)
                    f = if up then suYf s else 512 - suYf s
                in (s { suPh = PV1, suBase = base }, noOut { soMul = (fromIntegral d, fromIntegral f) })
           else let d = if up then v1 - v0 else v0 - v1
                    fl = if up then suXp s else xdiff - suXp s
                in ( s { suPh = PV2, suBase = base, suNeg = ((d < 0) /= (fl < 0)) /= (xdiff < 0) }
                   , noOut { soMul = (mag d, resize (mag fl)) } )
  PV1 -> (nextItem s (i32 (w32 (suBase s) + (w32 (siProd i) `shiftR` 9))), noOut)
  PV2 -> ( s { suPh = PV3 }
         , noOut { soDiv = Just (resize (siProd i), resize (mag (ehYLen (suEdge s)))) } )
  PV3
    | siDivBusy i -> (s, noOut)
    | otherwise ->
        let q = i32 (siDivQ i)
        in (nextItem s (suBase s + (if suNeg s then negate q else q)), noOut)

  PZ0 ->
    let z0 = suZ0 s
        z1 = suZ1 s
        xdiff = ehYLen (suEdge s)
        up = z0 < z1
        base = if up then z0 else z1
        disp = if up then z1 - z0 else z0 - z1
    in if xdiff == 0 || z0 == z1
         then (finishCurrent s z0, noOut)
         else if rhWBuf (suRec s)
           then let f = if up then suYf s else 512 - suYf s
                in (s { suPh = PZ1, suBase = base }, noOut { soMul = (fromIntegral disp, fromIntegral f) })
           else let sh = max 0 (bitLen disp - 10)
                    factor = if up then suXp s else xdiff - suXp s
                in ( s { suPh = PZ2, suBase = base, suSh = sh
                       , suNeg = (factor < 0) /= (suRecipE s < 0) }
                   , noOut { soMul = (fromIntegral (disp `shiftR` sh), resize (mag factor)) } )
  PZ1 -> (finishCurrent s (suBase s + i32 (siProd i `shiftR` 9)), noOut)
  PZ2 -> (s { suPh = PZ3 }, noOut { soMul = (resize (siProd i), resize (mag (suRecipE s))) })
  PZ3 ->
    let product0 = fromIntegral (siProd i) :: Int64
        signedProduct = if suNeg s then negate product0 else product0
        adjustment = (signedProduct `shiftR` 22) `shiftL` suSh s
    in (finishCurrent s (suBase s + i32 adjustment), noOut)

  -- Span: X-major coverage starts (left edge, then right edge).
  PC0 ->
    let e = suEdges s C.!! suK s
        (_, startx) = edgeStartX (suSwap s) (toSlope e)
        num = (startx `shiftL` 10) + 0x1FF
        ylen = ehYLen e
    in if ehXMajor e
         then ( s { suPh = PC1, suNeg = (num < 0) /= (ylen < 0) }
              , noOut { soMul = (mag num, resize (mag ylen) :: Unsigned 24) } )
         else nextCov s
  PC1 -> ( s { suPh = PC2 }
         , noOut { soDiv = Just (resize (siProd i), fromIntegral (ehXLen (suEdges s C.!! suK s))) } )
  PC2
    | siDivBusy i -> (s, noOut)
    | otherwise ->
        let q = i32 (siDivQ i)
        in nextCov (s { suCov = C.replace (suK s) (if suNeg s then negate q else q) (suCov s) })

  -- The span rule, pieces and interpolator ends.
  PRule ->
    let r = suRec s
        disp = siDisp i
        y = i32 (rhLine r)
        eL = toSlope (suEdges s C.!! (0 :: Int))
        eR = toSlope (suEdges s C.!! (1 :: Int))
        xstart = suEX s C.!! (0 :: Int)
        xend = rightPullIn eL eR xstart (suEX s C.!! (1 :: Int))
        alpha = (rhAttr r `shiftR` 16) .&. 0x1F
        wire = alpha == 0
        cfg = RasterConfig (fromIntegral disp) (fromIntegral alpha) wire 256
        covOf sl _ = if slopeSide sl then suCov s C.!! (1 :: Int) else suCov s C.!! (0 :: Int)
        params sw sl = edgeParamsWith covOf sw sl
        xs = rhX r
        nextXDiffer = xs C.!! idx10 (suNextL s) /= xs C.!! idx10 (suNextR s)
        rule = spanRuleWith params cfg (y == i32 (rhYBot r) - 1) nextXDiffer eL eR xstart xend
        (pl, pm, pr) = spanPieces cfg rule
        yedge
          | rhLine r == rhYTop r = 0x4
          | y == i32 (rhYBot r) - 1 = 0x8
          | otherwise = 0x0 :: Word32
        inner = if wire && yedge == 0 then Nothing else pm
        rangeOf = maybe (Range False 0 0) (\(a, b) -> Range True (fromIntegral a) (fromIntegral b))
        hiOf = maybe 0 (fromIntegral . snd)
        lastX = max (hiOf pl) (max (hiOf inner) (hiOf pr)) :: Unsigned 9
        sw = suSwap s
        xdiff = srEnd rule + 1 - srStart rule
        job0 = baseJob r True
        job = job0
          { sjX0 = fromIntegral (srStart rule)
          , sjXDiff = fromIntegral xdiff
          , sjLast = lastX
          , sjLeft = rangeOf pl, sjInner = rangeOf inner, sjRight = rangeOf pr
          , sjYEdge = yedge
          , sjLCov = srLCov rule, sjRCov = srRCov rule }
    in ( s { suPh = PP1, suSwap = sw, suXDiff = xdiff, suJob = job }
       , noOut { soRomAddr = romAddr xdiff } )
  PP1 ->
    let (_, wB) = pairOf s (suEW s)
    in ( s { suPh = PP2, suRecipS = i32 (siRom i `shiftR` 10) }
       , noOut { soMul = (fromIntegral wB, fromIntegral (suXDiff s)) } )
  PP2 ->
    let (wA, wB) = pairOf s (suEW s)
        (zA, zB) = pairOf s (suEZ s)
        wbuf = rhWBuf (suRec s)
        up = zA < zB
        base = if up then zA else zB
        disp = if up then zB - zA else zA - zB
        job = (suJob s)
          { sjNumStep = w32 wA
          , sjDen0 = resize (siProd i)
          , sjDenStep = fromIntegral (wA - wB) }
        zConst = job { sjZ = ZConst (w32 zA) }
        zPersp = job { sjZ = ZPersp (w32 base) (fromIntegral disp) up }
    in if zA == zB
         then (afterZ (s { suJob = zConst }), noOut)
         else if wbuf
           then (afterZ (s { suJob = zPersp }), noOut)
           else ( s { suPh = PP3, suJob = job, suBase = base, suUp = up, suDispZ = disp `shiftR` 9 }
                , noOut { soMul = (fromIntegral (suRecipS s), fromIntegral (suXDiff s)) } )
  PP3 -> ( s { suPh = PP4, suXR = i32 (siProd i) }
         , noOut { soMul = (fromIntegral (suRecipS s), fromIntegral (suDispZ s)) } )
  PP4 -> ( s { suPh = PP5, suKz = siProd i }
         , noOut { soMul = (fromIntegral (suXR s), fromIntegral (suDispZ s)) } )
  PP5 ->
    let up = suUp s
        k = suKz s
        acc0 = if up then 0 else siProd i
    in (afterZ (s { suJob = (suJob s) { sjZ = ZLin (w32 (suBase s)) (resize k) (resize acc0) up } }), noOut)

  -- Span attributes: R G B S T.
  PH0 ->
    let c = suCh s
        (v0, v1) = pairOf s (C.map (C.!! c) (suECh s))
        (wA, wB) = pairOf s (suEW s)
        linear = wA == wB && (wA .&. 0x7F) == 0 && (wB .&. 0x7F) == 0
        up = v0 < v1
        base = if up then v0 else v1
        d = if up then v1 - v0 else v0 - v1
        lo16 :: Int32 -> Unsigned 16
        lo16 = fromIntegral
        setCh j = s { suJob = (suJob s) { sjCh = C.replace c j (sjCh (suJob s)) } }
    in if v0 == v1
         then (nextCh (setCh (ChConst (lo16 v0))), noOut)
         else if not linear
           then (nextCh (setCh (ChPersp (lo16 base) (fromIntegral (w32 d)) up)), noOut)
           else ( s { suPh = PH1, suBase = base, suNeg = d < 0, suUp = up, suDispZ = d }
                , noOut { soDiv = Just (resize (mag d), fromIntegral (suXDiff s)) } )
  PH1
    | siDivBusy i -> (s, noOut)
    | otherwise ->
        let c = suCh s
            up = suUp s
            j = ChLin (fromIntegral (suBase s)) (suNeg s) (resize (siDivQ i)) (resize (siDivR i)) up
                  (if up then 0 else resize (mag (suDispZ s)))
        in (nextCh (s { suJob = (suJob s) { sjCh = C.replace c j (sjCh (suJob s)) } }), noOut)

  PEmit ->
    -- The offered job never depends on the pixel engine's ready.
    let msg = if rhEnd (suRec s) then JobLineEnd (rhLine (suRec s)) else JobSpan (suJob s)
        rdy = siJobReady i
    in (if rdy then s { suPh = PIdle } else s, noOut { soTake = rdy, soJob = Just msg })
  where
    romAddr :: Int32 -> Unsigned 9
    romAddr d = if d <= 0 then 0 else fromIntegral (d - 1)

-- | The job fields every polygon line carries.
baseJob :: RecHdr -> Bool -> SpanJob
baseJob r draw = emptyJob
  { sjY = rhLine r, sjMask = rhMask r, sjDraw = draw, sjShadow = rhShadow r
  , sjMode = depthModeOf (rhAttr r) (rhWBuf r) (rhFacing r)
  , sjAttr = rhAttr r, sjTexParam = rhTexParam r, sjTexPal = rhTexPal r, sjFacing = rhFacing r }

-- | Start the edge value sequence (W first).
startValues :: Su -> Su
startValues s = s { suPh = PV0, suItem = 0 }

itemPair :: Su -> Index 6 -> (Int32, Int32)
itemPair s k
  | k == 0 = (suW0 s, suW1 s)
  | otherwise = (suV0 s C.!! (k - 1), suV1 s C.!! (k - 1))

-- | Store an edge value and move to the next item; masks need only W and Z.
nextItem :: Su -> Int32 -> Su
nextItem s v =
  let s1 = s { suVals = C.replace (suItem s) v (suVals s) }
      lastItem = if rhMask (suRec s) then 0 else 5
  in if suItem s >= lastItem then s1 { suPh = PZ0 } else s1 { suPh = PV0, suItem = suItem s + 1 }

-- | The current edge is complete with depth @z@.
finishCurrent :: Su -> Int32 -> Su
finishCurrent s z =
  let e = suEdge s
      x = slopeXVal (toSlope e)
  in finishEdge s e x (suVals s C.!! (0 :: Int)) z (C.tail (suVals s))

finishEdge :: Su -> EdgeHw -> Int32 -> Int32 -> Int32 -> Vec 5 Int32 -> Su
finishEdge s e x w z ch =
  let k = suE s
      s1 = s { suEdges = C.replace k e (suEdges s), suEX = C.replace k x (suEX s)
             , suEW = C.replace k w (suEW s), suEZ = C.replace k z (suEZ s)
             , suECh = C.replace k ch (suECh s) }
      eL = toSlope (suEdges s1 C.!! (0 :: Int))
      eR = toSlope (suEdges s1 C.!! (1 :: Int))
      xstart = suEX s1 C.!! (0 :: Int)
      xend = rightPullIn eL eR xstart (suEX s1 C.!! (1 :: Int))
  in if k == 0
       then s1 { suPh = PLoad 0, suE = 1 }
       else s1 { suPh = PC0, suK = 0, suSwap = xstart > xend }

nextCov :: Su -> (Su, SetupOut)
nextCov s
  | suK s == 0 = (s { suPh = PC0, suK = 1 }, noOut)
  | otherwise = (s { suPh = PRule }, noOut)

-- | Span-order pair (start edge, end edge) of a per-edge value.
pairOf :: Su -> Vec 2 Int32 -> (Int32, Int32)
pairOf s v =
  let l = v C.!! (0 :: Int)
      r = v C.!! (1 :: Int)
  in if suSwap s then (r, l) else (l, r)

afterZ :: Su -> Su
afterZ s = if rhMask (suRec s) then s { suPh = PEmit } else s { suPh = PH0, suCh = 0 }

nextCh :: Su -> Su
nextCh s = if suCh s == 4 then s { suPh = PEmit } else s { suPh = PH0, suCh = suCh s + 1 }

------------------------------------------------------------------------------
-- Signal level

-- | The setup engine with its multiplier, divider, reciprocal ROM and the
-- record RAM (written by the front end).
setupEngine
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom Bool                         -- ^ synchronous restart (frame start)
  -> Signal dom Word32                       -- ^ DISP3DCNT
  -> Signal dom Word8                        -- ^ alpha-test reference
  -> Signal dom (Maybe RecHdr)               -- ^ record queue head
  -> Signal dom (Maybe (Unsigned 6, BitVector 64))  -- ^ record RAM write (front end)
  -> Signal dom Bool                         -- ^ pixel engine takes the job
  -> (Signal dom Bool, Signal dom (Maybe JobMsg))   -- ^ (pop record, job)
setupEngine clk rst en restart disp aref recH rbWrite jobReady = (C.fmap soTake out, C.fmap soJob out)
  where
    inp = SetupIn <$> recH <*> rbData <*> romData <*> prod <*> divBusy <*> divQ <*> divR
                  <*> jobReady <*> disp <*> aref
    -- the restart resets the state only; outputs never depend on it
    out = mealy clk rst en (\s (r, x) -> let (s', o) = setupStep s x in (if r then suInit else s', o)) suInit
            (bundle (restart, inp))
    rbData = blockRamPow2 clk en (C.replicate (C.SNat :: C.SNat 64) 0) (C.fmap soRbAddr out) rbWrite
    romData = romPow2 clk en recipRom (C.fmap soRomAddr out)
    prod = register clk rst en 0 (C.fmap (\o -> let (a, b) = soMul o in resize a * resize b) out)
    (divBusy, divQ, divR) = unbundle (mealy clk rst en
      (\st (r, q) -> let (st', o) = divStep st q in (if r then divInit else st', o)) divInit
      (bundle (restart, C.fmap soDiv out)))
