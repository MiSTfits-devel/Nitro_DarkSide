-- | Independent composed-scanline gate: replays a real NSD2 v10 trace emitted
-- by the production melonDS phase emitter and compares the current Haskell
-- trace/line renderer's top/bottom lines with the production scanout
-- framebuffer records. Trace records supply only inputs; expected pixels come
-- from melonDS's own compose/expand/brightness/swap path.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import qualified Data.ByteString as B
import Data.Bits ((.&.))
import Data.IORef
import qualified Data.Map.Strict as M
import Data.Word (Word16, Word32)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu2D.Trace
import Nds.Gpu2D.TraceRender

phaseFrame :: Phase -> Word32
phaseFrame p = word32At (phaseRegisters p) 0

phaseLine :: Phase -> Word16
phaseLine p = word16At (phaseRegisters p) 4

words32 :: B.ByteString -> [Word32]
words32 b = [word32At b (4 * i) | i <- [0 .. 255]]

-- | Every differing pixel as (x, got, expected).
diffs :: [Word32] -> [Word32] -> [(Int, Word32, Word32)]
diffs got want = [ (i, g, w) | (i, g, w) <- zip3 [0 ..] got want, g /= w ]

readLabels :: Maybe FilePath -> IO (M.Map Word32 String)
readLabels Nothing = pure M.empty
readLabels (Just path) = do
  txt <- readFile path
  pure (M.fromList [ (read (head ws), unwords (drop 3 ws))
                   | l <- lines txt, let ws = words l, length ws >= 4 ])

main :: IO ()
main = do
  args <- getArgs
  path <- case args of
    [p] -> pure p
    [p, _] -> pure p
    _ -> putStrLn "usage: compose-check <trace.nsd2> [cases.txt]" >> exitFailure
  labels <- readLabels (case args of [_, c] -> Just c; _ -> Nothing)

  stateRef <- newIORef (Right initialTraceRenderState)
  outRef <- newIORef []
  errRef <- newIORef ([] :: [(Word32, Word16, String)])
  oracleRef <- newIORef (M.empty :: M.Map (Word32, Word16) (B.ByteString, B.ByteString))
  expectedRef <- newIORef (0 :: Int)
  skipRef <- newIORef ([] :: [(Word32, Word16)])

  let onPhase p = case phaseKind p of
        SpritePhase -> do
          st <- readIORef stateRef
          case st of
            Left _ -> pure ()
            Right s -> case advanceTraceSprites s p of
              Left e -> modifyIORef errRef ((phaseFrame p, phaseLine p, "sprite phase: " ++ e) :)
              Right s' -> writeIORef stateRef (Right s')
        ScanlinePhase -> do
          st <- readIORef stateRef
          let regs = phaseRegisters p
              badMode = (word32At regs 292 .&. 7) == 7
                     || (word32At regs 382 .&. 7) == 7
          case st of
            Left _ -> pure ()
            Right s -> case renderTraceDisplays Nothing s p of
              Left e
                | badMode -> do
                    modifyIORef expectedRef (+ 1)
                    modifyIORef skipRef ((phaseFrame p, phaseLine p) :)
                | otherwise -> modifyIORef errRef ((phaseFrame p, phaseLine p, "scanline: " ++ e) :)
              Right (s', (top, bot))
                | badMode -> do
                    writeIORef stateRef (Right s')
                    modifyIORef skipRef ((phaseFrame p, phaseLine p) :)
                    modifyIORef errRef ((phaseFrame p, phaseLine p,
                      "unsupported video mode 7 was approximated instead of failing explicitly") :)
                | otherwise -> do
                    writeIORef stateRef (Right s')
                    modifyIORef outRef ((phaseFrame p, phaseLine p, top, bot) :)
      onOracle ev = case ev of
        ScreenOracle ol ->
          modifyIORef oracleRef (M.insert (oracleFrame ol, oracleY ol)
                                   (oracleTop ol, oracleBottom ol))
        _ -> pure ()

  result <- try (replayTrace path onPhase (const (pure [])) onOracle)
            :: IO (Either SomeException ())
  case result of
    Left e -> putStrLn ("compose-check: replay failed: " ++ show e) >> exitFailure
    Right () -> pure ()

  outs <- reverse <$> readIORef outRef
  errs <- reverse <$> readIORef errRef
  oracle <- readIORef oracleRef
  expectedInvalid <- readIORef expectedRef
  skipped <- readIORef skipRef

  let compareLine (f, y, top, bot) =
        case M.lookup (f, y) oracle of
          Nothing -> ["frame " ++ show f ++ " line " ++ show y
                      ++ ": production framebuffer oracle missing"]
          Just (ot, ob) ->
            let dt = diffs top (words32 ot)
                db = diffs bot (words32 ob)
                label = "frame " ++ show f ++ " line " ++ show y
                        ++ maybe "" (\n -> " [" ++ n ++ "]") (M.lookup f labels)
            in [ label ++ " top first " ++ show (head dt)
                 ++ " (" ++ show (length dt) ++ "/256)"
               | not (null dt) ]
               ++ [ label ++ " bottom first " ++ show (head db)
                    ++ " (" ++ show (length db) ++ "/256)"
                  | not (null db) ]
      failures = concatMap compareLine outs
      missing = [ "frame " ++ show f ++ " line " ++ show y ++ ": no rendered line"
                | (f, y) <- M.keys oracle
                , (f, y) `notElem` skipped
                , not (any (\(f', y', _, _) -> f' == f && y' == y) outs) ]
      errText = [ "frame " ++ show f ++ " line " ++ show y ++ ": " ++ e
                | (f, y, e) <- errs ]
      allFailures = errText ++ failures ++ missing
  mapM_ putStrLn allFailures
  putStrLn ("compose-check: " ++ show (length outs) ++ " lines, "
            ++ show (length allFailures) ++ " failures"
            ++ " (oracle lines " ++ show (M.size oracle)
            ++ ", explicit invalid-mode failures " ++ show expectedInvalid
            ++ ", render errors " ++ show (length errText) ++ ")")
  when (not (null allFailures)) exitFailure
