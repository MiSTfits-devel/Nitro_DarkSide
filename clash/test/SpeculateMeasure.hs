-- | Real NTR trace M5 measurement, independent cache/exact modes.
--
-- Run separate invocations with @SPECULATE_MODE=cache@ and
-- @SPECULATE_MODE=exact@. Each invocation replays the trace from the opening
-- bytes through decode, Chip replay, sprite/capture preparation and forced
-- complete pixels, and reports the actual whole monotonic wall. Cache mode
-- builds tokens, prefetches and maintains the cache; exact mode skips
-- cache-only token work. Outputs are hashed only as a consistency check
-- between independent timing runs; hash equality is not an equality proof.
-- Exact line equality comes from the existing direct per-line gate and the
-- independent oracle gates. Component timers are diagnostics only, not an
-- end-to-end estimate. Recorded type3/type8 pixels are never used as renderer
-- inputs.
module Main (main) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM, forM_, when)
import qualified Data.ByteString as B
import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.), xor)
import Data.IORef
import Data.List (foldl', sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromMaybe)
import Data.Word
import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)

import Nds.Gpu2D.Line (objLine, renderReferenceLine)
import Nds.Gpu2D.Speculate
import Nds.Gpu2D.Sprite (SpriteLine (..), emptySpriteLine)
import Nds.Gpu2D.Trace
import Nds.Gpu2D.TraceRender
import Nds.Gpu2D.TraceState
import Nds.Gpu2D.Types
import Nds.Gpu.Unified (UnifiedInput (..), unifiedLineWindowed)
import Nds.Gpu3D.Texture (TexMem (..))
import Nds.Gpu3D.TraceReplay

data FrameLine = FrameLine
  { flY :: !Int
  , flState :: !EngineState
  , fl3D :: !(Maybe [Word32])
  , flMasks :: ![Word8]
  , flObj :: ![Maybe LayerPixel]
  , flTokens :: !LineKeyTokens
  }

data Mode = CacheMode | ExactMode
  deriving (Eq, Show)

data Measure = Measure
  { mCache :: !Cache
  , mStats :: !Stats
  , mCacheNs :: !Word64
  , mRefNs :: !Word64
  , mLines :: !Int
  , mHash :: !Word32
  }

emptyMeasure :: Measure
emptyMeasure = Measure emptyCache emptyStats 0 0 0 0

zeroTex :: TexMem
zeroTex = TexMem (const 0) (const 0)

forceFrame :: FrameOutput -> ()
forceFrame fo =
  foldl' (\() line -> foldl' (\() p -> pxRgb p `seq` pxLayer p `seq` ()) () line) ()
    (foLines fo)

forceOutput :: FrameOutput -> ()
forceOutput fo = forceFrame fo `seq` foCache fo `seq` foStats fo `seq` ()

forceWord32s :: [Word32] -> [Word32]
forceWord32s xs = foldl' (\() w -> w `seq` ()) () xs `seq` xs

forceWord8s :: [Word8] -> [Word8]
forceWord8s xs = foldl' (\() w -> w `seq` ()) () xs `seq` xs

forceObj :: [Maybe LayerPixel] -> [Maybe LayerPixel]
forceObj xs = foldl' (\() p -> p `seq` ()) () xs `seq` xs

forceTokens :: LineKeyTokens -> LineKeyTokens
forceTokens t =
  lkt3D t `seq` lktSprite t `seq` lktWindow t `seq` lktCapture t
    `seq` lktDisplay t `seq` t

layerCode :: Layer -> Word32
layerCode LObj = 16
layerCode L3D = 17
layerCode LBackdrop = 18
layerCode (Bg n) = fromIntegral n

hashFrameOutput :: FrameOutput -> Word32
hashFrameOutput fo = foldl' hashLine 2166136261 (foLines fo)
  where
    hashLine h line = foldl' hashPixel h line
    hashPixel h p = (h `xor` pxRgb p `xor` (layerCode (pxLayer p) `shiftL` 8)) * 16777619

