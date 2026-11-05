{-# LANGUAGE BangPatterns #-}

-- | Differential gate for the flat triangle rasteriser.
--
-- Usage: raster-check CASES ORACLE
--
-- CASES is a text file of @TRI x0 y0 x1 y1 x2 y2 r g b@ lines. ORACLE is
-- the concatenated raw RGBA word buffers produced by the melonDS oracle, one
-- frame per case. The checker compares the model's covered-pixel set with the
-- oracle's non-zero pixels.
module Main (main) where

import Control.Monad (forM_, when)
import qualified Data.ByteString.Lazy as BL
import Data.Binary.Get (getWord32le, runGet)
import Data.Int (Int32)
import qualified Data.Set as S
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Text.Read (readMaybe)

import Clash.Prelude (Vec (..))

import Nds.Gpu3D.Raster

width, height :: Int
width = 256
height = 192

wordBytes :: Int
wordBytes = 4

parseCase :: String -> Maybe Tri
parseCase line =
  case words line of
    ("TRI":rest) ->
      case traverse readMaybe rest of
        Just vals ->
          case splitAt 9 vals of
            ([x0, y0, x1, y1, x2, y2, r, g, b], faceArg) ->
              let face = case faceArg of
                    [] -> True
                    (f:_) -> f /= 0
              in Just $ mkTri face
                ( Vertex x0 y0 0 0 r g b
                :> Vertex x1 y1 0 0 r g b
                :> Vertex x2 y2 0 0 r g b
                :> Nil
                )
            _ -> Nothing
        _ -> Nothing
    _ -> Nothing

oraclePoints :: BL.ByteString -> S.Set (Int, Int)
oraclePoints bs =
  let wordsOut = runGet (sequence (replicate (width * height) getWord32le)) bs
  in S.fromList
       [ (x, y)
       | (i, w) <- zip [0 ..] wordsOut
       , w /= 0
       , let (y, x) = i `divMod` width
       ]

modelPoints :: Int32 -> Tri -> S.Set (Int, Int)
modelPoints dispCnt tri =
  let rows = rasterTri (RasterConfig dispCnt 31 False 256) tri
      y0 = fromIntegral (max 0 (triYTop tri)) :: Int
  in S.fromList
       [ (fromIntegral x, y)
       | (y, xs) <- zip [y0 ..] rows
       , x <- xs
       , x >= 0
       , x < fromIntegral width
       , y >= 0
       , y < height
       ]

main :: IO ()
main = do
  args <- getArgs
  case args of
    [casesPath, oraclePath] -> run casesPath oraclePath 0
    [casesPath, oraclePath, dispCntArg] ->
      case readMaybe dispCntArg of
        Just dispCnt -> run casesPath oraclePath dispCnt
        Nothing -> error ("bad DISPCNT: " ++ dispCntArg)
    _ -> do
      putStrLn "usage: raster-check CASES ORACLE [DISPCNT]"
      exitFailure
  where
    run casesPath oraclePath dispCnt = do
      caseText <- readFile casesPath
      oracleBin <- BL.readFile oraclePath
      let cases = [c | Just c <- map parseCase (lines caseText)]
          frameSize = width * height * wordBytes
          frames = chunksOfBytes frameSize oracleBin
      when (length cases /= length frames) $
        error ("case/frame count mismatch: "
          ++ show (length cases) ++ " vs " ++ show (length frames))
      let results = zipWith (checkOne dispCnt) cases frames
          failures = length (filter not results)
      let failuresIdx = [i | (i, ok) <- zip [0 ..] results, not ok]
      forM_ (take 3 failuresIdx) $ \i -> do
        let tri = cases !! i
            expected = oraclePoints (frames !! i)
            actual = modelPoints dispCnt tri
            rows = rasterTri (RasterConfig dispCnt 31 False 256) tri
            y0 = fromIntegral (max 0 (triYTop tri)) :: Int
        putStrLn ("FAIL case " ++ show i ++ " " ++ show (triVertices tri))
        putStrLn ("  expected " ++ show (S.size expected)
          ++ " actual " ++ show (S.size actual))
        putStrLn ("  missing " ++ show (take 12 (S.toList (expected S.\\ actual))))
        putStrLn ("  extra   " ++ show (take 12 (S.toList (actual S.\\ expected))))
        forM_ (take 4 (zip [y0 ..] rows)) $ \(y, xs) ->
          putStrLn ("  row " ++ show y ++ ": " ++ show xs)
      putStrLn ("raster-check: " ++ show (length cases)
        ++ " cases, " ++ show failures ++ " failures")
      when (failures /= 0) exitFailure


checkOne :: Int32 -> Tri -> BL.ByteString -> Bool
checkOne dispCnt tri frame =
  let expected = oraclePoints frame
      actual = modelPoints dispCnt tri
  in expected == actual

chunksOfBytes :: Int -> BL.ByteString -> [BL.ByteString]
chunksOfBytes n bs
  | BL.null bs = []
  | otherwise = let (a, b) = BL.splitAt (fromIntegral n) bs
                in a : chunksOfBytes n b
