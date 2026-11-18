-- | Directed checker for the pure 2D line renderer.
--
-- Hand-computed pixel cases: 4bpp and 8bpp text backgrounds, a normal
-- sprite, priority order, and one alpha blend. These pin the reference model's
-- own arithmetic, which the speculation gate cannot see because it uses the same
-- renderer on both sides.
module Main (main) where

import Data.Bits (shiftR)
import Data.Maybe (isJust)
import Data.Word (Word32, Word8)
import System.Exit (exitFailure)

import Nds.Gpu2D.Line
import Nds.Gpu2D.Types

main :: IO ()
main = do
  let cases =
        [ ("4bpp text x=0", pixelRgb (text4 !! 0), 0x00080002)
        , ("4bpp text x=1", pixelRgb (text4 !! 1), 0x00080004)
        , ("4bpp text x=8", pixelRgb (text4 !! 8), 0x00080002)
        , ("8bpp text x=0", pixelRgb (text8 !! 0), 0x00080012)
        , ("8bpp text x=7", pixelRgb (text8 !! 7), 0x00080004)
        , ("8bpp extended palette", pixelRgb (bgTextLine esExt 0 0 !! 0), 0x0000003e)
        , ("horizontal mosaic", pixelRgb (bgTextLine esMosaic 0 0 !! 1), 0x00080002)
        , ("horizontal mosaic next block", pixelRgb (bgTextLine esMosaic 0 0 !! 2), 0x00080006)
        , ("obj x=0", pixelRgb (objLine objState 0 !! 0), 0x00100002)
        , ("priority", pixelOut (priorityLine !! 0), 0x00100002)
        , ("blend", pixelOut (blendLine !! 0), 0x000C0002)
        ]
      failures = [ name ++ " want " ++ show want ++ " got " ++ show got
                 | (name, got, want) <- cases
                 , got /= Just want ]
        ++ [ "obj is empty"
           | not (isJust (objLine objState 0 !! 0)) ]
  mapM_ (putStrLn . ("FAIL " ++)) failures
  putStrLn ("line-check: " ++ show (length cases) ++ " cases, "
    ++ show (length failures) ++ " failures")
  if null failures then pure () else exitFailure

pixelRgb :: Maybe LayerPixel -> Maybe Word32
pixelRgb = fmap lpRgb

pixelOut :: Maybe Pixel -> Maybe Word32
pixelOut = fmap pxRgb

-- 4bpp text: BG0, priority 0, tile 0, row 0 = 21 43 65 87.
text4 :: [Maybe LayerPixel]
text4 = bgTextLine es4 0 0

es4 :: EngineState
es4 = base
  { esBg = V4 (BgReg 0x0404 0 0 0 0 0 0 0 0) (BgReg 0 0 0 0 0 0 0 0 0)
           (BgReg 0 0 0 0 0 0 0 0 0) (BgReg 0 0 0 0 0 0 0 0 0)
  , esVram = memText4
  }

memText4 :: Memory
memText4 = memOf $
  [(0x2000, 0), (0x2001, 0), (0x2002, 0), (0x2003, 0)]
  ++ [(2, 0x01), (3, 0x10), (4, 0x02), (5, 0x10), (6, 0x03), (7, 0x10)
     , (8, 0x04), (9, 0x10), (10, 0x05), (11, 0x10), (12, 0x06), (13, 0x10)
     , (14, 0x07), (15, 0x10), (16, 0x08), (17, 0x10)]
  ++ [(0x4000, 0x21), (0x4001, 0x43), (0x4002, 0x65), (0x4003, 0x87)]

-- 8bpp text: BG0, tile 0, row 0 = 09 08 07 06 05 04 03 02.
text8 :: [Maybe LayerPixel]
text8 = bgTextLine es8 0 0

es8 :: EngineState
es8 = base
  { esBg = V4 (BgReg 0x0484 0 0 0 0 0 0 0 0) (BgReg 0 0 0 0 0 0 0 0 0)
           (BgReg 0 0 0 0 0 0 0 0 0) (BgReg 0 0 0 0 0 0 0 0 0)
  , esVram = memOf
      ((0x2000, 0) : (0x2001, 0) : zip [0x4000 .. 0x4007] [9, 8, 7, 6, 5, 4, 3, 2])
  }

