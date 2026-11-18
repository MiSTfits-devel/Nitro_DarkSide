-- | Standalone OBJ/sprite phase, transcribed from the vendored melonDS
-- @SoftRenderer2D::DrawSprites@ path.
--
-- The result is the raw 256-pixel @OBJLine@ encoding from
-- @GPU2D_Soft.h@: colour/index in bits 0-14, priority in bits 16-17,
-- @OBJ_IsOpaque@ in bit 18, @OBJ_IsSprite@ in bit 19, @OBJ_Mosaic@ in bit 20,
-- the OBJ mode in bits 27-28 and the bitmap alpha in bits 24-25/31-30. It is
-- deliberately not palette-expanded; composition happens later.
module Nds.Gpu2D.Sprite
  ( SpriteInput (..)
  , SpriteLine (..)
  , emptySpriteLine
  , drawSprites
  , applySpriteMosaic
  ) where

import Data.Bits (complement, shiftL, shiftR, testBit, (.&.), (.|.))
import Data.Int (Int32)
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (foldl')
import Data.Word (Word16, Word32, Word8)

-- | All state one sprite phase can observe. OAM and OBJ-VRAM reads are
-- engine-relative byte reads (engine B's windows already applied by the
-- caller). 'siOBJMask' is @GetOBJVRAM@'s mask.
data SpriteInput = SpriteInput
  { siEnabled    :: !Bool
  , siOBJEnabled :: !Bool
  , siDispCnt    :: !Word32
  , siMosaicLine :: !Word32
  , siTargetLine :: !Int
  , siOAMRead    :: Word32 -> Word8
  , siOBJRead    :: Word32 -> Word8
  , siOBJMask    :: !Word32
  }

data SpriteLine = SpriteLine
  { slPixels :: [Word32]
  , slWindow :: [Bool]
  } deriving (Eq, Show)

emptySpriteLine :: SpriteLine
emptySpriteLine = SpriteLine (replicate 256 0) (replicate 256 False)

-- Internal mutable-in-spirit line: sparse maps keep per-pixel writes O(log 256)
-- while the public contract stays a plain 256-element list.
data ILine = ILine !(IM.IntMap Word32) !IS.IntSet

emptyI :: ILine
emptyI = ILine IM.empty IS.empty

fromI :: ILine -> SpriteLine
fromI (ILine px win) = SpriteLine
  [IM.findWithDefault 0 i px | i <- [0 .. 255]]
  [IS.member i win | i <- [0 .. 255]]

-- melonDS @GPU2D_Soft.h@ OBJLine metadata bits.
objStandardPal, objDirectColor, objIsOpaque, objIsSprite, objMosaic :: Word32
objStandardPal = 1 `shiftL` 12
objDirectColor = 1 `shiftL` 15
objIsOpaque = 1 `shiftL` 18
objIsSprite = 1 `shiftL` 19
objMosaic = 1 `shiftL` 20
objBGPrioMask = 0x3 `shiftL` 16
objOpaPrioMask = objBGPrioMask .|. objIsOpaque

widths, heights :: [Int]
widths  = [8,16,8,8,16,32,8,8,32,32,16,8,64,64,32,8]
heights = [8,8,16,8,16,8,32,8,32,16,32,8,64,32,64,8]

-- | One sprite phase. Disabled engine preserves the incoming buffers;
-- enabled engine with OBJ disabled clears them, exactly as melonDS does.
drawSprites :: SpriteInput -> SpriteLine -> SpriteLine
drawSprites inp prior
  | not (siEnabled inp) = prior
  | not (siOBJEnabled inp) = emptySpriteLine
  | otherwise = fromI (foldl' drawOne emptyI ([0 .. 127] :: [Int]))
  where
    drawOne ln num =
      let a0 = oam16 inp (fromIntegral (num * 4))
          a1 = oam16 inp (fromIntegral (num * 4 + 1))
          a2 = oam16 inp (fromIntegral (num * 4 + 2))
          sprtype = (a0 `shiftR` 8) .&. 0x3
      in if sprtype == 2
           then ln
           else
             let iswin = ((a0 `shiftR` 10) .&. 0x3) == 2
                 sizeparam = fromIntegral ((a0 `shiftR` 14) .|. ((a1 .&. 0xC000) `shiftR` 12))
                 width = widths !! sizeparam
                 height = heights !! sizeparam
                 double = sprtype == 3
                 bw = if double then width * 2 else width
                 bh = if double then height * 2 else height
                 line = siTargetLine inp
                 y0 = fromIntegral (a0 .&. 0xFF)
                 visible = ((line - y0) .&. 0xFF) >= bh
                 xpos = signExtend9 (a1 .&. 0x1FF)
             in if visible || xpos <= negate bw
                  then ln
                  else
                    let ypos0
                          | testBit a0 12 && not iswin =
                              let m = fromIntegral ((siMosaicLine inp - fromIntegral y0) .&. 0xFF)
                              in if m >= bh then 0 else m
                          | otherwise = (line - y0) .&. 0xFF
                    in if odd sprtype
                         then drawRotscale inp iswin num bw bh width height xpos ypos0 a0 a1 a2 ln
                         else drawNormal inp iswin num width height xpos ypos0 a0 a1 a2 ln

-- | @ApplySpriteMosaicX@: horizontal sprite mosaic over the finished line.
applySpriteMosaic :: Word8 -> SpriteLine -> SpriteLine
applySpriteMosaic mosw line
  | mosw == 0 = line
  | otherwise = line { slPixels = go 0 0 0 (slPixels line) }
  where
    go _ _ _ [] = []
    go i mosx latch (p : ps) =
      let latch' =
            if mosx == 0 then p
            else if p .&. objMosaic == 0 then p
            else if latch .&. objMosaic == 0 then p
            else if (p .&. objBGPrioMask) < (latch .&. objBGPrioMask) then p
            else latch
          mosx' = if mosx == fromIntegral mosw then 0 else mosx + 1
      in latch' : go (i + 1) mosx' latch' ps

------------------------------------------------------------------------------
-- Pixel writes

drawPixel :: Bool -> Maybe Word32 -> Word32 -> Int -> ILine -> ILine
drawPixel iswin mcolor attr x ln@(ILine px win)
  | x < 0 || x > 255 = ln
  | iswin =
      case mcolor of
        Just _ -> ILine px (IS.insert x win)
        Nothing -> ln
  | otherwise =
      let old = IM.findWithDefault 0 x px
          oldOpaque = testBit old 18
          newOpaque = case mcolor of Just _ -> True; Nothing -> False
          prioCheck = (attr .&. objBGPrioMask) < (old .&. objBGPrioMask)
          px'
            | newOpaque && (not oldOpaque || prioCheck) =
                maybe 0 (.|. attr) mcolor
            | not newOpaque && not oldOpaque =
                (old .&. complement (objMosaic .|. objBGPrioMask))
                  .|. (attr .&. (objIsSprite .|. objMosaic .|. objBGPrioMask))
            | otherwise = old
      in ILine (IM.insert x px' px) win

setAt :: Int -> a -> [a] -> [a]
setAt i v xs =
  let (a, b) = splitAt i xs
  in case b of
       (_ : c) -> a ++ v : c
       [] -> xs

------------------------------------------------------------------------------
-- Tile and bitmap sprites

drawNormal :: SpriteInput -> Bool -> Int -> Int -> Int -> Int -> Int
           -> Word16 -> Word16 -> Word16 -> ILine -> ILine
drawNormal inp iswin num width height xpos0 ypos0 a0 a1 a2 ln0 =
  let pixelattr0 = ((fromIntegral a2 .&. 0x0C00) `shiftL` 6) .|. objIsSprite .|. objIsOpaque
      tilenum = fromIntegral a2 .&. 0x03FF
      spritemode = if iswin then 0 else fromIntegral ((a0 `shiftR` 10) .&. 0x3) :: Word32
      dispcnt = siDispCnt inp
      ypos1 = if testBit a1 13 then height - 1 - ypos0 else ypos0
      (xoff0, xend0, xpos1)
        | xpos0 >= 0 =
            let e = if xpos0 + width > 256 then 256 - xpos0 else width
            in (0, e, xpos0)
        | otherwise = (negate xpos0, width, 0)
      pixelattr1
        | testBit a0 12 && not iswin = pixelattr0 .|. objMosaic
        | otherwise = pixelattr0
      wmask = width - 8
  in if spritemode == 3
       then normalBitmap inp iswin width xoff0 xend0 xpos1 ypos1 a1 a2 tilenum pixelattr1 ln0
       else normalTile inp iswin width xoff0 xend0 xpos1 ypos1 a0 a1 a2 tilenum
                       spritemode wmask dispcnt pixelattr1 ln0

normalBitmap :: SpriteInput -> Bool -> Int -> Int -> Int -> Int -> Int
             -> Word16 -> Word16 -> Word32 -> Word32 -> ILine -> ILine
normalBitmap inp iswin width xoff xend xpos ypos a1 a2 tilenum pixelattr0 ln =
  let dispcnt = siDispCnt inp
      alpha = fromIntegral (a2 `shiftR` 12) :: Word32
  in if alpha == 0
       then ln
       else
         let pixelattr = pixelattr0 .|. 0xC0000000 .|. ((alpha + 1) `shiftL` 24)
             base
               | dispcnt .&. 0x40 /= 0 =
                   if dispcnt .&. 0x20 /= 0
                     then Nothing
                     else Just ((tilenum `shiftL` (7 + fromIntegral ((dispcnt `shiftR` 22) .&. 1)))
                                + fromIntegral ypos * fromIntegral width * 2)
               | dispcnt .&. 0x20 /= 0 =
                   Just (((tilenum .&. 0x1F) `shiftL` 4) .|. ((tilenum .&. 0x3E0) `shiftL` 7)
                         + fromIntegral ypos * 256 * 2)
               | otherwise =
                   Just (((tilenum .&. 0x00F) `shiftL` 4) .|. ((tilenum .&. 0x3F0) `shiftL` 7)
                         + fromIntegral ypos * 128 * 2)
         in case base of
              Nothing -> ln
              Just b ->
                let (addr0, stride)
                      | testBit a1 12 = (b + fromIntegral (width - 1) * 2 - fromIntegral xoff * 2, -2)
                      | otherwise = (b + fromIntegral xoff * 2, 2)
                    go _ xo xp acc
                      | xo >= xend = acc
                    go a xo xp acc =
                      let c = obj16 inp (fromIntegral a)
                          acc' = drawPixel iswin (if testBit c 15 then Just (fromIntegral c) else Nothing)
                                             pixelattr xp acc
                      in go (a + stride) (xo + 1) (xp + 1) acc'
                in go addr0 xoff xpos ln

normalTile :: SpriteInput -> Bool -> Int -> Int -> Int -> Int -> Int
           -> Word16 -> Word16 -> Word16 -> Word32 -> Word32 -> Int
           -> Word32 -> Word32 -> ILine -> ILine
normalTile inp iswin width xoff0 xend0 xpos0 ypos0 a0 a1 a2 tilenum spritemode wmask dispcnt pixelattr0 ln0 =
  let (addr0, pixelattr1)
        | dispcnt .&. (1 `shiftL` 4) /= 0 =
            let a = (tilenum `shiftL` fromIntegral ((dispcnt `shiftR` 20) .&. 0x3))
                      + fromIntegral ((ypos0 `shiftR` 3) * (width `shiftR` 3))
                        * (if testBit a0 13 then 2 else 1)
            in (a, pixelattr0)
        | otherwise = (tilenum + fromIntegral (ypos0 `shiftR` 3) * 0x20, pixelattr0)
      pixelattr2
        | spritemode == 1 = pixelattr1 .|. 0x80000000
        | otherwise = pixelattr1 .|. 0x10000000
  in if testBit a0 13
       then  -- 256-color
         let pixelattr = if iswin then pixelattr2
                         else if dispcnt .&. (1 `shiftL` 31) == 0
                                then pixelattr2 .|. objStandardPal
                                else pixelattr2 .|. (fromIntegral (a2 .&. 0xF000) `shiftR` 4)
             base = (addr0 `shiftL` 5) + fromIntegral ((ypos0 .&. 7) `shiftL` 3)
             (addr1, stride)
               | testBit a1 12 =
                   (base + fromIntegral (((width - 1) .&. wmask) `shiftL` 3)
                        + fromIntegral ((width - 1) .&. 7)
                        - fromIntegral ((xoff0 .&. wmask) `shiftL` 3)
                        - fromIntegral (xoff0 .&. 7), -1)
               | otherwise =
                   (base + fromIntegral ((xoff0 .&. wmask) `shiftL` 3)
                        + fromIntegral (xoff0 .&. 7), 1)
             go _ xo xp acc | xo >= xend0 = acc
             go a xo xp acc =
               let c = obj8 inp (fromIntegral a)
                   acc' = drawPixel iswin (if c /= 0 then Just (fromIntegral c) else Nothing)
                                      pixelattr xp acc
                   xo' = xo + 1
                   a' = a + stride + (if xo' .&. 7 == 0 then 56 * stride else 0)
               in go a' xo' (xp + 1) acc'
         in go addr1 xoff0 xpos0 ln0
       else  -- 16-color
         let pixelattr = if iswin then pixelattr2
                         else pixelattr2 .|. objStandardPal
                                .|. (fromIntegral (a2 .&. 0xF000) `shiftR` 8)
             base = (addr0 `shiftL` 5) + fromIntegral ((ypos0 .&. 7) `shiftL` 2)
             (addr1, stride)
               | testBit a1 12 =
                   (base + fromIntegral (((width - 1) .&. wmask) `shiftL` 2)
                        + fromIntegral (((width - 1) .&. 7) `shiftR` 1)
                        - fromIntegral ((xoff0 .&. wmask) `shiftL` 2)
                        - fromIntegral ((xoff0 .&. 7) `shiftR` 1), -1)
               | otherwise =
                   (base + fromIntegral ((xoff0 .&. wmask) `shiftL` 2)
                        + fromIntegral ((xoff0 .&. 7) `shiftR` 1), 1)
             go _ xo xp acc | xo >= xend0 = acc
             go a xo xp acc =
               let b = obj8 inp (fromIntegral a)
                   c
                     | testBit a1 12 = if xo .&. 1 == 1 then b .&. 0x0F else b `shiftR` 4
                     | xo .&. 1 == 1 = b `shiftR` 4
                     | otherwise = b .&. 0x0F
                   acc' = drawPixel iswin (if c /= 0 then Just (fromIntegral c) else Nothing)
                                      pixelattr xp acc
                   xo' = xo + 1
                   a' = a + (if xo .&. 1 == 1 then stride else 0)
                          + (if xo' .&. 7 == 0 then (if testBit a1 12 then -28 else 28) else 0)
               in go a' xo' (xp + 1) acc'
         in go addr1 xoff0 xpos0 ln0

drawRotscale :: SpriteInput -> Bool -> Int -> Int -> Int -> Int -> Int -> Int -> Int
             -> Word16 -> Word16 -> Word16 -> ILine -> ILine
drawRotscale inp iswin num bw bh width height xpos0 ypos a0 a1 a2 ln0 =
  let pixelattr0 = ((fromIntegral a2 .&. 0x0C00) `shiftL` 6) .|. objIsSprite .|. objIsOpaque
      tilenum = fromIntegral a2 .&. 0x03FF
      spritemode = if iswin then 0 else fromIntegral ((a0 `shiftR` 10) .&. 0x3) :: Word32
      dispcnt = siDispCnt inp
      centerX = bw `shiftR` 1
      centerY = bh `shiftR` 1
      pixelattr1 = if testBit a0 12 && not iswin then pixelattr0 .|. objMosaic else pixelattr0
      (xoff0, bw1, xpos1)
        | xpos0 >= 0 =
            let b = if xpos0 + bw > 256 then 256 - xpos0 else bw
            in (0, b, xpos0)
        | otherwise = (negate xpos0, bw, 0)
      rotidx = fromIntegral (((a1 `shiftR` 9) .&. 0x1F) * 16 + 3)
      rotA = fromIntegral (oam16 inp (rotidx + 0)) :: Int32
      rotB = fromIntegral (oam16 inp (rotidx + 4)) :: Int32
      rotC = fromIntegral (oam16 inp (rotidx + 8)) :: Int32
      rotD = fromIntegral (oam16 inp (rotidx + 12)) :: Int32
      rotX0 = fromIntegral (xoff0 - centerX) * rotA
              + fromIntegral (ypos - centerY) * rotB + fromIntegral (width `shiftL` 7)
      rotY0 = fromIntegral (xoff0 - centerX) * rotC
              + fromIntegral (ypos - centerY) * rotD + fromIntegral (height `shiftL` 7)
      widt = width `shiftL` 8
      heigh = height `shiftL` 8
  in if spritemode == 3
       then rotBitmap inp iswin bw1 xoff0 xpos1 rotX0 rotY0 rotA rotC widt heigh
                      a0 a2 tilenum pixelattr1 dispcnt ln0
       else rotTile inp iswin bw1 xoff0 xpos1 rotX0 rotY0 rotA rotC widt heigh
                    a0 a1 a2 tilenum pixelattr1 spritemode dispcnt ln0

rotBitmap :: SpriteInput -> Bool -> Int -> Int -> Int -> Int32 -> Int32 -> Int32 -> Int32
          -> Int -> Int -> Word16 -> Word16 -> Word32 -> Word32 -> Word32 -> ILine -> ILine
rotBitmap inp iswin bw xoff0 xpos0 rotX0 rotY0 rotA rotC widt heigh a0 a2 tilenum pixelattr0 dispcnt ln =
  let alpha = fromIntegral (a2 `shiftR` 12) :: Word32
  in if alpha == 0
       then ln
       else
         let pixelattr = pixelattr0 .|. 0xC0000000 .|. ((alpha + 1) `shiftL` 24)
             setup
               | dispcnt .&. 0x40 /= 0 =
                   if dispcnt .&. 0x20 /= 0 then Nothing
                   else Just (tilenum `shiftL` (7 + fromIntegral ((dispcnt `shiftR` 22) .&. 1)),
                              (widt `shiftR` 8) * 2)
               | dispcnt .&. 0x20 /= 0 =
                   Just (((tilenum .&. 0x01F) `shiftL` 4) .|. ((tilenum .&. 0x3E0) `shiftL` 7), 256 * 2)
               | otherwise =
                   Just (((tilenum .&. 0x00F) `shiftL` 4) .|. ((tilenum .&. 0x3F0) `shiftL` 7), 128 * 2)
         in case setup of
              Nothing -> ln
              Just (pixelsaddr, ytilefactor) ->
                let go :: Int32 -> Int32 -> Int -> Int -> ILine -> ILine
                    go _ _ xo xp acc | xo >= bw = acc
                    go rx ry xo xp acc =
                      let acc' =
                            if (fromIntegral rx :: Word32) < fromIntegral widt && (fromIntegral ry :: Word32) < fromIntegral heigh
                              then
                                let c = obj16 inp (fromIntegral
                                          (pixelsaddr + fromIntegral (ry `shiftR` 8) * fromIntegral ytilefactor
                                           + fromIntegral ((rx `shiftR` 8) `shiftL` 1)))
                                in drawPixel iswin (if testBit c 15 then Just (fromIntegral c) else Nothing)
                                                   pixelattr xp acc
                              else acc
                      in go (rx + rotA) (ry + rotC) (xo + 1) (xp + 1) acc'
                in go rotX0 rotY0 xoff0 xpos0 ln

rotTile :: SpriteInput -> Bool -> Int -> Int -> Int -> Int32 -> Int32 -> Int32 -> Int32
        -> Int -> Int -> Word16 -> Word16 -> Word16 -> Word32 -> Word32 -> Word32
        -> Word32 -> ILine -> ILine
rotTile inp iswin bw xoff0 xpos0 rotX0 rotY0 rotA rotC widt heigh a0 a1 a2 tilenum pixelattr0 spritemode dispcnt ln =
  let (addr0, ytf0)
        | dispcnt .&. (1 `shiftL` 4) /= 0 =
            (tilenum `shiftL` fromIntegral ((dispcnt `shiftR` 20) .&. 0x3),
             (widt `shiftR` 11) `shiftL` (if testBit a0 13 then 1 else 0))
        | otherwise = (tilenum, 0x20)
      pixelattr1
        | spritemode == 1 = pixelattr0 .|. 0x80000000
        | otherwise = pixelattr0 .|. 0x10000000
      pixelsaddr = addr0 `shiftL` 5
      ytilefactor = ytf0 `shiftL` 5
  in if testBit a0 13
       then
         let pixelattr = if iswin then pixelattr1
                         else if dispcnt .&. (1 `shiftL` 31) == 0
                                then pixelattr1 .|. objStandardPal
                                 else pixelattr1 .|. (fromIntegral (a2 .&. 0xF000) `shiftR` 4)
             go :: Int32 -> Int32 -> Int -> Int -> ILine -> ILine
             go _ _ xo xp acc | xo >= bw = acc
             go rx ry xo xp acc =
               let acc' =
                     if (fromIntegral rx :: Word32) < fromIntegral widt && (fromIntegral ry :: Word32) < fromIntegral heigh
                       then
                         let a = pixelsaddr + fromIntegral ((ry `shiftR` 11) * fromIntegral ytilefactor)
                                 + fromIntegral ((ry .&. 0x700) `shiftR` 5)
                                 + fromIntegral ((rx `shiftR` 11) * 64)
                                 + fromIntegral ((rx .&. 0x700) `shiftR` 8)
                             c = obj8 inp a
                         in drawPixel iswin (if c /= 0 then Just (fromIntegral c) else Nothing)
                                            pixelattr xp acc
                       else acc
               in go (rx + rotA) (ry + rotC) (xo + 1) (xp + 1) acc'
         in go rotX0 rotY0 xoff0 xpos0 ln
       else
         let pixelattr = if iswin then pixelattr1
                         else pixelattr1 .|. objStandardPal
                                 .|. (fromIntegral (a2 .&. 0xF000) `shiftR` 8)
             go :: Int32 -> Int32 -> Int -> Int -> ILine -> ILine
             go _ _ xo xp acc | xo >= bw = acc
             go rx ry xo xp acc =
               let acc' =
                     if (fromIntegral rx :: Word32) < fromIntegral widt && (fromIntegral ry :: Word32) < fromIntegral heigh
                       then
                         let a = pixelsaddr + fromIntegral ((ry `shiftR` 11) * fromIntegral ytilefactor)
                                 + fromIntegral ((ry .&. 0x700) `shiftR` 6)
                                 + fromIntegral ((rx `shiftR` 11) * 32)
                                 + fromIntegral ((rx .&. 0x700) `shiftR` 9)
                             b = obj8 inp a
                             c = if testBit rx 8 then b `shiftR` 4 else b .&. 0x0F
                         in drawPixel iswin (if c /= 0 then Just (fromIntegral c) else Nothing)
                                            pixelattr xp acc
                       else acc
               in go (rx + rotA) (ry + rotC) (xo + 1) (xp + 1) acc'
         in go rotX0 rotY0 xoff0 xpos0 ln

------------------------------------------------------------------------------
-- helpers

oam8 :: SpriteInput -> Word32 -> Word8
oam8 inp a = siOAMRead inp a

oam16 :: SpriteInput -> Word32 -> Word16
oam16 inp a = fromIntegral (oam8 inp (2 * a))
          .|. (fromIntegral (oam8 inp (2 * a + 1)) `shiftL` 8)

obj8 :: SpriteInput -> Word32 -> Word8
obj8 inp a = siOBJRead inp (a .&. siOBJMask inp)

obj16 :: SpriteInput -> Word32 -> Word16
obj16 inp a =
  fromIntegral (obj8 inp a) .|. (fromIntegral (obj8 inp (a + 1)) `shiftL` 8)

signExtend9 :: Word16 -> Int
signExtend9 v = fromIntegral ((fromIntegral v `shiftL` 23 :: Int32) `shiftR` 23)
