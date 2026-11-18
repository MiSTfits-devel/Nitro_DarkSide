-- Compare the partial Haskell trace renderer with independently emitted
-- melonDS framebuffer records. Unsupported scenes fail, not pass as matches.
module Main (main) where

import Control.Exception (finally)
import Control.Monad (forM_, unless, when)
import Data.IORef
import qualified Data.IntMap.Strict as M
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import Data.Word (Word32)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO (Handle, IOMode(WriteMode), hClose, hPutStr, hPutStrLn, openFile)
import Text.Printf (printf)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Text.Read (readMaybe)

import Nds.Gpu2D.Trace
import Nds.Gpu2D.TraceRender

data Result = Result { count :: !Int, bad :: !Int, unsupported :: !Int, first :: !(Maybe String) }
empty :: Result
empty = Result 0 0 0 Nothing

main :: IO ()
main = do
  args <- getArgs
  (path, dumpDir, frames) <- case args of
    path:dir:ns | not (null ns), Just fs <- traverse readMaybe ns -> pure (path, dir, fs :: [Int])
    _ -> fail "usage: trace-compare TRACE DUMP-DIRECTORY FRAME..."
  createDirectoryIfMissing True dumpDir
  outputs <- traverse (\f -> do
    top <- openFile (dumpDir </> ("frame-" ++ show f ++ "-top.txt")) WriteMode
    bottom <- openFile (dumpDir </> ("frame-" ++ show f ++ "-bottom.txt")) WriteMode
    hPutStrLn top ("frame " ++ show f)
    hPutStrLn bottom ("frame " ++ show f)
    pure (f,(top,bottom))) frames
  pending <- newIORef M.empty
  renderer <- newIORef initialTraceRenderState
  results <- newIORef M.empty
  captureStats <- newIORef (0 :: Int, 0 :: Int, 0 :: Int)
  let onPhase p = do
        current <- readIORef renderer
        case phaseKind p of
          SpritePhase -> either fail (writeIORef renderer) (advanceTraceSprites current p)
          ScanlinePhase -> do
            let b = phaseRegisters p
                f = fromIntegral (word32At b 0)
                y = fromIntegral (word16At b 4)
                recorded3d = fmap (\bytes -> [word32At bytes (x*4) | x <- [0..255]]) (phase3D p)
            case renderTraceDisplays recorded3d current p of
              Left why -> fail ("frame " ++ show f ++ " line " ++ show y ++ ": " ++ why)
              Right (next,rendered) -> do
                writeIORef renderer next
                when (f `elem` frames) $ do
                  case lookup f outputs of
                    Just (top,bottom) -> writeLine top (fst rendered) >> writeLine bottom (snd rendered)
                    Nothing -> pure ()
                  modifyIORef' pending (M.insert (f*512+y) (Right rendered))
      onCapture event = do
        current <- readIORef renderer
        (next,writes) <- either fail pure (handleTraceCapture current event)
        writeIORef renderer next
        modifyIORef' captureStats $ \(lines', words', lifecycle) -> case event of
          CaptureBegin{} -> (lines'+1, words'+length writes, lifecycle)
          _ -> (lines', words', lifecycle+1)
        pure writes
      onOracle (CaptureStateOracle f y flags active) = do
        current <- readIORef renderer
        unless (traceCaptureStateMatches current flags active) $
          fail ("capture state mismatch frame " ++ show f ++ " line " ++ show y)
      onOracle (EngineOracle _) = pure ()
      onOracle (ScreenOracle o) = do
        let f = fromIntegral (oracleFrame o)
            y = fromIntegral (oracleY o)
        when (f `elem` frames) $ do
          table <- readIORef pending
          item <- maybe (fail "oracle without corresponding rendered scanline") pure (M.lookup (f*512+y) table)
          modifyIORef' pending (M.delete (f*512+y))
          let update old = case item of
                Left why -> old { count = count old + 1, unsupported = unsupported old + 1,
                                  first = first old `orElse` Just ("line " ++ show y ++ ": " ++ why) }
                Right (top,bottom) ->
                  let expectedTop = [word32At (oracleTop o) (4*x) | x <- [0..255]]
                      expectedBottom = [word32At (oracleBottom o) (4*x) | x <- [0..255]]
                      differences = [(screen,x,a,e) | (screen,actual,expected) <- [("top",top,expectedTop),("bottom",bottom,expectedBottom)],
                                       (x,a,e) <- zip3 [0 :: Int ..] actual expected, a /= e]
                      detail (screen,x,a,e) = "line " ++ show y ++ " " ++ screen ++ " x=" ++ show x ++ " actual=" ++ show a ++ " expected=" ++ show e
                  in old { count = count old + 1, bad = bad old + length differences,
                           first = first old `orElse` case differences of [] -> Nothing; x:_ -> Just (detail x) }
          modifyIORef' results (M.alter (Just . update . maybe empty id) f)
  replayTrace path onPhase onCapture onOracle `finally` mapM_ (\(_, (a,b)) -> hClose a >> hClose b) outputs
  rs <- readIORef results
  remaining <- readIORef pending
  (captureLines,captureWords,lifecycleEvents) <- readIORef captureStats
  putStrLn ("capture: lines=" ++ show captureLines ++ " writes=" ++ show captureWords ++
            " lifecycle_events=" ++ show lifecycleEvents)
  putStrLn "Partial independent melonDS trace diagnostic (unsupported lines fail):"
  forM_ frames $ \f -> do
    let v = M.findWithDefault empty f rs
    putStrLn ("frame " ++ show f ++ ": lines=" ++ show (count v) ++ " pixel_mismatches=" ++ show (bad v) ++
              " unsupported_lines=" ++ show (unsupported v) ++ maybe "" (" first=" ++) (first v))
  let failed = not (M.null remaining) || any (\f -> let v = M.findWithDefault empty f rs in count v /= 192 || bad v /= 0 || unsupported v /= 0) frames
  when failed exitFailure

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just a) _ = Just a
orElse Nothing b = b

writeLine :: Handle -> [Word32] -> IO ()
writeLine h = hPutStr h . concatMap (printf "%05x\n" . packed)
  where
    packed c = ((c `shiftR` 18) .&. 63) .|. (((c `shiftR` 10) .&. 63) `shiftL` 6) .|.
               (((c `shiftR` 2) .&. 63) `shiftL` 12)
