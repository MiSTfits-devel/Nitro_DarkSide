-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, NoImplicitPrelude #-}
-- Physical native-BIOS board cone. Both BIOS words come from synchronous
-- upload RAMs. No direct-boot register seed or synthetic executable image.
module Nds.WholeCore.BiosTileSoc (biosTileSocTopEntity) where
import Clash.Explicit.Prelude hiding (Word,(++))
import Prelude ((++))
import qualified Nds.Memory.Fabric as F
import qualified Nds.WholeCore.DualSoc as D
import qualified Nds.WholeCore.Card as C
import qualified Nds.WholeCore.BiosIoPorts as I
import Nds.WholeCore.Arm9Io (IoOut(..))
import Nds.WholeCore.Arm9Slice (SliceOut(..))
import Nds.WholeCore.Arm9Soc (SocOut(..))
import Nds.WholeCore.NativeTileIo
import Nds.WholeCore.TileSoc
import Nds.WholeCore.TileFabric (fabricTile)
import Nds.WholeCore.TileMemoryBus

type Word=BitVector 32
type Oct=BitVector 8
data BoardIn=BoardIn {bios9,bios7 :: Word,ramDone :: Bool,ramData :: BitVector 64,captureReady :: Bool} deriving (Generic,NFDataX)
data Record=Record Bool Word (BitVector 3) Word deriving (Generic,NFDataX)
data Publish=Publish Record Record Bool (Unsigned 9) Bool Bool Bool Word deriving (Generic,NFDataX)
data Phys=Phys Bool Bool (Unsigned 26) (BitVector 4) Word deriving (Generic,NFDataX)
data Debug=Debug Bool Word Word Bool Word Word (BitVector 3) (BitVector 3) (BitVector 16) Bool deriving (Generic,NFDataX)
data BoardOut=BoardOut Word Word (BitVector 28) Phys Publish Debug deriving (Generic,NFDataX)
{-# ANN biosTileSocTopEntity (Synthesize {t_name="nds_bios_peripherals",
 t_inputs=[PortName "CLK",PortName "RST",PortName "DOUT",PortName "IORX",PortProduct "" (mapNames ["BOOT9_WORD","BOOT7_WORD","SD_DONE","SD_RDATA","CAPTURE_READY"])],
 t_output=PortProduct "" [PortName "DIN",PortName "IO7",PortName "LINE",PortName "SNOOP",PortName "IOTX",PortProduct "" [PortName "BOOT9_ADDR",PortName "BOOT7_ADDR",PortName "VIDEO",PortProduct "" (mapNames ["SD_REQ","SD_WRITE","SD_ADDR","SD_LANES","SD_DATA"]),PortProduct "" ([PortProduct "" (mapNames ["WRITE9","ADDR9","WIDTH9","DATA9"]),PortProduct "" (mapNames ["WRITE7","ADDR7","WIDTH7","DATA7"])] ++ mapNames ["HBLANK","SCANLINE","FRAME_END","VBLANK","QUERY9","QUERY_ADDR9"]),PortProduct "" (mapNames ["RETIRE9","PC9","INSN9","RETIRE7","PC7","INSN7","FAULT9","FAULT7","GPU_FAULT","LINE_MISS"])]]}) #-}
