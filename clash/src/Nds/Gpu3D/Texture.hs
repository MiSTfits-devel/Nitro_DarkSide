{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Exact melonDS texture sampling (@SoftRenderer3D::TextureLookup@), in the
-- three stages a streaming texture unit performs:
--
-- 1. 'texelFetch': coordinates to texture-memory addresses (wrap, clamp, flip,
--    texel address, and for 4x4-compressed textures the slot-1 index word).
-- 2. 'paletteFetch': fetched texel data to one palette word address plus the
--    texel's alpha and how the colour is formed from that word.
-- 3. 'texelColour': the fetched palette word to the RGB555 colour.
--
-- Memory is abstract ('TexMem'): halfword reads from the 512 KiB texture space
-- and word reads from the 128 KiB texture-palette space, which is exactly
-- what @ReadVRAMFlat_Texture@ and @ReadVRAMFlat_TexPal@ address. Every texel,
-- in every format, needs at most two texture halfwords and one palette word.
module Nds.Gpu3D.Texture
  ( TexMem (..)
  , TexState (..)
  , texState
  , Texel (..)
  , TexFetch (..)
  , PalKind (..)
  , PalFetch (..)
  , wrapCoord
  , texelFetch
  , paletteFetch
  , texelColour
  , textureLookup
  , texByte
  , texHalf16
  , palHalf
  ) where

import Prelude

import Data.Bits (complement, shiftL, shiftR, testBit, (.&.), (.|.))
import Data.Int (Int16, Int32)
import Data.Word (Word16, Word32, Word8)
import GHC.Generics (Generic)

import Clash.Prelude (NFDataX)

-- | The two texture memories as the 3D engine sees them.
data TexMem = TexMem
  { tmTexHalf :: Word32 -> Word16
    -- ^ halfword at an even byte address in texture slots 0-3 (masked to 0x7FFFE)
  , tmPalWord :: Word32 -> Word32
    -- ^ word at a 4-aligned byte address in palette slots 0-7 (masked to 0x1FFFC)
  }

-- | Per-polygon texture state, as @SetupPolygon@ derives it.
data TexState = TexState
  { tsBase    :: !Word32  -- ^ @(TexParam & 0xFFFF) << 3@
  , tsWidth   :: !Int32
  , tsWidthLog2 :: !Int   -- ^ @log2 tsWidth@ (3..10): the width is a power of two
  , tsHeight  :: !Int32
  , tsRepeatS :: !Bool
  , tsRepeatT :: !Bool
  , tsFlipS   :: !Bool
  , tsFlipT   :: !Bool
  , tsFormat  :: !Word8   -- ^ 0 none, 1 A3I5, 2 4-colour, 3 16-colour,
                          --   4 256-colour, 5 4x4 compressed, 6 A5I3, 7 direct
  , tsPalBase :: !Word32  -- ^ @TexPalette << (format == 2 ? 3 : 4)@
  , tsAlpha0  :: !Word8   -- ^ alpha of palette index 0: 0 when transparent, else 31
  } deriving (Eq, Generic, Show, NFDataX)

-- | Decode @TexParam@ and @TexPalette@.
texState :: Word32 -> Word32 -> TexState
texState texparam texpal =
  let fmt = fromIntegral ((texparam `shiftR` 26) .&. 0x7) :: Word8
  in TexState
    { tsBase = (texparam .&. 0xFFFF) `shiftL` 3
    , tsWidth = 8 `shiftL` fromIntegral ((texparam `shiftR` 20) .&. 0x7)
    , tsWidthLog2 = 3 + fromIntegral ((texparam `shiftR` 20) .&. 0x7)
    , tsHeight = 8 `shiftL` fromIntegral ((texparam `shiftR` 23) .&. 0x7)
    , tsRepeatS = testBit texparam 16
    , tsRepeatT = testBit texparam 17
    , tsFlipS = testBit texparam 18
    , tsFlipT = testBit texparam 19
    , tsFormat = fmt
    , tsPalBase = texpal `shiftL` (if fmt == 2 then 3 else 4)
    , tsAlpha0 = if testBit texparam 29 then 0 else 31
    }

-- | One sampled texel: RGB555 colour and 5-bit alpha.
data Texel = Texel
  { texColour :: !Word16
  , texAlpha  :: !Word8
  } deriving (Eq, Generic, Show, NFDataX)

-- | Stage-1 result: the texture-memory reads one texel needs.
data TexFetch = TexFetch
  { tfAddr  :: !Word32  -- ^ byte address of the texel data
  , tfInfo  :: !Word32  -- ^ 4x4: halfword address of the block's palette index
  , tfZero  :: !Bool    -- ^ 4x4: texel data reads as zero (slot-1 address)
  , tfShift :: !Int     -- ^ bit position of the texel inside its byte or halfword
  } deriving (Eq, Generic, Show, NFDataX)

-- | How the palette word becomes the colour.
data PalKind
  = PalLow        -- ^ low halfword
  | PalHigh       -- ^ high halfword
  | PalHalf       -- ^ 4x4 mode 1: (c0 + c1) / 2
  | PalMix53      -- ^ 4x4 mode 3: (5 c0 + 3 c1) / 8
  | PalMix35      -- ^ 4x4 mode 3: (3 c0 + 5 c1) / 8
  | PalDirect !Word16  -- ^ direct colour: no palette read
  | PalNone       -- ^ 4x4 transparent: colour 0, no palette read
  deriving (Eq, Generic, Show, NFDataX)

-- | Stage-2 result: one palette word to read, and the texel's alpha.
data PalFetch = PalFetch
  { pfAddr  :: !Word32  -- ^ 4-aligned byte address in palette space
  , pfKind  :: !PalKind
  , pfAlpha :: !Word8
  } deriving (Eq, Generic, Show, NFDataX)

-- | Wrap, flip or clamp one integer texel coordinate (already @>> 4@).
wrapCoord :: Bool -> Bool -> Int32 -> Int32 -> Int32
wrapCoord repeat' flip' size c
  | repeat' && flip' =
      if c .&. size /= 0 then (size - 1) - (c .&. (size - 1)) else c .&. (size - 1)
  | repeat' = c .&. (size - 1)
  | c < 0 = 0
  | c >= size = size - 1
  | otherwise = c

-- | Stage 1: integer texel position and the texture reads it needs. The
-- row offsets multiply by the power-of-two width, so they are shifts.
texelFetch :: TexState -> Int16 -> Int16 -> TexFetch
texelFetch st s16 t16 =
  let s = wrapCoord (tsRepeatS st) (tsFlipS st) (tsWidth st) (fromIntegral s16 `shiftR` 4)
      t = wrapCoord (tsRepeatT st) (tsFlipT st) (tsHeight st) (fromIntegral t16 `shiftR` 4)
      wl = tsWidthLog2 st
      base = tsBase st
      lin = fromIntegral ((t `shiftL` wl) + s) :: Word32
      plain a sh = TexFetch a 0 False sh
  in case tsFormat st of
       2 -> plain (base + (lin `shiftR` 2)) (fromIntegral ((s .&. 0x3) `shiftL` 1))
       3 -> plain (base + (lin `shiftR` 1)) (if testBit s 0 then 4 else 0)
       5 ->
         let a0 = base + fromIntegral (((t .&. 0x3FC) `shiftL` (wl - 2)) + (s .&. 0x3FC))
                       + fromIntegral (t .&. 0x3)
             a = a0 .&. 0x7FFFF
             slot1 = 0x20000 + ((a .&. 0x1FFFC) `shiftR` 1)
                       + (if a >= 0x40000 then 0x10000 else 0)
         in TexFetch a slot1 (a >= 0x20000 && a < 0x40000)
              (fromIntegral ((s .&. 0x3) `shiftL` 1))
       7 -> plain (base + (lin `shiftL` 1)) 0
       _ -> plain (base + lin) 0

-- | Stage 2: decode the fetched data to a palette word request. @texel@ is the
-- halfword holding 'tfAddr' (even address), @info@ the halfword at 'tfInfo'.
paletteFetch :: TexState -> TexFetch -> Word16 -> Word16 -> PalFetch
paletteFetch st tf texel info =
  let byte = if testBit (tfAddr tf) 0 then texel `shiftR` 8 else texel .&. 0xFF
      pal = tsPalBase st
      entry i = halfReq (pal + fromIntegral i `shiftL` 1)
      halfReq p = PalFetch (p .&. complement 0x3) (if testBit p 1 then PalHigh else PalLow)
      a0 i = if i == 0 then tsAlpha0 st else 31
  in case tsFormat st of
       1 -> entry (byte .&. 0x1F) (fromIntegral (((byte `shiftR` 3) .&. 0x1C) + (byte `shiftR` 6)))
       2 -> let i = (byte `shiftR` tfShift tf) .&. 0x3 in entry i (a0 i)
       3 -> let i = (byte `shiftR` tfShift tf) .&. 0xF in entry i (a0 i)
       4 -> entry byte (a0 byte)
       5 ->
         let val = if tfZero tf then 0 else (byte `shiftR` tfShift tf) .&. 0x3
             mode = info `shiftR` 14
             off = pal + (fromIntegral (info .&. 0x3FFF) `shiftL` 2)
             word0 k = PalFetch off k 31
             word1 k = PalFetch (off + 4) k 31
         in case val of
              0 -> word0 PalLow
              1 -> word0 PalHigh
              2 | mode == 1 -> word0 PalHalf
                | mode == 3 -> word0 PalMix53
                | otherwise -> word1 PalLow
              _ | mode == 2 -> word1 PalHigh
                | mode == 3 -> word0 PalMix35
                | otherwise -> PalFetch 0 PalNone 0
       6 -> entry (byte .&. 0x7) (fromIntegral (byte `shiftR` 3))
       _ -> PalFetch 0 (PalDirect texel) (if testBit texel 15 then 31 else 0)

-- | Stage 3: the palette word to the texel colour.
texelColour :: PalFetch -> Word32 -> Texel
texelColour pf word =
  let c0 = fromIntegral (word .&. 0xFFFF) :: Word32
      c1 = fromIntegral (word `shiftR` 16) :: Word32
      mix k0 k1 sh =
        let r = ((c0 .&. 0x001F) * k0 + (c1 .&. 0x001F) * k1) `shiftR` sh
            g = (((c0 .&. 0x03E0) * k0 + (c1 .&. 0x03E0) * k1) `shiftR` sh) .&. 0x03E0
            b = (((c0 .&. 0x7C00) * k0 + (c1 .&. 0x7C00) * k1) `shiftR` sh) .&. 0x7C00
        in fromIntegral (r .|. g .|. b)
      colour = case pfKind pf of
        PalLow -> fromIntegral c0
        PalHigh -> fromIntegral c1
        PalHalf -> mix 1 1 1
        PalMix53 -> mix 5 3 3
        PalMix35 -> mix 3 5 3
        PalDirect c -> c
        PalNone -> 0
  in Texel colour (pfAlpha pf)

-- | Byte read from texture space.
texByte :: TexMem -> Word32 -> Word8
texByte mem a =
  let h = tmTexHalf mem (a .&. 0x7FFFE)
  in fromIntegral (if testBit a 0 then h `shiftR` 8 else h)

-- | Halfword read from texture space at an even address.
texHalf16 :: TexMem -> Word32 -> Word16
texHalf16 mem a = tmTexHalf mem (a .&. 0x7FFFE)

-- | Halfword read from palette space at an even address.
palHalf :: TexMem -> Word32 -> Word16
palHalf mem p =
  let w = tmPalWord mem (p .&. 0x1FFFC)
  in fromIntegral (if testBit p 1 then w `shiftR` 16 else w)

-- | The whole lookup: the three stages against one memory.
textureLookup :: TexMem -> TexState -> Int16 -> Int16 -> Texel
textureLookup mem st s t =
  let tf = texelFetch st s t
      texel = texHalf16 mem (tfAddr tf .&. complement 1)
      info = if tsFormat st == 5 then texHalf16 mem (tfInfo tf) else 0
      pf = paletteFetch st tf texel info
      word = case pfKind pf of
        PalDirect _ -> 0
        PalNone -> 0
        _ -> tmPalWord mem (pfAddr pf .&. 0x1FFFC)
  in texelColour pf word
