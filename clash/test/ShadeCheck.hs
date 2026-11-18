-- | Native differential checker for pixel shading.
--
-- Reads @unit_oracle shade@: the toon table, then production @RenderPixel@
-- results over every blend mode (modulate, decal, toon, highlight, shadow),
-- texture on and off, every texel/vertex colour pair on one channel, every
-- texture alpha against every polygon alpha, and every RGB555 texel through
-- the direct VRAM path.
module Main (main) where

import Control.Monad (forM_, when)
import Data.Array.Unboxed (UArray, bounds, (!))
import Data.Bits (shiftR, testBit, (.&.))
import Data.Word (Word32)
import Numeric (showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu3D.Shade

import OracleIO (readWords)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> do
      ws <- readWords path
      let (lo, hi) = bounds ws
          total = hi - lo + 1
          toonT = [ws ! i | i <- [0 .. 31]]
          toon i = fromIntegral (toonT !! fromIntegral (i .&. 0x1F))
          n = (total - 32) `div` 5
          results = map (one toon ws) [0 .. n - 1]
          failures = [e | Just e <- results]
      forM_ (take 8 failures) (putStrLn . ("FAIL " ++))
      putStrLn ("shade-check: " ++ show n ++ " pixels, "
        ++ show (length failures) ++ " failures")
      when (n == 0 || not (null failures)) exitFailure
    _ -> putStrLn "usage: shade-check FILE" >> exitFailure

one :: (Word32 -> Word32) -> UArray Int Word32 -> Int -> Maybe String
one toon ws k =
  let at j = ws ! (32 + 5 * k + j)
      variant = at 0
      vcol = at 1
      texel = at 2
      pa = at 3
      want = at 4
      mode = fromIntegral (variant .&. 3)
      st = ShadeState mode (mode == 2 && testBit variant 2) (fromIntegral pa)
      ch w sh = fromIntegral ((w `shiftR` sh) .&. 0x3F)
      tex
        | not (testBit variant 3) = Nothing
        | testBit variant 4 =
            Just (expand555 (fromIntegral (texel .&. 0x7FFF)), if testBit texel 15 then 31 else 0)
        | otherwise = Just ((ch texel 0, ch texel 8, ch texel 16), fromIntegral (texel `shiftR` 24))
      got = shadePixel (fromIntegral (toon ((vcol .&. 0x3F) `shiftR` 1))) st
              (ch vcol 0, ch vcol 8, ch vcol 16) tex
  in if got == want then Nothing
     else Just ("variant=0x" ++ showHex variant "" ++ " vcol=0x" ++ showHex vcol ""
                ++ " texel=0x" ++ showHex texel "" ++ " polyalpha=" ++ show pa
                ++ " want=0x" ++ showHex want "" ++ " got=0x" ++ showHex got "")