esExt :: EngineState
esExt = es8
  { esDispCnt = esDispCnt es8 + 0x40000000
  , esVram = memOf ((0x2000,0) : (0x2001,0x20) : zip [0x4000..0x4007] [9,8,7,6,5,4,3,2])
  , esBgExtPal = memOf [(1042,0x1f),(1043,0)]
  }

esMosaic :: EngineState
esMosaic = es4
  { esBg = V4 (BgReg 0x0444 0 0 0 0 0 0 0 0) (BgReg 0 0 0 0 0 0 0 0 0)
           (BgReg 0 0 0 0 0 0 0 0 0) (BgReg 0 0 0 0 0 0 0 0 0)
  , esBgMosaicX = 1
  }

-- ONE sprite: normal, 4bpp, 8x8, x=0, y=0, tile 0, priority 0.
objState :: EngineState
objState = base
  { esOam = memOf
      [ (0, 0), (2, 0), (4, 0)
      , (6, 0), (8, 0), (10, 0), (12, 0), (14, 0) ]
  , esObjVram = memOf [(0, 0x21), (1, 0x43), (2, 0x65), (3, 0x87)]
  }

priorityLine :: [Maybe Pixel]
priorityLine = composeLine esPrio [Bg 0, LObj] [bgTextLine esPrio 0 0, objLine esPrio 0]

esPrio :: EngineState
esPrio = es4
  { esBg = V4 (BgReg 0x0405 0 0 0 0 0 0 0 0) (BgReg 0 0 0 0 0 0 0 0 0)
           (BgReg 0 0 0 0 0 0 0 0 0) (BgReg 0 0 0 0 0 0 0 0 0)
  , esOam = esOam objState
  , esObjVram = esObjVram objState
  }

blendLine :: [Maybe Pixel]
blendLine =
  composeLine esBlend [Bg 0, LObj] [bgTextLine esBlend 0 0, objLine esBlend 0]

esBlend :: EngineState
esBlend = esPrio
  { esBg = V4 (BgReg 0x0404 0 0 0 0 0 0 0 0) (BgReg 0 0 0 0 0 0 0 0 0)
           (BgReg 0 0 0 0 0 0 0 0 0) (BgReg 0 0 0 0 0 0 0 0 0)
  , esOam = memOf ((5, 4) : [(n * 8 + 1, 2) | n <- [1 .. 127]])
  , esBlendCnt = 0x1041
  , esEva = 8
  , esEvb = 8
  }

memOf :: [(Word32, Word8)] -> Memory
memOf kvs = Memory 0x000FFFFF (\a -> maybe 0 id (lookup a kvs))

paletteBytes :: Word32 -> [Int] -> [(Word32, Word8)]
paletteBytes base vals =
  concat [ [ (base + 2 * fromIntegral n, fromIntegral v)
          , (base + 2 * fromIntegral n + 1, fromIntegral (v `shiftR` 8)) ]
         | (n, v) <- zip [0 :: Int ..] vals ]

base :: EngineState
base = EngineState
  { esNum = 0
  , esDispCnt = 0x00001103
  , esBg = V4 (BgReg 0 0 0 0 0 0 0 0 0) (BgReg 0 0 0 0 0 0 0 0 0)
           (BgReg 0 0 0 0 0 0 0 0 0) (BgReg 0 0 0 0 0 0 0 0 0)
  , esBlendCnt = 0
  , esEva = 0
  , esEvb = 0
  , esEvy = 0
  , esObjMosaicLine = 0
  , esBgMosaicLine = 0
  , esBgMosaicX = 0
  , esBgExtPal = memOf []
  , esOamEpoch = 0
  , esVramEpoch = 0
  , esPaletteEpoch = 0
  , esOam = memOf []
  , esVram = memOf []
  , esObjVram = memOf []
  , esPalette = memOf
      (paletteBytes 0x000 [0x1000 + n | n <- [0 .. 255 :: Int]]
       ++ paletteBytes 0x200 [0x2000 + n | n <- [0 .. 255 :: Int]])
  }
