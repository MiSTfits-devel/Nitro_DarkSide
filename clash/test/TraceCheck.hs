-- Directed checks for raw NSD2 phase ordering and snapshot isolation.
module Main (main) where

import Control.Exception (IOException, finally, try)
import Control.Monad (unless)
import Data.Bits (shiftR)
import qualified Data.ByteString as B
import Data.IORef
import Data.Word (Word8, Word16, Word32)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openBinaryTempFile)

import Nds.Gpu2D.Trace
import Nds.Gpu2D.TraceState

le16 :: Word16 -> B.ByteString
le16 n = B.pack [fromIntegral n, fromIntegral (n `shiftR` 8)]
le32 :: Word32 -> B.ByteString
le32 n = B.pack [fromIntegral n, fromIntegral (n `shiftR` 8), fromIntegral (n `shiftR` 16), fromIntegral (n `shiftR` 24)]
record :: Word16 -> B.ByteString -> B.ByteString
record t b = le16 t <> le16 (fromIntegral (B.length b + 4)) <> b
header :: Word16 -> B.ByteString
header v = le32 0x3244534e <> le16 v <> le16 16 <> le32 0 <> le32 0
delta :: Word8 -> Word32 -> B.ByteString -> B.ByteString
delta region offset b = record 2 (le32 0 <> le16 0 <> B.pack [region,0] <> le32 offset <> b)
extPal :: B.ByteString
extPal = record 4 (B.replicate 48 0)
latches :: B.ByteString
latches = record 9 (B.replicate 64 0)
display :: B.ByteString
display = record 13 (B.replicate 562 0)
registers :: B.ByteString
registers = B.take 28 (B.replicate 472 0) <> le32 1 <> B.replicate 440 0
replace :: Int -> B.ByteString -> B.ByteString -> B.ByteString
replace offset value original = B.take offset original <> value <> B.drop (offset + B.length value) original

