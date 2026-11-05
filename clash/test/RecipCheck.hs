-- | Constant-table gate for the flat edge walk.
--
-- The flat rasteriser uses a 257-entry table for on-screen denominators and
-- falls back to the exact divider for taller edges. This checks both halves
-- against 'reciprocal18' for every denominator in the swept range.
module Main (main) where

import Data.Int (Int32)
import System.Exit (exitFailure)

import Nds.Gpu3D.Slope (reciprocal18, reciprocal18Tab)

check :: Int32 -> Maybe String
check d =
  let want = reciprocal18 d
      got = reciprocal18Tab d
  in if want == got then Nothing
     else Just ("d=" ++ show d ++ " exact=" ++ show want ++ " table=" ++ show got)

main :: IO ()
main = do
  let ds = [negate 0x200 .. 0x400]
      results = [(d, e) | d <- ds, Just e <- [check d]]
  mapM_ (\(_, e) -> putStrLn ("FAIL " ++ e)) (take 8 results)
  putStrLn ("recip-check: " ++ show (length ds) ++ " denominators, "
    ++ show (length results) ++ " failures")
  if null results then pure () else exitFailure
