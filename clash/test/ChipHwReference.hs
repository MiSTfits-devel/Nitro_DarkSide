{-# LANGUAGE DataKinds #-}

-- | Transaction-level reference for the free-running composed chip.
-- Bus handshakes set the input schedule, not the expected command values.
-- Every consumed command and transferred geometry event is checked against
-- independently queued model data before that expected data advances the model.
module ChipHwReference
  ( Reference (..), initialReference, referenceCycle, outstanding, referenceBlocked ) where

import Data.Bits ((.&.), (.|.), shiftL)
import Data.Maybe (isJust)
import qualified Data.Sequence as Seq
import Data.Word (Word32)
import Clash.Prelude (BitVector)

import Nds.Gpu3D.Chip hiding (ChipIn, ChipOut)
import Nds.Gpu3D.ChipHw (ChipIn (..), ChipOut (..))
import qualified Nds.Gpu3D.Geometry as Geo
import Nds.Gpu3D.GeometryHw.Event (toHwEvent)
import qualified Nds.Gpu3D.GxFront as Front
import Nds.Gpu3D.GxFrontHw (Access (..), HwEntry (..), busAccess, lanePlace)
import qualified Nds.Gpu3D.Polygon as Poly
import Nds.Gpu3D.Texture (TexMem)
import Nds.Gpu3D.Types (CmdEntry (..), GeoEvent (..), GeoStatus (..), PipeStatus (..), PolyState (..))
import qualified ChipHwGeoSchedule as GS

data Reference = Reference
  { refChip :: !Chip
  , refEvents :: !(Seq.Seq GeoEvent)
  , refIssued :: !Int
  , refTaken :: !Int
  , refDma :: !Int
  , refActualTaken :: !Int
  , refActualDma :: !Int
  , refSwapWait :: !Bool
  , refVBlankPending :: !(Maybe Bool) -- rendering enable latched at the gated pulse
  , refIrq :: !Bool
  , refChecks :: !Int
  , refActualChecks :: !Int
  , refCycle :: !Int
  , refPulseSchedule :: !(Seq.Seq (Int, Bool, Bool)) -- due, IRQ condition, DMA
  , refCountPrefixes :: !(Seq.Seq PipeStatus)
  , refReadPending :: !(Maybe [(BitVector 32, Maybe Int)])
  , refRenderPending :: !Bool
  , refOfferSeen :: !Bool
  , refZeroDotPrev :: !Word32
  , refPendingIterations :: ![Bool] -- pending packed cycles; False still takes a clock
  , refGeoSchedule :: !GS.GeoSchedule
  , refFifoPhysical :: !Int
  , refLevelSchedule :: !(Seq.Seq (Int, Int)) -- visible FIFO deltas, applied pre-edge
  }

initialReference :: Reference
initialReference = Reference
  { refChip = initChip, refEvents = Seq.empty, refIssued = 0, refTaken = 0
  , refDma = 0, refActualTaken = 0, refActualDma = 0, refSwapWait = False
  , refVBlankPending = Nothing, refIrq = False, refChecks = 0
  , refActualChecks = 0, refCycle = 0, refPulseSchedule = Seq.empty
  , refCountPrefixes = Seq.singleton (PipeStatus 0 0), refReadPending = Nothing
  , refRenderPending = False, refOfferSeen = False, refZeroDotPrev = 0xFFFFFF
  , refPendingIterations = [], refGeoSchedule = GS.initialGeoSchedule
  , refFifoPhysical = 0, refLevelSchedule = Seq.empty
  }

outstanding :: Chip -> Int
outstanding ch = let f = chFront ch in
  Seq.length (Front.gfPipe f) + Seq.length (Front.gfFifo f) + Seq.length (Front.gfStallQ f)

referenceBlocked :: Reference -> Bool
referenceBlocked r = Seq.null (refEvents r) && Seq.null (refPulseSchedule r) && Seq.null (refLevelSchedule r)
  && refVBlankPending r == Nothing && refReadPending r == Nothing && not (refRenderPending r) &&
  (not (Front.gfGeomEn (chFront (refChip r))) || refSwapWait r || outstanding (refChip r) == 0)

-- Packed zero/unsupported command bytes consume an iteration even when they
-- emit no entry. Preserve them when a packed write is suspended by FIFO full.
packIterations :: Word32 -> Front.Packer -> [Bool]
packIterations value pk =
  let (start, run) = Front.packStart value pk
      walk p = let (entry, p', more) = Front.packIter value p
               in isJust entry : if more then walk p' else []
  in if run then walk start else []

-- Return consumed clocks, unprocessed packed iterations, and independently
-- scheduled visible FIFO writes. PIPE writes do not change FIFO level.
runIterations :: Int -> Int -> Int -> [Bool] -> (Int, [Bool], Seq.Seq (Int, Int))
runIterations _ _ _ [] = (0, [], Seq.empty)
runIterations due pipe fifo xs@(emits : rest)
  | emits && fifo == 256 = (0, xs, Seq.empty)
  | otherwise =
      let pipeWrite = emits && fifo == 0 && pipe < 4
          fifoWrite = emits && not pipeWrite
          (n, left, changes) = runIterations (due + 1) (pipe + fromEnum pipeWrite)
                                (fifo + fromEnum fifoWrite) rest
          changes' = if fifoWrite then (due, 1) Seq.<| changes else changes
      in (n + 1, left, changes')

-- | Command/event order and values are exact. FIFO/DMA/IRQ register delays
-- are independently scheduled. Defined reads retain their bus schedule;
-- an overlapping RAM_COUNT read must linearize to one of the independently
-- computed old/new event prefixes, monotonically, and is exact when settled.
referenceCycle :: TexMem -> ChipIn -> ChipOut -> Reference -> (Reference, [String])
referenceCycle tex inp out old = (rSide, checks ++ readErrors ++ popErrors ++ eventErrors ++ geoErrors)
  where
    readMatches = case (refReadPending old, coRdata out) of
      (Just expected, Just actual) -> [prefix | (value, prefix) <- expected, value == actual]
      _ -> []
    readErrors = case (refReadPending old, coRdata out) of
      (Nothing, Nothing) -> []
      (Just _, Just _) | not (null readMatches) -> []
      (expected, actual) -> ["read response: actual=" ++ show actual ++ " expected=" ++ show expected]
    committed = case [i | Just i <- readMatches] of [] -> 0; matches -> minimum matches
    base = old { refCountPrefixes = Seq.drop committed (refCountPrefixes old) }
    -- The polygon engine serializes its pending VBlank after already accepted
    -- events. Apply it before the first subsequent ready/event transaction.
    settled0 = case refVBlankPending base of
      Just renderEnabled | coPolyReady out ->
        let c = refChip base
            p = chPoly c
            list = if renderEnabled && Poly.ppFlushReq p then Poly.renderOrder p else chRenderList c
            p' = fst (Poly.vblank p)
        in base { refChip = c { chPoly = p', chRenderList = list }, refVBlankPending = Nothing }
      _ -> base
    settled = if coPolyReady out
      then settled0 { refCountPrefixes = Seq.singleton (Poly.pipeStatus (chPoly (refChip settled0))) }
      else settled0
    modelEvents = if isJust (coGeoOffered out) && not (refOfferSeen old)
      then case Seq.viewl (refEvents settled) of
        GeVertex v ps Seq.:< rest -> GeVertex v (ps { psZeroDotW = refZeroDotPrev old }) Seq.<| rest
        _ -> refEvents settled
      else refEvents settled
    ch = refChip settled
    front = chFront ch
    geoStatus = (GS.geoScheduleStatus (refGeoSchedule settled) (coGeoCtlIdle out))
                  { gsBusy = refSwapWait settled }
    stable = coBusReady out || coCmdValid out
    actualDma = refActualDma old + fromEnum (coDma out)
    actualTaken = refActualTaken old + fromEnum (coCmdAccept out)
    actualChecks = refActualChecks old + fromEnum (coIrqCheck out)
    (pulseNow, futurePulses) = case Seq.viewl (refPulseSchedule old) of
      (due, irq, dma) Seq.:< rest | due == refCycle old -> (Just (irq, dma), rest)
      _ -> (Nothing, refPulseSchedule old)
    (levelNow, futureLevels) = Seq.spanl ((<= refCycle old) . fst) (refLevelSchedule old)
    physicalLevel = refFifoPhysical old + sum (fmap snd levelNow)
    fifoBits = (fromIntegral physicalLevel `shiftL` 16)
             .|. (if physicalLevel < 128 then 1 `shiftL` 25 else 0)
             .|. (if physicalLevel == 0 then 1 `shiftL` 26 else 0)
    check name ok = [name | not ok]
    headActual = fmap (\e -> CmdEntry (heCmd e) (heParam e)) (coCmdEntry out)
    checks =
      check "entry conservation" (refIssued old == refTaken old + outstanding ch)
      ++ check "accepted-entry conservation" (refActualTaken old == refTaken old)
      ++ (if coCmdValid out then check "offered command/data differs from reference PIPE head"
            (headActual == Front.headEntry front) else [])
      ++ check "pending pack entry conservation"
           (length (filter id (refPendingIterations old)) == Seq.length (Front.gfStallQ front))
      ++ check "registered FIFO IRQ" (coIrq out == refIrq old)
      ++ check "IRQ-check pulse timing" (coIrqCheck out == isJust pulseNow)
      ++ check "DMA pulse timing" (coDma out == maybe False snd pulseNow)
      ++ check "physical FIFO level" ((coGxStat out .&. 0x07FF0000) == fifoBits)
      ++ check "dedicated FIFO_LT_HALF level" (coFifoLtHalf out == (physicalLevel < 128))
      ++ check "physical FIFO bounds" (physicalLevel >= 0 && physicalLevel <= 256)
      ++ check "render launch without a queued request" (not (coRenderLaunch out) || refRenderPending old)
      ++ case coGeoOffered out of
           Nothing -> []
           Just event -> case Seq.lookup 0 modelEvents of
             Just expected -> check "offered polygon event/data" (event == toHwEvent expected)
             Nothing -> ["offered polygon event without an independent expected event"]
      ++ (if stable then
          check "FIFO occupancy/threshold/IRQ mode" ((coGxStat out .&. 0xC7FF0000) ==
                   (Front.gxStat geoStatus front .&. 0xC7FF0000))
          ++ check "ARM9 stall" (coStall out == chipStalled ch)
          ++ check "FIFO IRQ-check conservation" (actualChecks == refChecks old)
          ++ check ("DMA pulse conservation: actual=" ++ show actualDma ++ " expected=" ++ show (refDma old))
                   (actualDma == refDma old)
          else [])
      ++ (if stable && not (coGeomBusy out) then
          check "settled GXSTAT" (coGxStat out == Front.gxStat geoStatus front)
          ++ check "settled swap-pending" (coSwapPending out == refSwapWait settled)
          ++ check "undelivered expected geometry event at quiescence" (Seq.null (refEvents old))
          else [])
    irqNext
      | ciIfWrite inp = Front.fifoIrqCond (Front.gfIrqMode front) (fromIntegral physicalLevel)
      | Just (irq, _) <- pulseNow = irq
      | otherwise = refIrq old
    offeredSwap = isJust (coGeoOffered out) && case Seq.lookup 0 (refEvents old) of
      Just (GeSwap _) -> True
      _ -> False
    r0 = settled { refActualDma = actualDma, refActualTaken = actualTaken
                 , refActualChecks = actualChecks, refIrq = irqNext
                 , refSwapWait = refSwapWait settled || offeredSwap
                 , refCycle = refCycle old + 1, refPulseSchedule = futurePulses
                 , refReadPending = wantRead, refEvents = modelEvents
                 , refZeroDotPrev = Front.zeroDotW front
                 , refOfferSeen = isJust (coGeoOffered out) && not (isJust (coGeoTransfer out))
                 , refFifoPhysical = physicalLevel, refLevelSchedule = futureLevels }
    accepted = isJust (ciBus inp) && coBusReady out
    wantRead = case ciBus inp of
      Just b | accepted, let a = busAccess b, not (acWrite a) ->
        let fi = (chipFrontIn ch) { Front.fiGeo = geoStatus }
            isCount = (acAddr a .&. 0xFFFFFFFC) == 0x04000604
            candidates = if isCount
              then [(ps, Just i) | (i, ps) <- zip [0..] (foldr (:) [] (refCountPrefixes settled))]
              else [(Front.fiPipe fi, Nothing)]
        in Just [(lanePlace a (Front.mmioRead (fi { Front.fiPipe = ps }) (acSize a) (acAddr a) front), prefix)
                | (ps, prefix) <- candidates]
      _ -> Nothing
    busAction = case ciBus inp of
      Just b | accepted, let a = busAccess b, acWrite a ->
        Front.writeAction (Front.gfGeomEn front) (Front.gfRendEn front) (acSize a) (acAddr a) (acValue a)
      _ -> Front.WaNone
    rBus = case ciBus inp of
      Just b | accepted, let a = busAccess b, acWrite a ->
        let ch' = chipWrite (acSize a) (acAddr a) (acValue a) ch
            added = outstanding ch' - outstanding ch
            action = busAction
            modeCheck = case action of Front.WaGxStat _ (Just _) -> 1; _ -> 0
            (pending, levels) = case action of
              Front.WaGxFifo value ->
                let (_, left, changes) = runIterations (refCycle old + 2)
                      (Seq.length (Front.gfPipe front)) physicalLevel (packIterations value (Front.gfPack front))
                in (left, changes)
              Front.WaDirect _ _ ->
                let (_, left, changes) = runIterations (refCycle old + 1)
                      (Seq.length (Front.gfPipe front)) physicalLevel [True]
                in (left, changes)
              _ -> (refPendingIterations r0, Seq.empty)
            pulses = if modeCheck == 0 then refPulseSchedule r0
                     else refPulseSchedule r0 Seq.|> (refCycle old + 1, Front.gfIrq (chFront ch'), False)
        in r0 { refChip = ch', refIssued = refIssued old + added
              , refChecks = refChecks old + modeCheck, refPulseSchedule = pulses
              , refPendingIterations = pending, refLevelSchedule = refLevelSchedule r0 Seq.>< levels }
      _ -> r0
    -- Geometry's swap wait only clears if no output event was pending when
    -- VBlank arrived. The polygon engine has its own later VBlank boundary.
    rVBlank = if ciVBlank inp && Front.gfGeomEn front
      then rBus { refChip = (refChip rBus) { chFront = Front.vblank (chFront (refChip rBus)) }
                , refVBlankPending = Just (Front.gfRendEn front)
                , refCountPrefixes = if Poly.ppFlushReq (chPoly (refChip rBus))
                    then refCountPrefixes rBus Seq.|> PipeStatus 0 0 else refCountPrefixes rBus
                , refSwapWait = if isJust (coGeoOffered out) then refSwapWait rBus else False }
      else rBus
    (rEvent, eventErrors) = case coGeoTransfer out of
      Nothing -> (rVBlank, [])
      Just actual -> case Seq.viewl (refEvents rVBlank) of
        Seq.EmptyL -> (rVBlank, ["unexpected polygon event: " ++ show actual])
        expected Seq.:< rest ->
          let c = refChip rVBlank
              p = Poly.step (chPoly c) expected
              overflow = Poly.pipeOverflow p
              f = if overflow then Front.setDispCntFlags False True (chFront c) else chFront c
              c' = c { chPoly = if overflow then Poly.clearOverflow p else p, chFront = f }
          in (rVBlank { refChip = c', refEvents = rest
                     , refCountPrefixes = (refCountPrefixes rVBlank Seq.|> Poly.pipeStatus (chPoly c'))
                         Seq.>< (if refVBlankPending rVBlank /= Nothing && Poly.ppFlushReq (chPoly c')
                                   then Seq.singleton (PipeStatus 0 0) else Seq.empty)
                     , refSwapWait = case expected of GeSwap _ -> True; _ -> refSwapWait rVBlank },
              ["polygon event/data mismatch: actual=" ++ show actual ++ " expected=" ++ show (toHwEvent expected)
              | actual /= toHwEvent expected])
    (rPop, popErrors, completedCommand) = if not (coCmdAccept out) then (rEvent, [], Nothing) else
      let c = refChip rEvent in case Front.popEntry (chFront c) of
        Nothing -> (rEvent, ["hardware accepted a command from an empty reference PIPE"], Nothing)
        Just (expected, f, fx) ->
          let (command, params) = gatherEntry expected (chParams c)
              c0 = c { chFront = f, chParams = params }
              (c1, events) = case command of
                Nothing -> (c0, [])
                Just gi -> let (g, evs) = Geo.step (chGeo c0) gi in (c0 { chGeo = g }, evs)
              errors = ["accepted command/data mismatch: actual=" ++ show headActual ++ " expected=" ++ show expected
                       | headActual /= Just expected]
              completed = case command of
                Just (Geo.GeoCmd opcode _) -> Just (opcode, Geo.geoStatus (chGeo c1))
                _ -> Nothing
              moves = min 2 (Seq.length (Front.gfFifo (chFront c)))
              (resumeClocks, pending, resumeLevels) = if Front.pfRefill fx
                then runIterations (refCycle old + 2 + moves)
                      (Seq.length (Front.gfPipe (chFront c)) - 1 + moves)
                      (Seq.length (Front.gfFifo (chFront c)) - moves) (refPendingIterations rEvent)
                else (0, refPendingIterations rEvent, Seq.empty)
              refillLevels = if Front.pfRefill fx
                then Seq.fromList [(refCycle old + 2 + k, -1) | k <- [0 .. moves - 1]]
                else Seq.empty
              pulses = if Front.pfRefill fx
                then refPulseSchedule rEvent Seq.|>
                     (refCycle old + 2 + moves + resumeClocks, Front.gfIrq f, Front.pfDma fx)
                else refPulseSchedule rEvent
          in (rEvent { refChip = c1, refEvents = refEvents rEvent Seq.>< Seq.fromList events
                     , refTaken = refTaken rEvent + 1, refDma = refDma rEvent + fromEnum (Front.pfDma fx)
                     , refChecks = refChecks rEvent + fromEnum (Front.pfRefill fx)
                     , refPulseSchedule = pulses, refPendingIterations = pending
                     , refLevelSchedule = refLevelSchedule rEvent Seq.>< refillLevels Seq.>< resumeLevels }, errors, completed)
    ack = case busAction of Front.WaGxStat clear _ -> clear; _ -> False
    (geoSchedule', geoErrors) = GS.stepGeoSchedule (refGeoSchedule old) completedCommand
      (coGeoComplete out) (coGeoCtlIdle out) (not (coPolyReady out)) ack
    c0 = refChip rPop
    c1 = maybe c0 (\(g, r) -> chipPower g r c0) (ciPower inp)
    c2 = maybe c1 (\(x, m) -> chipXPos x m c1) (ciXPos inp)
    c3 = if ciIfWrite inp then chipIrqCheck c2 else c2
    c4 = if ciAbortFrame inp then chipAbortFrame c3 else c3
    c5 = if ciFrameEnd inp then chipFrameEnd c4 else c4
    c6 = if coRenderLaunch out then chipRenderStart tex c5 else c5
    rSide = rPop { refChip = c6, refGeoSchedule = geoSchedule'
                , refRenderPending = (refRenderPending rPop || ciRenderStart inp) && not (coRenderLaunch out) }
