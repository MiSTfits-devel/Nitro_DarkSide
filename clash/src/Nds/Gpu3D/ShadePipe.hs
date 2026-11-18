{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Pipelined per-pixel back end: texture sampling, shading and the
-- top-layer update, for pixels that already passed the depth test.
--
-- Three stages, one pixel per enabled cycle, the texture and palette
-- memories behind registered (one-cycle) read ports:
--
-- 1. decode @TexParam@/@TexPalette@/attribute, 'texelFetch': drive the texel
--    halfword address and the 4x4 index halfword address;
-- 2. 'paletteFetch' on the returned halfwords: drive the palette word address;
-- 3. 'texelColour', toon lookup, 'shadePixel' and 'plotPixel' on the returned
--    palette word: register the write.
--
-- 'pixelWithMemory' is the same three stages against an ideal memory. The
-- renderer model ('Nds.Gpu3D.Render') uses it for every plot, so the frame gate
-- compares exactly these stage functions with melonDS, and the pipeline gate
-- compares the pipeline with it. The 'Enable' stalls the whole pipeline; the
-- board wrapper must stall the memories' read registers with it (a
-- texture-cache miss is a stall). The toon table is a 32-entry LUT RAM
-- written through its own port (TOON_TABLE).
module Nds.Gpu3D.ShadePipe
  ( PixelIn (..)
  , PixelOut (..)
  , ShadeCfg (..)
  , pixelWithMemory
  , shadePipe
  , shadeTopEntity
  ) where

import Prelude

import Data.Bits (shiftR, testBit, (.&.))
import Data.Int (Int16, Int32)
import Data.Word (Word16, Word32, Word8)
import GHC.Generics (Generic)

import Clash.Explicit.Prelude
  ( Clock, Enable, KnownDomain, NFDataX, Reset, Signal, SNat (..), System, Unsigned
  , asyncRam, register )
import Clash.Annotations.TopEntity (PortName (..), TopEntity (..))

import Nds.Gpu3D.Shade
import Nds.Gpu3D.Texture

-- | One depth-passed pixel, with the raw polygon words it belongs to.
data PixelIn = PixelIn
  { piTexParam :: !Word32
  , piTexPal   :: !Word32
  , piAttr     :: !Word32   -- ^ polygon attribute
  , piFacing   :: !Bool
  , piVertex   :: !Rgb6     -- ^ interpolated vertex colour, 6-bit channels
  , piS, piT   :: !Int16    -- ^ interpolated 12.4 texture coordinates
  , piFlags    :: !Word32   -- ^ edge flags (bits 0-3)
  , piDstC     :: !Word32   -- ^ top-layer colour at the pixel
  , piDstA     :: !Word32   -- ^ top-layer attribute at the pixel
  , piZ        :: !Int32    -- ^ the pixel's depth, carried to the write
  , piAddr     :: !(Unsigned 8)  -- ^ X in the line buffer, carried to the write
  } deriving (Eq, Generic, Show, NFDataX)

-- | The registered result: the pixel's position and depth, and its write.
data PixelOut = PixelOut
  { poAddr  :: !(Unsigned 8)
  , poZ     :: !Int32
  , poWrite :: !(Maybe PixelWrite)
  } deriving (Eq, Generic, Show, NFDataX)

-- | The frame registers the back end reads.
data ShadeCfg = ShadeCfg
  { cfgDisp     :: !Word32  -- ^ DISP3DCNT: bit 0 texturing, 1 highlight, 3 blending
  , cfgAlphaRef :: !Word32  -- ^ effective alpha-test reference
  } deriving (Eq, Generic, Show, NFDataX)

-- | The back end against an ideal memory: every read the pipeline makes,
-- answered immediately. @toon@ reads the toon table.
pixelWithMemory :: TexMem -> ShadeCfg -> (Unsigned 5 -> Word16) -> PixelIn -> PixelOut
pixelWithMemory mem cfg toon p =
  let ts = texState (piTexParam p) (piTexPal p)
      tf = texelFetch ts (piS p) (piT p)
      pf = paletteFetch ts tf (tmTexHalf mem (texAddrOf tf)) (tmTexHalf mem (infoAddrOf tf))
  in finish cfg p (texelColour pf (tmPalWord mem (palAddrOf pf))) (toon (toonIndex p))

