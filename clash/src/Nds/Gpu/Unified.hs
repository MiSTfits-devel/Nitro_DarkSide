{-# LANGUAGE BangPatterns #-}

-- | Unified pixel-space GPU composition. In 3D mode BG0 is the 3D
-- layer, including transparent positions; the text BG0 is not drawn.
module Nds.Gpu.Unified
  ( UnifiedInput (..)
  , threeDPixel
  , unifiedLine
  , unifiedLineWindowed
  , unifiedFrame
  ) where

import Data.Bits ((.&.), shiftR, testBit)
import Data.List (foldl')
import Data.Word (Word8, Word32)

import Nds.Gpu2D.Line
import Nds.Gpu2D.Types

-- | The unified frame's inputs: one 2D engine and the 3D engine's per-pixel
-- output for that frame as @(x, y, colour)@ with the 3D alpha in bits 24..31.
data UnifiedInput = UnifiedInput
  { ui2d :: !EngineState
  , ui3d :: ![(Int, Int, Word32)]
  } deriving ()

-- | Decode the 3D alpha separately from the six-bit colour channels.
threeDPixel :: Word32 -> Maybe LayerPixel
threeDPixel c
  | c `shiftR` 24 == 0 = Nothing
  | otherwise = Just (LayerPixel (c .&. 0x00FFFFFF) 0 L3D (fromIntegral ((c `shiftR` 24) .&. 31)))

-- | Draw 3D at BG0 priority, without revealing the text BG0 through it.
unifiedLine :: UnifiedInput -> Int -> [Maybe Pixel]
unifiedLine ui y = unifiedLineWindowed ui y (replicate screenWidth 0xff)
  (if objEnable (esDispCnt (ui2d ui)) then objLine (ui2d ui) y else emptyLine)

-- | The sprite line comes from the earlier sprite phase; masks are resolved
-- from current window registers and that phase's OBJ-window bitmap.
unifiedLineWindowed :: UnifiedInput -> Int -> [Word8] -> [Maybe LayerPixel] -> [Maybe Pixel]
unifiedLineWindowed ui y masks sprites = composeWindowedLine es masks [Bg 0, Bg 1, Bg 2, Bg 3, LObj] rows
  where
    es = ui2d ui
    bg0
      | esNum es == 0 && testBit (esDispCnt es) 3 =
          if bgEnable (esDispCnt es) 0
          then map (fmap (\p -> p { lpPrio = fromIntegral (brCnt (v4Index (esBg es) 0) .&. 3) })) (row3d ui y)
          else emptyLine
      | otherwise = bgLine es (Bg 0) y
    rows =
      [ bg0
      , bgLine es (Bg 1) y
      , bgLine es (Bg 2) y
      , bgLine es (Bg 3) y
      , sprites
      ]

row3d :: UnifiedInput -> Int -> [Maybe LayerPixel]
row3d ui y = foldl' insert (replicate screenWidth Nothing) (ui3d ui)
  where
    insert rows (x, py, c)
      | py /= y = rows
      | x < 0 || x >= screenWidth = rows
      | otherwise =
          case threeDPixel c of
            Nothing -> rows
            Just p -> take x rows ++ [Just p] ++ drop (x + 1) rows

-- | One whole unified frame. The 3D line is simply part of the 2D
-- composition; there is no second picture and no later glue pass.
unifiedFrame :: UnifiedInput -> [[Pixel]]
unifiedFrame ui = [ line y | y <- [0 .. lineHeight - 1] ]
  where
    line y = map (maybe (error "unifiedLine: missing backdrop") id) (unifiedLine ui y)
