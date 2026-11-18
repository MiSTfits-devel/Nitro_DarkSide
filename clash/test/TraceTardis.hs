-- | Real-trace TARDIS measurement. Frames are eligible only when every line
-- is fully described by the line model's EngineState and has no OBJ, window
-- or 3D input; those inputs are not part of LineKey, so including such lines
-- would risk stale reuse. Everything else is counted and reported as
-- excluded rather than silently measured.
module Main (main) where

import Control.Exception (evaluate)
import Data.Bits ((.&.), testBit)
import Data.IORef
import qualified Data.IntMap.Strict as M
import Data.List (foldl')
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Text.Read (readMaybe)

import Nds.Gpu2D.Line
import Nds.Gpu2D.Speculate
import Nds.Gpu2D.Trace
import Nds.Gpu2D.TraceState
import Nds.Gpu2D.Types

main :: IO ()
main = do
  args <- getArgs
  (path, limit) <- case args of
    p:n:_ | Just k <- readMaybe n -> pure (p, k :: Int)
    [p] -> pure (p, 1000)
    _ -> fail "usage: trace-tardis TRACE [MAX-FRAME]"
  collected <- newIORef M.empty
  excluded <- newIORef (0 :: Int, 0 :: Int, 0 :: Int)
  replayTrace path (onPhase collected excluded limit) (const (pure [])) (const (pure ()))
  framesMap <- readIORef collected
  (exObj, exWindow, ex3D) <- readIORef excluded
  let frames = [ ss | (f, ss) <- M.toAscList framesMap, f <= limit, length ss == 192 ]
  if null frames then fail "no fully 2D frames in trace" else pure ()
  putStrLn ("eligible frames=" ++ show (length frames) ++
            " excluded_lines: obj=" ++ show exObj ++
            " window=" ++ show exWindow ++ " 3d=" ++ show ex3D)
  t0 <- getCurrentTime
  let (specLines, specStats) = runSpec frames emptyCache
  _ <- evaluate (checksum specLines)
  t1 <- getCurrentTime
  let (refLines, refStats) = runRef frames
  _ <- evaluate (checksum refLines)
  t2 <- getCurrentTime
  let lines' = 192 * length frames
      specTime = realToFrac (diffUTCTime t1 t0) * 1e9 :: Double
      refTime = realToFrac (diffUTCTime t2 t1) * 1e9 :: Double
      fmtStats st = "hits=" ++ show (stHits st) ++ " misses=" ++ show (stMisses st) ++
                    " fixups=" ++ show (stFixups st) ++
                    " prefetch=" ++ show (stPrefetchRenders st) ++
                    " demand=" ++ show (stDemandRenders st) ++
                    " invalidated=" ++ show (stInvalidated st) ++
                    " total_renders=" ++ show (totalRenders st)
      same = specLines == refLines
  putStrLn ("speculative: " ++ fmtStats specStats)
  putStrLn ("reference:   " ++ fmtStats refStats)
  putStrLn ("hit_rate=" ++ show (fromIntegral (stHits specStats) / fromIntegral lines'))
  putStrLn ("lines=" ++ show lines' ++ " output_equal=" ++ show same)
  putStrLn ("wall_ms: speculative=" ++ show (specTime / 1e6) ++
            " reference=" ++ show (refTime / 1e6) ++
            " ns_per_line_spec=" ++ show (specTime / fromIntegral lines') ++
            " ns_per_line_ref=" ++ show (refTime / fromIntegral lines'))
  if not same then exitFailure else pure ()

runSpec :: [[EngineState]] -> Cache -> ([[[Pixel]]], Stats)
runSpec frames cache0 = go frames cache0 emptyStats []
  where
    go [] _ st acc = (reverse acc, st)
    go (ss:rest) c st acc =
      let out = onePassFrame (FrameInput c ss)
          !_ = forceLines (foLines out)
      in go rest (foCache out) (add st (foStats out)) (foLines out : acc)

runRef :: [[EngineState]] -> ([[[Pixel]]], Stats)
runRef frames = go frames emptyStats []
  where
    go [] st acc = (reverse acc, st)
    go (ss:rest) st acc =
      let out = referenceFrame (FrameInput emptyCache ss)
          !_ = forceLines (foLines out)
      in go rest (add st (foStats out)) (foLines out : acc)

checksum :: [[[Pixel]]] -> Integer
checksum = foldl' (\acc frame -> foldl' (\a l -> foldl' (\b p -> b + fromIntegral (pxRgb p .&. 0xFFFFFF)) a l) acc frame) 0

forceLines :: [[Pixel]] -> ()
forceLines = foldl' (\() l -> foldl' (\() p -> pxRgb p `seq` pxLayer p `seq` ()) () l) ()

add :: Stats -> Stats -> Stats
add a b = Stats (stHits a + stHits b) (stMisses a + stMisses b)
  (stFixups a + stFixups b) (stPrefetchRenders a + stPrefetchRenders b)
  (stDemandRenders a + stDemandRenders b) (stInvalidated a + stInvalidated b)

onPhase :: IORef (M.IntMap [EngineState]) -> IORef (Int,Int,Int) -> Int -> Phase -> IO ()
onPhase collected excluded limit p
  | phaseKind p /= ScanlinePhase = pure ()
  | otherwise = do
      let r = phaseRegisters p
          f = fromIntegral (word32At r 0)
          y = fromIntegral (word16At r 4)
      if f > limit || y >= 192 then pure () else do
        let es = phaseEngine p 0
            disp = esDispCnt es
            obj = objEnable disp
            win = disp .&. 0xe000 /= 0
            three = testBit disp 3 && bgEnable disp 0
            reason | obj = 0 | win = 1 | three = 2 | otherwise = -1
        if reason < 0
          then modifyIORef' collected (M.insertWith (flip (++)) f [es])
          else modifyIORef' excluded (\(a,b,c) -> case reason of
                 0 -> (a+1,b,c)
                 1 -> (a,b+1,c)
                 _ -> (a,b,c+1))
