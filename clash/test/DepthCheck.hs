-- | Native differential checker for the edge depth interpolator.
--
-- Reads the @DEPTH@ records from @slope_oracle@: the production
-- @Slope<Side>::Setup@ with W values, the interpolator endpoints it chose, and
-- @Interpolator::InterpolateZ@ at eight scanlines spread across the edge.
module Main (main) where

import Control.Monad (forM_)
import Data.Int (Int32)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Text.Read (readMaybe)

import Nds.Gpu3D.Depth
import Nds.Gpu3D.Slope

data Case = Case
  { cSide :: Int32
  , cX0, cX1, cY0, cY1, cW0, cW1, cY :: Int32
  , cWBuf :: Bool
  , cZ0, cZ1, cIX0, cIX1 :: Int32
  , cZs :: [Int32]
  } deriving Show

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> do
      text <- readFile path
      let cases = [c | Just c <- map parseLine (lines text)]
          failures = [(i, e) | (i, Just e) <- zip [0 :: Int ..] (map check cases)]
      forM_ (take 8 failures) $ \(i, e) ->
        putStrLn ("FAIL depth case " ++ show i ++ ": " ++ e)
      putStrLn ("depth-check: " ++ show (length cases) ++ " cases, "
        ++ show (length failures) ++ " failures")
      if null cases || not (null failures) then exitFailure else pure ()
    _ -> do
      putStrLn "usage: depth-check FILE"
      exitFailure

parseLine :: String -> Maybe Case
parseLine line =
  case words line of
    ("DEPTH":rest) ->
      case traverse readMaybe rest of
        Just (side : x0 : x1 : y0 : y1 : w0 : w1 : y : wb : z0 : z1 : ix0 : ix1 : zs)
          | length zs == 8 ->
              Just (Case side x0 x1 y0 y1 w0 w1 y (wb /= 0) z0 z1 ix0 ix1 zs)
        _ -> Nothing
    _ -> Nothing

check :: Case -> Maybe String
check c =
  case slopeInterp slope of
    Nothing -> Just ("no interpolator for " ++ show c)
    Just interp
      | (interpX0 interp, interpX1 interp) /= (cIX0 c, cIX1 c) ->
          Just ("endpoints want=" ++ show (cIX0 c, cIX1 c)
                ++ " got=" ++ show (interpX0 interp, interpX1 interp)
                ++ " for " ++ show c)
      | otherwise ->
          let got = [ interpolateZ (cZ0 c) (cZ1 c) (setX sy interp) | sy <- samples ]
          in if got == cZs c
               then Nothing
               else Just ("z want=" ++ show (cZs c) ++ " got=" ++ show got
                          ++ " for " ++ show c)
  where
    -- The oracle clamps the setup scanline into the edge before Setup.
    ylo = min (cY0 c) (cY1 c)
    yhi = max (cY0 c) (cY1 c)
    sy0 = max ylo (min yhi (cY c))
    (_, slope) = setupSlope (cSide c /= 0) (cX0 c) (cX1 c) (cY0 c) (cY1 c)
                            (cW0 c) (cW1 c) sy0 (cWBuf c)
    ymin = ylo
    ymax = yhi - (if cY0 c /= cY1 c then 1 else 0)
    -- C++ integer division truncates toward zero: 'quot', not 'div'.
    samples = [ ymin + ((ymax - ymin) * i) `quot` 7 | i <- [0 .. 7] ]
