{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}

-- | NDS-facing control-plane subset of sys/hps_io.sv.
--
-- This is deliberately a transition function, rather than an HPS_BUS top
-- entity. The HPS bus is a bidirectional DE10-specific transport; the
-- wrapper owns its electrical direction while this module owns the portable
-- command state. Commands not represented below (SD buffers, PS/2, RTC and
-- file-transfer) must be implemented before this replaces the legacy block.
module Mister.HpsIoSubset
  ( HpsIoIn (..)
  , HpsIoOut (..)
  , HpsIoState (..)
  , initialHpsIoState
  , hpsIoStep
  , hpsIoControl
  ) where

import Clash.Prelude
import GHC.Generics (Generic)

data HpsIoIn = HpsIoIn
  { hiEnabled :: Bool
  , hiStrobe  :: Bool
  , hiWord    :: Unsigned 16
  }
  deriving (Eq, Generic, NFDataX, BitPack, Show)

data HpsIoOut = HpsIoOut
  { hoButtons            :: Unsigned 2
  , hoForcedScandoubler  :: Bool
  , hoJoystick0          :: Unsigned 32
  -- | Word 0 is the legacy status[15:0] field. Keeping the wire order
  -- explicit avoids accidental status-bit reversal at the HPS_BUS boundary.
  , hoStatusWords        :: Vec 8 (Unsigned 16)
  , hoGammaEnable        :: Bool
  , hoGammaWrite         :: Bool
  , hoGammaAddress       :: Unsigned 10
  , hoGammaValue         :: Unsigned 8
  }
  deriving (Eq, Generic, NFDataX, BitPack, Show)

data HpsIoState = HpsIoState
  { hsCommand    :: Unsigned 16
  , hsByteCount  :: Unsigned 4
  , hsConfig     :: Unsigned 16
  , hsJoystick0  :: Unsigned 32
  , hsStatusWords :: Vec 8 (Unsigned 16)
  , hsGammaEn    :: Bool
  , hsGammaAddr  :: Unsigned 10
  , hsGammaValue :: Unsigned 8
  }
  deriving (Eq, Generic, NFDataX, BitPack, Show)

initialHpsIoState :: HpsIoState
initialHpsIoState = HpsIoState 0 0 0 0 (repeat 0) False 0 0

outputOf :: Bool -> HpsIoState -> HpsIoOut
outputOf gammaWrite HpsIoState {..} = HpsIoOut
  { hoButtons = resize hsConfig
  , hoForcedScandoubler = testBit hsConfig 4
  , hoJoystick0 = hsJoystick0
  , hoStatusWords = hsStatusWords
  , hoGammaEnable = hsGammaEn
  , hoGammaWrite = gammaWrite
  , hoGammaAddress = hsGammaAddr
  , hoGammaValue = hsGammaValue
  }

-- | Follows the byte-count protocol in the legacy `uio_block` for the four
-- NDS-relevant, side-effect-free commands: config (01), joystick 0 (02),
-- status (1e), gamma enable/table programming (32/33).
hpsIoStep :: HpsIoState -> HpsIoIn -> (HpsIoState, HpsIoOut)
hpsIoStep state HpsIoIn {..}
  | not hiEnabled = (initialHpsIoState { hsConfig = hsConfig state
                                         , hsJoystick0 = hsJoystick0 state
                                         , hsStatusWords = hsStatusWords state
                                         , hsGammaEn = hsGammaEn state
                                         , hsGammaAddr = hsGammaAddr state
                                         , hsGammaValue = hsGammaValue state
                                         }, outputOf False state)
  | not hiStrobe = (state, outputOf False state)
  | hsByteCount state == 0 = (state { hsCommand = hiWord, hsByteCount = 1 }, outputOf False state)
  | otherwise = (next, outputOf gammaWrite next)
 where
  n = hsByteCount state
  advance s = s { hsByteCount = n + 1 }
  command = hsCommand state
  gammaWrite = command == 0x33
  word8 = resize hiWord :: Unsigned 8
  gammaAddr = (resize ((n .&. 3) - 1) `shiftL` 8) .|. resize (shiftR hiWord 8)

  next
    | command == 0x01 = advance state { hsConfig = hiWord }
    | command == 0x02 && n == 1 = advance state { hsJoystick0 = (hsJoystick0 state .&. 0xffff0000) .|. resize hiWord }
    | command == 0x02 && n == 2 = advance state { hsJoystick0 = (hsJoystick0 state .&. 0x0000ffff) .|. (resize hiWord `shiftL` 16) }
    | command == 0x1e && n <= 8 = advance state { hsStatusWords = replace (statusIndex n) hiWord (hsStatusWords state) }
    | command == 0x32 = advance state { hsGammaEn = testBit hiWord 0 }
    | command == 0x33 = state { hsByteCount = if n .&. 3 == 3 then 1 else n + 1
                               , hsGammaAddr = gammaAddr
                               , hsGammaValue = word8
                               }
    | otherwise = advance state

-- | The HPS protocol numbers status words from one. `replace` generates the
-- same 8-way mux as the legacy explicit case statement.
statusIndex :: Unsigned 4 -> Index 8
statusIndex n = unpack (pack (resize (n - 1) :: Unsigned 3))

-- | Synthesizable Clash signal form. The eventual HPS_BUS wrapper will drive
-- 'HpsIoIn' only when the UIO side of the bus is selected.
hpsIoControl :: HiddenClockResetEnable dom => Signal dom HpsIoIn -> Signal dom HpsIoOut
hpsIoControl = mealy hpsIoStep initialHpsIoState
