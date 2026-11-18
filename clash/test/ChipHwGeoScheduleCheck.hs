-- | Focused transaction-boundary checks for ChipHwGeoSchedule.
module Main (main) where

import Control.Monad (unless)

import ChipHwGeoSchedule
import Nds.Gpu3D.Types (GeoStatus (..))

check :: String -> Bool -> IO ()
check name ok = unless ok (error name)

advance :: GeoSchedule -> Maybe (Word, GeoStatus) -> Bool -> Bool -> Bool -> Bool -> GeoSchedule
advance s cmd complete idle polyBusy ack =
  let (s', errors) = stepGeoSchedule s (fmap (\(op, st) -> (fromIntegral op, st)) cmd)
                       complete idle polyBusy ack
  in if null errors then s' else error (show errors)

main :: IO ()
main = do
  let initial = geoScheduleStatus initialGeoSchedule True
      pushed = initial { gsProjStack = True, gsStackError = True }
      push = advance initialGeoSchedule (Just (0x11, pushed)) True True False False
      busy = geoScheduleStatus push False
      acked = advance push Nothing False False False True
      idleWithTag = geoScheduleStatus acked True
  check "push commits stack fields at acceptance" (gsProjStack busy && gsStackError busy && gsStackBusy busy)
  check "ack clears error and projection pointer during a push"
    (let st = geoScheduleStatus acked False in not (gsProjStack st) && not (gsStackError st) && gsStackBusy st)
  check "stack busy ends at control idle, before full completion" (not (gsStackBusy idleWithTag))

  let vec = advance initialGeoSchedule (Just (0x72, initial)) True True False False
  check "vector test busy while running" (gsTestBusy (geoScheduleStatus vec False))
  check "vector test busy ends before arithmetic tag drains" (not (gsTestBusy (geoScheduleStatus vec True)))

  let predictedHit = initial { gsBoxResult = True }
      box0 = advance initialGeoSchedule (Just (0x70, predictedHit)) True True False False
      box1 = advance box0 Nothing False False True False
      box2 = advance box1 Nothing False False False False
      boxDone = geoScheduleStatus box2 True
      finished = advance box2 Nothing True True False False
      boxAgain = advance finished (Just (0x70, initial)) True True False False
      held = advance boxAgain Nothing False False True False
      started = advance held Nothing False False False False
  check "box result commits at control completion" (gsBoxResult boxDone)
  check "box result survives a stalled next box" (gsBoxResult (geoScheduleStatus held False))
  check "box result clears after admitted start" (not (gsBoxResult (geoScheduleStatus started False)))
  check "box busy remains asserted while stalled" (gsTestBusy (geoScheduleStatus held False))

  let (_, failedStart) = stepGeoSchedule vec Nothing True True False False
      (_, badComplete) = stepGeoSchedule initialGeoSchedule Nothing True False False False
  check "missing running phase is rejected" (not (null failedStart))
  check "incoherent transaction completion is rejected" (not (null badComplete))
  putStrLn "chip geometry status schedule checks passed"
