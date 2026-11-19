-- | Native checker for the unified 3D/2D pixel path.
--
-- 1. With no 3D pixels, BG0 contributes no pixels, including its text BG.
-- 2. With an opaque 3D pixel on BG0, it appears at its original position.
-- 3. A transparent 3D pixel leaves the other layers/backdrop visible.
module Main (main) where

import Data.Bits ((.&.), complement, shiftL, shiftR, xor)
import Data.List (zipWith)
import Data.Word (Word32)
import System.Exit (exitFailure)

import Nds.Gpu.Unified
import Nds.Gpu2D.Line (renderReferenceFrame)
import Nds.Gpu2D.Types

main :: IO ()
main = do
  let es = mkState 1
      no3d = UnifiedInput es []
      opaque3d = UnifiedInput es [(17, 40, 0xFF336699)]
      transparent3d = UnifiedInput es [(17, 40, 0x00336699)]
      flat = unifiedFrame no3d
      flatRef = renderReferenceFrame es { esDispCnt = esDispCnt es .&. complement 0x100 }
      flatLine = unifiedLine no3d 40
      withChar = unifiedLine opaque3d 40
      transLine = unifiedLine transparent3d 40
      repeated = unifiedLine (UnifiedInput es
        [ (17,40,0x1f010203), (42,40,0x1f22333f)
        , (-1,40,0x1f101010), (17,41,0x1f112233)
        , (17,40,0x0000ffff), (300,40,0x1f202020)
        , (17,40,0x1f0a0b0c), (17,40,0x00ffffff)
        , (42,39,0x1f010101) ]) 40
      failures = concat
        [ [ "no 3D differs from the reference at line " ++ show y
          | (y, a, b) <- zip3 [0 ..] flat flatRef
          , a /= b ]
        , [ "opaque 3D did not replace BG0 at (17,40)"
          | withChar !! 17 /= Just (Pixel (0xFF336699 .&. 0x00FFFFFF) L3D) ]
        , [ "opaque 3D changed another pixel"
          | length changed /= 0 ]
        , [ "transparent 3D did not preserve BG0"
          | transLine /= flatLine ]
        , [ "unified frame lost pixel positions"
          | any ((/= 256) . length) flat ]
        , [ "unordered/duplicate sparse 3D lost last opaque position"
          | repeated !! 17 /= Just (Pixel 0x0a0b0c L3D)
            || repeated !! 42 /= Just (Pixel 0x22333f L3D) ]
        , [ "out-of-bounds/wrong-line 3D changed another position"
          | or [a/=b | (x,a,b) <- zip3 [0..] flatLine repeated, x/=17, x/=42] ]
        ]
      changed =
        [ x | (x, a, b) <- zip3 [0 ..] flatLine withChar
            , a /= b, x /= 17 ]
  mapM_ (putStrLn . ("FAIL " ++)) failures
  putStrLn ("unified-check: " ++ show (length failures) ++ " failures")
  if null failures then pure () else exitFailure

mkState :: Word32 -> EngineState
mkState seed = EngineState
  { esNum = 0
  , esDispCnt = 0x00000108  -- mode 0, BG0 sourced from 3D
  , esBg = V4
      (BgReg 0x0000 (fromIntegral seed) 0 0 0 0 0 (fromIntegral seed) 0)
      (BgReg 0x0080 (fromIntegral seed + 1) 0 0 0 0 0 0 0)
      (BgReg 0x0400 0 0 0 0 0 0 0 0)
      (BgReg 0x0000 0 0 0 0 0 0 0 0)
  , esBlendCnt = 0
  , esEva = 0
  , esEvb = 0
  , esEvy = 0
  , esObjMosaicLine = 0
  , esBgMosaicX = 0
  , esBgExtPal = mem 0
  , esBgMosaicLine = 0
  , esOam = mem 0x1234
  , esVram = mem 0x5678
  , esObjVram = mem 0x9ABC
  , esPalette = mem 0xDEF0
  , esOamEpoch = 0
  , esVramEpoch = 0
  , esPaletteEpoch = 0
  }

mem :: Word32 -> Memory
mem s = Memory 0x000FFFFF
  (\a -> fromIntegral (step (a `xor` s)))

step :: Word32 -> Word32
step x =
  let x1 = x `xor` (x `shiftL` 13)
      x2 = x1 `xor` (x1 `shiftR` 17)
  in x2 `xor` (x2 `shiftL` 5)
