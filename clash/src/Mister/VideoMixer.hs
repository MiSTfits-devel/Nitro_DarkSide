{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

-- | Clash implementation of the part of sys/video_mixer.sv that NDS uses.
--
-- NDS permanently selects scandoubler=0, hq2x=0 and HDMI_FREEZE=0.  Gamma is
-- performed by the small dual-clock RAM wrapper, before this module.  Keeping
-- that RAM outside the pixel-control state machine makes the latter an
-- ordinary, portable Clash component and preserves the original latency.
module Mister.VideoMixer
  ( MixerIn (..)
  , MixerOut (..)
  , mixerCore
  , topEntity
  ) where

import Clash.Prelude
import GHC.Generics (Generic)

data MixerIn = MixerIn
  { miCePix  :: Bit
  , miR      :: Unsigned 8
  , miG      :: Unsigned 8
  , miB      :: Unsigned 8
  , miHSync  :: Bit
  , miVSync  :: Bit
  , miHBlank :: Bit
  , miVBlank :: Bit
  }
  deriving (Eq, Generic, NFDataX, BitPack, Show)

data MixerOut = MixerOut
  { moCePixel :: Bit
  , moR       :: Unsigned 8
  , moG       :: Unsigned 8
  , moB       :: Unsigned 8
  , moHSync   :: Bit
  , moVSync   :: Bit
  , moDE      :: Bit
  }
  deriving (Eq, Generic, NFDataX, BitPack, Show)

data MixerState = MixerState
  { msOldCe    :: Bit
  , msCeOsc    :: Bit
  , msFrameOsc :: Bit
  , msOldVs    :: Bit
  , msRPipe    :: Unsigned 8
  , msGPipe    :: Unsigned 8
  , msBPipe    :: Unsigned 8
  , msHDe      :: Bit
  , msVDe      :: Bit
  , msHs       :: Bit
  , msVs       :: Bit
  , msOldHDe   :: Bit
  , msOut      :: MixerOut
  }
  deriving (Eq, Generic, NFDataX, Show)

initialState :: MixerState
initialState = MixerState
  { msOldCe = 0, msCeOsc = 0, msFrameOsc = 0, msOldVs = 0
  , msRPipe = 0, msGPipe = 0, msBPipe = 0
  , msHDe = 0, msVDe = 0, msHs = 0, msVs = 0, msOldHDe = 0
  , msOut = MixerOut 0 0 0 0 0 0 0
  }

-- | Exact register ordering of the non-gamma, non-scandoubler branch in
-- sys/video_mixer.sv. In particular, output registers consume the *previous*
-- CE_PIXEL value; this is relied on by the framework's pixel timing.
step :: MixerState -> MixerIn -> (MixerState, MixerOut)
step MixerState {..} MixerIn {..} = (next, out')
 where
  risingVs = msOldVs == 0 && miVSync == 1
  ceOsc'   = if risingVs then 0 else msCeOsc .|. (msOldCe `xor` miCePix)
  frameOsc' = if risingVs then msCeOsc else msFrameOsc
  cePixel' = if msFrameOsc == 1
               then complement msOldCe .&. miCePix
               else miCePix

  hDe' = complement miHBlank
  vDe' = complement miVBlank
  deChanged = msOldHDe `xor` msHDe

  out' = if moCePixel msOut == 1
    then MixerOut
      { moCePixel = cePixel'
      , moR       = msRPipe
      , moG       = msGPipe
      , moB       = msBPipe
      , moHSync   = msHs
      , moVSync   = msVs
      , moDE      = if deChanged == 1 then msVDe .&. msHDe else moDE msOut
      }
    else msOut { moCePixel = cePixel' }

  oldHDe' = if moCePixel msOut == 1 then msHDe else msOldHDe
  next = MixerState
    { msOldCe = miCePix
    , msCeOsc = ceOsc'
    , msFrameOsc = frameOsc'
    , msOldVs = miVSync
    , msRPipe = miR, msGPipe = miG, msBPipe = miB
    , msHDe = hDe', msVDe = vDe', msHs = miHSync, msVs = miVSync
    , msOldHDe = oldHDe'
    , msOut = out'
    }

mixerCore :: HiddenClockResetEnable dom => Signal dom MixerIn -> Signal dom MixerOut
mixerCore = mealy step initialState

{-# ANN topEntity
  (Synthesize
    { t_name = "nds_clash_video_mixer_core"
    , t_inputs = [ PortName "CLK_VIDEO"
                 , PortName "RST"
                 , PortName "EN"
                 , PortName "ce_pix"
                 , PortName "R"
                 , PortName "G"
                 , PortName "B"
                 , PortName "HSync"
                 , PortName "VSync"
                 , PortName "HBlank"
                 , PortName "VBlank"
                 ]
    , t_output = PortProduct "out"
        [ PortName "CE_PIXEL", PortName "VGA_R", PortName "VGA_G"
        , PortName "VGA_B", PortName "VGA_HS", PortName "VGA_VS"
        , PortName "VGA_DE"
        ]
    }) #-}
topEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System Bit
  -> Signal System (Unsigned 8) -> Signal System (Unsigned 8) -> Signal System (Unsigned 8)
  -> Signal System Bit -> Signal System Bit -> Signal System Bit -> Signal System Bit
  -> ( Signal System Bit
     , Signal System (Unsigned 8), Signal System (Unsigned 8), Signal System (Unsigned 8)
     , Signal System Bit, Signal System Bit, Signal System Bit
     )
topEntity clk rst en ce r g b hs vs hb vb =
  withClockResetEnable clk rst en $
    unbundle (mixerCore (MixerIn <$> ce <*> r <*> g <*> b <*> hs <*> vs <*> hb <*> vb))
