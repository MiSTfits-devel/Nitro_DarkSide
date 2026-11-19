-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds,DeriveAnyClass,DeriveGeneric,NoImplicitPrelude #-}
module Nds.WholeCore.BiosIoPorts where
import Clash.Explicit.Prelude
import qualified Nds.WholeCore.Card as C
-- The native system endpoint owns only decoded addresses. Replies, including
-- held reads, are routed by valid, never by the following request address.
data IoTx=IoTx C.CardBus C.CardBus Bool deriving (Generic,NFDataX)
data IoRx=IoRx {owns9 :: Bool,rep9,rep7 :: C.CardReply, int9,int7 :: BitVector 32,post,query :: Bool,queryAddr :: BitVector 32} deriving (Generic,NFDataX)
