-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, NoImplicitPrelude #-}
module SystemSpiTop where
import Clash.Explicit.Prelude
import Nds.WholeCore.Card
import Nds.WholeCore.SystemSpi

type Bus = (Bool,Bool,BitVector 32,BitVector 3,BitVector 32,Bool)
type Reply = (Bool,Bool,BitVector 32,Bool)
type Fw = (BitVector 16,Bool,Bool,BitVector 2,BitVector 8,Bool)
bus :: Bus -> CardBus
bus (v,w,a,n,d,r)=CardBus v w a n d r
reply :: CardReply -> Reply
reply (CardReply r v d f)=(r,v,d,f)
axis :: BitVector 40 -> CalAxis
axis a=CalAxis (slice d39 d28 a) (slice d27 d16 a) (slice d15 d8 a) (slice d7 d0 a)
{-# ANN topEntity (Synthesize {t_name="nds_system_spi",t_inputs=[PortName "CLK",PortName "RST",PortName "TICK",PortName "KEYS",PortName "PEN",PortName "X",PortName "Y",PortName "CALX",PortName "CALY",PortName "LID",PortName "MIC",PortName "DONE",PortName "FDATA",PortName "WIP",PortProduct "B9" [PortName "V",PortName "W",PortName "A",PortName "N",PortName "D",PortName "R"],PortProduct "B7" [PortName "V",PortName "W",PortName "A",PortName "N",PortName "D",PortName "R"]],t_output=PortProduct "" [PortProduct "R9" [PortName "R",PortName "V",PortName "D",PortName "F"],PortProduct "R7" [PortName "R",PortName "V",PortName "D",PortName "F"],PortProduct "FW" [PortName "A",PortName "RD",PortName "WR",PortName "L",PortName "D",PortName "REL"],PortName "OFF",PortName "IRQ9",PortName "IRQ7"]}) #-}
topEntity :: Clock System -> Reset System -> Signal System Bool -> Signal System (BitVector 12) -> Signal System Bool -> Signal System (BitVector 8) -> Signal System (BitVector 8) -> Signal System (BitVector 40) -> Signal System (BitVector 40) -> Signal System Bool -> Signal System (BitVector 12) -> Signal System Bool -> Signal System (BitVector 32) -> Signal System Bool -> Signal System Bus -> Signal System Bus -> Signal System (Reply,Reply,Fw,Bool,BitVector 32,BitVector 32)
topEntity clk rst tick keys pen x y cx cy lid mic done w busy b9 b7 = expose <$> outputs
 where
  pins=SystemPins <$> keys <*> pen <*> x <*> y <*> (axis <$> cx) <*> (axis <$> cy) <*> lid <*> mic <*> done <*> w <*> busy
  s=register clk rst enableGen initialSpi s'
  (s',outputs)=unbundle (systemSpiStep <$> s <*> tick <*> pins <*> (bus <$> b9) <*> (bus <$> b7))
  expose (r9,r7,FirmwarePort a rd wr l d release,p,i,j)=(reply r9,reply r7,(a,rd,wr,l,d,release),p,i,j)
