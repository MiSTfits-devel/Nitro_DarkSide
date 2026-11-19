-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, NoImplicitPrelude #-}
module Nds.WholeCore.BiosCartUnit (CartPins(..), Save(..), CartResult(..), biosCartTopEntity) where
import Clash.Explicit.Prelude hiding (Word)
import qualified Nds.WholeCore.Card as C
import qualified Nds.WholeCore.CardNative as K
import qualified Nds.WholeCore.CardRomAdapter as A
import qualified Nds.WholeCore.BackupSpi as B
type Word=BitVector 32
data CartPins=CartPins C.CardBus C.CardBus Bool Word Word Bool Bool (BitVector 64) Bool (BitVector 4) Bool Bool Bool (BitVector 8) Bool deriving (Generic,NFDataX)
data Save=Save Bool Bool (BitVector 24) (BitVector 8) Bool deriving (Generic,NFDataX)
data CartResult=CartResult {r9,r7 :: C.CardReply,irq9,irq7,req :: Bool,addr :: Word,saveBus :: Save} deriving (Generic,NFDataX)
{-# ANN biosCartTopEntity (Synthesize {t_name="nds_bios_cart",t_inputs=[PortName "CLK",PortName "RST",PortName "CART_IN"],t_output=PortName "CART_OUT"}) #-}
biosCartTopEntity :: Clock System -> Reset System -> Signal System CartPins -> Signal System CartResult
biosCartTopEntity clk rst pins=CartResult <$> (K.nativeReply9 <$> card) <*> (K.nativeReply7 <$> card) <*> (K.nativeIrq9 <$> card) <*> (K.nativeIrq7 <$> card) <*> (A.boardRequest <$> rom) <*> (A.boardAddress <$> rom) <*> save
 where
  card=K.nativeCard clk rst enableGen ((\(CartPins b9 b7 ins ident mask _ _ _ _ _ _ _ _ _ _) a b->K.NativeCardIn b9 b7 (C.CardIn ins False ident mask (A.cardReady a) (A.cardReplyValid a) (A.cardReplyData a)) (B.xferReady b) (B.xferRespValid b) (B.xferRespByte b) (B.xferRespFault b)) <$> pins <*> rom <*> bk)
  bk=mealy clk rst enableGen B.backupStep B.initialBackup ((\c (CartPins _ _ _ _ _ _ _ _ pv pt ir ready valid dat fault)->B.BackupIn (K.nativeSpiValid c) (K.nativeSpiByte c) (K.nativeSpiHold c) (K.nativeSpiSelected c) (K.nativeSpiReplyReady c) pv pt ir ready valid dat fault) <$> card <*> pins)
  save=(\b->Save (B.cacheReqValid b) (B.cacheReqWrite b) (B.cacheReqAddr b) (B.cacheReqData b) (B.cacheRespReady b)) <$> bk
  rom=A.cardRomAdapter clk rst enableGen ((\c (CartPins _ _ _ _ _ ready valid dat _ _ _ _ _ _ _)->A.AdapterIn (K.nativeRomValid c) (K.nativeRomAddress c) ready valid dat) <$> card <*> pins)