main :: IO ()
main = do
  dir <- getTemporaryDirectory
  (path, h) <- openBinaryTempFile dir "nsd2-phase-check"
  hClose h
  let input = header 10 <> delta 2 511 (B.pack [1,2]) <> extPal <> latches <> display <>
              record 12 registers <> delta 2 511 (B.pack [3,4]) <> latches <> display <>
              record 3 (B.replicate 6 0 <> le16 256 <> B.replicate 1024 42) <>
              record 1 registers <> record 14 (B.replicate 8 0 <> B.replicate 1024 23) <>
              record 8 (B.replicate 6 0 <> le16 256 <> B.replicate 2048 19)
  (do
      B.writeFile path input
      phases <- newIORef []
      oracles <- newIORef []
      replayTrace path (\p -> modifyIORef' phases (p:)) (const (fail "unexpected capture")) (\o -> modifyIORef' oracles (o:))
      ps <- reverse <$> readIORef phases
      os <- readIORef oracles
      case ps of
        [sprite, line] -> do
          unless (phaseKind sprite == SpritePhase && phaseKind line == ScanlinePhase) $ fail "phase order"
          unless (readRegion8 (phaseMemory sprite) 2 511 == 1 && readRegion8 (phaseMemory sprite) 2 512 == 2) $ fail "sprite snapshot"
          unless (readRegion8 (phaseMemory line) 2 511 == 3 && readRegion8 (phaseMemory line) 2 512 == 4) $ fail "scanline delta"
          unless (phaseBGRead sprite 0 511 == 1 && phaseBGRead line 0 512 == 4) $ fail "banked BG mapping"
          let wr = replace 292 (le32 0x2000) $ replace (292+64) (B.pack [2,4]) $
                     replace (292+72) (B.pack [0x21,0,0x02,0]) $
                     replace (292+76) (B.pack [1,0]) (phaseRegisters line)
              masks = phaseWindowMasks (line { phaseRegisters = wr }) 0 (replicate 256 False)
          unless (take 6 masks == [2,2,0x21,0x21,2,2] && length masks == 256) $ fail "window boundary"
          unless (phase3D sprite == Nothing && fmap B.length (phase3D line) == Just 1024) $ fail "3D input ownership"
          unless (fmap (B.length . displayFIFOBuffer) (phaseDisplayState line) == Just 512) $ fail "display FIFO"
        _ -> fail "wrong phase count"
      case reverse os of
        [EngineOracle e, ScreenOracle o] ->
          unless (B.length (oracleEnginePixels e) == 1024 && B.length (oracleTop o) == 1024 && B.length (oracleBottom o) == 1024) $ fail "oracle callback"
        _ -> fail "oracle callback count"
      B.writeFile path (header 9 <> extPal <> latches <> record 1 registers)
      v9 <- newIORef []
      replayTrace path (\p -> modifyIORef' v9 (p:)) (const (fail "unexpected capture")) (const (fail "unexpected oracle"))
      legacy <- readIORef v9
      case legacy of
        [p] -> unless (phaseDisplayState p == Nothing) $ fail "v9 compatibility"
        _ -> fail "v9 phase count"
      let begin y = record 15 (le32 0 <> le16 y <> B.replicate 18 0)
          end y = record 17 (le32 0 <> le16 y <> B.replicate 38 0)
          captureDelta y prefix = record 16 (le32 0 <> le16 y <> B.pack [2,0] <> le32 0 <>
                                            B.pack prefix <> B.replicate 508 0)
          captureInput = header 11 <> delta 2 0 (B.pack [0x22,0x11,0x44,0x33]) <>
                         record 5 (le32 7 <> le32 5 <> le32 1 <> B.pack [0x20,0,0,0] <> le32 99) <>
                         begin 0 <> captureDelta 0 [0x34,0x12,0x44,0x33] <> end 0 <>
                         delta 2 2 (B.pack [0x78,0x56]) <>
                         record 7 (le32 7 <> le32 6 <> le32 1 <> le32 0x4000060 <> le32 4 <> B.pack [2,0,0,0]) <>
                         begin 1 <> captureDelta 1 [0x78,0x56,0x78,0x56] <> end 1 <>
                         extPal <> latches <> display <> record 1 registers <>
                         record 6 (le32 7 <> le32 7 <> le32 1 <> le32 3 <> le32 1 <> le32 2)
          runCapture callback out =
            replayTrace path (\p -> modifyIORef' out (p:)) callback (const (pure ()))
          correct event = case event of
            CaptureBegin _ 0 _ _ _ m -> do
              unless (map (readRegion8 m 2) [0..3] == [0x22,0x11,0x44,0x33]) $
                fail "capture saw expected bytes before first write"
              pure [(0,0,0x1234)]
            CaptureBegin _ 1 _ _ _ m -> do
              unless (map (readRegion8 m 2) [0..3] == [0x34,0x12,0x78,0x56]) $
                fail "CPU delta or same-bank capture feedback out of order"
              let word = fromIntegral (readRegion8 m 2 2) + fromIntegral (readRegion8 m 2 3) * 256
              pure [(0,0,word)]
            _ -> fail "unexpected capture event"
          reject label callback out = do
            result <- try (runCapture callback out) :: IO (Either IOException ())
            case result of
              Left _ -> pure ()
              Right () -> fail (label ++ " capture writes accepted")
      B.writeFile path captureInput
      captured <- newIORef []
      runCapture correct captured
      cp <- readIORef captured
      case cp of
        [p] -> unless (map (readRegion8 (phaseMemory p) 2) [0..3] == [0x78,0x56,0x78,0x56]) $
                 fail "capture writes missing from independent memory"
        _ -> fail "v11 phase count"
      ordered <- newIORef []
      replayTraceGeometry path
        (\timestamp event memory -> do
           let expected = case event of
                 GeometryCommand{} -> [0x22,0x11,0x44,0x33]
                 GeometryRegister{} -> [0x34,0x12,0x78,0x56]
                 GeometryFrameSummary{} -> [0x78,0x56,0x78,0x56]
           unless (map (readRegion8 memory 2) [0..3] == expected) $
             fail "geometry event saw memory from the wrong point in the stream"
           modifyIORef' ordered (++ [(timestamp, Just event)]))
        (const (modifyIORef' ordered (++ [(0,Nothing)]))) correct (const (pure ()))
      events <- readIORef ordered
      unless (events == [(0x100000005,Just (GeometryCommand 7 0x20 99)),
                         (0x100000006,Just (GeometryRegister 7 0x4000060 4 2)),
                         (0,Nothing),
                         (0x100000007,Just (GeometryFrameSummary 7 3 1 2))]) $
        fail "geometry order, timestamp or final record"
      reject "missing" (const (pure [])) captured
      reject "extra" (const (pure [(0,0,0x1234),(0,300,0x5678)])) captured
      reject "wrong" (const (pure [(0,0,0x1235)])) captured
      let stamp n = le32 n <> le32 1
          render flags = le32 9 <> le16 215 <> le16 0 <> stamp 4 <> le16 7 <>
                         B.pack [1,1,flags,0] <> B.pack [0..8] <> B.replicate 3 0 <>
                         B.concat (map le32 [1,2,4,8]) <> B.concat (map le32 [16..23])
          boundary y = le32 9 <> le16 y <> le16 0 <> stamp 5
          inputs = header 12 <> delta 2 0 (B.pack [9,8]) <>
                   record 20 (le32 9 <> stamp 1 <> B.pack [1,0,0,0] <> le32 8) <>
                   record 21 (le32 9 <> stamp 2 <> le16 7 <> le16 0) <>
                   record 22 (le32 9 <> stamp 3 <> le32 1 <> le32 0) <>
                   record 23 (render 1) <> record 23 (render 0) <>
                   record 24 (boundary 262) <> record 25 (boundary 192) <>
                   record 26 (le32 9 <> stamp 6 <> le32 0x4000400 <> le32 0x12345678 <> B.pack [4,0,0,0])
          renderEvent initial = GeometryRenderStart 9 215 7 True True initial (B.pack [0..8]) [1,2,4,8] [16..23]
      B.writeFile path inputs
      raw3d <- newIORef []
      replayTraceGeometry path
        (\timestamp event memory -> do
           unless (readRegion8 memory 2 0 == 9 && readRegion8 memory 2 1 == 8) $
             fail "v12 3D event lost render-start VRAM"
           modifyIORef' raw3d (++ [(timestamp,event)]))
        (const (fail "unexpected phase")) (const (fail "unexpected capture")) (const (fail "unexpected oracle"))
      rawEvents <- readIORef raw3d
      unless (rawEvents == [(0x100000001,GeometryPower 9 True False 8),
                            (0x100000002,GeometryXPos 9 7),
                            (0x100000003,GeometryAbort 9 True),
                            (0x100000004,renderEvent True),
                            (0x100000004,renderEvent False),
                            (0x100000005,GeometryFrameEnd 9 262),
                            (0x100000005,GeometryVBlank 9 192),
                            (0x100000006,GeometryGxWrite 9 0x4000400 0x12345678 4)]) $
        fail "v12 3D input decoding"
      putStrLn "NSD2 v9-v12 phases, geometry, capture provenance, CPU deltas and same-bank feedback: passed"
    ) `finally` removeFile path
