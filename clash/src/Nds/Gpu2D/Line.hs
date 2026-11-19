{-# LANGUAGE BangPatterns #-}

-- | In-progress pure 2D scanline model.  It is not yet a complete melonDS
-- transcription: sprite transforms, windows, capture and several background
-- formats require additional state and independent differential coverage.
module Nds.Gpu2D.Line
  ( Layer (..)
  , LayerPixel (..)
  , Pixel (..)
  , emptyLine
  , expandColor15
  , bgLine
  , bgTextLine
  , bgAffineLine
  , bgBitmapLine
  , objLine
  , composeLine
  , composeWindowedLine
  , renderReferenceLine
  , renderReferenceFrame
  , colorBlend4
  , colorBlend5
  , colorBrightnessUp
  , colorBrightnessDown
  , spriteSize
  , screenWidth
  , lineHeight
  ) where

import Data.Bits ((.&.), (.|.), complement, shiftL, shiftR, testBit)
import Data.Int (Int32)
import Data.List (foldl', sortOn)
import Data.Word (Word8, Word16, Word32)

import Nds.Gpu2D.Types

screenWidth :: Int
screenWidth = 256

lineHeight :: Int
lineHeight = 192

-- | A completely transparent line used as the composition accumulator.
emptyLine :: [Maybe LayerPixel]
emptyLine = replicate screenWidth Nothing

-- | Expand a 15-bit BGR555 colour into the reference's 6-bit line word:
-- red in bits 0..7, green in bits 8..15 and blue in bits 16..23.
expandColor15 :: Word16 -> Word32
expandColor15 c =
  let r = fromIntegral ((c .&. 0x001F) `shiftL` 1) :: Word32
      g = fromIntegral (((c .&. 0x03E0) `shiftR` 4) .|. ((c .&. 0x8000) `shiftR` 15)) :: Word32
      b = fromIntegral ((c .&. 0x7C00) `shiftR` 9) :: Word32
  in r .|. (g `shiftL` 8) .|. (b `shiftL` 16)

-- | Colour operations from @GPU_ColorOp.h@, exactly.
colorBlend4 :: Word32 -> Word32 -> Word32 -> Word32 -> Word32
colorBlend4 val1 val2 eva evb =
  let r = (((val1 .&. 0x00003F) * eva) + ((val2 .&. 0x00003F) * evb) + 0x8) `shiftR` 4
      g = ((((val1 .&. 0x003F00) * eva) + ((val2 .&. 0x003F00) * evb) + 0x800) `shiftR` 4) .&. 0x007F00
      b = ((((val1 .&. 0x3F0000) * eva) + ((val2 .&. 0x3F0000) * evb) + 0x80000) `shiftR` 4) .&. 0x7F0000
      r' = if r > 0x3F then 0x3F else r
      g' = if g > 0x3F00 then 0x3F00 else g
      b' = if b > 0x3F0000 then 0x3F0000 else b
  in r' .|. g' .|. b' .|. 0xFF000000

colorBlend5 :: Word32 -> Word32 -> Word32
colorBlend5 val1 val2 =
  let eva = ((val1 `shiftR` 24) .&. 0x1F) + 1
      evb = 32 - eva
  in if eva == 32
       then val1
       else
         let r = (((val1 .&. 0x00003F) * eva) + ((val2 .&. 0x00003F) * evb) + 0x10) `shiftR` 5
             g = ((((val1 .&. 0x003F00) * eva) + ((val2 .&. 0x003F00) * evb) + 0x1000) `shiftR` 5) .&. 0x007F00
             b = ((((val1 .&. 0x3F0000) * eva) + ((val2 .&. 0x3F0000) * evb) + 0x100000) `shiftR` 5) .&. 0x7F0000
             r' = if r > 0x3F then 0x3F else r
             g' = if g > 0x3F00 then 0x3F00 else g
             b' = if b > 0x3F0000 then 0x3F0000 else b
         in r' .|. g' .|. b' .|. 0xFF000000

colorBrightnessUp :: Word32 -> Word32 -> Word32 -> Word32
colorBrightnessUp val factor bias =
  let rb = val .&. 0x3F003F
      g = val .&. 0x003F00
      rb' = rb + ((((0x3F003F - rb) * factor) + (bias * 0x010001)) `shiftR` 4) .&. 0x3F003F
      g' = g + ((((0x003F00 - g) * factor) + (bias * 0x000100)) `shiftR` 4) .&. 0x003F00
  in rb' .|. g' .|. 0xFF000000

colorBrightnessDown :: Word32 -> Word32 -> Word32 -> Word32
colorBrightnessDown val factor bias =
  let rb = val .&. 0x3F003F
      g = val .&. 0x003F00
      rb' = rb - (((rb * factor) + (bias * 0x010001)) `shiftR` 4) .&. 0x3F003F
      g' = g - (((g * factor) + (bias * 0x000100)) `shiftR` 4) .&. 0x003F00
  in rb' .|. g' .|. 0xFF000000

bgPaletteBase :: EngineState -> Word32
bgPaletteBase es = if esNum es == 1 then 0x400 else 0x000

objPaletteBase :: EngineState -> Word32
objPaletteBase es = if esNum es == 1 then 0x600 else 0x200

bgPaletteEntry :: EngineState -> Word32 -> Word16
bgPaletteEntry es idx = memoryRead16 (esPalette es) (bgPaletteBase es + idx * 2)

objPaletteEntry :: EngineState -> Word32 -> Word16
objPaletteEntry es idx = memoryRead16 (esPalette es) (objPaletteBase es + idx * 2)

objVramBase :: EngineState -> Word32
objVramBase es = if esNum es == 1 then 0x20000 else 0x00000

-- | One BG's line, dispatched on BGMODE and BGCnt.
--
-- Background type depends on the display mode and layer, not BGCNT bit 7
-- (which selects colour depth for text backgrounds).
bgLine :: EngineState -> Layer -> Int -> [Maybe LayerPixel]
bgLine es (Bg n) y
  | n < 0 || n > 3 || not (bgEnable (esDispCnt es) n) = emptyLine
  | n < 2 && mode /= 6 = bgTextLine es n y
  | n == 2 && mode `elem` [0,1,3] = bgTextLine es n y
  | n == 2 && mode `elem` [2,4] = bgAffineLine es n y
  | n == 2 && mode == 5 = bgExtendedLine es n y
  | n == 2 && mode == 6 = bgLargeLine es
  | n == 3 && mode == 0 = bgTextLine es n y
  | n == 3 && mode `elem` [1,2] = bgAffineLine es n y
  | n == 3 && mode `elem` [3,4,5] = bgExtendedLine es n y
  | otherwise = emptyLine
  where mode = dispMode (esDispCnt es)
bgLine _ _ _ = emptyLine

-- | Text background line: the common 4bpp and 8bpp paths of
-- @DrawBG_TextImpl@, including flips and the two tile-map sizes.
bgTextLine :: EngineState -> Int -> Int -> [Maybe LayerPixel]
bgTextLine es n y = map pixel [0 .. screenWidth - 1]
  where
    reg = v4Index (esBg es) n
    bgcnt = brCnt reg
    bgcntW = fromIntegral bgcnt :: Word32
    is256 = testBit bgcnt 7
    yoff0 = fromIntegral (brY reg) + (if testBit bgcnt 6
                         then esBgMosaicLine es
                         else fromIntegral y)
    wideX = if testBit bgcnt 14 then 0x100 else 0x0
    tilemap0
      | esNum es == 1 = (bgcntW .&. 0x1F00) `shiftL` 3
      | otherwise = ((esDispCnt es .&. 0x38000000) `shiftR` 11)
                      + ((bgcntW .&. 0x1F00) `shiftL` 3)
    tileset
      | esNum es == 1 = (bgcntW .&. 0x003C) `shiftL` 12
      | otherwise = ((esDispCnt es .&. 0x07000000) `shiftR` 8)
                      + ((bgcntW .&. 0x003C) `shiftL` 12)
    tilemap
      | testBit bgcnt 15 =
          tilemap0 + ((yoff0 .&. 0x1F8) `shiftL` 3)
            + (if testBit bgcnt 14 then (yoff0 .&. 0x100) `shiftL` 3 else 0)
      | otherwise = tilemap0 + ((yoff0 .&. 0xF8) `shiftL` 3)
    priority = fromIntegral (bgcnt .&. bgPriorityMask)
    pixel i =
      let sourceI = if testBit bgcnt 6 then i - i `mod` (fromIntegral (esBgMosaicX es) + 1) else i
          xpos = (fromIntegral (brX reg) + fromIntegral sourceI) .&. 0xFFFF
          curtile = memoryRead16Masked (esVram es)
            (tilemap + ((xpos .&. 0xF8) `shiftR` 2) + ((xpos .&. wideX) `shiftL` 3))
          curtileW = fromIntegral curtile :: Word32
          flipX = testBit curtile 10
          tileX = if flipX then 7 - (xpos .&. 7) else xpos .&. 7
          row = if testBit curtile 11 then 7 - (yoff0 .&. 7) else yoff0 .&. 7
          palette = (curtileW .&. 0xF000) `shiftR` 8
      in if is256
           then
             let addr = tileset + ((curtileW .&. 0x03FF) `shiftL` 6) + (row `shiftL` 3) + tileX
                 color = memoryRead8 (esVram es) (addr .&. memoryMask (esVram es))
                 slot = if n < 2 && testBit bgcnt 13 then n + 2 else n
                 extaddr = fromIntegral slot * 8192 + (curtileW `shiftR` 12) * 512 + fromIntegral color * 2
                 palColor = if testBit (esDispCnt es) 30
                            then memoryRead16Masked (esBgExtPal es) extaddr
                            else bgPaletteEntry es (fromIntegral color)
             in if color == 0
                  then Nothing
                  else Just (LayerPixel (expandColor15 palColor)
                               priority (Bg n) 0)
           else
             let addr = tileset + ((curtileW .&. 0x03FF) `shiftL` 5)
                          + (row `shiftL` 2) + (tileX `shiftR` 1)
                 byte = memoryRead8 (esVram es) (addr .&. memoryMask (esVram es))
                 color = if testBit tileX 0 then byte `shiftR` 4 else byte .&. 0x0F
             in if color == 0
                  then Nothing
                  else Just (LayerPixel (expandColor15 (bgPaletteEntry es (palette + fromIntegral color)))
                               priority (Bg n) 0)

-- | 8bpp affine background (BG2/BG3).
bgAffineLine :: EngineState -> Int -> Int -> [Maybe LayerPixel]
bgAffineLine es n _ = bgAffineCommon False es n

bgExtendedLine :: EngineState -> Int -> Int -> [Maybe LayerPixel]
bgExtendedLine es n y
  | testBit (brCnt (v4Index (esBg es) n)) 7 = bgBitmapLine es n y
  | otherwise = bgAffineCommon True es n

bgAffineCommon :: Bool -> EngineState -> Int -> [Maybe LayerPixel]
bgAffineCommon extended es n = map pixel [0 .. screenWidth - 1]
  where
    reg = v4Index (esBg es) n
    bgcnt = brCnt reg
    bgcntW = fromIntegral bgcnt :: Word32
    priority = fromIntegral (bgcnt .&. bgPriorityMask)
    (coordMask, yShift)
      | size == 0 = (0x07800, 7)
      | size == 1 = (0x0F800, 8)
      | size == 2 = (0x1F800, 9)
      | otherwise = (0x3F800, 10)
      where size = fromIntegral ((bgcnt `shiftR` 14) .&. 0x3)
    overflowMask = if testBit bgcnt 13 then 0 else complement (coordMask .|. 0x7FF)
    tilemapBase
      | esNum es == 1 = (bgcntW .&. 0x1F00) `shiftL` 3
      | otherwise = ((esDispCnt es .&. 0x38000000) `shiftR` 11)
                      + ((bgcntW .&. 0x1F00) `shiftL` 3)
    tilesetBase
      | esNum es == 1 = (bgcntW .&. 0x003C) `shiftL` 12
      | otherwise = ((esDispCnt es .&. 0x07000000) `shiftR` 8)
                      + ((bgcntW .&. 0x003C) `shiftL` 12)
    stepX = fromIntegral (brPA reg) :: Int32
    stepY = fromIntegral (brPC reg) :: Int32
    yShift' = yShift - 3
    pixel i =
      let sourceI = if testBit bgcnt 6 then i - i `mod` (fromIntegral (esBgMosaicX es) + 1) else i
          rotX = brRX reg + fromIntegral sourceI * stepX
          rotY = brRY reg + fromIntegral sourceI * stepY
      in if (rotX .|. rotY) .&. overflowMask /= 0
           then Nothing
           else
             let mapIndex = fromIntegral (((rotY .&. coordMask) `shiftR` 11) `shiftL` yShift')
                              + fromIntegral ((rotX .&. coordMask) `shiftR` 11)
                 mapAddr = tilemapBase + if extended then mapIndex * 2 else mapIndex
                 curtile = if extended then memoryRead16Masked (esVram es) mapAddr
                           else fromIntegral (memoryRead8 (esVram es) (mapAddr .&. memoryMask (esVram es)))
                 x0 = fromIntegral ((rotX `shiftR` 8) .&. 7)
                 y0 = fromIntegral ((rotY `shiftR` 8) .&. 7)
                 x = if extended && testBit curtile 10 then 7-x0 else x0
                 y = if extended && testBit curtile 11 then 7-y0 else y0
                 addr = tilesetBase + (fromIntegral (curtile .&. 0x3ff) `shiftL` 6) + (y `shiftL` 3) + x
                 color = memoryRead8 (esVram es) (addr .&. memoryMask (esVram es))
                 extaddr = fromIntegral n * 8192 + fromIntegral (curtile `shiftR` 12) * 512 + fromIntegral color * 2
                 palColor = if extended && testBit (esDispCnt es) 30
                            then memoryRead16Masked (esBgExtPal es) extaddr
                            else bgPaletteEntry es (fromIntegral color)
             in if color == 0 then Nothing
                else Just (LayerPixel (expandColor15 palColor) priority (Bg n) 0)

-- | Extended affine bitmap, either indexed or direct-colour.
bgBitmapLine :: EngineState -> Int -> Int -> [Maybe LayerPixel]
bgBitmapLine es n y = map pixel [0 .. screenWidth - 1]
  where
    reg = v4Index (esBg es) n
    bgcnt = brCnt reg
    bgcntW = fromIntegral bgcnt :: Word32
    priority = fromIntegral (bgcnt .&. bgPriorityMask)
    (xMask, yMask, yShift)
      | size == 0 = (0x07FFF, 0x07FFF, 7)
      | size == 1 = (0x0FFFF, 0x0FFFF, 8)
      | size == 2 = (0x1FFFF, 0x0FFFF, 9)
      | otherwise = (0x1FFFF, 0x1FFFF, 9)
      where size = fromIntegral ((bgcnt `shiftR` 14) .&. 0x3)
    (ofxMask, ofyMask)
      | testBit bgcnt 13 = (0, 0)
      | otherwise = (complement xMask, complement yMask)
    tilemapBase = (bgcntW .&. 0x1F00) `shiftL` 6
    stepX = fromIntegral (brPA reg) :: Int32
    stepY = fromIntegral (brPC reg) :: Int32
    pixel i =
      let sourceI = if testBit bgcnt 6 then i - i `mod` (fromIntegral (esBgMosaicX es) + 1) else i
          rotX = brRX reg + fromIntegral sourceI * stepX
          rotY = brRY reg + fromIntegral sourceI * stepY
      in if rotX .&. ofxMask /= 0 || rotY .&. ofyMask /= 0
           then Nothing
           else
             let index = fromIntegral (((rotY .&. yMask) `shiftR` 8) `shiftL` yShift)
                           + fromIntegral ((rotX .&. xMask) `shiftR` 8)
                 direct = testBit bgcnt 2
                 addr = tilemapBase + if direct then index * 2 else index
                 vram = esVram es
                 color = memoryRead16Masked vram addr
                 paletteIndex = memoryRead8 vram (addr .&. memoryMask vram)
             in if direct
                then if testBit color 15
                     then Just (LayerPixel (expandColor15 (color .&. 0x7fff)) priority (Bg n) 0)
                     else Nothing
                else if paletteIndex == 0 then Nothing
                     else Just (LayerPixel (expandColor15 (bgPaletteEntry es (fromIntegral paletteIndex))) priority (Bg n) 0)

-- | Mode 6's 8bpp large bitmap starts at VRAM address zero.
bgLargeLine :: EngineState -> [Maybe LayerPixel]
bgLargeLine es = map pixel [0 .. screenWidth - 1]
  where
    reg = v4Index (esBg es) 2
    bgcnt = brCnt reg
    (xmask, ymask, yshift) = case (bgcnt `shiftR` 14) .&. 3 of
      0 -> (0x1ffff,0x3ffff,9)
      1 -> (0x3ffff,0x1ffff,10)
      2 -> (0x1ffff,0x0ffff,9)
      _ -> (0x1ffff,0x1ffff,9)
    xoverflow = if testBit bgcnt 13 then 0 else complement xmask
    yoverflow = if testBit bgcnt 13 then 0 else complement ymask
    pixel i =
      let sourceI = if testBit bgcnt 6 then i - i `mod` (fromIntegral (esBgMosaicX es) + 1) else i
          x = brRX reg + fromIntegral sourceI * fromIntegral (brPA reg)
          y = brRY reg + fromIntegral sourceI * fromIntegral (brPC reg)
          address = fromIntegral (((y .&. ymask) `shiftR` 8) `shiftL` yshift) +
                    fromIntegral ((x .&. xmask) `shiftR` 8)
          color = memoryRead8 (esVram es) (address .&. memoryMask (esVram es))
      in if x .&. xoverflow /= 0 || y .&. yoverflow /= 0 || color == 0
         then Nothing
         else Just (LayerPixel (expandColor15 (bgPaletteEntry es (fromIntegral color)))
                   (fromIntegral (bgcnt .&. 3)) (Bg 2) 0)

-- | A normal (non-affine) sprite line, in OAM order, with strict
-- priority exactly like @DrawSpritePixel@.
objLine :: EngineState -> Int -> [Maybe LayerPixel]
objLine es y = foldl' overlay emptyLine (map (normalSprite es y) [0 .. 127])
  where
    overlay acc cand = zipWith choose acc cand
    choose Nothing Nothing = Nothing
    choose (Just o) Nothing = Just o
    choose Nothing (Just c) = Just c
    choose (Just o) (Just c) =
      if lpPrio c < lpPrio o then Just c else Just o
    -- Equal priority keeps the earlier sprite, exactly as the draw order
    -- does, because the fold visits sprites in OAM order.

normalSprite :: EngineState -> Int -> Int -> [Maybe LayerPixel]
normalSprite es y n =
  if typ == 2 || ypos >= boundH || xpos <= -boundW
    then emptyLine
    else replicate start Nothing ++ map pixel [start .. end]
             ++ replicate (screenWidth - end - 1) Nothing
  where
    oam = esOam es
    a0 = memoryRead16 oam (fromIntegral n * 8)
    a1 = memoryRead16 oam (fromIntegral n * 8 + 2)
    a2 = memoryRead16 oam (fromIntegral n * 8 + 4)
    typ = fromIntegral ((a0 `shiftR` 8) .&. 0x3) :: Int
    size = fromIntegral ((a0 `shiftR` 14) .|. ((a1 .&. 0xC000) `shiftR` 12)) :: Int
    (width, height) = spriteSize size
    (boundW, boundH) = if typ == 3 then (width * 2, height * 2) else (width, height)
    xpos = signExtend9 (a1 .&. 0x1FF)
    ypos
      | testBit a0 12 && typ /= 2 =
          fromIntegral ((esObjMosaicLine es - fromIntegral (a0 .&. 0xFF)) .&. 0xFF :: Word32)
      | otherwise =
          fromIntegral ((fromIntegral y - fromIntegral (a0 .&. 0xFF)) .&. 0xFF :: Word32)
    yposAdj = if ypos >= boundH then 0 else ypos
    start = max 0 xpos
    end = min (screenWidth - 1) (xpos + boundW - 1)
    is256 = testBit a0 13
    tile = fromIntegral (a2 .&. 0x03FF) :: Word32
    flipX = testBit a1 12
    flipY = testBit a1 13
    priority = fromIntegral ((a2 `shiftR` 10) .&. 0x3)
    pixel x =
      let xoff = x - xpos
          xoff' = if flipX then boundW - 1 - xoff else xoff
          yy = if flipY then boundH - 1 - yposAdj else yposAdj
          byte = memoryRead8 (esObjVram es)
            (objVramBase es + tile * (if is256 then 64 else 32)
              + fromIntegral yy * (if is256 then 8 else 4)
              + fromIntegral (xoff' `div` (if is256 then 1 else 2)))
          color = if is256 then byte
                  else if odd xoff' then byte `shiftR` 4
                  else byte .&. 0x0F
      in if color == 0
           then Nothing
           else Just (LayerPixel
                  (expandColor15 (objPaletteEntry es
                    (fromIntegral ((if is256 then 0 else (a2 .&. 0xF000) `shiftR` 8))
                      + fromIntegral color)))
                  priority LObj 0)

spriteSize :: Int -> (Int, Int)
spriteSize s = case s of
  0 -> (8, 8); 1 -> (16, 16); 2 -> (8, 16); 3 -> (8, 8)
  4 -> (16, 8); 5 -> (32, 16); 6 -> (16, 32); 7 -> (8, 32)
  8 -> (32, 8); 9 -> (32, 16); 10 -> (64, 32); 11 -> (32, 64)
  12 -> (64, 64); 13 -> (32, 64); 14 -> (8, 64); _ -> (8, 8)

signExtend9 :: Word16 -> Int
signExtend9 v =
  let w = fromIntegral (v .&. 0x1FF) :: Int
  in if testBit v 8 then w - 512 else w

-- | The backdrop participates as target 2 and occupies every otherwise
-- transparent position. OBJ wins ties against backgrounds; BG0 wins BG1,
-- and so on, as in the reference's back-to-front drawing order.
composeLine :: EngineState -> [Layer] -> [[Maybe LayerPixel]] -> [Maybe Pixel]
composeLine es layers rows = composeWindowedLine es (replicate screenWidth 0xff) layers rows

-- | Mask bits select visible layers and permit ordinary colour effects.
composeWindowedLine :: EngineState -> [Word8] -> [Layer] -> [[Maybe LayerPixel]] -> [Maybe Pixel]
composeWindowedLine es masks _ rows = walk screenWidth masks rows
  where
    -- Advance each linked list once per pixel. Re-indexing every row with
    -- (!!) made a fixed-width line quadratic even when only backdrop is on.
    walk 0 _ _ = []
    walk n (mask:remainingMasks) remainingRows =
      let (values,tails) = advanceRows remainingRows
      in composeAt mask values : walk (n-1) remainingMasks tails
    walk _ [] _ = error "composeWindowedLine: short window mask"
    advanceRows [] = ([],[])
    advanceRows ((value:rest):remainingRows) =
      let (values,tails) = advanceRows remainingRows
      in (value:values,rest:tails)
    advanceRows ([]:_) = error "composeWindowedLine: short layer row"
    backdrop = LayerPixel (expandColor15 (bgPaletteEntry es 0)) 4 LBackdrop 0
    rank p = case lpLayer p of
      LObj -> 0 :: Int
      Bg n -> n + 1
      L3D -> 1
      LBackdrop -> 5
    candidates mask values = [lp | Just lp <- values, fromIntegral mask .&. target (lpLayer lp) /= 0] ++ [backdrop]
    composeAt mask values =
      case sortOn (\lp -> (lpPrio lp, rank lp)) (candidates mask values) of
        w : rest ->
          let under = case rest of
                u : _ -> Just u
                [] -> Nothing
          in Just (Pixel (blendPixel mask w under) (lpLayer w))
        [] -> Just (Pixel (lpRgb backdrop) LBackdrop)
    target layer = case layer of
      LObj -> 0x10
      L3D -> 0x01
      _ -> layerFlag layer
    blendPixel mask w u =
      let cnt = esBlendCnt es
          target2 = maybe 0 (\p -> target (lpLayer p) `shiftL` 8) u
          second = cnt .&. target2 /= 0
          first = cnt .&. target (lpLayer w) /= 0
          val1 = lpRgb w .|. (fromIntegral (lpAlpha w) `shiftL` 24)
          val2 = maybe 0 lpRgb u
          effect | lpLayer w == L3D && second = 4
                 | lpLayer w == LObj && lpAlpha w /= 0 && second = 1
                 | first && testBit mask 5 = (cnt `shiftR` 6) .&. 3
                 | otherwise = 0
          (eva, evb) | lpLayer w == LObj && lpAlpha w /= 0 && lpAlpha w <= 16 =
                        (fromIntegral (lpAlpha w), 16 - fromIntegral (lpAlpha w))
                     | otherwise = (esEva es, esEvb es)
          rgb | effect == 1 && second = colorBlend4 val1 val2 eva evb
              | effect == 2 = colorBrightnessUp val1 (esEvy es) 0x8
              | effect == 3 = colorBrightnessDown val1 (esEvy es) 0x7
              | effect == 4 = colorBlend5 val1 val2
              | otherwise = val1
      in rgb .&. 0x00FFFFFF

-- | Render one reference line of one engine.
renderReferenceLine :: EngineState -> Int -> [Pixel]
renderReferenceLine es y =
  map (maybe (Pixel (expandColor15 (bgPaletteEntry es 0)) LBackdrop) id)
      (composeLine es (map Bg [0 .. 3] ++ [LObj])
        (map (\n -> bgLine es (Bg n) y) [0 .. 3] ++
         [if objEnable (esDispCnt es) then objLine es y else emptyLine]))

-- | Render one whole reference frame.
renderReferenceFrame :: EngineState -> [[Pixel]]
renderReferenceFrame es = map (renderReferenceLine es) [0 .. lineHeight - 1]
