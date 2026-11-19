{-# LANGUAGE BangPatterns #-}
-- | Timestamped functional GX executor. Arithmetic and polygon ownership stay
-- in Chip; this module supplies the GPU3D::Run/AddCycles pipeline schedule.
-- Time is the 33.513982 MHz system clock, not the 100 MHz Clash implementation
-- clock. Commands execute only at their independently scheduled FIFO-consume
-- deadline. Rendering is functional and does not advance this clock.
module Nds.Gpu3D.Timed
  ( TimedChip(..), TimedEffect(..), initTimedChip, timedDeadline
  , timedAdvance, timedWrite, timedWriteContinuation, timedRead, timedVBlank, timedPower
  ) where

import Data.Bits
import Data.Maybe (isJust)
import Data.Word
import qualified Data.Sequence as S
import Nds.Gpu3D.Chip
import qualified Nds.Gpu3D.Geometry as G
import qualified Nds.Gpu3D.GxFront as F
import qualified Nds.Gpu3D.Polygon as P
import Nds.Gpu3D.Types

-- Effects occur at tcTime, and must be applied before the next bus access.
data TimedEffect = GxIrq !Bool | GxDma deriving (Eq, Show)
data TimedChip = TimedChip
  { tcChip :: !Chip, tcTime :: !Word64, tcDebt :: !Int
  , tcVertex :: !Int, tcNormal :: !Int, tcPolygon :: !Int
  , tcSlotClock :: !Int, tcSlots :: !Word32, tcBusy :: !Bool
  }

initTimedChip :: Word64 -> TimedChip
initTimedChip t = TimedChip initChip t 0 0 0 0 0 1 False

runnable :: TimedChip -> Bool
runnable t = F.gfGeomEn f && not (P.ppFlushReq (chPoly (tcChip t)))
  where f = chFront (tcChip t)

timedDeadline :: TimedChip -> Maybe Word64
timedDeadline t
  | not (runnable t) || not (tcBusy t) = Nothing
  | isJust (F.headEntry (chFront (tcChip t))) = Just (tcTime t + fromIntegral (max 0 (tcDebt t)))
  | otherwise = Just (tcTime t + fromIntegral (if tcDebt t>0 then tcDebt t else pipelines))
  where pipelines = maximum [tcVertex t, tcNormal t, tcPolygon t]

-- | One due deadline, not an unbounded full FIFO drain. A caller may not jump
-- over the returned deadline: doing so would lose intervening DMA/IRQ effects.
timedAdvance :: Word64 -> TimedChip -> Either String (TimedChip, [TimedEffect])
timedAdvance now t
  | now < tcTime t = Left "GX timestamp moved backwards"
  | maybe False (< now) (timedDeadline t) = Left "GX deadline skipped"
  | not (runnable t) || not (tcBusy t) = Right (t { tcTime = now }, [])
  | debt > 0 = Right (t { tcTime = now, tcDebt = debt }, [])
  | otherwise = case F.headEntry (chFront (tcChip t)) of
      Nothing -> Right (finish (-debt) t { tcTime = now, tcDebt = debt }, [])
      Just _ -> Right (execute t { tcTime = now, tcDebt = debt })
  where debt = tcDebt t - fromIntegral (now - tcTime t)

advancePipes :: Int -> TimedChip -> TimedChip
advancePipes n t
  | tcPolygon t == 0 = t { tcVertex = max 0 (tcVertex t-n) }
  | tcPolygon t > n = t { tcVertex = max 0 (tcVertex t-n)
                        , tcPolygon = tcPolygon t-n
                        , tcSlotClock = clocks-shifts*9
                        , tcSlots = tcSlots t `shiftR` shifts }
  | otherwise = t { tcVertex = max 0 (tcVertex t-n), tcPolygon = 0
                   , tcSlotClock = 0, tcSlots = 1 }
  where
    clocks = tcSlotClock t+n
    -- The reference advances while counter > 9, not >= 9.
    shifts = max 0 ((clocks-1) `div` 9)

addCycles :: Int -> TimedChip -> TimedChip
addCycles n t = let p = advancePipes n t in p { tcDebt = tcDebt t+n }

finish :: Int -> TimedChip -> TimedChip
finish n t = p { tcDebt = 0, tcNormal = normal, tcBusy = busy
               , tcChip = c { chFront = F.settleBits (chFront c) } }
  where
    p = addCycles n t
    normal = max 0 (tcNormal p-n)
    busy = tcVertex p /= 0 || normal /= 0 || tcPolygon p /= 0
    c = tcChip p

nextVertexSlot :: TimedChip -> TimedChip
nextVertexSlot t = go (10-tcSlotClock t) t
  where
    go n s
      | tcPolygon s > n =
          let slots = tcSlots s `shiftR` 1
              s' = s { tcDebt = tcDebt s+n, tcVertex = max 0 (tcVertex s-n)
                     , tcPolygon = tcPolygon s-n, tcSlotClock = 1, tcSlots = slots }
          in if testBit slots 0 then s' { tcSlots = clearBit slots 0 } else go 9 s'
      | otherwise = s { tcDebt = tcDebt s+n, tcVertex = max 0 (tcVertex s-n)
                       , tcPolygon = 0, tcSlotClock = 0, tcSlots = 1 }

