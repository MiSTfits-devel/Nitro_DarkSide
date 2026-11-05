{-# LANGUAGE BangPatterns #-}

-- | Generate random flat-triangle cases for the raster gate.
--
-- Usage: gen-raster-cases COUNT OUT
module Main (main) where

import Control.Monad (forM, replicateM, unless)
import Data.List (nub, sort)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.Random (randomRIO)

width, height :: Int
width = 256
height = 192

pickYs :: IO [Int]
pickYs = replicateM 3 (randomRIO (0, height - 1))

main :: IO ()
main = do
  args <- getArgs
  case args of
    [countText, outPath] -> do
      let count = read countText
      cases <- forM [1 .. count] $ \i -> do
        ys <- pickYs
        xs <- replicateM 3 (randomRIO (-(width `div` 8), width + width `div` 8 - 1))
        let color = 1 + (i `mod` 63)
            facing = isOdd i
            verts = zipWith (\x y -> " " ++ show x ++ " " ++ show y)
              xs (sort ys)
        pure $ "TRI" ++ concat verts ++ " "
          ++ show color ++ " " ++ show (color `div` 2) ++ " "
          ++ show (color `div` 3) ++ " " ++ (if facing then "1" else "0")
      writeFile outPath (unlines cases)
    _ -> do
      putStrLn "usage: gen-raster-cases COUNT OUT"
      exitFailure

isOdd :: Int -> Bool
isOdd n = n `mod` 2 == 1
