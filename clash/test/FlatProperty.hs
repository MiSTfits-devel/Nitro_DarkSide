{-# LANGUAGE DataKinds #-}

-- | Exhaustive small-grid equivalence gate for the flat row shortcut.
--
-- 'Nds.Gpu3D.Flat.rowSpanFast' assumes the three melonDS fill segments are
-- contiguous under the forced-opaque configuration. This gate enumerates every
-- ordered triple of distinct vertices on a small grid, walks both the fast and the
-- exact row machinery, and compares the covered X sets scanline by scanline.
module Main (main) where

import Data.Bits (shiftR)
import Data.Int (Int32)
import Data.List (sort)
import Data.Word (Word64)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Clash.Prelude (Vec (..))

import Nds.Gpu3D.Flat (flatCfg, screenH, screenW)
import Nds.Gpu3D.Raster

gridX :: [Int32]
gridX = [-2 .. 5]

gridY :: [Int32]
gridY = [-2 .. 7]

points :: [(Int32, Int32)]
points = [(x, y) | x <- gridX, y <- gridY]

expand :: Maybe (Int32, Int32) -> [Int32]
expand Nothing = []
expand (Just (a, b)) = [max 0 a .. min (screenW - 1) b]

cover :: [Maybe (Int32, Int32)] -> [Int32]
cover = sort . concatMap expand

walk :: Bool -> (Int32, Int32) -> (Int32, Int32) -> (Int32, Int32) -> [(Int32, [Int32], [Int32])]
walk facing (x0, y0) (x1, y1) (x2, y2) =
  let tri = mkTri facing (Vertex x0 y0 0 0 0 0 0 :> Vertex x1 y1 0 0 0 0 0 :> Vertex x2 y2 0 0 0 0 0 :> Nil)
      yb = triYBottom tri
      go y rf rs acc
        | y >= yb = reverse acc
        | otherwise =
            let (_, xs, xe, rf') = prepareRowFast y rf
                fast = let (a, b) = if xs > xe then (xe, xs) else (xs, xe)
                           lo = max 0 a
                           hi = min (screenW - 1) b
                       in if lo <= hi then [lo .. hi] else []
                ((sa, sb, sc), rs') = rowSpans flatCfg y rs
                exact = cover [sa, sb, sc]
                onScreen = y >= 0 && y < screenH
            in go (y + 1) rf' rs' (if onScreen then (y, fast, exact) : acc else acc)
  in go (triYTop tri) (setupRasterFast tri) (setupRaster tri) []

check :: Bool -> (Int32, Int32) -> (Int32, Int32) -> (Int32, Int32) -> Maybe String
check facing a b c =
  case [ (y, fast, exact) | (y, fast, exact) <- walk facing a b c, fast /= exact ] of
    [] -> Nothing
    ((y, fast, exact) : _) ->
      Just (show facing ++ " " ++ show [a, b, c] ++ " y=" ++ show y
            ++ " fast=" ++ show fast ++ " exact=" ++ show exact)

lcg :: Word64 -> Word64
lcg s = s * 736413722395729017 + 243269519089996359

draw :: Word64 -> Int32 -> Int32 -> (Int32, Word64)
draw s lo hi =
  let s' = lcg s
      span' = fromIntegral (hi - lo + 1) :: Word64
      v = fromIntegral ((s' `shiftR` 0x21) `mod` span') + lo
  in (v, s')

randomCase :: Word64 -> ((Bool, (Int32, Int32), (Int32, Int32), (Int32, Int32)), Word64)
randomCase s0 =
  let (x0, s1) = draw s0 (negate 0x40) (screenW + 0x40)
      (y0, s2) = draw s1 (negate 0x40) (screenH + 0x40)
      (x1, s3) = draw s2 (negate 0x40) (screenW + 0x40)
      (y1, s4) = draw s3 (negate 0x40) (screenH + 0x40)
      (x2, s5) = draw s4 (negate 0x40) (screenW + 0x40)
      (y2, s6) = draw s5 (negate 0x40) (screenH + 0x40)
      (f, s7) = draw s6 0 1
  in ((odd f, (x0, y0), (x1, y1), (x2, y2)), s7)

main :: IO ()
main = do
  args <- getArgs
  let randomCount = case args of
                      (a:_) -> read a
                      [] -> 0x40000
      triples = [ (a, b, c)
                | a <- points, b <- points, c <- points
                ]
      exhaustive = [ (facing, a, b, c)
                   | facing <- [False, True]
                   , (a, b, c) <- triples
                   ]
      random = map fst (take randomCount (iterate (\(_, s) -> randomCase s) (randomCase 0x123456789abcdef)))
      cases = exhaustive ++ random
      failures = [ (i, e) | (i, Just e) <- zip [0 :: Int ..] (map (\(f, a, b, c) -> check f a b c) cases) ]
  mapM_ (\(i, e) -> putStrLn ("FAIL case " ++ show i ++ ": " ++ e)) (take 8 failures)
  putStrLn ("flat-property: " ++ show (length cases) ++ " cases, "
    ++ show (length failures) ++ " failures")
  if null failures then pure () else exitFailure
