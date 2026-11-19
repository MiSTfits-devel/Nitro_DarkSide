-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}

-- | Adapt Card's single-outstanding 32-bit image port to a 64-bit board ROM
-- provider. Addresses on both interfaces are byte offsets in the image.
-- The request is held by Card until accepted. The board returns exactly one
-- response, no earlier than the cycle after acceptance. The board and this
-- adapter share a reset: reset must discard any outstanding board response.
-- Unbacked image bytes are supplied by the board as 0xff.
module Nds.WholeCore.CardRomAdapter
  ( AdapterState, AdapterIn(..), AdapterOut(..), initialAdapter, adapterStep
  , cardRomAdapter, cardRomAdapterTopEntity
  ) where

import Prelude ()
import Clash.Prelude

data AdapterState = AdapterState { pending :: Bool, upper :: Bool }
  deriving (Generic, NFDataX)

data AdapterIn = AdapterIn
  { cardRequest :: Bool
  , cardAddress :: BitVector 32
  , boardReady :: Bool
  , boardReplyValid :: Bool
  , boardReplyData :: BitVector 64
  } deriving (Generic, NFDataX)

data AdapterOut = AdapterOut
  { cardReady :: Bool
  , cardReplyValid :: Bool
  , cardReplyData :: BitVector 32
  , boardRequest :: Bool
  , boardAddress :: BitVector 32
  } deriving (Eq, Show, Generic, NFDataX)

initialAdapter :: AdapterState
initialAdapter = AdapterState False False

adapterStep :: AdapterState -> AdapterIn -> (AdapterState, AdapterOut)
adapterStep s i = (next, out)
 where
  available = not (pending s)
  accepted = available && cardRequest i && boardReady i
  returned = pending s && boardReplyValid i
  next = AdapterState
    { pending = (pending s && not returned) || accepted
    , upper = if accepted then testBit (cardAddress i) 2 else upper s }
  out = AdapterOut
    { cardReady = available && boardReady i
    , cardReplyValid = returned
    , cardReplyData = if upper s then slice d63 d32 (boardReplyData i)
                                else slice d31 d0 (boardReplyData i)
    , boardRequest = available && cardRequest i
    , boardAddress = cardAddress i .&. 0xfffffff8 }

cardRomAdapter
  :: KnownDomain dom => Clock dom -> Reset dom -> Enable dom
  -> Signal dom AdapterIn -> Signal dom AdapterOut
cardRomAdapter clk rst en input = gate <$> active <*> raw
 where
  raw = withClockResetEnable clk rst en (mealy adapterStep initialAdapter input)
  active = (&&) <$> fromEnable en <*> (not <$> unsafeToActiveHigh rst)
  gate running o = o { cardReady = running && cardReady o
                     , cardReplyValid = running && cardReplyValid o
                     , boardRequest = running && boardRequest o }

{-# ANN cardRomAdapterTopEntity
  (Synthesize
    { t_name = "nds_card_rom_adapter"
    , t_inputs = [ PortName "CLK", PortName "RST", PortName "EN"
                 , PortName "CARD_REQ_VALID", PortName "CARD_ADDR"
                 , PortName "DDR_READY", PortName "DDR_REPLY_VALID", PortName "DDR_REPLY_DATA" ]
    , t_output = PortProduct "" [ PortName "CARD_READY", PortName "CARD_REPLY_VALID"
                              , PortName "CARD_REPLY_DATA", PortName "DDR_REQ_VALID", PortName "DDR_ADDR" ]
    }) #-}
cardRomAdapterTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System Bool -> Signal System (BitVector 32)
  -> Signal System Bool -> Signal System Bool -> Signal System (BitVector 64)
  -> Signal System AdapterOut
cardRomAdapterTopEntity clk rst en req addr ready valid dat =
  cardRomAdapter clk rst en (AdapterIn <$> req <*> addr <*> ready <*> valid <*> dat)
