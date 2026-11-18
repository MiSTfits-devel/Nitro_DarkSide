{-# LANGUAGE LambdaCase #-}
-- | Stream Haskell-rendered NDS frames from an NSD2 v12 trace to stdout.
--
-- TRACE may be a pipe fed live by @melonds_fbdump --trace2d-raw3d@. Pixels come
-- only from the Haskell models: Nds.Gpu3D.Chip (via TraceReplay) supplies the
-- 3D line and Nds.Gpu2D (renderTraceDisplays) composes both screens. Recorded
-- melonDS type8 screen lines are used only to count exact-matching lines.
--
-- Fails closed: any model, sprite, capture or 3D error, a normalized GX record
-- without the v12 raw stream, or a frame without all 192 lines stops the
-- stream with an explicit error. No partial or substituted frame is emitted.
--
-- Output records (little-endian, 20-byte header):
--   "NDSF", u32 frame, u32 matched lines, u32 compared lines, u32 0,
--     then 256x384 BGRA8888 (top screen, then bottom);
--   "NDSE", u32 status (0 end of stream, 1 error), u32 message bytes, u64 0,
--     then the UTF-8 message. Always the last record.
module Main (main) where

import Control.Exception (SomeException, displayException, throwIO, try, ErrorCall (..))
import Control.Monad (unless, when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as BC
import Data.IORef
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import Data.Word (Word16, Word32)
import Numeric (showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO

import Nds.Gpu2D.Trace
import Nds.Gpu2D.TraceRender
import Nds.Gpu3D.Texture (TexMem)
import Nds.Gpu3D.TraceReplay

data View = View
  { vChip :: !Trace3DState
  , vTex :: !(Maybe TexMem)
  , vRaw :: !Bool
  , vFrame :: !(Maybe Word32)
  , vLines :: !(IM.IntMap ([Word32], [Word32]))
  , vMatched :: !Int
  , vCompared :: !Int
  , vHs :: !(M.Map (Word32, Word16) ([Word32], [Word32]))
  , vOracle :: !(M.Map (Word32, Word16) ([Word32], [Word32]))
  }

main :: IO ()
main = do
  path <- getArgs >>= \case
    [p] -> pure p
    _ -> hPutStrLn stderr "usage: trace-view TRACE.nsd2" >> exitFailure
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering (Just (1024 * 1024)))
  ref <- newIORef (View initialTrace3DState Nothing False Nothing IM.empty 0 0 M.empty M.empty)
  trRef <- newIORef initialTraceRenderState
  let chip f = modifyIORef' ref (\v -> v { vChip = f (vChip v) })
      apply what ev = do
        v <- readIORef ref
        tex <- maybe (stop (what ++ " before the first render-start memory snapshot")) pure (vTex v)
        c <- orStop what (applyTrace3DEvent tex ev (vChip v))
        writeIORef ref v { vChip = c }
      normalized what = do
        raw <- vRaw <$> readIORef ref
        unless raw $ stop (what ++ " before any raw type-26 GX write: a v12 --trace2d-raw3d stream is required")
      onGeometry ts ev mem = case ev of
        GeometryGxWrite f addr val width -> do
          modifyIORef' ref (\v -> v { vRaw = True })
          apply ("GX write frame " ++ show f ++ " addr " ++ hex addr) (Trace3DGxWrite f ts addr val width)
        -- v12 emits every accepted GX bus write as type 26 before its side
        -- effects; type 5/7 are the same writes normalized, so they are not
        -- applied a second time.
        GeometryCommand f _ _ -> normalized ("type-5 GX command frame " ++ show f)
        GeometryRegister f _ _ _ -> normalized ("type-7 GX register frame " ++ show f)
        GeometryFrameSummary {} -> pure ()   -- diagnostic counters only
        GeometryPower _ geom rend _ -> chip (trace3DPower geom rend)
        GeometryXPos _ xpos -> chip (trace3DXPos xpos 0xFFFF)
        GeometryAbort _ active -> when active (chip trace3DAbortFrame)
        GeometryRenderStart _ _ xpos geom rend initial _ texMaps texPalMaps ->
          modifyIORef' ref (\v ->
            let tex = trace3DTexMem mem texMaps texPalMaps
                c1 = trace3DXPos xpos 0xFFFF (trace3DPower geom rend (vChip v))
            in v { vTex = Just tex, vChip = if initial then c1 else trace3DRenderStart tex c1 })
        GeometryFrameEnd _ _ -> chip trace3DFrameEnd
        GeometryVBlank _ _ -> chip trace3DVBlank

      onPhase p = do
        let f = word32At (phaseRegisters p) 0
            y = word16At (phaseRegisters p) 4
            at = "frame " ++ show f ++ " line " ++ show y
        tr <- readIORef trRef
        case phaseKind p of
          SpritePhase -> orStop ("sprite phase " ++ at) (advanceTraceSprites tr p) >>= writeIORef trRef
          ScanlinePhase -> do
            v <- readIORef ref
            case vFrame v of
              Just g | g /= f -> stop ("frame " ++ show g ++ " ended with " ++ show (IM.size (vLines v))
                                       ++ "/192 lines before " ++ at)
              _ -> pure ()
            when (IM.member (fromIntegral y) (vLines v)) $ stop ("duplicate " ++ at)
            line3d <- orStop ("3D " ++ at) (trace3DLine (fromIntegral y) (vChip v))
            (tr', screens) <- orStop ("render " ++ at) (renderTraceDisplays (Just line3d) tr p)
            writeIORef trRef tr'
            let v1 = (record (f, y) (Left screens) v)
                       { vFrame = Just f, vLines = IM.insert (fromIntegral y) screens (vLines v) }
            if y /= 191 then writeIORef ref v1 else do
              unless (IM.keys (vLines v1) == [0 .. 191]) $
                stop ("frame " ++ show f ++ " has " ++ show (IM.size (vLines v1)) ++ "/192 lines at line 191")
              emit f v1
              writeIORef ref v1 { vFrame = Nothing, vLines = IM.empty }

      onCapture ev = do
        tr <- readIORef trRef
        (tr', ws) <- orStop "display capture" (handleTraceCapture tr ev)
        writeIORef trRef tr'
        pure ws

      onOracle = \case
        ScreenOracle ol -> modifyIORef' ref (record (oracleFrame ol, oracleY ol)
                             (Right (words32 (oracleTop ol), words32 (oracleBottom ol))))
        _ -> pure ()

  r <- try (replayTraceGeometry path onGeometry onPhase onCapture onOracle) :: IO (Either SomeException ())
  v <- readIORef ref
  let counts = "matched " ++ show (vMatched v) ++ "/" ++ show (vCompared v) ++ " lines"
  case r of
    Left e -> finish 1 ("error: " ++ displayException e ++ " (" ++ counts ++ ")") >> exitFailure
    Right () -> do
      let partial = IM.size (vLines v)
          msg | partial /= 0 = "end of stream inside frame " ++ maybe "?" show (vFrame v) ++ " ("
                               ++ show partial ++ "/192 lines, not shown); " ++ counts
              | otherwise = "end of stream; " ++ counts
      finish 0 msg

stop :: String -> IO a
stop = throwIO . ErrorCall

orStop :: String -> Either String a -> IO a
orStop what = either (\e -> stop (what ++ ": " ++ e)) pure

hex :: Word32 -> String
hex w = "0x" ++ showHex w ""

-- | Pair a Haskell line (Left) with the melonDS record (Right) for counting.
record :: (Word32, Word16) -> Either ([Word32], [Word32]) ([Word32], [Word32]) -> View -> View
record k side v = case side of
  Left hs -> case M.lookup k (vOracle v) of
    Just o -> done hs o v { vOracle = M.delete k (vOracle v) }
    Nothing -> v { vHs = M.insert k hs (vHs v) }
  Right o -> case M.lookup k (vHs v) of
    Just hs -> done hs o v { vHs = M.delete k (vHs v) }
    Nothing -> v { vOracle = M.insert k o (vOracle v) }
  where
    done hs o w = w { vCompared = vCompared w + 1
                    , vMatched = vMatched w + if hs == o then 1 else 0 }

emit :: Word32 -> View -> IO ()
emit f v = do
  let px = foldMap BB.word32LE
      u32 = BB.word32LE . fromIntegral
      screens = IM.elems (vLines v)
  BB.hPutBuilder stdout $
    BB.string7 "NDSF" <> BB.word32LE f <> u32 (vMatched v) <> u32 (vCompared v) <> u32 (0 :: Int)
    <> foldMap (px . fst) screens <> foldMap (px . snd) screens
  hFlush stdout
  hPutStrLn stderr ("trace-view: frame " ++ show f ++ " matched " ++ show (vMatched v)
                    ++ "/" ++ show (vCompared v))

-- | Terminal record; also logged to stderr.
finish :: Word32 -> String -> IO ()
finish status msg = do
  hPutStrLn stderr ("trace-view: " ++ msg)
  let bytes = BC.pack msg
  r <- try (do BB.hPutBuilder stdout (BB.string7 "NDSE" <> BB.word32LE status
                 <> BB.word32LE (fromIntegral (B.length bytes)) <> BB.word64LE 0 <> BB.byteString bytes)
               hFlush stdout) :: IO (Either SomeException ())
  either (const (pure ())) pure r   -- the viewer may already be gone

words32 :: B.ByteString -> [Word32]
words32 b = [word32At b (4 * i) | i <- [0 .. 255]]
