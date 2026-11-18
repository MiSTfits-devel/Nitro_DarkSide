{-# LANGUAGE BangPatterns #-}

-- | Ordered NSD2 input replay.  Framebuffer records are delivered through a
-- separate oracle callback and never form part of a renderer input snapshot.
-- The immutable, copy-on-write pages preserve earlier phase snapshots when a
-- later delta changes VRAM.  Missing pages have the trace's initial zero value.
module Nds.Gpu2D.Trace
  ( TraceMemory, readRegion8
  , PhaseKind(..), Phase(..), DisplayState(..), Latch(..), EngineLatch(..)
  , ExtendedPaletteMap(..), OracleEvent(..), OracleLine(..), OracleEngineLine(..)
  , CaptureEvent(..), CaptureWrite, GeometryEvent(..), replayTrace, replayTraceGeometry
  , word8At, word16At, word32At
  ) where

import Control.Monad (unless, when)
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import qualified Data.ByteString as B
import qualified Data.IntMap.Strict as M
import Data.Unique (Unique, newUnique)
import Data.Word (Word8, Word16, Word32, Word64)
import System.IO (Handle, IOMode(ReadMode), withBinaryFile)

-- Pages use the trace's 512-byte dirty granularity, but deltas can start or
-- end at any byte and can cross page boundaries.
data TraceMemory = TraceMemory !(M.IntMap (M.IntMap B.ByteString)) !Unique !Integer

-- Only the decoder creates snapshots; its stream identity and monotonically
-- increasing revision cannot be supplied or forged by a renderer caller.
instance Eq TraceMemory where
  TraceMemory _ streamA revisionA == TraceMemory _ streamB revisionB =
    streamA == streamB && revisionA == revisionB

instance Show TraceMemory where
  show (TraceMemory _ _ revision) = "TraceMemory revision " ++ show revision

regionSizes :: [Int]
regionSizes = [2048,2048,131072,131072,131072,131072,65536,16384,16384,32768,16384,262144,131072]

readRegion8 :: TraceMemory -> Int -> Int -> Word8
readRegion8 (TraceMemory regions _ _) region offset
  | region < 0 || region >= length regionSizes || offset < 0 || offset >= regionSizes !! region =
      error "NSD2: region read out of bounds"
  | otherwise = case M.lookup region regions >>= M.lookup (offset `div` 512) of
      Nothing -> 0
      Just page -> B.index page (offset `mod` 512)

applyDelta :: TraceMemory -> Int -> Int -> B.ByteString -> Either String TraceMemory
applyDelta (TraceMemory regions stream revision) region offset bytes
  | region < 0 || region >= length regionSizes = Left "unknown memory region"
  | offset < 0 || offset > regionSizes !! region || B.length bytes > regionSizes !! region - offset = Left "memory delta out of bounds"
  | otherwise = Right (TraceMemory (M.insert region (go offset bytes pages) regions) stream (revision+1))
  where
    pages = M.findWithDefault M.empty region regions
    go !_ rest !m | B.null rest = m
    go !pos rest !m =
      let (pageNo, within) = pos `divMod` 512
          count = min (512 - within) (B.length rest)
          old = M.findWithDefault (B.replicate 512 0) pageNo m
          new = B.take within old <> B.take count rest <> B.drop (within + count) old
      in go (pos + count) (B.drop count rest) (M.insert pageNo new m)

word8At :: B.ByteString -> Int -> Word8
word8At = B.index
word16At :: B.ByteString -> Int -> Word16
word16At b i = fromIntegral (word8At b i) .|. (fromIntegral (word8At b (i+1)) `shiftL` 8)
word32At :: B.ByteString -> Int -> Word32
word32At b i = fromIntegral (word16At b i) .|. (fromIntegral (word16At b (i+2)) `shiftL` 16)
word64At :: B.ByteString -> Int -> Word64
word64At b i = fromIntegral (word32At b i) .|. (fromIntegral (word32At b (i+4)) `shiftL` 32)

data PhaseKind = ScanlinePhase | SpritePhase deriving (Eq, Show)

-- Packed engine/scanline register bytes retain every latch and mapping, with
-- offsets defined by Trace2DScanlinePacket and Trace2DEngine in the C header.
-- No framebuffer or composited expected pixels are present in Phase.
data Phase = Phase
  { phaseKind :: !PhaseKind
  , phaseRegisters :: !B.ByteString
  , phaseLatch :: !Latch
  , phaseExtendedPaletteMap :: !ExtendedPaletteMap
  , phaseDisplayState :: !(Maybe DisplayState)
  , phaseMemory :: !TraceMemory
  , phase3D :: !(Maybe B.ByteString)
  }

data EngineLatch = EngineLatch
  { latchX2 :: !Word32, latchX3 :: !Word32
  , latchY2 :: !Word32, latchY3 :: !Word32
  , latchBGMosaicY :: !Word8, latchBGMosaicYMax :: !Word8
  , latchOBJMosaicY :: !Word8, latchFlags :: !Word8
  , latchBGMosaicLine :: !Word32, latchOBJMosaicLine :: !Word32
  } deriving (Eq, Show)

data Latch = Latch !EngineLatch !EngineLatch deriving (Eq, Show)
newtype ExtendedPaletteMap = ExtendedPaletteMap B.ByteString deriving (Eq, Show)
data DisplayState = DisplayState
  { displayEngineAEnabled :: !Bool, displayEngineBEnabled :: !Bool
  , displayCaptureCnt :: !Word32, displayLCDCMap :: !Word32
  , displayFIFO :: !B.ByteString, displayFIFOReadPtr :: !Word8
  , displayFIFOWritePtr :: !Word8, displayFIFOBuffer :: !B.ByteString
  } deriving (Eq, Show)

data OracleLine = OracleLine
  { oracleFrame :: !Word32, oracleY :: !Word16
  , oracleTop :: !B.ByteString, oracleBottom :: !B.ByteString
  } deriving (Eq, Show)

data OracleEngineLine = OracleEngineLine
  { oracleEngineFrame :: !Word32, oracleEngineY :: !Word16
  , oracleEngineNumber :: !Word8, oracleEnginePixels :: !B.ByteString
  } deriving (Eq, Show)

data OracleEvent = ScreenOracle !OracleLine | EngineOracle !OracleEngineLine
  | CaptureStateOracle !Word32 !Word16 ![Word16] !Bool
  deriving (Eq, Show)

type CaptureWrite = (Int, Word32, Word16)
-- Geometry records are raw inputs, distinct from the recorded 3D line.
data GeometryEvent
  = GeometryCommand !Word32 !Word8 !Word32
  | GeometryRegister !Word32 !Word32 !Word32 !Word8
  | GeometryFrameSummary !Word32 !Word32 !Word32 !Word32
  | GeometryPower !Word32 !Bool !Bool !Word32
  | GeometryXPos !Word32 !Word16
  | GeometryAbort !Word32 !Bool
  | GeometryRenderStart !Word32 !Word16 !Word16 !Bool !Bool !Bool !B.ByteString ![Word32] ![Word32]
  | GeometryFrameEnd !Word32 !Word16
  | GeometryVBlank !Word32 !Word16
  | GeometryGxWrite !Word32 !Word32 !Word32 !Word8
  deriving (Eq, Show)


-- These are input events only; expected capture bytes/flags are kept apart.
data CaptureEvent
  = CaptureBegin !Word32 !Word16 !Word32 !Word32 !Word32 !TraceMemory
  | CaptureLifecycleStart !Word32 !Word16 !Word32 !Word32
  | CaptureLifecycleEnd !Word32 !Word16 !Word32 !Word32

data Replay = Replay
  { memory :: !TraceMemory, latch :: !(Maybe ((Word32, Word16), Latch))
  , paletteMap :: !(Maybe ExtendedPaletteMap)
  , display :: !(Maybe ((Word32, Word16), DisplayState))
  , pixels3D :: !(Maybe ((Word32, Word16), B.ByteString))
  , expectedMemory :: !TraceMemory
  , capturePending :: !(Maybe (Word32, Word16, [CaptureWrite]))
  }

initial :: Unique -> Unique -> Replay
initial stream expectedStream = Replay (TraceMemory M.empty stream 0) Nothing Nothing Nothing Nothing
  (TraceMemory M.empty expectedStream 0) Nothing

engineLatch :: B.ByteString -> Int -> EngineLatch
engineLatch b i = EngineLatch (word32At b i) (word32At b (i+4))
  (word32At b (i+8)) (word32At b (i+12)) (word8At b (i+16))
  (word8At b (i+17)) (word8At b (i+18)) (word8At b (i+19))
  (word32At b (i+20)) (word32At b (i+24))

-- | Stream from the beginning, applying each delta before delivering its
-- phase. Callbacks run in file order; malformed/truncated input fails closed.
-- Version 9 has no sprite-phase or display-state records; consumers requiring
-- those inputs must reject the corresponding missing information themselves.
replayTrace :: FilePath -> (Phase -> IO ()) -> (CaptureEvent -> IO [CaptureWrite]) -> (OracleEvent -> IO ()) -> IO ()
replayTrace path = replayTraceGeometry path (\_ _ _ -> pure ())

-- | Deliver raw geometry events immediately, including after the last 2D
-- phase. Timestamps are preserved and callbacks run in stream order.
replayTraceGeometry :: FilePath -> (Word64 -> GeometryEvent -> TraceMemory -> IO ())
                    -> (Phase -> IO ()) -> (CaptureEvent -> IO [CaptureWrite])
                    -> (OracleEvent -> IO ()) -> IO ()
replayTraceGeometry path onGeometry onPhase onCapture onOracle = withBinaryFile path ReadMode $ \h -> do
  stream <- newUnique
  expectedStream <- newUnique
  header <- exactly h 16
  unless (word32At header 0 == 0x3244534e && word16At header 6 == 16 &&
          word16At header 4 `elem` [9,10,11,12]) $ fail "NSD2: unsupported header"
  let version = word16At header 4
      loop !s = do
        rh <- B.hGet h 4
        if B.null rh then unless (capturePending s == Nothing) (fail "NSD2: unterminated capture") else do
          unless (B.length rh == 4) $ fail "NSD2: truncated record header"
          let typ = word16At rh 0; size = fromIntegral (word16At rh 2)
          when (size < 4) $ fail "NSD2: invalid record size"
          b <- exactly h (size - 4)
          s' <- record version typ b s
          loop s'
      record version typ b s = case typ of
        1 -> phase version ScanlinePhase b s
        12 -> if version < 10 then fail "NSD2: unexpected sprite phase" else phase version SpritePhase b s
        2 -> do
          when (capturePending s /= Nothing) $ fail "NSD2: input delta inside capture"
          atLeast 12 b
          let region = fromIntegral (word8At b 6); offset = fromIntegral (word32At b 8)
          m <- either (fail . ("NSD2: " ++)) pure (applyDelta (memory s) region offset (B.drop 12 b))
          em <- either (fail . ("NSD2: " ++)) pure (applyDelta (expectedMemory s) region offset (B.drop 12 b))
          pure s { memory = m, expectedMemory = em }
        3 -> do
          require 1032 b
          unless (word16At b 6 == 256) $ fail "NSD2: invalid 3D line length"
          pure s { pixels3D = Just ((word32At b 0, word16At b 4), B.drop 8 b) }
        4 -> do
          require 48 b
          pure s { paletteMap = Just (ExtendedPaletteMap (B.drop 8 b)) }
        5 -> do
          require 20 b
          onGeometry (word64At b 4) (GeometryCommand (word32At b 0) (word8At b 12) (word32At b 16)) (memory s)
          pure s
        6 -> do
          require 24 b
          onGeometry (word64At b 4) (GeometryFrameSummary (word32At b 0) (word32At b 12) (word32At b 16) (word32At b 20)) (memory s)
          pure s
        7 -> do
          require 24 b
          unless (word8At b 20 `elem` [1,2,4]) $ fail "NSD2: invalid geometry register width"
          onGeometry (word64At b 4) (GeometryRegister (word32At b 0) (word32At b 12) (word32At b 16) (word8At b 20)) (memory s)
          pure s
        8 -> do
          require 2056 b
          unless (word16At b 6 == 256) $ fail "NSD2: invalid framebuffer line length"
          onOracle (ScreenOracle (OracleLine (word32At b 0) (word16At b 4) (B.take 1024 (B.drop 8 b)) (B.drop 1032 b)))
          pure s
        9 -> do
          require 64 b
          pure s { latch = Just ((word32At b 0, word16At b 4), Latch (engineLatch b 8) (engineLatch b 36)) }
        13 -> do
          require 562 b
          let d = DisplayState (word8At b 6 /= 0) (word8At b 7 /= 0)
                    (word32At b 8) (word32At b 12) (B.take 32 (B.drop 16 b))
                    (word8At b 48) (word8At b 49) (B.drop 50 b)
          pure s { display = Just ((word32At b 0, word16At b 4), d) }
        14 -> do
          when (version < 10) $ fail "NSD2: unexpected engine oracle"
          require 1032 b
          when (word8At b 6 > 1 || word8At b 7 /= 0) $ fail "NSD2: invalid engine oracle"
          onOracle (EngineOracle (OracleEngineLine (word32At b 0) (word16At b 4) (word8At b 6) (B.drop 8 b)))
          pure s
        15 -> do
          require 24 b
          when (version < 11 || capturePending s /= Nothing) $ fail "NSD2: unexpected capture begin"
          let f = word32At b 0; y = word16At b 4
          writes <- onCapture (CaptureBegin f y (word32At b 8) (word32At b 12) (word32At b 16) (memory s))
          m <- applyCaptureWrites (memory s) writes
          pure s { memory = m, capturePending = Just (f,y,writes) }
        16 -> do
          atLeast 12 b
          let f = word32At b 0; y = word16At b 4
              region = fromIntegral (word8At b 6); offset = fromIntegral (word32At b 8)
              bytes = B.drop 12 b
          case capturePending s of
            Just (cf,cy,_) | cf == f && cy == y -> pure ()
            _ -> fail "NSD2: capture delta without matching begin"
          when (region < 2 || region > 5) $ fail "NSD2: invalid capture bank"
          expected <- either (fail . ("NSD2: " ++)) pure (applyDelta (expectedMemory s) region offset bytes)
          unless (and [readRegion8 (memory s) region (offset+i) == B.index bytes i | i <- [0..B.length bytes-1]]) $
            fail ("NSD2: capture mismatch frame " ++ show f ++ " line " ++ show y ++ " region " ++ show region ++ " offset " ++ show offset)
          pure s { expectedMemory = expected }
        17 -> do
          require 44 b
          let f = word32At b 0; y = word16At b 4
          writes <- case capturePending s of
            Just (cf,cy,ws) | cf == f && cy == y -> pure ws
            _ -> fail "NSD2: capture end without matching begin"
          unless (all (matchesExpected (memory s) (expectedMemory s)) writes) $
            fail ("NSD2: unexpected capture write frame " ++ show f ++ " line " ++ show y)
          onOracle (CaptureStateOracle f y [word16At b (8+2*i) | i <- [0..15]] (word8At b 40 /= 0))
          pure s { capturePending = Nothing }
        t | t == 18 || t == 19 -> do
          require 52 b
          let f = word32At b 0; y = word16At b 4; cnt = word32At b 8; lcdc = word32At b 12
          writes <- onCapture (if t == 18 then CaptureLifecycleStart f y cnt lcdc else CaptureLifecycleEnd f y cnt lcdc)
          unless (null writes) $ fail "NSD2: lifecycle event produced memory writes"
          onOracle (CaptureStateOracle f y [word16At b (16+2*i) | i <- [0..15]] (word8At b 48 /= 0))
          pure s
        20 -> do
          when (version < 12) $ fail "NSD2: unexpected 3D power record"
          require 20 b
          onGeometry (word64At b 4) (GeometryPower (word32At b 0) (word8At b 12 /= 0)
                       (word8At b 13 /= 0) (word32At b 16)) (memory s)
          pure s
        21 -> do
          when (version < 12) $ fail "NSD2: unexpected 3D X position record"
          require 16 b
          onGeometry (word64At b 4) (GeometryXPos (word32At b 0) (word16At b 12)) (memory s)
          pure s
        22 -> do
          when (version < 12) $ fail "NSD2: unexpected 3D abort record"
          require 20 b
          onGeometry (word64At b 4) (GeometryAbort (word32At b 0) (word32At b 12 /= 0)) (memory s)
          pure s
        23 -> do
          when (version < 12) $ fail "NSD2: unexpected 3D render-start record"
          require 82 b
          when (word8At b 20 .&. 0xfe /= 0) $ fail "NSD2: invalid 3D render-start flags"
          let event = GeometryRenderStart (word32At b 0) (word16At b 4) (word16At b 16)
                        (word8At b 18 /= 0) (word8At b 19 /= 0) (word8At b 20 .&. 1 /= 0)
                        (B.take 9 (B.drop 22 b))
                        [word32At b (34+4*i) | i <- [0..3]]
                        [word32At b (50+4*i) | i <- [0..7]]
          onGeometry (word64At b 8) event (memory s)
          pure s
        t | t == 24 || t == 25 -> do
          when (version < 12) $ fail "NSD2: unexpected 3D frame boundary"
          require 16 b
          let event = (if t == 24 then GeometryFrameEnd else GeometryVBlank) (word32At b 0) (word16At b 4)
          onGeometry (word64At b 8) event (memory s)
          pure s
        26 -> do
          when (version < 12) $ fail "NSD2: unexpected raw GX bus write"
          require 24 b
          unless (word8At b 20 `elem` [1,2,4]) $ fail "NSD2: invalid GX bus width"
          onGeometry (word64At b 4) (GeometryGxWrite (word32At b 0) (word32At b 12)
                       (word32At b 16) (word8At b 20)) (memory s)
          pure s
        -- Unknown records are not silently ignored: a later version needs an
        -- explicit compatibility decision before its inputs are exact.
        _ | typ `elem` [10,11] -> pure s
          | otherwise -> fail ("NSD2: unknown record type " ++ show typ)
      phase version kind b s = do
        require 472 b
        let position = (word32At b 0, word16At b 6)
        (lpos, l) <- maybe (fail "NSD2: phase missing internal latch") pure (latch s)
        unless (lpos == position) $ fail "NSD2: latch belongs to another phase"
        p <- maybe (fail "NSD2: phase missing extended palette map") pure (paletteMap s)
        d <- case display s of
          Nothing | version >= 10 -> fail "NSD2: phase missing display state"
                  | otherwise -> pure Nothing
          Just (dpos, value) -> do
            unless (dpos == position) $ fail "NSD2: display state belongs to another phase"
            pure (Just value)
        pixels <- case (kind, pixels3D s) of
          (ScanlinePhase, Just (ppos, value)) -> do
            unless (ppos == position) $ fail "NSD2: 3D line belongs to another phase"
            pure (Just value)
          _ -> pure Nothing
        onPhase (Phase kind b l p d (memory s) pixels)
        pure s { latch = Nothing, display = Nothing, pixels3D = if kind == ScanlinePhase then Nothing else pixels3D s }
  loop (initial stream expectedStream)

-- Group adjacent ordered word writes into one immutable page update. A wrap,
-- overlapping address or bank change starts a new run, preserving order.
applyCaptureWrites :: TraceMemory -> [CaptureWrite] -> IO TraceMemory
applyCaptureWrites memory0 = go memory0
  where
    go memory [] = pure memory
    go memory ((bank,index,value):rest)
      | bank < 0 || bank > 3 || index >= 65536 = fail "NSD2: capture write out of bounds"
      | otherwise = gather memory bank index (index+1) [hi value,lo value] rest
    gather memory bank start next bytes ((bank',index,value):rest)
      | bank' == bank && index == next && index < 65536 =
          gather memory bank start (next+1) (hi value : lo value : bytes) rest
    gather memory bank start _ bytes rest = do
      updated <- either (fail . ("NSD2: " ++)) pure $
        applyDelta memory (bank+2) (fromIntegral start*2) (B.pack (reverse bytes))
      go updated rest
    lo value = fromIntegral value
    hi value = fromIntegral (value `shiftR` 8)

matchesExpected :: TraceMemory -> TraceMemory -> CaptureWrite -> Bool
matchesExpected actual expected (bank,index,_) =
  let region = bank+2; offset = fromIntegral index*2
  in readRegion8 actual region offset == readRegion8 expected region offset &&
     readRegion8 actual region (offset+1) == readRegion8 expected region (offset+1)

exactly :: Handle -> Int -> IO B.ByteString
exactly h n = do
  b <- B.hGet h n
  unless (B.length b == n) $ fail "NSD2: truncated record"
  pure b

require :: Int -> B.ByteString -> IO ()
require n b = unless (B.length b == n) $ fail "NSD2: invalid record length"

atLeast :: Int -> B.ByteString -> IO ()
atLeast n b = unless (B.length b >= n) $ fail "NSD2: invalid record length"
