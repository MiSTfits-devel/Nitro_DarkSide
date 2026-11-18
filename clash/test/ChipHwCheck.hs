{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Clash-simulation gate for the chip hardware ("Nds.Gpu3D.ChipHw", top
-- @nds_gpu3d@) against the whole-chip model ("Nds.Gpu3D.Chip").
--
-- @chip-hw-check SCRIPT VRAM [SCRIPT VRAM ...]@ replays each op script (the
-- ones @run_chip_check.sh@ generates) through 'chipHw' with behavioural
-- memories behind its two @Mem@ ports (random ready, in-order latency 1..12),
-- and advances an independent transaction scoreboard on the actual schedule:
--
-- * every offered/accepted command and parameter matches the reference PIPE;
-- * every transferred geometry event matches the independently executed
--   expected command, before the expected event reaches the polygon model;
-- * accepted inputs = consumed entries + independently queued residuals;
-- * FIFO/PIPE occupancy, stall, IRQ/checks and DMA pulses match the reference,
--   with all phases counted (including bus, burst, idle and render cycles);
-- * defined reads keep their bus schedule; overlapping RAM_COUNT reads must
--   linearize monotonically to independently computed event-prefix states;
-- * frame pixels match after rendering completes. Only documented
--   undefined-busy geometry result ports are fenced.
--
-- '+' means no post-access drain, NOT zero geometry progress: the hardware
-- stays free-running. The old precomputed zero-progress burst oracle is not
-- a valid clock schedule for this gate. See ChipHwReference.
--
-- Environment: READY (ready probability numerator over 1024, default 768),
-- LATMAX (default 12), IF_EVERY_CYCLE=1 (focused IF/refill boundary stimulus).
module Main (main) where

import Control.Monad (unless, when)
import Data.Array.Unboxed (UArray, bounds, listArray, (!))
import Data.Bits (complement, shiftL, shiftR, testBit, xor, (.&.), (.|.))
import qualified Data.IntMap.Strict as IM
import Data.List (foldl', nub)
import qualified Data.Sequence as Seq
import qualified Data.Sequence as S
import Data.Sequence (Seq, ViewL (..), viewl, (|>))
import Data.Word (Word16, Word32, Word64)
import Numeric (readHex, showHex)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import Text.Printf (printf)

import Clash.Explicit.Prelude (System, enableGen, Bit, BitVector, unpack)
import qualified Clash.Explicit.Prelude as C
import Clash.Explicit.Signal (systemClockGen, systemResetGen)
import Clash.Signal.Internal (Signal (..))
import Clash.XException (hasUndefined)

import Nds.Gpu3D.Chip hiding (ChipIn, ChipOut)
import qualified Nds.Gpu3D.PolyRam as PC
import Nds.Gpu3D.RasterHw (RasterIn (..), RasterOut (..), rasterHw)
import Nds.Gpu3D.RasterHw.Types (Bases (..), RegsHw (..))
import Nds.Gpu3D.Mem (MemReq (..))
import Nds.Gpu3D.ChipHw (chipHw, chipTopEntity, offPoly, offLower, offOut, offPal, ChipIn (..), ChipOut (..), arbiter, OutReq (..))
import Nds.Gpu3D.GxFront (Size (..))
import Nds.Gpu3D.GxFrontHw (BusReq (..))
import Nds.Gpu3D.Mem (MemAddr, MemReq (..))
import Nds.Gpu3D.Render (outputLine)
import ChipHwReference
import Nds.Gpu3D.Texture (TexMem)

import OracleIO

------------------------------------------------------------------------------
-- Ops

data Op
  = OWrite Size Word32 Word32
  | ORead Size Word32
  | OPower Word32
  | OXPos Size Word32 Word32
  | OVCount Size Word32 Word32
  | OIrqAck Word32
  | OVBlank
  | ORender
  | OFrameEnd
  | OLines
  | OTime
  deriving (Show)

isLines :: Op -> Bool
isLines = \case
  OLines -> True
  _ -> False

isRender :: Op -> Bool
isRender = \case
  ORender -> True
  _ -> False

parseOp :: String -> Either String (Bool, Op)
parseOp line = case words line of
  (('+' : c) : rest) -> (,) True <$> op (c : rest)
  ws -> (,) False <$> op ws
  where
    op ws = case ws of
      ["W", s, a, v] -> OWrite <$> size s <*> hex a <*> hex v
      ["R", s, a] -> ORead <$> size s <*> hex a
      ["P", v] -> OPower <$> hex v
      ["X", s, a, v] -> OXPos <$> size s <*> hex a <*> hex v
      ["A", s, a, v] -> OVCount <$> size s <*> hex a <*> hex v
      ["I", v] -> OIrqAck <$> hex v
      ["V"] -> Right OVBlank
      ["S"] -> Right ORender
      ["F"] -> Right OFrameEnd
      ["L"] -> Right OLines
      ["T"] -> Right OTime
      _ -> Left ("bad op: " ++ line)
    size "8" = Right S8
    size "16" = Right S16
    size "32" = Right S32
    size s = Left ("bad width " ++ s)
    hex t = case readHex t of
      [(v, "")] -> Right (fromInteger v)
      _ -> Left ("bad number " ++ t)

-- | An 8- or 16-bit write value and its lane mask, as the front end takes it.
laneW :: Size -> Word32 -> Word32 -> (Word16, Word16)
laneW sz a v = case (sz, a .&. 1) of
  (S8, 1) -> (fromIntegral (v `shiftL` 8), 0xFF00)
  (S8, _) -> (fromIntegral v, 0x00FF)
  _ -> (fromIntegral v, 0xFFFF)

------------------------------------------------------------------------------
-- Memory

type Mem = IM.IntMap Word64

memRead :: Mem -> MemAddr -> Word64
memRead m a = IM.findWithDefault 0 (fromIntegral (a `shiftR` 3)) m

memWrite :: MemAddr -> Word64 -> Word64 -> Mem -> Mem
memWrite a be d m =
  let k = fromIntegral (a `shiftR` 3) :: Int
      old = IM.findWithDefault 0 k m
      mask = foldl' (\acc lane ->
               if testBit be lane then acc .|. (0xFF `shiftL` (8 * lane)) else acc)
             0 [0..7]
  in IM.insert k ((old .&. complement mask) .|. (d .&. mask)) m

-- Keep the texture port disjoint from polygon/lower/output RAM. The oracle
-- image stores little-endian 32-bit words: texture slots, then palettes.
texBase :: MemAddr
texBase = 0x400000

imageBacking :: UArray Int Word32 -> Mem
imageBacking img = IM.fromDistinctAscList
  [ (fromIntegral (texBase `shiftR` 3) + i `div` 2,
     fromIntegral (img ! i) .|. (fromIntegral (if i+1 <= hi then img ! (i+1) else 0) `shiftL` 32))
  | i <- [0,2..hi] ]
  where (_,hi) = bounds img

------------------------------------------------------------------------------
-- Random numbers (SplitMix)

newtype Rng = Rng Word64

next :: Rng -> (Word64, Rng)
next (Rng s) =
  let s' = s + 0x9E3779B97F4A7C15
      z = (s `xor` (s `shiftR` 30)) * 0xBF58476D1CE4E5B9
      z2 = (z `xor` (z `shiftR` 27)) * 0x94D049BB133111EB
  in (z2 `xor` (z2 `shiftR` 31), Rng s')

------------------------------------------------------------------------------
-- Behavioural memory ports

data Port = Port
  { ptReady :: !Bool
  , ptQueue :: !(Seq (Int, Word64))   -- ^ (due cycle, data), in request order
  , ptLast  :: !Int                   -- ^ due cycle of the last queued response
  }

port0 :: Port
port0 = Port False Seq.empty 0

data MemCfg = MemCfg
  { mcReady :: !Word64  -- ^ ready probability numerator over 1024
  , mcLat   :: !Int
  , mcIfEach :: !Bool   -- ^ focused IRQ regression: acknowledge on every running clock
  }

------------------------------------------------------------------------------
-- Statistics

data Stats = Stats
  { sOps, sWrites, sReads, sEntries, sDma, sBurst, sFrames, sLines
  , sSwaps, sAborted, sHeld, sIrq, sBusWait, sFails, sCycles, sRenderC :: !Int }

emptyStats :: Stats
emptyStats = Stats 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0

statList :: Stats -> [Int]
statList s =
  [ sOps s, sWrites s, sReads s, sEntries s, sDma s, sBurst s, sFrames s
  , sLines s, sSwaps s, sAborted s, sHeld s, sIrq s, sBusWait s, sFails s
  , sCycles s, sRenderC s ]

------------------------------------------------------------------------------
-- The hardware side

data Ph
  = PbIdle       -- ^ take the next op
  | PbAccess     -- ^ hold the ARM9 access until the chip takes it
  | PbRead       -- ^ wait for the read data
  | PbPulse      -- ^ one cycle of a pulse input
  | PbStart      -- ^ one cycle of the RENDER_START pulse
  | PbDrain      -- ^ let the geometry engine catch up
  | PbNext       -- ^ the op is done
  | PbRender     -- ^ wait for the rasteriser to start (after @RENDER_START@)
  | PbRenderRun  -- ^ wait for the rasteriser to finish
  | PbLines      -- ^ wait for the rasteriser, then read the frame's lines
  | PbDone       -- ^ compare
  deriving (Eq, Show)

data D = D
  { dCycle    :: !Int
  , dIfEach   :: !Bool
  , dMem      :: !Mem
  , dPorts    :: !(Port, Port)
  , dRng      :: !Rng
  , dOps      :: ![(Bool, Op)]
  , dOp       :: !(Maybe (Bool, Op))
  , dFn       :: !Int
  , dPh       :: !Ph
  , dIn       :: !ChipIn
  , dLines    :: !(Maybe [Word32])
  , dGroups   :: ![(String, [Word32])]
  , dReference :: !Reference
  , dEntries  :: !Int
  , dDma      :: !Int
  , dBusWait  :: !Int
  , dT0       :: !Int
  , dPhT0     :: !Int
  , dRenderT0 :: !Int
  , dGeomN    :: !Int
  , dNextV    :: !Word16
  , dFrames   :: ![Int]
  , dFinished :: !Bool
  , dHangWhy :: !(Maybe String)
  , dHang     :: !Bool
  , dFails    :: ![String]
  , dStats    :: !Stats
  }

d0 :: MemCfg -> Mem -> [(Bool, Op)] -> D
d0 cfg initialMemory ops = D
  { dCycle = 0, dIfEach = mcIfEach cfg, dMem = initialMemory, dPorts = (port0, port0)
  , dRng = Rng 0x1234567890ABCDEF, dOps = ops, dOp = Nothing, dFn = 0
  , dPh = PbIdle, dIn = emptyIn, dLines = Nothing
  , dGroups = [], dReference = initialReference
  , dEntries = 0, dDma = 0, dBusWait = 0, dT0 = 0, dPhT0 = 0, dRenderT0 = 0
  , dGeomN = 0, dNextV = 0, dFrames = [], dFinished = False, dHangWhy = Nothing
  , dHang = False, dFails = [], dStats = emptyStats
  }

emptyIn :: ChipIn
emptyIn = ChipIn Nothing False False False False False Nothing Nothing
  offPoly texBase True Nothing True Nothing

busOp :: Op -> Bool
busOp = \case
  OWrite _ _ _ -> True
  ORead _ _ -> True
  _ -> False

isReadOp :: Maybe (Bool, Op) -> Bool
isReadOp (Just (_, ORead _ _)) = True
isReadOp _ = False

isLinesOp :: Maybe (Bool, Op) -> Bool
isLinesOp (Just (_, OLines)) = True
isLinesOp _ = False

burstOp :: Maybe (Bool, Op) -> Bool
burstOp = maybe False fst

-- | The input an op drives.
opIn :: Word16 -> (Bool, Op) -> ChipIn
opIn nv (_, op) = case op of
  OWrite sz a v -> withBus sz a v False
  ORead sz a -> withBus sz a 0 True
  OPower v -> emptyIn { ciPower = Just (testBit v 3, testBit v 2) }
  OXPos sz a v ->
    let (x, mk) = laneW sz a v in emptyIn { ciXPos = Just (x, mk) }
  OVCount sz a v ->
    let (val, mk) = laneW sz a v
        nv' = (nv .&. complement mk) .|. (val .&. mk .&. 0x1FF)
    in emptyIn { ciAbortFrame = nv' /= nv }
  OIrqAck _ -> emptyIn { ciIfWrite = True }
  OVBlank -> emptyIn { ciVBlank = True }
  ORender -> emptyIn { ciRenderStart = True }
  OFrameEnd -> emptyIn { ciFrameEnd = True }
  OLines -> emptyIn
  OTime -> emptyIn
  where
    withBus :: Size -> Word32 -> Word32 -> Bool -> ChipIn
    withBus sz a v rnw =
      let be = case sz of
            S8 -> 1 `shiftL` fromIntegral (a .&. 3)
            S16 -> 3 `shiftL` fromIntegral (a .&. 2)
            S32 -> 0xF
          accw = case sz of
            S8 -> 0
            S16 -> 1
            S32 -> 2
          l = case sz of
            S8 -> a .&. 3
            S16 -> a .&. 2
            S32 -> 0
          din = fromIntegral (v `shiftL` (8 * fromIntegral l))
      in emptyIn { ciBus = Just (BusReq (fromIntegral (a .&. 0x0FFFFFFC)) din rnw accw be) }

-- | The next queued operation is a pure display event. A held FIFO write is
-- released to its comparison when such an event follows; the event itself is
-- processed normally afterwards, which drains the FIFO.
nextDisplayPulse :: D -> Maybe (Bool, Op)
nextDisplayPulse d = case dOps d of
  (b, o') : _ | isPulseDisplay o' -> Just (b, o')
  _ -> Nothing

isPulseDisplay :: Op -> Bool
isPulseDisplay o = case o of
  OVBlank -> True
  ORender -> True
  OFrameEnd -> True
  _ -> False

-- Geometry result RAM is documented valid only when its engine is idle.
-- Only those undefined-busy result reads are fenced. Defined in-flight
-- RAM_COUNT, GXSTAT, IRQ, MMIO writes and display events keep their schedule.
needsStableInput :: [(Bool, Op)] -> Bool
needsStableInput ((_, op) : _) = case op of
  ORead _ a -> a >= 0x04000620 && a < 0x040006A4
  _ -> False
needsStableInput [] = False

-- | The chip input this cycle.
toIn :: D -> ChipIn
toIn d
  | dFinished d = emptyIn
  | otherwise =
      let input = withMemory (dIn d) $ case dPh d of
            PbAccess -> dIn d
            PbPulse -> dIn d
            PbStart -> dIn d
            _ -> emptyIn
      in input { ciIfWrite = ciIfWrite input || (dIfEach d && dCycle d >= 512) }

-- Memory runs continuously, including while the bus is idle or a frame is
-- rendering. Do not discard its response when changing an operation phase.
withMemory :: ChipIn -> ChipIn -> ChipIn
withMemory src dst = dst
  { ciMemReady = ciMemReady src, ciMemResp = ciMemResp src
  , ciTexReady = ciTexReady src, ciTexResp = ciTexResp src }

-- | The frame's line @y@ from where the rasteriser wrote it: the output
-- words are un-scrolled (the rasteriser was given @XPos = 0@), so @GetLine@'s
-- scroll is applied here.
hwLine :: Mem -> Word16 -> Int -> [Word32]
hwLine m xpos y =
  let base = offOut + fromIntegral (y * 1024)
      w0 i = memRead m (base + fromIntegral (8 * (i `div` 2)))
      px i = fromIntegral (if even i then w0 i .&. 0xFFFFFFFF
                                     else (w0 i `shiftR` 32) .&. 0xFFFFFFFF)
      row = listArray (0, 255) [ px i | i <- [0 .. 255] ] :: UArray Int Word32
  in outputLine xpos row

-- VCOUNT writes update the tracked value whether or not they pulse abort.
vcountAfter :: Word16 -> (Bool, Op) -> Word16
vcountAfter nv (_, OVCount sz a v) =
  let (val, mk) = laneW sz a v
  in (nv .&. complement mk) .|. (val .&. mk .&. 0x1FF)
vcountAfter nv _ = nv

stepD :: MemCfg -> TexMem -> D -> ChipOut -> D
stepD cfg tex d o
  | dFinished d = d
  | dCycle d - dPhT0 d > budget d = d { dFinished = True, dHang = True
                             , dHangWhy = Just (hangMsg d o ++ undefMsg o) }
  | otherwise = dEnd
  where
    t = dCycle d
    [pMem, pTex] = [fst (dPorts d), snd (dPorts d)]
    -- The two Mem ports serve their requests the way the model's oracle does.
    -- A completed response is presented once and only then removed: popping
    -- it before `respOf` silently dropped the last read of every burst.
    serve (m, rng, acc) (p, req) =
      let (r1, rng1) = next rng
          (r2, rng2) = next rng1
          lat = 1 + fromIntegral (r2 `mod` fromIntegral (mcLat cfg))
          (dueNow, respWord) = case viewl (ptQueue p) of
            (due, w) :< _ | due <= t -> (True, w)
            _ -> (False, 0)
          q0 = if dueNow
                 then case viewl (ptQueue p) of
                        (_ :< rest) -> rest
                        _ -> ptQueue p
                 else ptQueue p
          (m', q1, lastDue) = case req of
            Just (MemRead a) | ptReady p ->
              let due = max (t + lat) (ptLast p + 1)
              in (m, q0 |> (due, memRead m a), due)
            Just (MemWrite a be dat) | ptReady p ->
              (memWrite a (fromIntegral (toInteger be)) (fromIntegral (toInteger dat)) m,
               q0, ptLast p)
            _ -> (m, q0, ptLast p)
          ready' = (r1 `mod` 1024) < mcReady cfg
      in (m', rng2, acc ++ [(Port ready' q1 lastDue, if dueNow then Just (fromIntegral respWord) else Nothing)])
    (mem1, rng1, pss) = foldl' serve (dMem d, dRng d, [])
      [(pMem, reqOf <$> coMemReq o), (pTex, reqOf <$> coTexReq o)]
    reqOf (OutReq a w be dat) = if w then MemWrite a be dat else MemRead a
    (p1, r1resp) = pss !! 0
    (p2, r2resp) = pss !! 1
    -- the chip sees the previous state's responses this cycle
    in1 = (dIn d)
      { ciMemReady = ptReady p1, ciMemResp = r1resp
      , ciTexReady = ptReady p2, ciTexResp = r2resp }
    (reference', referenceErrors) = referenceCycle tex (toIn d) o (dReference d)
    stampedErrors = map (\msg -> "cycle " ++ show t ++ ", op " ++ show (dFn d) ++ ": " ++ msg) referenceErrors
    d1 = d { dCycle = t + 1, dMem = mem1, dRng = rng1, dPorts = (p1, p2)
            , dIn = in1, dReference = reference'
            , dEntries = dEntries d + fromEnum (coCmdAccept o)
            , dDma = dDma d + fromEnum (coDma o)
            , dFails = take 12 (dFails d ++ stampedErrors)
            , dStats = (dStats d) { sFails = sFails (dStats d) + length referenceErrors }
            , dGeomN = dGeomN d + fromEnum (coGeomBusy o) }
    -- the op's phases
    d2raw = case dPh d of
      PbIdle | needsStableInput (dOps d)
             , coGeomBusy o || coCmdAccept o || not (coPolyReady o)
               || not (referenceBlocked (dReference d)) -> d1
      PbIdle -> case dOps d of
        [] | coGeomBusy o || coRenderBusy o || not (referenceBlocked (dReference d))
             || coCmdAccept o || coDma o || coIrqCheck o -> d1
           | otherwise -> d1 { dFinished = True
                             , dStats = (dStats d1) { sEntries = dEntries d1
                                                    , sDma = dDma d1, sCycles = t + 1 } }
        (os@(b, o') : rest) ->
          let ins = opIn (dNextV d) (b, o')
              ph' | busOp o' = PbAccess
                  | isLines o' = PbLines
                  | isRender o' = PbStart
                  | otherwise = PbPulse
          in d1 { dOps = rest, dOp = Just os, dIn = withMemory in1 ins, dPh = ph'
                , dNextV = vcountAfter (dNextV d) os
                , dT0 = t, dGroups = []
                , dLines = Nothing, dFn = dFn d + 1 }
      PbAccess
        | coBusReady o -> d1 { dPh = if isReadOp (dOp d) then PbRead else PbDrain }
        | otherwise -> d1 { dBusWait = dBusWait d + 1 }
      PbRead
        | Just _ <- coRdata o -> d1 { dPh = PbDrain }
        | otherwise -> d1
      PbPulse -> d1 { dPh = PbDrain }
      PbStart -> d1 { dPh = PbRender }
      PbDrain
        | burstOp (dOp d) -> d1 { dPh = PbNext }
        | drained -> d1 { dPh = PbNext }
        | Just (_, OWrite _ _ _) <- dOp d
        , coStall o, Just _ <- nextDisplayPulse d -> d1 { dPh = PbNext }
        | otherwise -> d1
      PbNext -> d1 { dPh = PbDone }
      PbRender
        | coRenderBusy o -> d1 { dPh = PbRenderRun, dRenderT0 = t }
        | coRenderOverrun o -> d1 { dPh = PbIdle }
        | otherwise -> d1
      PbRenderRun
        | not (coRenderBusy o) -> d1 { dPh = PbLines
                                    , dFrames = (t - dRenderT0 d) : dFrames d }
        | otherwise -> d1
      PbLines
        | not (coRenderBusy o)
        , Nothing <- coMemReq o
        , Nothing <- coTexReq o
        , S.null (ptQueue p1), S.null (ptQueue p2) ->
            d1 { dPh = PbDone
               , dGroups = if isLinesOp (dOp d)
                             then [("lines", concatMap (\y -> chipGetLine y (refChip reference')) [0 .. 191])]
                             else dGroups d1
               , dLines = if isLinesOp (dOp d)
                            then Just (if coAbort o then replicate (192 * 256) 0
                                       else concat [hwLine (dMem d1) (coXPos o) y
                                                    | y <- [0 .. 191]])
                            else Nothing }
        | otherwise -> d1
      PbDone -> d1
    drained = not (coGeomBusy o) && (coSwapPending o || not (coCmdValid o)) && coBusReady o
    groups' = case dOp d of
      Just (_, OLines) -> [("lines", maybe [] id (dLines d2))]
      _ -> []
    -- compare the op at its end
    d2 = if dPh d2raw /= dPh d then d2raw { dPhT0 = t + 1 } else d2raw
    dEnd = case dPh d2 of
      PbDone
        | dFn d2 > 0 ->
            let want = dGroups d2
                diffs = cmpGroups (dFn d2) want groups'
                diffs' = map (\d -> case dOp d2 of
                                Just (_, o') -> "[" ++ show o' ++ "] " ++ d
                                Nothing -> d) diffs
                st = (dStats d2)
                  { sOps = sOps (dStats d2) + 1
                  , sEntries = dEntries d2
                  , sDma = dDma d2
                  , sFails = sFails (dStats d2) + length diffs
                  , sBusWait = sBusWait (dStats d2) + dBusWait d2
                  , sCycles = t + 1
                  , sFrames = sFrames (dStats d2) + length (dFrames d2)
                  , sRenderC = sRenderC (dStats d2) + sum (dFrames d2)
                  , sLines = sLines (dStats d2)
                            + length (maybe [] id (dLines d2))
                  , sWrites = sWrites (dStats d2)
                           + case dOp d2 of
                               Just (_, OWrite _ _ _) -> 1
                               _ -> 0
                  , sReads = sReads (dStats d2)
                          + case dOp d2 of
                              Just (_, ORead _ _) -> 1
                              _ -> 0
                  , sBurst = sBurst (dStats d2) + fromEnum (burstOp (dOp d2))
                  , sHeld = sHeld (dStats d2) + fromEnum (coStall o)
                  , sIrq = sIrq (dStats d2) + fromEnum (coIrq o)
                  , sAborted = sAborted (dStats d2) + fromEnum (coAbort o)
                  }
            in d2 { dPh = PbIdle, dOp = Nothing, dIn = withMemory (dIn d2) emptyIn
                  , dLines = Nothing
                  , dFails = take 12 (dFails d2 ++ diffs'), dStats = st, dFrames = []
                  , dBusWait = 0 }
        | otherwise -> d2 { dPh = PbIdle, dOp = Nothing }
      _ -> d2

-- | The hang report: the driver's phase and op, the block outputs and the
-- requests the chip has out.
-- | Which of the chip's outputs carry an undefined value.
undefMsg :: ChipOut -> String
undefMsg o = " undef=" ++ show
  [ ("busReady", hasUndefined (coBusReady o)), ("rdata", hasUndefined (coRdata o))
  , ("stall", hasUndefined (coStall o)), ("irq", hasUndefined (coIrq o))
  , ("irqCheck", hasUndefined (coIrqCheck o)), ("dma", hasUndefined (coDma o))
  , ("fifoLtHalf", hasUndefined (coFifoLtHalf o))
  , ("gxStat", hasUndefined (coGxStat o))
  , ("geomBusy", hasUndefined (coGeomBusy o))
  , ("swapPending", hasUndefined (coSwapPending o))
  , ("renderBusy", hasUndefined (coRenderBusy o))
  , ("renderDone", hasUndefined (coRenderDone o))
  , ("renderOverrun", hasUndefined (coRenderOverrun o))
  , ("abort", hasUndefined (coAbort o)), ("xpos", hasUndefined (coXPos o))
  , ("cmdValid", hasUndefined (coCmdValid o))
  , ("cmdAccept", hasUndefined (coCmdAccept o))
  , ("memReq", hasUndefined (coMemReq o)), ("texReq", hasUndefined (coTexReq o)) ]

hangMsg :: D -> ChipOut -> String
hangMsg d o =
  show ( coGeomBusy o, coCmdValid o, coBusReady o, coRenderBusy o
       , show (dPh d), maybe "?" (show . snd) (dOp d), dFn d
       , fmap (\(OutReq a w _ _) -> (a, w)) (coMemReq o)
       , fmap (\(OutReq a w _ _) -> (a, w)) (coTexReq o)
       )

cmpGroups :: Int -> [(String, [Word32])] -> [(String, [Word32])] -> [String]
cmpGroups n want got =
  concat [ case (lookup nm want, lookup nm got) of
             (Just w, Just g) | w == g -> []
             (Just w, Just g) ->
               [ "op " ++ show n ++ ": " ++ nm ++ " " ++
                 unwords [ show i ++ " want=0x" ++ showHex a "" ++ " got=0x" ++ showHex b ""
                         | (i, a, b) <- take 6 bad ]
                 ++ " (" ++ show (length bad) ++ " words differ)" ]
               where bad = [ (i, a, b) | (i, a, b) <- zip3 [0 :: Int ..] w g, a /= b ]
             (w, g) ->
               [ "op " ++ show n ++ ": " ++ nm ++ " want=" ++
                 show (length (maybe [] id w)) ++ " words, got=" ++
                 show (length (maybe [] id g)) ]
         | nm <- nub (map fst want ++ map fst got) ]

------------------------------------------------------------------------------
-- The driver

driver
  :: MemCfg -> TexMem -> D -> Signal System ChipOut
  -> Signal System D
driver cfg tex d ~(o :- os) =
  d :- (let d' = stepD cfg tex d o in d' `seq` driver cfg tex d' os)

-- A whole frame render can legitimately take most of 1M simulated cycles; a
-- stuck bus handshake must fail far sooner. Budgets are per phase, so a hung
-- handshake cannot burn a render's allowance.
budget :: D -> Int
budget d = case dPh d of
  PbRender    -> 1000000
  PbRenderRun -> 1000000
  PbLines     -> 1000000
  PbDone      -> 1000000
  PbDrain     -> 1000000
  _           -> 20000


runOps :: MemCfg -> TexMem -> Mem -> [(Bool, Op)] -> D
runOps cfg tex initialMemory ops = lastDone drv
  where
    ins = toIn <$> drv
    outs = chipHw systemClockGen systemResetGen enableGen ins
    drv = driver cfg tex (d0 cfg initialMemory ops) outs
    lastDone (d :- ds)
      | dFinished d = d
      | otherwise = lastDone ds

------------------------------------------------------------------------------
-- Cases

runCase :: FilePath -> FilePath -> IO Stats
runCase scriptPath imgPath = do
  text <- readFile scriptPath
  ops <- case mapM parseOp (filter (not . null) (lines text)) of
    Left e -> putStrLn ("FAIL " ++ scriptPath ++ ": " ++ e) >> exitFailure
    Right o -> pure o
  img <- readWords imgPath
  readyQ <- maybe 768 read <$> lookupEnv "READY"
  latMax <- maybe 12 read <$> lookupEnv "LATMAX"
  ifEach <- (== Just "1") <$> lookupEnv "IF_EVERY_CYCLE"
  let cfg = MemCfg (fromIntegral readyQ) latMax ifEach
      tex = imageMemory img
      d = runOps cfg tex (imageBacking img) ops
      st = dStats d
  printf "chip-hw-check %s: %d ops (%d writes, %d reads, %d bursts), %d GX entries, %d DMA triggers, %d swaps, %d frames (%d render cycles), %d lines compared, %d aborted, %d ops ending stalled, %d with the IRQ raised, %d bus-wait cycles, %d cycles, %d mismatches\n"
    scriptPath (sOps st) (sWrites st) (sReads st) (sBurst st)
    (sEntries st) (sDma st) (sSwaps st) (sFrames st) (sRenderC st)
    (sLines st) (sAborted st) (sHeld st) (sIrq st) (sBusWait st) (sCycles st)
    (sFails st)
  mapM_ (putStrLn . ("  " ++)) (dFails d)
  putStrLn ("stats: " ++ unwords (map show (statList st)))
  when (dHang d) $ putStrLn ("  FAIL hang " ++ show (dHangWhy d)) >> exitFailure
  pure st

-- | The rasteriser alone, on the record the composition computes, driven by the
-- composition's arbiter: does its frame complete?
probeMain :: IO ()
probeMain = do
  let clk = systemClockGen
      rst = systemResetGen
      en = enableGen
      zRegs = RegsHw 0x4000 0 0 0x7FFF 0 0 0 (C.repeat 0) (C.repeat 0) (C.repeat 0) 0
      tick = C.register clk rst en (0 :: C.Unsigned 8) ((+ 1) <$> tick)
      start = (\k -> if k == 3 then Just (zRegs, PC.FrameDesc 0 0) else Nothing) <$> tick
      bases = Bases 0 0x200000 0x80000 0x100000 0x200000
      -- n=5: the rasteriser's four memory ports and its texture port
      reqs = put5 <$> (roPolyReq <$> outs) <*> (roLowReq <$> outs)
                 <*> (roOutReq <$> outs) <*> (roTexReq <$> outs) <*> pure Nothing
      put5 a b c d e =
        C.replace (4 :: C.Index 5) e (C.replace (3 :: C.Index 5) d
          (C.replace (2 :: C.Index 5) c (C.replace (1 :: C.Index 5) b
            (C.replace (0 :: C.Index 5) a
              (C.repeat Nothing :: C.Vec 5 (Maybe MemReq))))))
      (rdys, fwd, resps) = arbiter 0 clk rst en
        (reqs :: Signal System (C.Vec 5 (Maybe MemReq))) (pure True) govResp
      -- RasterHwCheck's memory model, verbatim, on the arbiter's port:
      -- per-port four-deep queue, due-scheduled responses, random ready
      govResp = (\(_, q, _) t -> case S.viewl q of
                    (due, w) :< _ | due <= t -> Just (fromIntegral w)
                    _ -> Nothing) <$> memSt <*> tk
      memSt = C.register clk rst en ((1 :: Word64), (S.empty :: S.Seq (Int, Word64)), (0 :: Int))
                (step <$> memSt <*> tk <*> fwd)
      tk = C.register clk rst en (0 :: Int) ((+ 1) <$> tk)
      step (w, q, last) t f =
        let w1 = w * 6364136223846793005 + 1442695040888963407
            w2 = w1 * 6364136223846793005 + 1442695040888963407
            lat = 1 + fromIntegral (w2 `mod` (12 :: Word64))
            rdy = ((w1 `shiftR` 33) `mod` 1024) < 768
            q0 = case S.viewl q of
              (due, _) S.:< rest | due <= t -> rest
              _ -> q
            (q1, last') = case f of
              Just (MemRead _) | rdy ->
                let due = max (t + lat) (last + 1) in (q0 S.|> (due, 0), due)
              _ -> (q0, last)
        in (w2, q1, last')
      insSig = RasterIn <$> start <*> pure bases <*> at 0 rdys <*> at 0 resps
                  <*> at 3 rdys <*> at 3 resps <*> at 1 rdys <*> at 1 resps
                  <*> at 2 rdys
      outs = rasterHw clk rst en insSig
      at k v = (C.!! k) <$> v
      busy = C.sampleN 200000 ((,) <$> (roBusy <$> outs) <*> ((,) <$> (isJustS <$> (roPolyReq <$> outs)) <*> (isJustS <$> (roTexReq <$> outs))))
      cyc = C.sampleN 200000 ((,) <$> (roBusy <$> outs)
              <*> ((,,,,,) <$> (isJustS <$> (roPolyReq <$> outs)) <*> (isJustS <$> (roTexReq <$> outs))
                  <*> (isJustS <$> (roLowReq <$> outs)) <*> (isJustS <$> (roOutReq <$> outs))
                  <*> (roDone <$> outs) <*> (roOverrun <$> outs)))
      isJustS (Just _) = True
      isJustS Nothing = False
      rise = length (takeWhile (not . fst) busy)
  printf "probe: RENDER_BUSY rises on cycle %d, high on %d of %d sampled cycles\n"
    rise (length (filter fst busy)) (length busy)
  printf "probe: first cycles (busy, polyReq, texReq): %s\n"
    (show (take 20 busy))
  printf "probe: 30 cycles from the rise (busy, polyReq, texReq, lowReq, outReq, done, overrun):\n    %s\n"
    (show (take 30 (map snd (drop (rise - 1) cyc))))
  printf "probe: record RegsHw dispCnt=0x%X clear2=0x%X fdCount=%d fdBank=%d bases=%s\n"
    (0x4000 :: Int) (0x7FFF :: Int) (0 :: Int) (0 :: Int) (show bases)


main :: IO ()
main = do
  let original = 0x1122334455667788
      replacement = 0xAABBCCDDEEFF0011
      memory = IM.singleton 0 original
      cases = [(0,original), (0xFF,replacement), (3,0x1122334455660011),
               (0x81,0xAA22334455667711), (0x55,0x11BB33DD55FF7711)]
  unless (all (\(be,want) -> memRead (memWrite 0 be replacement memory) 0 == want) cases) $
    fail "behavioral memory byte-enable regression"
  args <- getArgs
  if args == ["--probe"] then probeMain else main' args

main' :: [String] -> IO ()
main' args = do
  when (null args || odd (length args)) $
    putStrLn "usage: chip-hw-check SCRIPT VRAM [...]" >> exitFailure
  sts <- mapM (uncurry runCase) (pairs args)
  let total = foldl' addStat emptyStats sts
  printf "chip-hw-check totals: %d ops (%d writes, %d reads, %d bursts), %d GX entries, %d DMA triggers, %d swaps, %d frames (%d render cycles), %d lines compared, %d aborted, %d stalled, %d IRQ, %d bus-wait cycles, %d cycles, %d mismatches\n"
    (sOps total) (sWrites total) (sReads total) (sBurst total)
    (sEntries total) (sDma total) (sSwaps total) (sFrames total)
    (sRenderC total) (sLines total) (sAborted total) (sHeld total)
    (sIrq total) (sBusWait total) (sCycles total) (sFails total)
  unless (sFails total == 0) exitFailure
  where
    pairs (a : b : rest) = (a, b) : pairs rest
    pairs _ = []
    addStat a b = Stats
      { sOps = sOps a + sOps b, sWrites = sWrites a + sWrites b
      , sReads = sReads a + sReads b, sEntries = sEntries a + sEntries b
      , sDma = sDma a + sDma b, sBurst = sBurst a + sBurst b
      , sFrames = sFrames a + sFrames b, sLines = sLines a + sLines b
      , sSwaps = sSwaps a + sSwaps b, sAborted = sAborted a + sAborted b
      , sHeld = sHeld a + sHeld b, sIrq = sIrq a + sIrq b
      , sBusWait = sBusWait a + sBusWait b, sFails = sFails a + sFails b
      , sCycles = sCycles a + sCycles b, sRenderC = sRenderC a + sRenderC b
      }
