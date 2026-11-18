{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Exact melonDS pixel shading, alpha blending and framebuffer update rules.
--
-- 'shadePixel' is @SoftRenderer3D::RenderPixel@: toon and highlight shading,
-- texture modulation and decal (which shadow polygons, blend mode 3, also
-- use), and the wireframe alpha override. 'alphaBlend' is
-- @SoftRenderer3D::AlphaBlend@. 'plotPixel' is what a shaded pixel that passed
-- the depth test does to the top layer: the alpha test, the opaque write, and
-- @PlotTranslucentPixel@'s polygon-ID, fog-flag and depth-update rules.
-- Colours are the renderer's internal form: 6-bit channels in bytes 0-2 and a
-- 5-bit alpha in byte 3.
module Nds.Gpu3D.Shade
  ( Rgb6
  , ShadeState (..)
  , shadeState
  , expand555
  , packColour
  , shadePixel
  , alphaBlend
  , PlotState (..)
  , plotState
  , PixelWrite (..)
  , plotPixel
  ) where

import Prelude

import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.))
import Data.Word (Word16, Word32, Word8)
import GHC.Generics (Generic)

import Clash.Prelude (NFDataX)

-- | Three 6-bit channels.
type Rgb6 = (Word8, Word8, Word8)

-- | The polygon and display state the shader reads.
data ShadeState = ShadeState
  { ssBlendMode :: !Word8  -- ^ polygon attribute bits 4-5
  , ssHighlight :: !Bool   -- ^ blend mode 2 with DISP3DCNT bit 1
  , ssPolyAlpha :: !Word8  -- ^ polygon attribute bits 16-20; 0 is wireframe
  } deriving (Eq, Generic, Show, NFDataX)

-- | Derive the shader state from the polygon attribute and DISP3DCNT.
shadeState :: Word32 -> Word32 -> ShadeState
shadeState attr dispcnt =
  let mode = fromIntegral ((attr `shiftR` 4) .&. 0x3)
  in ShadeState mode (mode == 2 && testBit dispcnt 1)
       (fromIntegral ((attr `shiftR` 16) .&. 0x1F))

-- | RGB555 to the renderer's 6-bit channels: @c << 1@, plus one when nonzero.
expand555 :: Word16 -> Rgb6
expand555 c =
  let ch v = let x = fromIntegral v .&. 0x3E in if x /= 0 then x + 1 else x
  in (ch (c `shiftL` 1), ch (c `shiftR` 4), ch (c `shiftR` 9))

-- | Pack channels and alpha into the colour-buffer word.
packColour :: Rgb6 -> Word8 -> Word32
packColour (r, g, b) a =
  fromIntegral r .|. (fromIntegral g `shiftL` 8) .|. (fromIntegral b `shiftL` 16)
    .|. (fromIntegral a `shiftL` 24)