main :: IO ()
main = do
  args <- getArgs
  (path, maxFrames) <- case args of
    [p] -> pure (p, maxBound :: Word32)
    [p, n] -> pure (p, read n)
    _ -> putStrLn "usage: SPECULATE_MODE=cache|exact speculate-measure <trace.nsd2> [maxFrames]" >> exitFailure
  modeName <- maybe "cache" id <$> lookupEnv "SPECULATE_MODE"
  mode <- case modeName of
    "cache" -> pure CacheMode
    "exact" -> pure ExactMode
    _ -> putStrLn "SPECULATE_MODE must be cache or exact" >> exitFailure
  modeRef <- newIORef mode

  chipRef <- newIORef (trace3DPower True True initialTrace3DState)
  trRef <- newIORef initialTraceRenderState
  renderErrRef <- newIORef (Nothing :: Maybe String)
  texRef <- newIORef zeroTex
  rawRef <- newIORef False
  measuresRef <- newIORef (M.fromList [(0, emptyMeasure), (1, emptyMeasure)])
  perEngineRef <- newIORef (M.empty :: M.Map Int (M.Map Int FrameLine))
  chipNsRef <- newIORef (0 :: Word64)
  chipLinesRef <- newIORef (0 :: Int)
  engineFramesRef <- newIORef (0 :: Int)
  prepNsRef <- newIORef (0 :: Word64)
  geomPrepNsRef <- newIORef (0 :: Word64)
  tokenPrepNsRef <- newIORef (0 :: Word64)
  replayNsRef <- newIORef (0 :: Word64)

  let applyEv st ev = case applyTrace3DEvent (zeroTex) ev st of
        Left _ -> pure st
        Right c -> pure c

      onGeom ts ev mem = do
        t0 <- getMonotonicTimeNSec
        st <- readIORef chipRef
        case ev of
          GeometryGxWrite f addr val width -> do
            writeIORef rawRef True
            applyEv st (Trace3DGxWrite f ts addr val width) >>= writeIORef chipRef
          GeometryCommand f cmd param -> do
            raw <- readIORef rawRef
            when (not raw) $
              applyEv st (Trace3DCommand f ts (fromIntegral cmd) param) >>= writeIORef chipRef
          GeometryRegister f addr val width -> do
            raw <- readIORef rawRef
            when (not raw) $
              applyEv st (Trace3DRegister f ts addr val width) >>= writeIORef chipRef
          GeometryFrameSummary _ _ _ _ -> pure ()
          GeometryPower _ geom rend _ ->
            writeIORef chipRef (trace3DPower geom rend st)
          GeometryXPos _ xpos ->
            writeIORef chipRef (trace3DXPos xpos 0xFFFF st)
          GeometryAbort _ active ->
            when active $ writeIORef chipRef (trace3DAbortFrame st)
          GeometryRenderStart _ _ xpos geom rend initial _vramcnt texMaps texPalMaps -> do
            let tex = trace3DTexMem mem texMaps texPalMaps
                st1 = trace3DXPos xpos 0xFFFF (trace3DPower geom rend st)
                st2 | initial = st1
                    | otherwise = trace3DRenderStart tex st1
            writeIORef texRef tex
            writeIORef chipRef st2
          GeometryFrameEnd _ _ -> writeIORef chipRef (trace3DFrameEnd st)
          GeometryVBlank _ _ -> writeIORef chipRef (trace3DVBlank st)
        t1 <- getMonotonicTimeNSec
        modifyIORef' prepNsRef (+ (t1 - t0))
        modifyIORef' geomPrepNsRef (+ (t1 - t0))

      onPhase p = case phaseKind p of
        SpritePhase -> do
          t0 <- getMonotonicTimeNSec
          trs <- readIORef trRef
          case advanceTraceSprites trs p of
            Left e -> writeIORef renderErrRef (Just ("sprite phase: " ++ e))
            Right trs' -> writeIORef trRef trs'
          t1 <- getMonotonicTimeNSec
          modifyIORef' prepNsRef (+ (t1 - t0))
        ScanlinePhase -> do
          tPrep0 <- getMonotonicTimeNSec
          tr <- readIORef chipRef
          trs <- readIORef trRef
          let f = word32At (phaseRegisters p) 0
              y = fromIntegral (word16At (phaseRegisters p) 4)
          ready <- if f < maxFrames
            then do
              let esA = phaseEngine p 0
                  uses3d = testBit (esDispCnt esA) 3
                           && (esDispCnt esA .&. (1 `shiftL` 8)) /= 0
              got <- if uses3d
                then do
                  t0 <- getMonotonicTimeNSec
                  ws <- evaluate (forceWord32s (either (const (replicate 256 0)) id (trace3DLine y tr)))
                  t1 <- getMonotonicTimeNSec
                  modifyIORef' chipNsRef (+ (t1 - t0))
                  modifyIORef' chipLinesRef (+ 1)
                  pure (Just ws)
                else pure Nothing
              case renderTraceDisplays (Just (fromMaybe (replicate 256 0) got)) trs p of
                Left e -> writeIORef renderErrRef (Just ("scanline " ++ show y ++ ": " ++ e)) >> pure []
                Right (trs', _) -> do
                  writeIORef trRef trs'
                  forM [0, 1] $ \n -> do
                    let es = phaseEngine p n
                        gotN = if n == 0 then got else Nothing
                    tTok0 <- getMonotonicTimeNSec
                    let (masks, obj, toks) = traceComposeInputs trs' p n
                    masks' <- evaluate (forceWord8s masks)
                    obj' <- evaluate (forceObj obj)
                    toks' <- if mode == CacheMode
                      then evaluate (forceTokens toks)
                      else pure noLineKeyTokens
                    tTok1 <- getMonotonicTimeNSec
                    modifyIORef' tokenPrepNsRef (+ (tTok1 - tTok0))
                    let fl = FrameLine y es gotN masks' obj' toks'
                    per <- readIORef perEngineRef
                    let m = M.insert y fl (M.findWithDefault M.empty n per)
                    writeIORef perEngineRef (M.insert n m per)
                    pure (if M.size m == 192 then Just (n, m) else Nothing)
            else pure []
          tPrep1 <- getMonotonicTimeNSec
          modifyIORef' prepNsRef (+ (tPrep1 - tPrep0))
          forM_ (catMaybes ready) (uncurry measureEngine)

      measureEngine n m = do
        let ls = [ l | (_, l) <- sortOn fst (M.toList m) ]
            states = map flState ls
            lineMap = M.fromList [ (flY l, l) | l <- ls ]
            tok y = maybe noLineKeyTokens flTokens (M.lookup y lineMap)
            render y es = case M.lookup y lineMap of
              Nothing -> renderReferenceLine es y
              Just l ->
                let pixels3d = maybe [] (\ws -> zipWith (\x c -> (x, y, c)) [0 ..] ws) (fl3D l)
                in map (fromMaybe (Pixel 0 LBackdrop))
                     (unifiedLineWindowed (UnifiedInput es pixels3d) y (flMasks l) (flObj l))
            fi cache = FrameInput cache states
        ms <- readIORef measuresRef
        let old = M.findWithDefault emptyMeasure n ms
        runMode <- readIORef modeRef
        new <- case runMode of
          CacheMode -> do
            (tA, outCache) <- timed (onePassFrameWithTokens render tok (fi (mCache old)))
            let st' = statAdd (mStats old) (foStats outCache)
                h = mHash old * 16777619 `xor` hashFrameOutput outCache
            pure old { mCache = foCache outCache, mStats = st'
                     , mCacheNs = mCacheNs old + tA
                     , mLines = mLines old + length states, mHash = h }
          ExactMode -> do
            (tB, outRef) <- timed (referenceFrameWith render (fi emptyCache))
            let h = mHash old * 16777619 `xor` hashFrameOutput outRef
            pure old { mRefNs = mRefNs old + tB
                     , mLines = mLines old + length states, mHash = h }
        modifyIORef measuresRef (M.insert n new)
        modifyIORef engineFramesRef (+ 1)
        per <- readIORef perEngineRef
        writeIORef perEngineRef (M.insert n M.empty per)

      timed act = do
        t0 <- getMonotonicTimeNSec
        let out = act
        _ <- evaluate (forceOutput out)
        t1 <- getMonotonicTimeNSec
        pure (t1 - t0, out)

  tReplay0 <- getMonotonicTimeNSec
  r <- try (replayTraceGeometry path onGeom onPhase (const (pure [])) (const (pure ())))
         :: IO (Either SomeException ())
  tReplay1 <- getMonotonicTimeNSec
  writeIORef replayNsRef (tReplay1 - tReplay0)
  case r of
    Left e -> putStrLn ("speculate-measure: replay failed: " ++ show e) >> exitFailure
    Right () -> pure ()

  ms <- readIORef measuresRef
  let allMs = M.elems ms
      st = foldl' statAdd emptyStats (map mStats allMs)
      linesTotal = sum (map mLines allMs)
      cacheNs = sum (map mCacheNs allMs)
      refNs = sum (map mRefNs allMs)
      outputHash = foldl' (\h m -> h * 16777619 `xor` mHash m) 2166136261 allMs
      hits = stHits st
      misses = stMisses st
      lookups = hits + misses
      rate = if lookups == 0 then 0 else fromIntegral hits / fromIntegral lookups
  eframes <- readIORef engineFramesRef
  cns <- readIORef chipNsRef
  cls <- readIORef chipLinesRef
  pns <- readIORef prepNsRef
  gns <- readIORef geomPrepNsRef
  tns <- readIORef tokenPrepNsRef
  rns <- readIORef replayNsRef
  putStrLn ("speculate-measure: mode=" ++ show mode ++ " trace=" ++ path
            ++ " frames=" ++ show (eframes `div` 2)
            ++ " engineFrames=" ++ show eframes ++ " lines=" ++ show linesTotal)
  putStrLn ("  outputHash=" ++ show outputHash)
  case mode of
    CacheMode -> putStrLn ("  cache work: prefetch=" ++ show (stPrefetchRenders st)
      ++ " demand=" ++ show (stDemandRenders st)
      ++ " totalRenders=" ++ show (totalRenders st)
      ++ " hits=" ++ show hits ++ " misses=" ++ show misses
      ++ " hitRate=" ++ show (fromIntegral (round (rate * 1000) :: Integer) / 10 :: Double) ++ "%"
      ++ " fixups=" ++ show (stFixups st) ++ " evicted=" ++ show (stInvalidated st))
    ExactMode -> putStrLn ("  exact work: renders=" ++ show linesTotal)
  putStrLn ("  component prep wall=" ++ showNs pns
            ++ " (geometry=" ++ showNs gns
            ++ ", 3D Chip=" ++ showNs cns
            ++ ", input/token prep=" ++ showNs tns
            ++ (if mode == ExactMode then ", cache tokens skipped" else "") ++ ")")
  case mode of
    CacheMode -> putStrLn ("  measured cache pass wall=" ++ showNs cacheNs
      ++ " (prefetch+demand+key/token+cache maintenance)")
    ExactMode -> putStrLn ("  measured exact pass wall=" ++ showNs refNs)
  putStrLn ("  end-to-end wall=" ++ showNs rns
            ++ " (whole decode/Chip/sprite/capture/render, forced outputs)")
  putStrLn ("  3D (Haskell Chip): lines=" ++ show cls ++ " chipLineNs=" ++ showNs cns
            ++ " forced=yes composeIncluded=yes")
  putStrLn "  per engine:"
  forM_ (M.toList ms) $ \(n, m) ->
    let stn = mStats m
        hn = stHits stn
        mn = stMisses stn
        ln = hn + mn
        rn = if ln == 0 then (0 :: Double) else fromIntegral hn / fromIntegral ln
    in putStrLn ("    engine " ++ show n ++ ": lines=" ++ show (mLines m)
        ++ " prefetch=" ++ show (stPrefetchRenders stn)
        ++ " demand=" ++ show (stDemandRenders stn)
        ++ " total=" ++ show (totalRenders stn)
        ++ " hits=" ++ show hn ++ " misses=" ++ show mn
        ++ " hitRate=" ++ show (fromIntegral (round (rn * 1000) :: Integer) / 10 :: Double) ++ "%"
        ++ " evicted=" ++ show (stInvalidated stn)
        ++ " passWall=" ++ showNs (mCacheNs m) ++ "/" ++ showNs (mRefNs m))
  putStrLn "  output hash is a consistency check between independent timing runs, not an equality proof; use the direct per-line/oracle gates for correctness"

showNs :: Word64 -> String
showNs ns = show (fromIntegral ns / 1e9 :: Double) ++ "s"

ratio :: Word64 -> Word64 -> Double
ratio a b = if b == 0 then 0 else fromIntegral a / fromIntegral b

statAdd :: Stats -> Stats -> Stats
statAdd a b = Stats
  { stHits = stHits a + stHits b
  , stMisses = stMisses a + stMisses b
  , stFixups = stFixups a + stFixups b
  , stPrefetchRenders = stPrefetchRenders a + stPrefetchRenders b
  , stDemandRenders = stDemandRenders a + stDemandRenders b
  , stInvalidated = stInvalidated a + stInvalidated b
  }

hashLine :: [Word32] -> Word32
hashLine = foldl' (\h w -> (h `xor` w) * 16777619) 2166136261
