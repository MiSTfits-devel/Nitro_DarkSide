-- | Native differential checker for attribute interpolation.
--
-- Reads @unit_oracle attr@ records: one production @Interpolator<0>@ (span) or
-- @Interpolator<1>@ (edge) setup, then @SetX@ over consecutive and scattered X
-- with @Interpolate@ for a vertex colour, a texture coordinate and a W value,
-- and @InterpolateZ@ for a depth, at every X.
module Main (main) where

import Control.Monad (forM_)
import Data.Array.Unboxed (UArray, bounds, (!))
import Data.Bits (testBit)
import Data.Int (Int32)
import Data.Word (Word32)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu3D.Depth

import OracleIO (readWords)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> do
      ws <- readWords path
      let setups = parse ws 0
          results = concatMap check setups
          failures = [e | Just e <- results]
          samples = length results
      forM_ (take 8 failures) (putStrLn . ("FAIL " ++))
      putStrLn ("attr-check: " ++ show (length setups) ++ " interpolators, "
        ++ show samples ++ " samples x 4 values, "
        ++ show (length failures) ++ " failures")
      if null setups || not (null failures) then exitFailure else pure ()
    _ -> putStrLn "usage: attr-check FILE" >> exitFailure

data Setup = Setup
  { sDir, sWBuf :: Bool
  , sX0, sX1, sW0, sW1 :: Int32
  , sVals :: [(Int32, Int32)]  -- colour, texcoord, W, then Z endpoints
  , sSamples :: [(Int32, [Int32])]
  }

parse :: UArray Int Word32 -> Int -> [Setup]
parse ws i
  | i > snd (bounds ws) = []
  | otherwise =
      let at k = fromIntegral (ws ! (i + k)) :: Int32
          flags = ws ! i
          n = fromIntegral (ws ! (i + 13)) :: Int
          vals = [(at 5, at 6), (at 7, at 8), (at 9, at 10), (at 11, at 12)]
          sample j = let b = i + 14 + 5 * j
                     in (fromIntegral (ws ! b), [fromIntegral (ws ! (b + k)) | k <- [1 .. 4]])
          s = Setup (testBit flags 0) (testBit flags 1) (at 1) (at 2) (at 3) (at 4)
                vals (map sample [0 .. n - 1])
      in s : parse ws (i + 14 + 5 * n)

check :: Setup -> [Maybe String]
check s = map one (sSamples s)
  where
    base = setupInterp (sDir s) (sX0 s) (sX1 s) (sW0 s) (sW1 s) (sWBuf s)
    one (x, want) =
      let i = setX x base
          [(a0, a1), (b0, b1), (c0, c1), (z0, z1)] = sVals s
          got = [interpolate a0 a1 i, interpolate b0 b1 i, interpolate c0 c1 i, interpolateZ z0 z1 i]
      in if got == want then Nothing
         else Just ("dir=" ++ show (sDir s) ++ " wbuf=" ++ show (sWBuf s)
                    ++ " x0=" ++ show (sX0 s) ++ " x1=" ++ show (sX1 s)
                    ++ " w=" ++ show (sW0 s, sW1 s) ++ " x=" ++ show x
                    ++ " vals=" ++ show (sVals s)
                    ++ " want=" ++ show want ++ " got=" ++ show got)
