-- | Independent M4 3D replay + composition check.
--
-- Inputs are the ordered v12 raw records (power, RenderXPos, abort,
-- render-start memory+mapping snapshot, VBlank, frame end) plus the v11
-- geometry stream. Recorded type3 3D lines and type8 screen lines are the
-- independent melonDS expected output and are never fed into the model.
--
-- The Haskell 3D line comes from Nds.Gpu3D.TraceReplay (whole Chip model) and
-- is handed explicitly to renderTraceDisplays as the 3D provider, so the
-- composition path never reads recorded pixels.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import qualified Data.ByteString as B
import Data.Bits (testBit, shiftL, shiftR, (.&.), (.|.))
import Data.IORef
import Data.List (foldl')
import qualified Data.Map.Strict as M
import Data.Word (Word16, Word32, Word64, Word8)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu2D.Trace
import Nds.Gpu2D.TraceRender
import Nds.Gpu3D.Texture (TexMem (..))
import Nds.Gpu3D.TraceReplay

data ReplayState = ReplayState
  { rsChip :: Trace3DState
  , rsTex :: TexMem
  , rsXPos :: Word16
  , rsPower :: (Bool, Bool)
  , rsRaw :: Bool
  }

zeroTex :: TexMem
zeroTex = TexMem (const 0) (const 0)

main :: IO ()
main = do
  args <- getArgs
  path <- case args of [p] -> pure p; _ -> putStrLn "usage: m4-check <trace.nsd2>" >> exitFailure
  stRef <- newIORef (ReplayState initialTrace3DState zeroTex 0 (True, True) False)
  res3dRef <- newIORef []
  resScrRef <- newIORef []
  trRef <- newIORef initialTraceRenderState

  let applyEvent st ev = case applyTrace3DEvent (rsTex st) ev (rsChip st) of
        Left e -> pure st
        Right c -> pure st { rsChip = c }
      onGeometry ts ev mem = do
        st <- readIORef stRef
        case ev of
          GeometryGxWrite f addr val width -> do
            st' <- applyEvent st { rsRaw = True } (Trace3DGxWrite f ts addr val width)
            writeIORef stRef st'
          GeometryCommand f cmd param ->
            if rsRaw st then pure ()
            else applyEvent st (Trace3DCommand f ts (fromIntegral cmd) param) >>= writeIORef stRef
          GeometryRegister f addr val width ->
            if rsRaw st then pure ()
            else applyEvent st (Trace3DRegister f ts addr val width) >>= writeIORef stRef
          GeometryFrameSummary _ _ _ _ -> pure ()   -- diagnostic summary only
          GeometryPower _ geom rend _ ->
            writeIORef stRef st { rsPower = (geom, rend)
                                , rsChip = trace3DPower geom rend (rsChip st) }
          GeometryXPos _ xpos ->
            writeIORef stRef st { rsXPos = xpos
                                , rsChip = trace3DXPos xpos 0xFFFF (rsChip st) }
          GeometryAbort _ active ->
            when active $ writeIORef stRef st { rsChip = trace3DAbortFrame (rsChip st) }
          GeometryRenderStart _ _ xpos geom rend initial _vramcnt texMaps texPalMaps -> do
            let st1 = st { rsTex = trace3DTexMem mem texMaps texPalMaps
                         , rsXPos = xpos
                         , rsPower = (geom, rend)
                         , rsChip = trace3DXPos xpos 0xFFFF
                                    (trace3DPower geom rend (rsChip st)) }
                st2 | initial = st1
                    | otherwise = st1 { rsChip = trace3DRenderStart (rsTex st1) (rsChip st1) }
            writeIORef stRef st2
          GeometryFrameEnd _ _ ->
            writeIORef stRef st { rsChip = trace3DFrameEnd (rsChip st) }
          GeometryVBlank _ _ ->
            writeIORef stRef st { rsChip = trace3DVBlank (rsChip st) }

      onPhase p = do
        tr <- readIORef trRef
        case phaseKind p of
          SpritePhase -> case advanceTraceSprites tr p of
            Left _ -> pure ()
            Right tr' -> writeIORef trRef tr'
          ScanlinePhase -> do
            st <- readIORef stRef
            let f = word32At (phaseRegisters p) 0
                y = word16At (phaseRegisters p) 4
                got3d = either (const (replicate 256 0)) id
                          (trace3DLine (fromIntegral y) (rsChip st))
            writeIORef stRef st
            case phase3D p of
              Just bs ->
                let want = [ word32At bs (4 * i) | i <- [0 .. 255] ]
                in modifyIORef res3dRef ((f, y, got3d, want) :)
              Nothing -> pure ()
            case renderTraceDisplays (Just got3d) tr p of
              Left _ -> pure ()
              Right (tr', (top, bot)) -> do
                writeIORef trRef tr'
                modifyIORef resScrRef ((f, y, top, bot) :)
      onCapture ev = do
        tr <- readIORef trRef
        case handleTraceCapture tr ev of
          Left _ -> pure []
          Right (tr', ws) -> writeIORef trRef tr' >> pure ws
  oracleMapRef <- newIORef M.empty
  let onOracle' ev = case ev of
        ScreenOracle ol -> modifyIORef oracleMapRef (M.insert (oracleFrame ol, oracleY ol)
                              (oracleTop ol, oracleBottom ol))
        _ -> pure ()
  r <- try (replayTraceGeometry path onGeometry onPhase onCapture onOracle')
         :: IO (Either SomeException ())
  case r of
    Left e -> putStrLn ("m4-check: replay failed: " ++ show e) >> exitFailure
    Right () -> pure ()

  res3d <- reverse <$> readIORef res3dRef
  resScr <- reverse <$> readIORef resScrRef
  oracle <- readIORef oracleMapRef
  let bad3d = [ (f, y, g, w) | (f, y, g, w) <- res3d, g /= w ]
      badScr = [ (f, y, top, bot, want)
               | (f, y, top, bot) <- resScr
               , Just (wt, wb) <- [M.lookup (f, y) oracle]
               , let want = (words32 wt, words32 wb)
               , top /= fst want || bot /= snd want ]
      noScr = [ (f, y) | (f, y, _, _) <- resScr, not (M.member (f, y) oracle) ]
  mapM_ (\(f, y, g, w) -> putStrLn ("3D frame " ++ show f ++ " line " ++ show y
      ++ ": first diff " ++ show (firstDiff g w))) (take 10 bad3d)
  mapM_ (\(f, y, top, bot, (wt, wb)) -> putStrLn ("screen frame " ++ show f
      ++ " line " ++ show y ++ ": top " ++ show (firstDiff top wt)
      ++ " n=" ++ show (length [() | (a,b) <- zip top wt, a /= b])
      ++ " bottom " ++ show (firstDiff bot wb)
      ++ " n=" ++ show (length [() | (a,b) <- zip bot wb, a /= b]))) (take 10 badScr)
  mapM_ (\(f, n) -> putStrLn ("3D mismatches frame " ++ show f ++ ": " ++ show n))
        (M.toList (M.fromListWith (+) [ (f, 1::Int) | (f, _, _, _) <- bad3d ]))
  mapM_ (\(f, n) -> putStrLn ("screen mismatches frame " ++ show f ++ ": " ++ show n))
        (M.toList (M.fromListWith (+) [ (f, 1::Int) | (f, _, _, _, _) <- badScr ]))
  putStrLn ("m4-check: type3 " ++ show (length res3d) ++ " lines, "
            ++ show (length bad3d) ++ " 3D mismatches; screen "
            ++ show (length resScr) ++ " lines, " ++ show (length badScr)
            ++ " screen mismatches, " ++ show (length noScr) ++ " missing oracle")
  when (not (null bad3d) || not (null badScr)) exitFailure

words32 :: B.ByteString -> [Word32]
words32 b = [word32At b (4 * i) | i <- [0 .. 255]]

firstDiff :: Eq a => [a] -> [a] -> Maybe (Int, a, a)
firstDiff = go 0
  where
    go _ [] [] = Nothing
    go n (a:as) (b:bs) | a == b = go (n+1) as bs
                       | otherwise = Just (n, a, b)
    go _ _ _ = Nothing
