-- | Native differential checker for texture sampling.
--
-- Reads @unit_oracle texel@ records (TexParam, TexPalette, S and T, and the
-- production @TextureLookup@ colour and alpha) and the VRAM image the oracle
-- sampled, and recomputes each texel through the staged 'textureLookup'.
module Main (main) where

import Control.Monad (forM_, when)
import Data.Array.Unboxed (UArray, bounds, (!))
import Data.Bits (shiftR, (.&.))
import Data.Int (Int16)
import qualified Data.Map.Strict as M
import Data.Word (Word32)
import Numeric (showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu3D.Texture

import OracleIO (imageMemory, readWords)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [recPath, imgPath] -> do
      recs <- readWords recPath
      img <- readWords imgPath
      when (count img /= 0x28000) $ putStrLn "FAIL short VRAM image" >> exitFailure
      let mem = imageMemory img
          n = count recs `div` 4
          results = map (one mem recs) [0 .. n - 1]
          failures = [e | (_, Just e) <- results]
          perFormat = M.fromListWith (+) [(f, 1 :: Int) | (f, _) <- results]
      forM_ (take 8 failures) (putStrLn . ("FAIL " ++))
      putStrLn ("texel-check: " ++ show n ++ " lookups ("
        ++ unwords [ name f ++ "=" ++ show c | (f, c) <- M.toList perFormat ]
        ++ "), " ++ show (length failures) ++ " failures")
      when (n == 0 || not (null failures)) exitFailure
    _ -> putStrLn "usage: texel-check RECORDS IMAGE" >> exitFailure

count :: UArray Int Word32 -> Int
count a = let (lo, hi) = bounds a in hi - lo + 1

one :: TexMem -> UArray Int Word32 -> Int -> (Word32, Maybe String)
one mem recs k =
  let tp = recs ! (4 * k)
      pal = recs ! (4 * k + 1)
      st = recs ! (4 * k + 2)
      out = recs ! (4 * k + 3)
      s = fromIntegral (st .&. 0xFFFF) :: Int16
      t = fromIntegral (st `shiftR` 16) :: Int16
      Texel c a = textureLookup mem (texState tp pal) s t
      want = (fromIntegral (out .&. 0xFFFF), fromIntegral (out `shiftR` 16))
  in ( (tp `shiftR` 26) .&. 0x7
     , if (c, a) == want then Nothing
       else Just ("texparam=0x" ++ showHex tp "" ++ " texpal=0x" ++ showHex pal ""
                  ++ " s=" ++ show s ++ " t=" ++ show t
                  ++ " want=" ++ show want ++ " got=" ++ show (c, a)) )

name :: Word32 -> String
name f = case f of
  1 -> "A3I5"
  2 -> "pal4"
  3 -> "pal16"
  4 -> "pal256"
  5 -> "4x4"
  6 -> "A5I3"
  _ -> "direct"
