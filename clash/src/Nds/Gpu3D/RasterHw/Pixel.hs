{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | The pixel engine: one 'SpanJob' at a time over the current line's
-- buffers, one span position per cycle.
--
-- Stages (all advance together; a texture-cache miss holds them):
--
-- * P0 walks the positions @x = srStart .. last@ and keeps the perspective
--   numerator @N = (x' * wA mod 2^24) << 8@ and denominator
--   @D = x' * wA + (xdiff - x') * wB@ by addition;
-- * S1-S3 divide @N / D@ (three restoring steps each; the factor is at most
--   256, 9 bits), exactly as @Interpolator::SetX@;
-- * at S3 the linear depth and attribute accumulators step (Z-buffer depth
--   @(K * x') >> 13@, linear attributes as quotient/remainder pairs of
--   @delta * x' / xdiff@) and the line-buffer and stencil reads are issued;
-- * S4 forms depth, colour and texture coordinates, runs 'pixelTarget'
--   (or 'maskPixelWith' for a shadow mask, which writes the stencil here)
--   and hands the pixel to 'Nds.Gpu3D.ShadePipe' (twice when a translucent
--   pixel may also land on the lower layer);
-- * at the pipe's output 'pixelCommit' writes the pixel back, carrying the
--   anti-aliasing coverage accumulator in order.
--
-- Between spans the pipeline drains, so a span never reads a pixel an
-- earlier span has not written yet.
module Nds.Gpu3D.RasterHw.Pixel
  ( PixSt (..)
  , pix0
  , PixIn (..)
  , PixOut (..)
  , Side (..)
  , side0
  , pixStep
    -- * Span values (for checks)
  , spanValues
  ) where

import Prelude

import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.), complement)
import Data.Int (Int16, Int32)
import Data.Word (Word32, Word8)
import GHC.Generics (Generic)

import Clash.Prelude (BitVector, NFDataX, Signed, Unsigned, Vec, resize)
import qualified Clash.Prelude as C

import Nds.Gpu3D.Raster (SpanRule (..))
import Nds.Gpu3D.Render (Piece (..), Px (..), maskPixelWith, pixelCommit, pixelTarget, startCoverage)
import Nds.Gpu3D.RasterHw.Setup (JobMsg (..))
import Nds.Gpu3D.RasterHw.Types
import Nds.Gpu3D.Shade (PixelWrite (..))
import Nds.Gpu3D.ShadePipe (PixelIn (..), PixelOut (..))

-- | A position in flight.
data Pos = Pos
  { psValid :: !Bool
  , psX     :: !(Unsigned 9)
  , psPiece :: !(Maybe Piece)
  } deriving (Eq, Generic, Show, NFDataX)

pos0 :: Pos
pos0 = Pos False 0 Nothing

-- | A divider stage: remainder, remaining numerator bits, quotient so far.
data DivS = DivS
  { dvR   :: !(Unsigned 26)
  , dvN   :: !(BitVector 9)
  , dvQ   :: !(Unsigned 9)
  , dvD   :: !(Unsigned 26)
  } deriving (Eq, Generic, Show, NFDataX)

divS0 :: DivS
divS0 = DivS 0 0 0 1

-- | Stage 4: the position, its factor and linear values.
data S4 = S4
  { s4Pos  :: !Pos
  , s4Yf   :: !(Unsigned 9)
  , s4Z    :: !Word32              -- ^ Z-buffer linear depth
  , s4Ch   :: !(Vec 5 (Unsigned 16)) -- ^ linear attribute values
  , s4Pass2 :: !Bool               -- ^ the first plot is in the pipe, the second is due
  } deriving (Eq, Generic, Show, NFDataX)

-- | What a pipe entry needs at commit.
data Side = Side
  { sdX      :: !(Unsigned 9)
  , sdPx     :: !Px
  , sdLower  :: !Bool
  , sdDst    :: !Word32
  , sdPiece  :: !Piece
  , sdZ      :: !Int32
  , sdSecond :: !Bool      -- ^ this entry is the second (lower-layer) plot
  , sdNeed2  :: !Bool      -- ^ a second plot follows this one
  } deriving (Eq, Generic, Show, NFDataX)

side0 :: Side
side0 = Side 0 (Px 0 0 0 0 0 0) False 0 PInner 0 False False

data Mode = MIdle | MClear !(Unsigned 4) | MRun | MDrain
  deriving (Eq, Generic, Show, NFDataX)

data PixSt = PixSt
  { peMode   :: !Mode
  , peJob    :: !SpanJob
  , pePrevMask :: !Bool
  -- P0
  , peX      :: !(Unsigned 10)
  , peP      :: !(Unsigned 26)
  , peD      :: !(Unsigned 26)
  -- divider stages
  , pe1, pe2, pe3 :: !Pos
  , pd1, pd2, pd3 :: !DivS
  -- linear accumulators, for the position at S3
  , peZAcc   :: !(Unsigned 38)
  , peChQ    :: !(Vec 5 (Unsigned 16))
  , peChR    :: !(Vec 5 (Signed 11))
  , pe4      :: !S4
  -- commit
  , peInFlight :: !(Unsigned 3)
  , peWi, peRi :: !(Unsigned 2)
  , peFirst  :: !(Maybe PixelWrite)
  , peXCov   :: !Int32
  , peRight  :: !Bool
  , peEnPrev :: !Bool
  , peStLast :: !(Maybe (Unsigned 5, BitVector 32))
  } deriving (Eq, Generic, Show, NFDataX)

s40 :: S4
s40 = S4 pos0 0 0 (C.repeat 0) False

pix0 :: PixSt
pix0 = PixSt
  { peMode = MIdle, peJob = emptyJob, pePrevMask = False
  , peX = 0, peP = 0, peD = 0
  , pe1 = pos0, pe2 = pos0, pe3 = pos0, pd1 = divS0, pd2 = divS0, pd3 = divS0
  , peZAcc = 0, peChQ = C.repeat 0, peChR = C.repeat 0, pe4 = s40
  , peInFlight = 0, peWi = 0, peRi = 0, peFirst = Nothing, peXCov = 0, peRight = False
  , peEnPrev = True, peStLast = Nothing }

-- Input and output records are lazy: the pipe enable depends on the pipe
-- input this engine drives, so no field may force another.
data PixIn = PixIn
  { pinJob    :: Maybe JobMsg          -- ^ offered job
  , pinLine   :: Maybe (Unsigned 8)    -- ^ the line being rendered (render phase)
  , pinRam    :: (LayerPx, LayerPx)    -- ^ line buffer at the address issued last cycle
  , pinSt     :: BitVector 32          -- ^ stencil word at the address issued last cycle
  , pinEn     :: Bool                  -- ^ pipe enable (every needed cache access hits)
  , pinOut    :: Maybe PixelOut        -- ^ pipe output register
  , pinSide   :: Side                  -- ^ side RAM at the read index
  , pinDisp   :: Word32
  } deriving (Generic, NFDataX)

data PixOut = PixOut
  { poTake    :: Bool
  , poLineEnd :: Bool                  -- ^ the line's last job is done (pulse)
  , poRamRd   :: Unsigned 8
  , poRamWr   :: Maybe (Unsigned 8, (LayerPx, LayerPx))
  , poStRd    :: Unsigned 5
  , poStWr    :: Maybe (Unsigned 5, BitVector 32)
  , poPipeIn  :: Maybe PixelIn
  , poSideWr  :: Maybe (Unsigned 2, Side)
  , poSideRd  :: Unsigned 2
  , poIdle    :: Bool
  , poPrevMask :: Bool
  } deriving (Generic, NFDataX)

------------------------------------------------------------------------------

pieceAt :: SpanJob -> Unsigned 9 -> Maybe Piece
pieceAt j x
  | inRange (sjLeft j) x = Just PLeft
  | inRange (sjInner j) x = Just PInner
  | inRange (sjRight j) x = Just PRight
  | otherwise = Nothing

hasPixels :: SpanJob -> Bool
hasPixels j = sjDraw j && (rValid (sjLeft j) || rValid (sjInner j) || rValid (sjRight j))

-- | Three restoring division steps.
divSteps :: DivS -> DivS
divSteps = step . step . step
  where
    step d =
      let r1 = (resize (dvR d) `shiftL` 1) .|. (if testBit (dvN d) 8 then 1 else 0) :: Unsigned 27
          ge = r1 >= resize (dvD d)
      in d { dvR = resize (if ge then r1 - resize (dvD d) else r1)
           , dvN = dvN d `shiftL` 1
           , dvQ = (dvQ d `shiftL` 1) .|. (if ge then 1 else 0) }

-- | Initial divider stage for numerator @n@ (32 bits) over @d@.
divStart :: Word32 -> Unsigned 26 -> DivS
divStart n d = DivS (fromIntegral (n `shiftR` 9)) (fromIntegral (n .&. 0x1FF)) 0 d

-- | The stencil line word and lane of X on line @y@.
stAddr :: Unsigned 8 -> Unsigned 9 -> Unsigned 5
stAddr y x = (if testBit y 0 then 16 else 0) + resize (x `shiftR` 4)

stLane :: Unsigned 9 -> Int
stLane x = 2 * fromIntegral (x .&. 15)

-- | The attribute value at S4.
chValue :: Unsigned 9 -> ChJob -> Unsigned 16 -> Unsigned 16
chValue yf c lin = case c of
  ChConst v -> v
  ChLin {} -> lin
  ChPersp base delta up ->
    let f = if up then resize yf else 256 - resize yf :: Unsigned 33
        p = resize delta * f :: Unsigned 33
    in base + resize (p `shiftR` 8)

zValue :: Unsigned 9 -> ZJob -> Word32 -> Int32
zValue yf zj lin = case zj of
  ZConst v -> fromIntegral v
  ZLin {} -> fromIntegral lin
  ZPersp base delta up ->
    let f = if up then resize yf else 256 - resize yf :: Unsigned 33
        p = resize delta * f :: Unsigned 33
    in fromIntegral (base + fromIntegral (p `shiftR` 8))

-- | One step of the linear accumulators.
stepLin :: SpanJob -> (Unsigned 38, Vec 5 (Unsigned 16), Vec 5 (Signed 11))
        -> (Unsigned 38, Vec 5 (Unsigned 16), Vec 5 (Signed 11))
stepLin j (zacc, qs, rs) =
  let zacc' = case sjZ j of
        ZLin _ k _ up -> if up then zacc + k else zacc - k
        _ -> zacc
      xd = fromIntegral (sjXDiff j) :: Signed 11
      ch c q r = case c of
        ChLin _ _ dq dr up _ ->
          if up
            then let r' = r + fromIntegral dr
                 in if r' >= xd then (q + dq + 1, r' - xd) else (q + dq, r')
            else let r' = r - fromIntegral dr
                 in if r' < 0 then (q - dq - 1, r' + xd) else (q - dq, r')
        _ -> (q, r)
      qr = C.zipWith3 ch (sjCh j) qs rs
  in (zacc', C.map fst qr, C.map snd qr)

-- | The linear values at the accumulators.
linValues :: SpanJob -> (Unsigned 38, Vec 5 (Unsigned 16)) -> (Word32, Vec 5 (Unsigned 16))
linValues j (zacc, qs) =
  let z = case sjZ j of
        ZLin base _ _ _ -> base + fromIntegral (zacc `shiftR` 13)
        _ -> 0
      ch c q = case c of
        ChLin base neg _ _ _ _ -> if neg then base - q else base + q
        _ -> 0
  in (z, C.zipWith ch (sjCh j) qs)

-- | The accumulators at position 0 of a job.
linInit :: SpanJob -> (Unsigned 38, Vec 5 (Unsigned 16), Vec 5 (Signed 11))
linInit j =
  let zacc = case sjZ j of
        ZLin _ _ a _ -> a
        _ -> 0
      q c = case c of
        ChLin _ _ _ _ _ q0 -> q0
        _ -> 0
  in (zacc, C.map q (sjCh j), C.repeat 0)

pieceFlags :: Piece -> Word32
pieceFlags p = case p of
  PLeft -> 0x1
  PInner -> 0x0
  PRight -> 0x2

-- | The values the pixel engine forms for every position of a job, with the
-- same stage functions (P0 accumulators, the divider stages, the linear
-- accumulators, S4): @(x, piece, z, (R, G, B) after c6, S, T)@. For checks.
spanValues :: SpanJob -> [(Unsigned 9, Maybe Piece, Int32, (Word8, Word8, Word8), Int16, Int16)]
spanValues j = go (resize (sjX0 j) :: Unsigned 10) (0 :: Unsigned 26) (resize (sjDen0 j) :: Unsigned 26) (linInit j)
  where
    lastPos = resize (sjLast j) :: Unsigned 10
    c6 v = fromIntegral (v `shiftR` 3) :: Word8
    go x p d lin@(zacc, qs, _)
      | x > lastPos = []
      | otherwise =
          let n0 = (fromIntegral (resize p :: Unsigned 24) :: Word32) `shiftL` 8
              dv = divSteps (divSteps (divSteps (divStart n0 d)))
              yf = if dvD dv == 0 then 0 else dvQ dv
              (zl, chl) = linValues j (zacc, qs)
              z = zValue yf (sjZ j) zl
              chv k = chValue yf (sjCh j C.!! k) (chl C.!! k)
              xs = resize x :: Unsigned 9
              v = (xs, pieceAt j xs, z, (c6 (chv (0 :: Int)), c6 (chv 1), c6 (chv 2))
                  , fromIntegral (chv 3), fromIntegral (chv 4))
              p' = p + resize (fromIntegral (sjNumStep j) :: Unsigned 17)
              d' = fromIntegral (fromIntegral d + (resize (sjDenStep j) :: Signed 27))
          in v : go (x + 1) p' d' (stepLin j lin)

-- | One cycle of the pixel engine.
pixStep :: PixSt -> PixIn -> (PixSt, PixOut)
pixStep s i = (s', out)
  where
    j = peJob s
    disp = pinDisp i
    -- ---------------------------------------------------------------- S4
    p4 = pe4 s
    pos4 = s4Pos p4
    x4 = psX pos4
    (topL, lowL) = pinRam i
    px = pxOfLayers topL lowL
    z4 = zValue (s4Yf p4) (sjZ j) (s4Z p4)
    chv :: Int -> Unsigned 16
    chv k = chValue (s4Yf p4) (sjCh j C.!! k) (s4Ch p4 C.!! k)
    c6 v = fromIntegral (v `shiftR` 3) :: Word8
    edge4 pc = sjYEdge j .|. pieceFlags pc
    stWord = case peStLast s of
      Just (a, w) | a == stAddr (sjY j) x4 -> w
      _ -> pinSt i
    st4 = fromIntegral ((stWord `shiftR` stLane x4) .&. 3) :: Word8
    -- shadow mask: the stencil write at S4
    maskWr
      | sjMask j && psValid pos4 && maybe False (const True) (psPiece pos4) =
          let v = maskPixelWith (sjMode j) z4 px st4
              lane = stLane x4
              w = (stWord .&. complement (3 `shiftL` lane)) .|. (fromIntegral v `shiftL` lane)
          in Just (stAddr (sjY j) x4, w)
      | otherwise = Nothing
    -- polygon pixel: target and the plots
    target
      | not (sjMask j) && psValid pos4, Just _ <- psPiece pos4 = pixelTarget (sjShadow j) (sjMode j) z4 st4 px
      | otherwise = Nothing
    need2 = case target of
      Just (lower, dst) -> not lower && dst .&. 0xF /= 0
      Nothing -> False
    pin second =
      let (dc, da) = case target of
            Just (lower, _) | not second && not lower -> (pxC px, pxA px)
            _ -> (pxLC px, pxLA px)
          pc = maybe PInner id (psPiece pos4)
      in PixelIn (sjTexParam j) (sjTexPal j) (sjAttr j) (sjFacing j)
           (c6 (chv 0), c6 (chv 1), c6 (chv 2))
           (fromIntegral (chv 3) :: Int16) (fromIntegral (chv 4) :: Int16)
           (edge4 pc) dc da z4 (resize x4)
    pipeIn = case target of
      Just _ -> Just (pin (s4Pass2 p4))
      Nothing -> Nothing
    en = pinEn i
    accepted = en && maybe False (const True) pipeIn
    -- S4 holds for the second plot.
    adv = en && not (need2 && not (s4Pass2 p4))
    sideOf second = case target of
      Just (lower, dst) -> Side x4 px lower dst (maybe PInner id (psPiece pos4)) z4 second (need2 && not second)
      Nothing -> side0
    sideWr = if accepted then Just (peWi s, sideOf (s4Pass2 p4)) else Nothing
    -- ---------------------------------------------------------------- commit
    fresh = peEnPrev s && maybe False (const True) (pinOut i)
    sd = pinSide i
    rule = SpanRule False 0 0 0 (sjLCov j) 0 (sjRCov j) False False
    xcovIn
      | sdPiece sd == PRight && not (peRight s) = startCoverage (sjRCov j) (peXCov s)
      | otherwise = peXCov s
    (ramWr, first', xcov', right', committed) = case pinOut i of
      Just o | fresh ->
        let w = poWrite o
        in if not (sdSecond sd) && sdNeed2 sd
             then (Nothing, w, peXCov s, peRight s, True)
             else
               let (first, second) = if sdSecond sd then (peFirst s, w) else (w, Nothing)
                   (pxN, xc) = pixelCommit (testBit disp 4) (edge4 (sdPiece sd)) (sdPiece sd) rule (sdZ sd)
                                 (sdLower sd, sdDst sd) first second xcovIn (sdPx sd)
                   (t, l) = layersOfPx pxN
               in (Just (resize (sdX sd), (t, l)), Nothing, xc, peRight s || sdPiece sd == PRight, True)
      _ -> (Nothing, peFirst s, peXCov s, peRight s, False)
    inflight' = peInFlight s + (if accepted then 1 else 0) - (if committed then 1 else 0)
    -- ---------------------------------------------------------------- S3 / P0
    p3 = pe3 s
    yf3 = if dvD (pd3 s) == 0 then 0 else dvQ (pd3 s)
    (zl, chl) = linValues j (peZAcc s, peChQ s)
    (zacc', chq', chr') = stepLin j (peZAcc s, peChQ s, peChR s)
    running = peMode s == MRun
    x0pos = peX s
    lastPos = resize (sjLast j) :: Unsigned 10
    emit = running && x0pos <= lastPos
    xs0 = resize x0pos :: Unsigned 9
    n0 = (fromIntegral (resize (peP s) :: Unsigned 24) :: Word32) `shiftL` 8
    newPos = Pos emit xs0 (if emit then pieceAt j xs0 else Nothing)
    -- reads: the S3 position when advancing, else the S4 one again
    rdX = if adv then psX p3 else x4
    stRdX = rdX
    -- ---------------------------------------------------------------- next state
    advanced = s
      { pe1 = newPos, pd1 = divSteps (divStart n0 (peD s))
      , pe2 = pe1 s, pd2 = divSteps (pd1 s)
      , pe3 = pe2 s, pd3 = divSteps (pd2 s)
      , pe4 = S4 p3 yf3 zl chl False
      , peZAcc = if psValid p3 then zacc' else peZAcc s
      , peChQ = if psValid p3 then chq' else peChQ s
      , peChR = if psValid p3 then chr' else peChR s
      , peX = if emit then x0pos + 1 else x0pos
      , peP = if emit then peP s + resize (fromIntegral (sjNumStep j) :: Unsigned 17) else peP s
      , peD = if emit then fromIntegral (fromIntegral (peD s) + (resize (sjDenStep j) :: Signed 27)) else peD s
      }
    held = s { pe4 = p4 { s4Pass2 = s4Pass2 p4 || (accepted && need2) } }
    -- the commit's coverage state first, so a job intake (pipeline empty)
    -- can reset it
    s1 = (if adv then advanced else held) { peFirst = first', peXCov = xcov', peRight = right' }
    empty = not (psValid (pe1 s) || psValid (pe2 s) || psValid (pe3 s) || psValid pos4) && peInFlight s == 0
              && not emit
    -- job intake
    (takeJob, lineEnd, s2)
      | peMode s == MIdle, Just (JobLineEnd y) <- pinJob i, pinLine i == Just y = (True, True, s1)
      | peMode s == MIdle, Just (JobSpan sj) <- pinJob i, pinLine i == Just (sjY sj) =
          let (za, cq, cr) = linInit sj
              start = s1 { peJob = sj, peX = resize (sjX0 sj), peP = 0, peD = resize (sjDen0 sj)
                         , peZAcc = za, peChQ = cq, peChR = cr
                         , peXCov = startCoverage (sjLCov sj) 0, peRight = False }
              runIt = if hasPixels sj then start { peMode = MRun } else start
          in if sjMask sj
               then if pePrevMask s
                      then (True, False, runIt)
                      else (True, False, start { peMode = MClear 0, pePrevMask = True })
               else (True, False, runIt { pePrevMask = False })
      | MClear k <- peMode s =
          (False, False, if k == 15 then (if hasPixels j then s1 { peMode = MRun } else s1 { peMode = MIdle }) else s1 { peMode = MClear (k + 1) })
      | running && not emit = (False, False, s1 { peMode = MDrain })
      | peMode s == MDrain && empty = (False, False, s1 { peMode = MIdle })
      | otherwise = (False, False, s1)
    clrWr = case peMode s of
      MClear k -> Just ((if testBit (sjY j) 0 then 16 else 0) + resize k, 0)
      _ -> Nothing
    stWr = case clrWr of
      Just w -> Just w
      Nothing -> maskWr
    s' = s2 { peInFlight = inflight', peWi = if accepted then peWi s + 1 else peWi s
            , peRi = if committed then peRi s + 1 else peRi s
            , peEnPrev = en
            , peStLast = case stWr of
                Just w -> Just w
                Nothing -> peStLast s }
    out = PixOut
      { poTake = takeJob
      , poLineEnd = lineEnd
      , poRamRd = resize rdX
      , poRamWr = ramWr
      , poStRd = stAddr (sjY j) stRdX
      , poStWr = stWr
      , poPipeIn = pipeIn
      , poSideWr = sideWr
      , poSideRd = peRi s
      , poIdle = peMode s == MIdle
      , poPrevMask = pePrevMask s
      }
