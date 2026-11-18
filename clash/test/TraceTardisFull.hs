-- | Whole-frame TARDIS measurement on v12: every line whose engine A BG0 is
-- not 3D, including OBJ, windows, mosaic and capture state, is keyed with
-- explicit sprite/window/capture tokens. 3D-active lines are excluded and
-- counted; no silent sampling.
module Main (main) where

import Control.Exception (evaluate)
import Data.Bits ((.&.), testBit)
import Data.IORef
import qualified Data.IntMap.Strict as M
import Data.List (foldl')
import Data.Maybe (fromMaybe)
import Data.Word (Word8)
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Text.Read (readMaybe)

import Nds.Gpu.Unified
import Nds.Gpu2D.Line
import Nds.Gpu2D.Speculate
import Nds.Gpu2D.Sprite (SpriteLine(..))
import Nds.Gpu2D.Trace
import Nds.Gpu2D.TraceRender
import Nds.Gpu2D.TraceState
import Nds.Gpu2D.Types

data LineInput = LineInput !EngineState ![Word8] ![Maybe LayerPixel] LineKeyTokens

main :: IO ()
main = do
  args <- getArgs
  (path, limit) <- case args of
    p:n:_ | Just k <- readMaybe n -> pure (p, k :: Int)
    [p] -> pure (p, 1000)
    _ -> fail "usage: trace-tardis-full TRACE [MAX-FRAME]"
  collected <- newIORef M.empty
  excluded <- newIORef (0 :: Int)
  st0 <- newIORef initialTraceRenderState
  replayTrace path (onPhase collected excluded st0 limit) (const (pure [])) (const (pure ()))
  fm <- readIORef collected
  ex <- readIORef excluded
  let frames = [ ls | (f, ls) <- M.toAscList fm, f <= limit, length ls == 192 ]
      lines' = 192 * length frames
  if null frames then fail "no eligible frames" else pure ()
  putStrLn ("eligible frames=" ++ show (length frames) ++ " excluded_3d_lines=" ++ show ex)
  t0 <- getCurrentTime
  let (specLines, specStats) = runSpec frames emptyCache
  _ <- evaluate (checksum specLines)
  t1 <- getCurrentTime
  let (refLines, refStats) = runRef frames
  _ <- evaluate (checksum refLines)
  t2 <- getCurrentTime
  let specTime = realToFrac (diffUTCTime t1 t0) * 1e9 :: Double
      refTime = realToFrac (diffUTCTime t2 t1) * 1e9 :: Double
      same = specLines == refLines
      showStats st = "hits=" ++ show (stHits st) ++ " misses=" ++ show (stMisses st) ++
                     " fixups=" ++ show (stFixups st) ++ " prefetch=" ++ show (stPrefetchRenders st) ++
                     " demand=" ++ show (stDemandRenders st) ++ " invalidated=" ++ show (stInvalidated st) ++
                     " total_renders=" ++ show (totalRenders st)
  putStrLn ("speculative: " ++ showStats specStats)
  putStrLn ("reference:   " ++ showStats refStats)
  putStrLn ("hit_rate=" ++ show (fromIntegral (stHits specStats) / fromIntegral lines'))
  putStrLn ("lines=" ++ show lines' ++ " output_equal=" ++ show same)
  putStrLn ("wall_ms: speculative=" ++ show (specTime/1e6) ++ " reference=" ++ show (refTime/1e6) ++
            " ns_per_line_spec=" ++ show (specTime/fromIntegral lines') ++
            " ns_per_line_ref=" ++ show (refTime/fromIntegral lines'))
  if not same then exitFailure else pure ()

renderFrameLine :: [LineInput] -> Int -> EngineState -> [Pixel]
renderFrameLine inputs y es = case drop y inputs of
  LineInput _ masks obj _ : _ ->
    map (fromMaybe (error "missing backdrop"))
        (unifiedLineWindowed (UnifiedInput es []) y masks obj)
  [] -> error "line outside frame"

runSpec :: [[LineInput]] -> Cache -> ([[[Pixel]]], Stats)
runSpec frames cache0 = go frames cache0 emptyStats []
  where
    go [] _ st acc = (reverse acc, st)
    go (ls:rest) c st acc =
      let out = onePassFrameWithTokens (renderFrameLine ls) (\y -> tokenAt ls y) (FrameInput c (map esOf ls))
          !_ = forceLines (foLines out)
      in go rest (foCache out) (add st (foStats out)) (foLines out : acc)
    esOf (LineInput es _ _ _) = es
    tokenAt ls y = case drop y ls of
      LineInput _ _ _ t : _ -> t
      [] -> noLineKeyTokens

runRef :: [[LineInput]] -> ([[[Pixel]]], Stats)
runRef frames = go frames emptyStats []
  where
    go [] st acc = (reverse acc, st)
    go (ls:rest) st acc =
      let out = referenceFrameWith (renderFrameLine ls)
                  (FrameInput emptyCache (map (\(LineInput es _ _ _) -> es) ls))
          !_ = forceLines (foLines out)
      in go rest (add st (foStats out)) (foLines out : acc)

forceLines :: [[Pixel]] -> ()
forceLines = foldl' (\() l -> foldl' (\() p -> pxRgb p `seq` pxLayer p `seq` ()) () l) ()

checksum :: [[[Pixel]]] -> Integer
checksum = foldl' (\a fr -> foldl' (\b l -> foldl' (\c p -> c + fromIntegral (pxRgb p .&. 0xFFFFFF)) b l) a fr) 0

add :: Stats -> Stats -> Stats
add a b = Stats (stHits a + stHits b) (stMisses a + stMisses b)
  (stFixups a + stFixups b) (stPrefetchRenders a + stPrefetchRenders b)
  (stDemandRenders a + stDemandRenders b) (stInvalidated a + stInvalidated b)

onPhase :: IORef (M.IntMap [LineInput]) -> IORef Int
        -> IORef TraceRenderState -> Int -> Phase -> IO ()
onPhase collected excluded stateRef limit p
  | phaseKind p /= ScanlinePhase = do
      s <- readIORef stateRef
      either (const (pure ())) (writeIORef stateRef) (advanceTraceSprites s p)
  | otherwise = do
      let r = phaseRegisters p
          f = fromIntegral (word32At r 0)
          y = fromIntegral (word16At r 4)
      s <- readIORef stateRef
      let recorded3d = fmap (\b -> [word32At b (x*4) | x <- [0..255]]) (phase3D p)
      case renderTraceDisplays recorded3d s p of
        Left _ -> pure ()
        Right (next, _) -> do
          writeIORef stateRef next
          if f > limit || y >= 192 then pure () else do
            let es = phaseEngine p 0
                disp = esDispCnt es
                three = testBit disp 3 && bgEnable disp 0
            if three
              then modifyIORef' excluded (+1)
              else do
                let (masks, obj, tokens) = traceComposeInputs next p 0
                modifyIORef' collected (M.insertWith (flip (++)) f
                  [LineInput es masks obj tokens])