texAddrOf, infoAddrOf :: TexFetch -> Word32
texAddrOf tf = tfAddr tf .&. 0x7FFFE
infoAddrOf tf = tfInfo tf .&. 0x7FFFE

palAddrOf :: PalFetch -> Word32
palAddrOf pf = pfAddr pf .&. 0x1FFFC

texOn :: ShadeCfg -> PixelIn -> Bool
texOn cfg p = testBit (cfgDisp cfg) 0 && (piTexParam p `shiftR` 26) .&. 0x7 /= 0

finish :: ShadeCfg -> PixelIn -> Texel -> Word16 -> PixelOut
finish cfg p (Texel c a) toonEntry =
  let attr = piAttr p
      shadow = attr .&. 0x30 == 0x30 && attr .&. 0x3F000000 /= 0
      texel = if texOn cfg p then Just (expand555 c, a) else Nothing
      col = shadePixel toonEntry (shadeState attr (cfgDisp cfg)) (piVertex p) texel
      w = plotPixel (testBit (cfgDisp cfg) 3) (cfgAlphaRef cfg)
            (plotState attr (piFacing p) shadow) (piFlags p) col (piDstC p) (piDstA p)
  in PixelOut (piAddr p) (piZ p) w

toonIndex :: PixelIn -> Unsigned 5
toonIndex p = let (r, _, _) = piVertex p in fromIntegral ((r :: Word8) `shiftR` 1)

-- | The pipeline. Outputs: texel halfword address, 4x4 index halfword
-- address, palette word address (all byte addresses, read one cycle later),
-- and the registered pixel write, three enabled cycles after its input.
shadePipe
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom ShadeCfg
  -> Signal dom (Maybe (Unsigned 5, Word16))  -- ^ toon table write
  -> Signal dom (Maybe PixelIn)
  -> Signal dom Word16   -- ^ texture halfword at the texel address
  -> Signal dom Word16   -- ^ texture halfword at the 4x4 index address
  -> Signal dom Word32   -- ^ palette word
  -> ( Signal dom Word32, Signal dom Word32, Signal dom Word32
     , Signal dom (Maybe PixelOut) )
shadePipe clk rst en cfg toonWrite inp texD infoD palD =
  (texAddr, infoAddr, palAddr, out)
  where
    fetchA = fmap (fmap (\p -> (p, texelFetch (texState (piTexParam p) (piTexPal p)) (piS p) (piT p)))) inp
    texAddr = maybe 0 (texAddrOf . snd) <$> fetchA
    infoAddr = maybe 0 (infoAddrOf . snd) <$> fetchA
    regA = register clk rst en Nothing fetchA

    fetchB = stageB <$> regA <*> texD <*> infoD
    stageB ma texel info = fmap (\(p, tf) ->
      (p, paletteFetch (texState (piTexParam p) (piTexPal p)) tf texel info)) ma
    palAddr = maybe 0 (palAddrOf . snd) <$> fetchB
    regB = register clk rst en Nothing fetchB

    toonRead = asyncRam clk clk en (SNat :: SNat 32)
                 (maybe 0 (toonIndex . fst) <$> regB) toonWrite
    stageC c mb word toon = fmap (\(p, pf) -> finish c p (texelColour pf word) toon) mb
    out = register clk rst en Nothing (stageC <$> cfg <*> regB <*> palD <*> toonRead)

-- | Concrete top entity for synthesis and resource estimation.
{-# ANN shadeTopEntity
  (Synthesize
    { t_name = "nds_gpu3d_shade"
    , t_inputs =
        [ PortName "CLK"
        , PortName "RST"
        , PortName "EN"
        , PortName "CFG"
        , PortName "TOON_WRITE"
        , PortName "PIXEL"
        , PortName "TEX_DATA"
        , PortName "INFO_DATA"
        , PortName "PAL_DATA"
        ]
    , t_output = PortProduct ""
        [ PortName "TEX_ADDR", PortName "INFO_ADDR", PortName "PAL_ADDR", PortName "OUT" ]
    }) #-}
shadeTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System ShadeCfg
  -> Signal System (Maybe (Unsigned 5, Word16))
  -> Signal System (Maybe PixelIn)
  -> Signal System Word16
  -> Signal System Word16
  -> Signal System Word32
  -> ( Signal System Word32, Signal System Word32, Signal System Word32
     , Signal System (Maybe PixelOut) )
shadeTopEntity = shadePipe
{-# NOINLINE shadeTopEntity #-}
