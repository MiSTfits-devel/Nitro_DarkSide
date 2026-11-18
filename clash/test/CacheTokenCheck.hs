-- | Independent M5 token-key check: mutates each composed-line input outside
-- EngineState (sprite buffer, window mask/coords, capture flags, display
-- state, 3D line) on a real trace phase and requires the corresponding cache
-- token and LineKey to change. Identical inputs must keep the same key.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import qualified Data.ByteString as B
import Data.Bits ((.&.), (.|.), shiftL)
import Data.IORef
import Data.List (nub)
import Data.Maybe (fromMaybe, isNothing)
import Data.Word
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu2D.Trace
import Nds.Gpu2D.TraceRender
import Nds.Gpu2D.TraceState (phaseEngine)
import Nds.Gpu2D.Types

setB :: Int -> Word8 -> B.ByteString -> B.ByteString
setB i v b = B.take i b <> B.singleton v <> B.drop (i + 1) b

main :: IO ()
main = do
  args <- getArgs
  path <- case args of [p] -> pure p; _ -> putStrLn "usage: cache-token-check <trace.nsd2>" >> exitFailure
  stRef <- newIORef initialTraceRenderState
  pickedRef <- newIORef (Nothing :: Maybe (Phase, TraceRenderState))
  spriteToksRef <- newIORef ([] :: [Maybe Word32])
  result <- try (replayTraceGeometry path
    (\_ _ _ -> pure ())
    (\p -> do
        st <- readIORef stRef
        case phaseKind p of
          SpritePhase -> case advanceTraceSprites st p of
            Left _ -> pure ()
            Right st' -> writeIORef stRef st'
          ScanlinePhase -> case renderTraceDisplays (Just (replicate 256 0)) st p of
            Left _ -> pure ()
            Right (st', _) -> do
              writeIORef stRef st'
              let (_, _, toks) = traceComposeInputs st' p 0
              modifyIORef spriteToksRef (lktSprite toks :)
              picked <- readIORef pickedRef
              when (isNothing picked) $ writeIORef pickedRef (Just (p, st'))
    )
    (const (pure []))
    (const (pure ()))) :: IO (Either SomeException ())
  case result of
    Left e -> putStrLn ("cache-token-check: replay failed: " ++ show e) >> exitFailure
    Right () -> pure ()
  picked <- readIORef pickedRef
  case picked of
    Nothing -> putStrLn "cache-token-check: no scanline phase" >> exitFailure
    Just (p0, st) -> do
      spriteToks <- readIORef spriteToksRef
      let y0 = fromIntegral (word16At (phaseRegisters p0) 4)
          es = phaseEngine p0 0
          baseT = traceComposeInputs st p0 0
          toksOf p = let (_, _, t) = traceComposeInputs st p 0 in t
          (_, _, base) = baseT
          keyOf t = lineKeyTok t es y0
          regs = phaseRegisters p0
          -- Window: enable WIN0, set coords and inside mask.
          winSetup = foldl (\b (i, v) -> setB i v b) regs
            [ (293, B.index regs 293 .|. 0x20)  -- DISPCNT bit13
            , (292 + 64, 10), (292 + 65, 200)   -- WIN0 x1,x2
            , (292 + 66, 0), (292 + 67, 192)    -- WIN0 y1,y2
            , (292 + 72, 0x21)                  -- WinCnt0: BG0+effect
            , (292 + 76, 1)                     -- Win0Active vertical inside
            ]
          pWin = p0 { phaseRegisters = winSetup }
          regsWin2 = setB (292 + 72) 0x01 winSetup
          pWin2 = p0 { phaseRegisters = regsWin2 }
          -- Display: screens enable/swap, brightness, FIFO buffer.
          pScreen = p0 { phaseRegisters = setB 8 0 regs }   -- ScreensEnabled
          pSwap = p0 { phaseRegisters = setB 9 1 regs }
          pBright = p0 { phaseRegisters = setB 12 (B.index regs 12 + 1) regs }
          pFifo = p0 { phaseDisplayState = fmap (\d -> d
                     { displayFIFOBuffer = B.replicate 512 0x5A }) (phaseDisplayState p0) }
          -- 3D line identity.
          p3D = p0 { phase3D = fmap (setB 0 0xFF) (phase3D p0) }
          -- Capture flags: same state/sources, different CaptureCnt.
          mem = phaseMemory p0
          f = word32At regs 0
          mkCap cnt = handleTraceCapture st (CaptureLifecycleStart f (word16At regs 4) cnt 1)
          capTokens = [ fromMaybe 0 (lktCapture t)
                      | Right (stc, _) <- [mkCap c | c <- [0, 1 `shiftL` 18, 1 `shiftL` 20, (1 `shiftL` 18) .|. (1 `shiftL` 20)]]
                      , let (_, _, t) = traceComposeInputs stc p0 0 ]
          capDiff = length (nub capTokens) > 1
          spriteDiff = length (nub spriteToks) > 1
          spriteN = length (nub spriteToks)
          checks =
            [ ("window coordinates/enable change window token", lktWindow (toksOf pWin) /= lktWindow base)
            , ("window mask byte changes window token", lktWindow (toksOf pWin2) /= lktWindow (toksOf pWin))
            , ("window token changes key", keyOf (toksOf pWin2) /= keyOf base)
            , ("screens-enabled changes display token", lktDisplay (toksOf pScreen) /= lktDisplay base)
            , ("screen swap changes display token", lktDisplay (toksOf pSwap) /= lktDisplay base)
            , ("master brightness changes display token", lktDisplay (toksOf pBright) /= lktDisplay base)
            , ("display FIFO changes display token", lktDisplay (toksOf pFifo) /= lktDisplay base)
            , ("display token changes key", keyOf (toksOf pFifo) /= keyOf base)
            , ("sprite buffer token varies with sprite input", spriteDiff)
            , ("capture flags change capture token", capDiff)
            , ("identical inputs keep token/key",
               toksOf p0 == base && keyOf base == lineKeyTok base es y0)
            , ("3D line changes 3D token", maybe True (\_ -> lkt3D (toksOf p3D) /= lkt3D base) (phase3D p0))
            ]
          failures = [ n | (n, ok) <- checks, not ok ]
      mapM_ (putStrLn . ("FAIL " ++)) failures
      putStrLn ("spriteTokens distinct=" ++ show spriteN ++ " captureTokens=" ++ show capTokens)
      putStrLn ("cache-token-check: " ++ show (length checks) ++ " checks, "
                ++ show (length failures) ++ " failures"
                ++ " (phase frame " ++ show (word32At regs 0) ++ " line " ++ show y0 ++ ")")
      when (not (null failures)) exitFailure