stallPolygon :: Int -> Int -> TimedChip -> TimedChip
stallPolygon delay nonstall t
  | tcPolygon t > 0 = t { tcDebt = tcDebt t+tcPolygon t+delay
                        , tcVertex = 0, tcNormal = 0, tcPolygon = 0
                        , tcSlotClock = 0, tcSlots = 1 }
  | otherwise = addCycles (if tcVertex t > nonstall then tcVertex t-nonstall+1 else tcNormal t+1) t

baseDelay :: Word8 -> Bool -> TimedChip -> TimedChip
baseDelay op first t
  | not first = addCycles 1 t
  | op >= 0x23 && op <= 0x28 = (if testBit (tcSlots t) 0 then addCycles 1 t else nextVertexSlot t) { tcNormal = 0 }
  | op == 0x70 = stallPolygon 11 0 t
  | op == 0x32 = stallPolygon 9 2 t
  | op == 0x40 = stallPolygon 1 0 t
  | op `elem` [0x20,0x30,0x31,0x72] = clearNormal (addCycles (if tcVertex t > 2 then tcVertex t-1 else tcNormal t+1) t)
  | op `elem` [0x29,0x2a,0x2b,0x33,0x34,0x41,0x60,0x71] = clearNormal (addCycles (if tcVertex t > 0 then tcVertex t+1 else tcNormal t+1) t)
  | otherwise = clearNormal (addCycles (tcNormal t+1) t)
  where clearNormal s = s { tcNormal = 0 }

execute :: TimedChip -> (TimedChip, [TimedEffect])
execute t = case F.popEntry front of
  Nothing -> (t, [])
  Just (entry, after, fx) ->
    let op = ceCmd entry
        -- Keep retiring-command bits until the next boundary, and preserve
        -- bits newly asserted when this pop admits stall-queue entries.
        kept = after { F.gfPushPopBit = F.gfPushPopBit front || F.gfPushPopBit after
                     , F.gfTestBit = F.gfTestBit front || F.gfTestBit after }
        c = (tcChip t) { chFront = kept }
        (command, params) = gatherEntry entry (chParams c)
        first = cmdNumParams op <= 1 || null (chParams c)
        delayed = baseDelay op first t { tcChip = c { chParams = params } }
        result = case command of
          Nothing -> delayed
          Just cmd -> commandCost op (chGeo c) (execGeo cmd (tcChip delayed)) delayed
        effects = [GxIrq (F.irqLine kept) | F.pfRefill fx] ++ [GxDma | F.pfDma fx]
    in (result, effects)
  where front = F.settleBits (chFront (tcChip t))

