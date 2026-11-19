-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, NoImplicitPrelude #-}
-- | Native board's posted ARM9 GX stream. A successful write reserves the
-- event on the same edge, not after retirement. Status from the normalizer
-- is local; test bits and clip/vector matrices come from an ordered H3R1
-- fence. Registers absent from that snapshot fault instead of returning zero.
module Nds.WholeCore.GxLink
  ( GxIn(..), GxOut(..), GxState, initialGx, gxOwns, gxStep ) where
import Clash.Prelude hiding (Word)
import Nds.WholeCore.Card (CardBus(..), CardReply(..))

type Word = BitVector 32
data GxIn = GxIn { gxSpace :: Bool, gxLiveStatus :: Word, gxResultValid :: Bool, gxResult :: Word }
  deriving (Generic,NFDataX)
data GxOut = GxOut { gxBusReply :: CardReply, gxPost :: Bool, gxQuery :: Bool, gxQueryAddress :: Word, gxIrq :: Bool }
  deriving (Generic,NFDataX)
data Phase = Idle | Query Word (BitVector 3) | Reply Word Bool deriving (Generic,NFDataX)
data GxState = GxState Phase (BitVector 2) (BitVector 15) deriving (Generic,NFDataX)
initialGx :: GxState
initialGx = GxState Idle 0 0

gxOwns :: Word -> Bool
gxOwns a = (a >= 0x04000060 && a < 0x04000064) || (a >= 0x04000320 && a < 0x040003c0)
        || (a >= 0x04000400 && a < 0x040005cc) || (a >= 0x04000600 && a < 0x040006a4)

gxStep :: GxState -> (CardBus,GxIn) -> (GxState,GxOut)
gxStep (GxState p mode disp) (b,i) = (GxState next mode' disp',GxOut reply post query a irq)
 where
  a = busReqAddr b; w = busReqWidth b; d = busReqData b
  shift a' = 8 * fromIntegral (unpack (slice d1 d0 a') :: Unsigned 2)
  extract :: Word -> BitVector 3 -> Word -> Word
  extract addr width v = (v `shiftR` shift addr) .&. case width of 1 -> 0xff; 2 -> 0xffff; _ -> maxBound
  alignedD = d `shiftL` shift a
  ready = case p of Idle -> gxSpace i; _ -> False
  accepted = ready && busReqValid b && gxOwns a
  stat addr = addr >= 0x04000600 && addr < 0x04000604
  dc = a == 0x04000060 && w /= 1
  geometry = a >= 0x04000400 && a < 0x040005cc
  render = a >= 0x04000320 && a < 0x040003c0
  supportedWrite = dc || render || (geometry && w == 4) || stat a || (a == 0x04000610 && w /= 1)
  matrix = a >= 0x04000640 && a <= 0x040006a0 && w == 4
  post = accepted && busReqWrite b && supportedWrite
  query = accepted && not (busReqWrite b) && (matrix || a == 0x04000600)
  localStatus = (resize mode `shiftL` 30) .|. gxLiveStatus i
  irq = (mode == 1 && testBit localStatus 25) || (mode == 2 && testBit localStatus 26)
  mode' = if post && stat a && (a + resize w) == 0x04000604 then slice d31 d30 alignedD else mode
  disp' = if post && dc then resize (d .&. 0x4fff) else disp
  reply = case p of Reply v e -> CardReply False True v e; _ -> CardReply ready False 0 False
  next = case p of
    Idle | query -> Query a w
         | accepted && busReqWrite b -> Reply 0 (not supportedWrite)
         | accepted && dc -> Reply (resize disp) False
         | accepted && stat a -> Reply (extract a w localStatus) False
         | accepted -> Reply 0 True
    Query addr width | gxResultValid i -> Reply (if stat addr then extract addr width (localStatus .|. (gxResult i .&. 3)) else gxResult i) False
    Reply _ _ | busReplyReady b -> Idle
    _ -> p