-- | Shade one pixel. @toonEntry@ is the toon table entry at
-- @vertex red >> 1@, the only index production reads (toon mode replaces the
-- vertex colour with it, highlight mode adds it). The texel is 'Nothing' when
-- texturing is off for this polygon, otherwise its 6-bit colour and 5-bit
-- alpha.
shadePixel :: Word16 -> ShadeState -> Rgb6 -> Maybe (Rgb6, Word8) -> Word32
shadePixel toonEntry st (vr0, vg0, vb0) mtexel =
  let mode = ssBlendMode st
      pa = ssPolyAlpha st
      toon = expand555 toonEntry
      (vr, vg, vb)
        | mode == 2 && ssHighlight st = (vr0, vr0, vr0)
        | mode == 2 = toon
        | otherwise = (vr0, vg0, vb0)
      w :: Word8 -> Word32
      w = fromIntegral
      n :: Word32 -> Word8
      n = fromIntegral
      ((r, g, b), a) = case mtexel of
        Nothing -> ((vr, vg, vb), pa)
        Just ((tr, tg, tb), ta)
          | testBit mode 0 ->
              -- The texel alpha is 0..31, so its complement is 5 bits wide.
              let decal t v = n ((w t * w ta + w v * ((31 - w ta) .&. 0x1F)) `shiftR` 5)
                  c | ta == 0 = (vr, vg, vb)
                    | ta == 31 = (tr, tg, tb)
                    | otherwise = (decal tr vr, decal tg vg, decal tb vb)
              in (c, pa)
          | otherwise ->
              let modu t v = n (((w t + 1) * (w v + 1) - 1) `shiftR` 6)
              in ( (modu tr vr, modu tg vg, modu tb vb)
                 , n (((w ta + 1) * (w pa + 1) - 1) `shiftR` 5) )
      (r', g', b')
        | ssHighlight st =
            let (hr, hg, hb) = toon
                sat x y = min 63 (x + y)
            in (sat r hr, sat g hg, sat b hb)
        | otherwise = (r, g, b)
      a' = if pa == 0 then 31 else a
  in packColour (r', g', b') a'

-- | Blend a translucent source over the colour buffer. A destination with
-- alpha 0 takes the source unchanged; otherwise the channels blend only when
-- DISP3DCNT bit 3 is set, and the alpha becomes the larger of the two. The
-- source alpha is 0..31 (what 'shadePixel' produces), so both blend weights
-- are 6 bits wide.
alphaBlend :: Bool -> Word32 -> Word32 -> Word32
alphaBlend blending src dst
  | dstA == 0 = src
  | otherwise =
      let ch sh = (src `shiftR` sh) .&. 0x3F
          dch sh = (dst `shiftR` sh) .&. 0x3F
          a1 = alpha + 1
          mix sh
            | blending = (ch sh * (a1 .&. 0x3F) + dch sh * ((32 - a1) .&. 0x3F)) `shiftR` 5
            | otherwise = ch sh
      in mix 0 .|. (mix 8 `shiftL` 8) .|. (mix 16 `shiftL` 16)
           .|. (max alpha dstA `shiftL` 24)
  where
    alpha = src `shiftR` 24
    dstA = dst `shiftR` 24

-- | Per-polygon state for 'plotPixel'.
data PlotState = PlotState
  { plPolyAttr   :: !Word32  -- ^ @Attr & 0x3F008000@, plus bit 4 when back-facing
  , plDepthWrite :: !Bool    -- ^ polygon attribute bit 11: translucent pixels update depth
  , plShadow     :: !Bool    -- ^ shadow polygon (blend mode 3, nonzero ID)
  } deriving (Eq, Generic, Show, NFDataX)

-- | Derive the plot state from the polygon attribute and its facing.
plotState :: Word32 -> Bool -> Bool -> PlotState
plotState attr facing shadow =
  PlotState ((attr .&. 0x3F008000) .|. (if facing then 0 else 0x10)) (testBit attr 11) shadow

-- | The top-layer update one pixel makes.
data PixelWrite = PixelWrite
  { pwColour :: !Word32
  , pwAttr   :: !Word32
  , pwDepth  :: !Bool  -- ^ write the pixel's depth too
  } deriving (Eq, Generic, Show, NFDataX)

-- | What a shaded pixel that passed the depth test writes, given DISP3DCNT's
-- blending bit, the alpha-test reference, its edge flags, and the
-- destination colour and attribute. 'Nothing' when the alpha test rejects it
-- or a translucent pixel meets its own translucent (or, for shadows, opaque)
-- polygon ID.
plotPixel :: Bool -> Word32 -> PlotState -> Word32 -> Word32 -> Word32 -> Word32
          -> Maybe PixelWrite
plotPixel blending alphaRef ps flags col dstC dstA
  | alpha <= alphaRef = Nothing
  | alpha == 31 = Just (PixelWrite col (pa .|. flags) True)
  | skip = Nothing
  | otherwise = Just (PixelWrite (alphaBlend blending col dstC) attr1 (plDepthWrite ps))
  where
    alpha = col `shiftR` 24
    pa = plPolyAttr ps
    attr0 = (pa .&. 0xE0F0) .|. ((pa `shiftR` 8) .&. 0xFF0000) .|. 0x400000
              .|. (dstA .&. 0xFF001F0F)
    sameTrans = dstA .&. 0x7F0000 == attr0 .&. 0x7F0000
    skip
      | plShadow ps =
          if testBit dstA 22 then sameTrans else dstA .&. 0x3F000000 == pa .&. 0x3F000000
      | otherwise = sameTrans
    attr1 = if testBit dstA 15 then attr0 else attr0 .&. 0xFFFF7FFF