biosTileSocTopEntity :: Clock System -> Reset System -> Signal System (D.DualOut,Bool) -> Signal System I.IoRx -> Signal System BoardIn -> Signal System (D.DualIn,D.FirmwareIo7,BitVector 64,Maybe Word,I.IoTx,BoardOut)
biosTileSocTopEntity clk rst core io pins=bundle (din,seven,F.cpuLine <$> fab,snoop,I.IoTx <$> b9 <*> b7 <*> phase,observed)
 where
  run=not <$> unsafeToActiveHigh rst
  phase=D.ce7 . D.arb <$> dual
  ce=(\r t ready -> r && t && ready) <$> run <*> phase <*> (captureReady <$> pins)
  (dual,arm7)=unbundle core
  observed=BoardOut <$> (bootAddr . D.cpu9 <$> dual) <*> (bootAddr . D.cpu7 <$> dual) <*> video <*> phys <*> publisher <*> dbg
  din=D.DualIn <$> (bios9 <$> pins) <*> (bios7 <$> pins) <*> (C.cardReqReady <$> r9) <*> (C.cardReplyValid <$> r9) <*> (C.cardReplyData <$> r9) <*> (C.cardReplyFault <$> r9) <*> irq9 <*> pure C.noCartridge <*> ((&&) <$> run <*> (mainReady <$> bus)) <*> (mainValid <$> bus) <*> (mainData <$> bus)
  seven=D.FirmwareIo7 <$> (C.cardReqReady <$> r7) <*> (C.cardReplyValid <$> r7) <*> (C.cardReplyData <$> r7) <*> (C.cardReplyFault <$> r7) <*> irq7
  b9=(\d->cpuBus (D.cpu9 d) (D.io9 d)) <$> dual
  b7=(\d->cpuBus (D.cpu7 d) (D.io7 d)) <$> dual
  cpu d routed=let i=D.io9 d in SocOut (D.cpu9 d) (i {extReqValid=extReqValid i && not routed && not (owns (gpuReqAddr (D.cpu9 d)))}) (D.card d)
  (regs,gpu,vr,takeV)=fabricTile clk rst (pure True) ce (cpu <$> dual <*> (I.owns9 <$> io)) (mutation <$> bus) (invalidation <$> bus) fab
  bus=memoryBus clk rst dual arm7 ce ((\g p->goMemHold g || not (captureReady p)) <$> gpu <*> pins) fab
  fab=F.memoryFabric clk rst (F.FabricIn <$> (fabricReq <$> bus) <*> (fabricTake <$> bus) <*> vr <*> takeV <*> (ramDone <$> pins) <*> (ramData <$> pins))
  snoop=(\f b -> case fabricReq b of Just q | F.cpuReady f && F.cpuWrite q && slice d31 d24 (F.cpuAddr q)==2 -> Just (F.cpuAddr q); _ -> Nothing) <$> fab <*> bus
  phys=(\f->Phys (F.sdReq f) (F.sdWrite f) (F.sdHalfAddr f) (F.sdLanes f) (F.sdData f)) <$> fab
  r7=I.rep7 <$> io
  irq7=I.int7 <$> io
  gpuR l on=C.CardReply (on && loReqReady l) (on && loReplyValid l) (loReplyData l) (loReplyFault l)
  r9=combineReply <$> (I.owns9 <$> io) <*> (I.rep9 <$> io) <*> (combineReply <$> (owns . C.busReqAddr <$> b9) <*> (gpuR <$> (gpuLink <$> bus) <*> ce) <*> (gpuR <$> regs <*> ce))
  irq9=(\n l e->n .|. if e then loIrqSet l else 0) <$> (I.int9 <$> io) <*> regs <*> ce
  video=(\g e->let v=goVideo g in pack (e && vCe v) ++# pack (vDe v) ++# pack (vHs v) ++# pack (vVs v) ++# vRgb v) <$> gpu <*> ce
  record c yes=Record yes (gpuReqAddr c) (gpuReqWidth c) (gpuReqData c)
  publication d b g e a z=Publish w9 (Record from7 addr7 width7 data7) (e && goH g==1584) (goVc g) (e && goH g==0 && goVc g==192) (goVc g>=192) (I.query z) (I.queryAddr z)
    where c9=D.cpu9 d;m=D.memReq d
          -- The registered tile/VRAM transaction precedes delivery of the
          -- ordered CPU reply. The same CPU cannot issue another GX store
          -- before this publication. Never publish a rejected GPU operation.
          txn=case memTxn b of Just t->Just t; Nothing->goTxn g
          w9=case txn of
            Just t | e && txWrite t && not (txFault t)->Record True (txAddr t) (txWidth t) (txValue t)
            _ -> record c9 (I.post z)
          from7=a && D.memReqValid m && mainReady b && D.memReqWrite m && slice d31 d24 (D.memReqAddr m)==6
          lanes=D.memReqLanes m
          offs=case lanes of 2->1; 4->2; 8->3; 12->2; _->0 :: BitVector 2
          addr7=slice d31 d2 (D.memReqAddr m) ++# offs
          width7=case lanes of 15->4; 3->2; 12->2; _->1
          data7=shiftR (D.memReqData m) (8*fromEnum (unpack offs :: Unsigned 2))
  publisher=publication <$> dual <*> bus <*> gpu <*> ce <*> arm7 <*> io
  dbg=(\d g e-> let a=D.cpu9 d;b=D.cpu7 d in Debug (retireValid a) (retirePc a) (retireOpcode a) (retireValid b) (retirePc b) (retireOpcode b) (fault a) (fault b) (goFault g) (e && goLineMiss g)) <$> dual <*> gpu <*> ce
{-# NOINLINE biosTileSocTopEntity #-}
