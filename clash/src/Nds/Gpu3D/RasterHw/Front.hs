{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The polygon front end: per scanline, the frame's active polygons in
-- list order, fetched from polygon and vertex RAM ("Nds.Gpu3D.PolyRam")
-- into the setup engine's record queue, then a line-end token.
--
-- Two engines share the polygon read port:
--
-- * the scanner streams the Y-range words of the render list (up to 8
--   reads outstanding into an 8-word FIFO) and emits, per line, every
--   sorted position whose range covers the line ('polygonActiveHw'), then
--   a line-end marker;
-- * the fetcher takes one position at a time and reads the render list
--   entry (record index), header words H0 and H1, the vertex slots (vertex
--   RAM index, FinalZ, FinalW) and the two vertex RAM words of every slot,
--   writing slots and vertex words into the record RAM and the vertex X and
--   Y into the record header. Vertices are read through their indices when
--   the line is rendered, as melonDS reads vertex RAM live. Reads inside one
--   step are pipelined; steps wait for their responses.
--
-- Arbitration: the fetcher has priority; a tag queue (one bit per
-- outstanding read, at most 32) routes the in-order responses back.
module Nds.Gpu3D.RasterHw.Front
  ( frontEnd
  , polygonActiveHw
  , ScanItem (..)
  ) where

import Prelude

import Data.Bits (complement, shiftL, shiftR, testBit, (.&.), (.|.))
import GHC.Generics (Generic)

import Clash.Explicit.Prelude
  ( Bit, BitVector, Clock, Enable, Index, KnownDomain, NFDataX, Reset, Signal, Unsigned, Vec
  , asyncRam, bundle, resize, unbundle, unpack )
import qualified Clash.Explicit.Prelude as C
import Clash.Explicit.Mealy (mealy)

import Nds.Gpu3D.Mem (MemAddr, MemReq (..))
import Nds.Gpu3D.PolyRam
import Nds.Gpu3D.RasterHw.Setup (RecHdr (..), recHdr0, recWordAddr)

-- | Is a polygon with this Y-range drawn on line @y@? Lines @YTop ..
-- YBottom - 1@, and the single line of a horizontal polygon
-- ('Nds.Gpu3D.Render.polygonActive'); degenerate polygons never.
polygonActiveHw :: Unsigned 8 -> (Unsigned 8, Unsigned 8, Bool) -> Bool
polygonActiveHw y (yt, yb, deg) = not deg && y >= yt && (y < yb || (y == yt && yb == yt))

------------------------------------------------------------------------------
-- Scanner

data ScanItem
  = SiPoly !(Unsigned 8) !(Unsigned 11)  -- ^ line, sorted position
  | SiEnd !(Unsigned 8)                  -- ^ line end
  deriving (Eq, Generic, Show, NFDataX)

data ScanSt = ScanSt
  { scRun   :: !Bool
  , scLine  :: !(Unsigned 8)
  , scQi    :: !(Unsigned 10)   -- ^ next word to request
  , scQc    :: !(Unsigned 10)   -- ^ word at the FIFO head
  , scOut   :: !(Unsigned 4)    -- ^ reads outstanding
  , scFill  :: !(Unsigned 4)    -- ^ words in the FIFO
  , scWp    :: !(Unsigned 3)
  , scRp    :: !(Unsigned 3)
  , scMask  :: !(BitVector 4)   -- ^ lanes of the head word still to emit
  , scFresh :: !Bool            -- ^ the head word's mask is not computed yet
  } deriving (Eq, Generic, Show, NFDataX)

scan0 :: ScanSt
scan0 = ScanSt False 0 0 0 0 0 0 0 0 True

-- Input records are lazy: some fields depend combinationally on the
-- engine's own outputs (through the other engine), and a strict field
-- would force them before the step runs.
data ScanIn = ScanIn
  { sinStart :: Bool
  , sinBase  :: MemAddr
  , sinBank  :: Bit
  , sinCount :: Unsigned 12
  , sinGrant :: Bool                      -- ^ the port takes the scanner's request
  , sinResp  :: Maybe (BitVector 64)      -- ^ a response routed to the scanner
  , sinHead  :: BitVector 64              -- ^ FIFO word at the read pointer
  , sinTake  :: Bool                      -- ^ the fetcher takes the offered item
  }

-- | (state, (request, FIFO write, offered item)). The start only resets the
-- state; the outputs never depend on it (a frame starts when both engines
-- are idle).
scanStep :: ScanSt -> ScanIn
         -> (ScanSt, (Maybe MemReq, Maybe (Unsigned 3, BitVector 64), Maybe ScanItem, Unsigned 3))
scanStep s0 i = (if sinStart i then scan0 { scRun = True } else sNext, outs)
  where
    (sNext, outs)
      | not (scRun s0) = (s0, (Nothing, Nothing, Nothing, scRp s0))
      | otherwise = (s3, (req, fifoW, item, scRp s0))
    -- Widen before rounding up: a full 2048-polygon bank must not wrap to zero.
    words' = resize (((resize (sinCount i) :: Unsigned 13) + 3) `shiftR` 2) :: Unsigned 11
    canIssue = resize (scQi s0) < words' && scOut s0 + scFill s0 < 8
    req = if canIssue then Just (MemRead (yRangeAddr (sinBase i) (sinBank i) (resize (scQi s0) `shiftL` 2))) else Nothing
    issued = canIssue && sinGrant i
    fifoW = fmap (\w -> (scWp s0, w)) (sinResp i)
    got = maybe False (const True) (sinResp i)
    s1 = s0 { scQi = if issued then scQi s0 + 1 else scQi s0
            , scOut = scOut s0 + (if issued then 1 else 0) - (if got then 1 else 0)
            , scWp = if got then scWp s0 + 1 else scWp s0
            , scFill = scFill s0 + (if got then 1 else 0) }
    y = scLine s0
    -- The head word's active lanes.
    laneActive k =
      let p = (resize (scQc s0) `shiftL` 2) + fromIntegral (k :: Int) :: Unsigned 12
          r = resize (sinHead i `shiftR` (16 * k)) :: BitVector 16
      in p < sinCount i && polygonActiveHw y (decodeYRange r)
    freshMask = C.pack (C.map laneActive (C.reverse (C.iterateI (+ 1) (0 :: Int)) :: Vec 4 Int))
    mask = if scFresh s0 then freshMask else scMask s0
    lowest :: Index 4
    lowest | testBit mask 0 = 0
           | testBit mask 1 = 1
           | testBit mask 2 = 2
           | otherwise = 3
    lineDone = resize (scQc s0) >= words'
    item
      | lineDone = Just (SiEnd y)
      | scFill s0 == 0 = Nothing
      | mask /= 0 = Just (SiPoly y ((resize (scQc s0) `shiftL` 2) + fromIntegral lowest))
      | otherwise = Nothing
    s2
      | lineDone =
          if sinTake i
            then s1 { scLine = y + 1, scQi = 0, scQc = 0, scFresh = True, scRun = y /= 191 }
            else s1
      | scFill s0 == 0 = s1
      | mask == 0 = s1 { scQc = scQc s0 + 1, scRp = scRp s0 + 1, scFill = scFill s1 - 1, scFresh = True }
      | sinTake i =
          let m' = mask .&. complement (1 `shiftL` fromIntegral lowest)
          in if m' == 0
               then s1 { scQc = scQc s0 + 1, scRp = scRp s0 + 1, scFill = scFill s1 - 1, scFresh = True }
               else s1 { scMask = m', scFresh = False }
      | otherwise = s1 { scMask = mask, scFresh = False }
    s3 = s2

------------------------------------------------------------------------------
-- Fetcher

data FPh
  = FIdle
  | FEntry
  | FHead
  | FSlots
  | FVerts
  | FPush
  | FEnd
  deriving (Eq, Generic, Show, NFDataX)

data FetchSt = FetchSt
  { ftPh    :: !FPh
  , ftLine  :: !(Unsigned 8)
  , ftPos   :: !(Unsigned 11)
  , ftIss   :: !(Unsigned 5)
  , ftRcv   :: !(Unsigned 5)
  , ftG     :: !(Unsigned 12)
  , ftH0    :: !(BitVector 64)
  , ftIdx   :: !(Vec 10 (Unsigned 14))
  , ftCur   :: !RecHdr
  , ftQueue :: !(Vec 2 RecHdr)
  , ftFull  :: !(Vec 2 Bool)
  , ftWp    :: !(Unsigned 1)
  , ftRp    :: !(Unsigned 1)
  } deriving (Eq, Generic, Show, NFDataX)

fetch0 :: FetchSt
fetch0 = FetchSt FIdle 0 0 0 0 0 0 (C.repeat 0) recHdr0 (C.repeat recHdr0) (C.repeat False) 0 0

data FetchIn = FetchIn
  { fnStart :: Bool
  , fnBase  :: MemAddr
  , fnBank  :: Bit
  , fnItem  :: Maybe ScanItem
  , fnGrant :: Bool
  , fnResp  :: Maybe (BitVector 64)
  , fnPop   :: Bool                -- ^ the setup engine pops the queue head
  }

-- | (state, (request, take scanner item, record RAM write, queue head))
fetchStep :: FetchSt -> FetchIn
          -> (FetchSt, (Maybe MemReq, Bool, Maybe (Unsigned 6, BitVector 64), Maybe RecHdr))
fetchStep s0 i = (if fnStart i then fetch0 else s2, (req, takeItem, rbW, headOut))
  where
    headOut = if ftFull s0 C.!! ftRp s0 then Just (ftQueue s0 C.!! ftRp s0) else Nothing
    s = if fnPop i && ftFull s0 C.!! ftRp s0
          then s0 { ftFull = C.replace (ftRp s0) False (ftFull s0), ftRp = ftRp s0 + 1 }
          else s0
    b = fnBase i
    total = case ftPh s of
      FEntry -> 1
      FHead -> 2
      FSlots -> resize (rhN (ftCur s))
      FVerts -> resize (rhN (ftCur s)) `shiftL` 1
      _ -> 0 :: Unsigned 5
    slotFree = not (ftFull s C.!! ftWp s)
    addrOf k = case ftPh s of
      FEntry -> renderListAddr b (fnBank i) (ftPos s)
      FHead -> polyHeaderAddr b (ftG s) (if k == 0 then 0 else 1)
      FSlots -> polySlotAddr b (ftG s) (resize k)
      _ -> vertexAddr b (ftIdx s C.!! (k `shiftR` 1)) (if testBit k 0 then 1 else 0)
    canIssue = ftIss s < total && (ftPh s /= FHead || slotFree)
    req = if canIssue then Just (MemRead (addrOf (ftIss s))) else Nothing
    s1 = if canIssue && fnGrant i then s { ftIss = ftIss s + 1 } else s
    takeItem = ftPh s == FIdle && maybe False (const True) (fnItem i)
    next st = st { ftIss = 0, ftRcv = 0 }
    (s2, rbW) = case ftPh s of
      FIdle -> case fnItem i of
        Just (SiPoly y p) -> (next s1 { ftPh = FEntry, ftLine = y, ftPos = p }, Nothing)
        Just (SiEnd y) -> (s1 { ftPh = FEnd, ftLine = y }, Nothing)
        Nothing -> (s1, Nothing)
      FEntry -> case fnResp i of
        Just w ->
          let e = decodeRenderEntry w
          in ( next s1 { ftPh = FHead, ftG = rePoly e
                       , ftCur = (ftCur s1) { rhYTop = reYTop e, rhYBot = reYBottom e } }
             , Nothing )
        Nothing -> (s1, Nothing)
      FHead -> case fnResp i of
        Just w
          | ftRcv s1 == 0 -> (s1 { ftRcv = 1, ftH0 = w }, Nothing)
          | otherwise ->
              let h = decodeHeader (ftH0 s1) w 0
                  c = (ftCur s1)
                    { rhEntry = ftWp s1, rhEnd = False, rhLine = ftLine s1
                    , rhAttr = unpack (phAttr h), rhTexParam = unpack (phTexParam h)
                    , rhTexPal = unpack (phTexPalette h), rhN = phNumVerts h
                    , rhWBuf = phWBuffer h, rhFacing = phFacingView h
                    , rhMask = phShadowMask h, rhShadow = phShadow h
                    , rhVTop = phVTop h, rhVBot = phVBottom h }
              in (next s1 { ftPh = FSlots, ftCur = c }, Nothing)
        Nothing -> (s1, Nothing)
      FSlots -> case fnResp i of
        Just w ->
          let k = ftRcv s1
              st = s1 { ftRcv = k + 1, ftIdx = C.replace k (psIndex (decodeSlot w)) (ftIdx s1) }
          in ( if k + 1 == total then next st { ftPh = FVerts } else st
             , Just (recWordAddr (ftWp s) (resize k) 0, w) )
        Nothing -> (s1, Nothing)
      FVerts -> case fnResp i of
        Just w ->
          let k = ftRcv s1
              vk = k `shiftR` 1
              c = ftCur s1
              c' | testBit k 0 = c
                 | otherwise =
                     let v = decodeVertexRec w 0
                     in c { rhX = C.replace vk (vrX v) (rhX c), rhY = C.replace vk (vrY v) (rhY c) }
              st = s1 { ftRcv = k + 1, ftCur = c' }
          in ( if k + 1 == total then st { ftPh = FPush } else st
             , Just (recWordAddr (ftWp s) (resize vk) (if testBit k 0 then 2 else 1), w) )
        Nothing -> (s1, Nothing)
      FPush ->
        let wp = ftWp s1
        in ( s1 { ftPh = FIdle, ftQueue = C.replace wp (ftCur s1) (ftQueue s1)
                , ftFull = C.replace wp True (ftFull s1), ftWp = wp + 1 }
           , Nothing )
      FEnd
        | slotFree ->
            let wp = ftWp s1
                tok = recHdr0 { rhEnd = True, rhLine = ftLine s1, rhEntry = wp }
            in ( s1 { ftPh = FIdle, ftQueue = C.replace wp tok (ftQueue s1)
                    , ftFull = C.replace wp True (ftFull s1), ftWp = wp + 1 }
               , Nothing )
        | otherwise -> (s1, Nothing)

------------------------------------------------------------------------------
-- Port arbitration

data ArbSt = ArbSt
  { arTags  :: !(BitVector 32)   -- ^ bit k: outstanding read k belongs to the scanner
  , arCount :: !(Unsigned 6)
  } deriving (Eq, Generic, Show, NFDataX)

-- | Grant, route. Inputs: fetcher request, scanner request, port ready,
-- port response. Outputs: port request, fetcher grant, scanner grant,
-- response to the fetcher, response to the scanner.
arbStep :: ArbSt -> (Maybe MemReq, Maybe MemReq, Bool, Maybe (BitVector 64))
        -> (ArbSt, (Maybe MemReq, Bool, Bool, Maybe (BitVector 64), Maybe (BitVector 64)))
arbStep s (fr, sr, ready, resp) = (s', (portReq, gF, gS, rF, rS))
  where
    room = arCount s < 32
    (portReq, isScan) = case fr of
      Just r | room -> (Just r, False)
      _ -> case sr of
        Just r | room -> (Just r, True)
        _ -> (Nothing, False)
    accepted = ready && maybe False (const True) portReq
    gF = accepted && not isScan
    gS = accepted && isScan
    popped = maybe False (const True) resp
    headScan = testBit (arTags s) 0
    rF = if popped && not headScan then resp else Nothing
    rS = if popped && headScan then resp else Nothing
    tags1 = if popped then arTags s `shiftR` 1 else arTags s
    cnt1 = if popped then arCount s - 1 else arCount s
    tags2 = if accepted && isScan then tags1 .|. (1 `shiftL` fromIntegral cnt1) else tags1
    cnt2 = if accepted then cnt1 + 1 else cnt1
    s' = ArbSt tags2 cnt2

------------------------------------------------------------------------------
-- Signal level

-- | The front end. Inputs: frame start, polygon window base, bank, count,
-- polygon port ready and response, setup engine pop. Outputs: polygon port
-- request, queue head, record RAM write.
frontEnd
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom Bool
  -> Signal dom MemAddr
  -> Signal dom Bit
  -> Signal dom (Unsigned 12)
  -> Signal dom Bool
  -> Signal dom (Maybe (BitVector 64))
  -> Signal dom Bool
  -> ( Signal dom (Maybe MemReq)
     , Signal dom (Maybe RecHdr)
     , Signal dom (Maybe (Unsigned 6, BitVector 64)) )
frontEnd clk rst en start base bank count ready resp pop = (portReq, headOut, rbW)
  where
    (portReq, gF, gS, rF, rS) = unbundle (mealy clk rst en arbStep (ArbSt 0 0) (bundle (fReq, sReq, ready, resp)))
    scanOut = mealy clk rst en scanStep scan0
      (ScanIn <$> start <*> base <*> bank <*> count <*> gS <*> rS <*> fifoHead <*> takeItem)
    (sReq, fifoW, item, rp) = unbundle scanOut
    fifoHead = asyncRam clk clk en (C.SNat :: C.SNat 8) rp fifoW
    fetchOut = mealy clk rst en fetchStep fetch0
      (FetchIn <$> start <*> base <*> bank <*> item <*> gF <*> rF <*> pop)
    (fReq, takeItem, rbW, headOut) = unbundle fetchOut
