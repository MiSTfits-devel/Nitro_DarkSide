-- | Transaction-level GXSTAT geometry status reference.  The accepted
-- commands and their resulting states come from the independent geometry
-- model; the two progress inputs are control-phase observations, never the
-- GXSTAT, busy, or IRQ outputs being checked.
--
-- This checks status coherence with the command protocol, not exact engine
-- latency.  In particular BOX_TEST's clipping work is variable: control-idle
-- marks its completion, while a bounded watchdog catches lack of progress.
module ChipHwGeoSchedule
  ( GeoSchedule, initialGeoSchedule, geoScheduleStatus, stepGeoSchedule ) where

import Data.Word (Word8)

import Nds.Gpu3D.Types (GeoStatus (..))

-- A running test or push/pop, with BOX_TEST's independently computed result.
-- The age also distinguishes the mandatory first running cycle from a later
-- control-idle completion.
data Active = Active
  { activeCommand :: !Word8
  , activeBoxResult :: !Bool
  , activeBoxStarted :: !Bool
  , activeAge :: !Int
  }

data GeoSchedule = GeoSchedule
  { scheduleStatus :: !GeoStatus
  , scheduleActive :: !(Maybe Active)
  , scheduleWaiting :: !Bool
  , scheduleQuietAge :: !Int
  }

initialGeoSchedule :: GeoSchedule
initialGeoSchedule = GeoSchedule (GeoStatus False False 0 False False False False) Nothing False 0

-- | Expected status as this cycle begins.  Control idle is a transaction
-- phase boundary; it is deliberately distinct from full completion, since a
-- final multiply tag can remain after the test/stack busy bits have dropped.
-- The caller supplies the independently tracked swap wait as gsBusy.
geoScheduleStatus :: GeoSchedule -> Bool -> GeoStatus
geoScheduleStatus s ctlIdle = base
  { gsTestBusy = running && command >= 0x70 && command <= 0x72
  , gsStackBusy = running && (command == 0x11 || command == 0x12)
  , gsBoxResult = case scheduleActive s of
      Just a | ctlIdle && activeCommand a == 0x70 -> activeBoxResult a
      _ -> gsBoxResult base
  }
  where
    base = scheduleStatus s
    running = case scheduleActive s of Just _ -> not ctlIdle; Nothing -> False
    command = maybe 0 activeCommand (scheduleActive s)

-- | Advance one clock.  The optional pair is the independently gathered
-- expected command and its model status after execution.  @complete@ means
-- control idle with no outstanding arithmetic tag or held event; @ctlIdle@
-- is the earlier control phase boundary.  @polygonBusy@ is the polygon
-- transaction backpressure seen by BOX_TEST's start, and @ack@ is the accepted
-- GXSTAT stack acknowledge.  Inputs refer to the current cycle; returned state
-- is for the next cycle.
stepGeoSchedule
  :: GeoSchedule -> Maybe (Word8, GeoStatus) -> Bool -> Bool -> Bool -> Bool
  -> (GeoSchedule, [String])
stepGeoSchedule s command complete ctlIdle polygonBusy ack =
  (GeoSchedule statusFinal activeFinal waitingFinal quietAgeFinal, errors)
  where
    current = geoScheduleStatus s ctlIdle
    previous = scheduleActive s
    finished = case previous of Just _ -> ctlIdle; Nothing -> False
    errors =
      ["geometry completion while control is not idle" | complete && not ctlIdle]
      ++ ["geometry command failed to enter its running phase"
         | Just a <- [previous], activeAge a == 0, ctlIdle]
      ++ ["geometry command exceeded the progress bound"
         | Just a <- [previous], activeAge a == progressBound, not ctlIdle]
      ++ ["geometry transaction exceeded the completion bound"
         | scheduleWaiting s, scheduleQuietAge s == progressBound, not complete]
      ++ ["geometry accepted another completed command before the previous phase ended"
         | Just _ <- [command], Just _ <- [previous], not ctlIdle]
    progressed = case previous of
      Just a | not finished -> Just a
        { activeBoxStarted = activeBoxStarted a || (activeCommand a == 0x70 && not polygonBusy)
        , activeAge = activeAge a + 1 }
      _ -> Nothing
    -- BOX_TEST clears the previous result when its CStart is admitted by the
    -- polygon pipeline, not when its final parameter is accepted.
    cleared = case previous of
      Just a | not finished && activeCommand a == 0x70
             && not (activeBoxStarted a) && not polygonBusy -> current { gsBoxResult = False }
      _ -> current
    (updated, activeFinal) = case command of
      Nothing -> (cleared, progressed)
      Just (op, result) ->
        let stack = if op >= 0x11 && op <= 0x14
              then cleared { gsPosStack = gsPosStack result, gsProjStack = gsProjStack result
                           , gsStackError = gsStackError result }
              else cleared
            active = if op == 0x11 || op == 0x12 || (op >= 0x70 && op <= 0x72)
              then Just (Active op (gsBoxResult result) False 0)
              else progressed
        in (stack, active)
    -- Acknowledge is applied after command bookkeeping on the same edge.
    statusFinal = if ack then updated { gsProjStack = False, gsStackError = False } else updated
    -- Consecutive commands may overlap a trailing arithmetic tag, so bound
    -- full completion from the last accepted command rather than from each.
    (waitingFinal, quietAgeFinal) = case command of
      Just _ -> (True, 0)
      Nothing | complete -> (False, 0)
              | scheduleWaiting s -> (True, scheduleQuietAge s + 1)
              | otherwise -> (False, 0)

-- The whole-chip gate has independent phase/transaction timeouts as well.
-- This bound permits long, backpressured polygon work without silently accepting
-- a geometry transaction that never completes.
progressBound :: Int
progressBound = 1000000
