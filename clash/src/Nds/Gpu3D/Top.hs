{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Clash entry point for the NDS edge walk.
--
-- The pure equations live in 'Nds.Gpu3D.Slope'; this module only turns
-- them into a synchronous machine. A 'SlopeSetup' command loads one polygon
-- edge and returns its first X; each 'SlopeStep' advances one scanline.
module Nds.Gpu3D.Top
  ( SlopeCmd (..)
  , SlopeResp (..)
  , slopeMachine
  , topEntity
  ) where

import Clash.Prelude
import Data.Int (Int32)
import GHC.Generics (Generic)

import Nds.Gpu3D.Slope

toBV :: Int32 -> BitVector 32
toBV = fromIntegral

fromBV :: BitVector 32 -> Int32
fromBV = fromIntegral . toInteger

data SlopeCmd
  = SlopeSetup
      (BitVector 1) (BitVector 1)  -- side, W-buffer
      (BitVector 32) (BitVector 32) (BitVector 32) (BitVector 32)  -- x0 x1 y0 y1
      (BitVector 32) (BitVector 32) (BitVector 32)        -- w0 w1 y
  | SlopeStep
  deriving (Eq, Generic, NFDataX, Show)

data SlopeResp = SlopeResp
  { srValid :: (BitVector 1)
  , srX     :: (BitVector 32)
  } deriving (Eq, Generic, NFDataX, Show)

slopeMachine :: HiddenClockResetEnable dom
  => Signal dom SlopeCmd -> Signal dom SlopeResp
slopeMachine = mealy slopeStep Nothing

slopeStep :: Maybe Slope -> SlopeCmd -> (Maybe Slope, SlopeResp)
slopeStep Nothing SlopeStep = (Nothing, SlopeResp 0 0x0)
slopeStep (Just s) SlopeStep =
  let (x, s') = stepSlope s
  in (Just s', SlopeResp 1 (toBV x))
slopeStep _ (SlopeSetup sideBits wbBits x0 x1 y0 y1 w0 w1 y) =
  let side = unpack sideBits
      wb = unpack wbBits
      (x, s) = setupSlope side (fromBV x0) (fromBV x1)
        (fromBV y0) (fromBV y1) (fromBV w0)
        (fromBV w1) (fromBV y) wb
  in (Just s, SlopeResp 1 (toBV x))

{-# ANN topEntity
  (Synthesize
    { t_name = "nds_gpu3d_slope"
    , t_inputs =
        [ PortName "CLK"
        , PortName "RST"
        , PortName "EN"
        , PortName "CMD"
        ]
    , t_output = PortProduct "out"
        [ PortName "VALID", PortName "X" ]
    }) #-}
topEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System SlopeCmd
  -> Signal System (BitVector 1, BitVector 32)
topEntity clk rst en =
  withClockResetEnable clk rst en $
    fmap (\r -> (srValid r, srX r)) . slopeMachine