commandCost :: Word8 -> G.GeoState -> Chip -> TimedChip -> TimedChip
commandCost op before after t
  | op == 0x50 = s { tcDebt = 325, tcVertex = 0, tcNormal = 0
                    , tcPolygon = 0, tcSlotClock = 0, tcSlots = 1 }
  | op >= 0x23 && op <= 0x28 =
      let p = chPoly after
          s' = case P.ppLastSubmit p of
            Nothing -> s
            Just report -> let (cycles,slots) = P.submitTiming (P.ppMode p) report
                           in s { tcPolygon = fromIntegral cycles, tcSlots = slots, tcSlotClock = 1 }
      in addCycles 3 s' { tcVertex = 7 }
  | op == 0x21 = addCycles (max 1 (popCount (G.gCurPolyAttr before .&. 15))) s { tcNormal = 7 }
  | otherwise = addCycles extra s
  where
    s = t { tcChip = after }
    tex = G.gMtxMode before == 3
    both = G.gMtxMode before == 2
    matrix n = if tex then 33-n else 35-n + if both then 30 else 0
    extra = case op of
      0x11 -> 16; 0x12 -> if tex then 17 else 35
      0x13 -> 16; 0x14 -> if tex then 17 else 35
      0x15 -> if tex then 0 else 18
      0x16 -> if tex then 10 else 18
      0x17 -> if tex then 7 else 18
      0x18 -> matrix 16; 0x19 -> matrix 12; 0x1a -> matrix 9
      0x1b -> if tex then 30 else 32
      0x1c -> matrix 3
      0x30 -> 3; 0x31 -> 3; 0x32 -> 5; 0x33 -> 1
      0x70 -> 254; 0x71 -> 5; 0x72 -> 4
      _ -> 0

timedWrite :: F.Size -> Word32 -> Word32 -> TimedChip -> Either String (TimedChip, [TimedEffect])
timedWrite size address value t
  | chipStalled c = Left "GX bus transaction issued while stalled"
  | otherwise = writeAccepted size address value (chipWrite size address value c) t
  where c = tcChip t

-- | Only the service's authenticated same-instruction continuation may call
-- this while stalled. Use the normal decoder and existing front-end pending
-- FIFO, without advancing time or changing ordinary bus admission.
timedWriteContinuation :: Word32 -> Word32 -> TimedChip -> Either String (TimedChip, [TimedEffect])
timedWriteContinuation address value t
  | not (chipStalled (tcChip t)) = Left "GX continuation without an active stall"
  | otherwise = writeAccepted F.S32 address value (chipWriteContinuation address value (tcChip t)) t

writeAccepted :: F.Size -> Word32 -> Word32 -> Chip -> TimedChip -> Either String (TimedChip, [TimedEffect])
writeAccepted size address value c' t =
  Right (t { tcChip = c', tcBusy = tcBusy t || not (S.null (F.gfPipe (chFront c'))) }, effects)
  where
    c = tcChip t
    action = F.writeAction (F.gfGeomEn (chFront c)) (F.gfRendEn (chFront c)) size address value
    effects = case action of
      F.WaGxStat _ (Just _) -> [GxIrq (chipIrq c')]
      _ -> []

timedRead :: F.Size -> Word32 -> TimedChip -> Word32
timedRead size address t = F.mmioRead inputs size address (chFront c)
  where
    c = tcChip t
    inputs = (chipFrontIn c) { F.fiGeo = (G.geoStatus (chGeo c)) { gsBusy = tcBusy t } }

timedVBlank :: TimedChip -> TimedChip
timedVBlank t = t { tcChip = chipVBlank (tcChip t) }

timedPower :: Bool -> Bool -> TimedChip -> TimedChip
timedPower geom render t = t { tcChip = chipPower geom render (tcChip t) }
