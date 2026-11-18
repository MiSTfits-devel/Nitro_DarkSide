-- | Independent gate for Nds.Gpu2D.Capture: production
-- SoftRenderer::DoCapture is the only source of expected VRAM changes.
module Main (main) where

import Control.Monad (unless, when)
import Data.Bits (shiftR, (.&.))
import qualified Data.Binary.Get as G
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.IntMap.Strict as IM
import Data.Word (Word16, Word32)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu2D.Capture

data Case = Case
  { cCnt, cLine, cLcdc, cDispCnt, cSeed :: Word32
  , cSrc2D, cSrc3D :: [Word32]
  , cFifo :: [Word16]
  , cChanges :: [(Word32, Word16)]
  , cFlagsStart, cFlagsEnd :: [Word16]
  }

parseFile :: FilePath -> IO [Case]
parseFile path = do
  raw <- BL.readFile path
  pure $ G.runGet (do
    magic <- G.getByteString 4
    unless (magic == B.pack [67,65,80,49]) (fail "bad CAP1 magic")
    n <- G.getWord32le
    mapM (const parseCase) [1 .. n]) raw

parseCase :: G.Get Case
parseCase = do
  cnt <- G.getWord32le; ln <- G.getWord32le; lc <- G.getWord32le
  dc <- G.getWord32le; sd <- G.getWord32le
  s2 <- mapM (const G.getWord32le) [1 .. 256]
  s3 <- mapM (const G.getWord32le) [1 .. 256]
  fifo <- mapM (const G.getWord16le) [1 .. 256]
  n <- G.getWord32le
  ch <- mapM (const ((,) <$> G.getWord32le <*> G.getWord16le)) [1 .. n]
  fs <- mapM (const G.getWord16le) [1 .. 16]
  fe <- mapM (const G.getWord16le) [1 .. 16]
  pure (Case cnt ln lc dc sd s2 s3 fifo ch fs fe)

bankWord :: Word32 -> Int -> Word32 -> Word16
bankWord seed b i =
  fromIntegral ((seed * 37 + fromIntegral b * 911 + i * 1103 + (i `div` 128)) .&. 0xFFFF)

checkCase :: Int -> Case -> [String]
checkCase n c =
  let inp = CaptureInput
        { ciState = emptyCaptureState
        , ciCaptureCnt = cCnt c
        , ciLine = cLine c
        , ciVramMapLCDC = cLcdc c
        , ciDispCntA = cDispCnt c
        , ciSrc2D = cSrc2D c
        , ciSrc3D = cSrc3D c
        , ciSrcBFifo = cFifo c
        , ciVramRead = \b i -> bankWord (cSeed c) b i
        }
      out = captureLine inp
      dstbank = fromIntegral ((cCnt c `shiftR` 16) .&. 3) :: Int
      finalMap = foldl (\m (b, a, v) -> if b == dstbank then IM.insert (fromIntegral a) v m else m)
                       IM.empty (coWrites out)
      actual = IM.fromList [ (i, v) | (i, v) <- IM.toList finalMap
                         , v /= bankWord (cSeed c) dstbank (fromIntegral i) ]
      expected = IM.fromList (map (\(a, v) -> (fromIntegral a, v)) (cChanges c))
      badWrites = [ (b, a) | (b, a, _) <- coWrites out, b /= dstbank ]
      st1 = captureStart emptyCaptureState (cCnt c) (cLcdc c)
      st2 = captureEnd st1 (cCnt c)
  in [ "case " ++ show n ++ ": " ++ what
     | (what, bad) <- [ ("wrong-bank writes " ++ show badWrites, not (null badWrites))
                      , ("VRAM map mismatch: got " ++ show (IM.size actual) ++ " expected " ++ show (IM.size expected),
                         actual /= expected)
                      , ("capture start flags " ++ show (csFlags st1) ++ " expected " ++ show (cFlagsStart c),
                         csFlags st1 /= cFlagsStart c)
                      , ("capture end flags " ++ show (csFlags st2) ++ " expected " ++ show (cFlagsEnd c),
                         csFlags st2 /= cFlagsEnd c)
                      ]
     , bad ]

main :: IO ()
main = do
  args <- getArgs
  path <- case args of [p] -> pure p; _ -> putStrLn "usage: capture-check <oracle.bin>" >> exitFailure
  cases <- parseFile path
  let failures = concat [ checkCase i c | (i, c) <- zip [0 :: Int ..] cases ]
  mapM_ putStrLn failures
  putStrLn ("capture-check: " ++ show (length cases) ++ " cases, " ++ show (length failures) ++ " mismatches")
  when (not (null failures)) exitFailure
