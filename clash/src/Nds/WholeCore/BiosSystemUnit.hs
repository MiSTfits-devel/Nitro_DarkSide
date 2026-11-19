-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, NoImplicitPrelude #-}
module Nds.WholeCore.BiosSystemUnit (biosSystemTopEntity) where
import Clash.Explicit.Prelude hiding (Word)
import qualified Nds.WholeCore.SystemSpi as S
import qualified Nds.WholeCore.GxLink as X
import qualified Nds.WholeCore.Card as C
import qualified Nds.WholeCore.CardNative as K
import qualified Nds.WholeCore.Rtc as R
import qualified Nds.WholeCore.BiosCartUnit as KBus
import qualified Nds.WholeCore.BiosIoPorts as I
import Nds.WholeCore.NativeTileIo (rtcLink,selected,combineReply,rejectBus,mapNames)
type Word=BitVector 32
type Oct=BitVector 8
data Pins=Pins {keys :: BitVector 12,pen :: Bool,tx,ty :: Oct,cx,cy :: BitVector 40,lid :: Bool,mic :: BitVector 12
  ,fwDone :: Bool,fwWord :: Word,fwBusy :: Bool,rtcSeed :: BitVector 56,rtcToggle :: Bool
  ,inserted :: Bool,chipId,imageMask :: Word,romReady,romValid :: Bool,romData :: BitVector 64
  ,saveProfile :: Bool,saveType :: BitVector 4,saveIr,saveReady,saveValid :: Bool,saveByte :: Oct,saveFault :: Bool
  ,captureReady :: Bool,gxLive :: Word,gxValid :: Bool,gxResult :: Word} deriving (Generic,NFDataX)
data Observed=Observed S.FirmwarePort Bool (BitVector 56) Bool Bool Word KBus.Save deriving (Generic,NFDataX)
{-# ANN biosSystemTopEntity (Synthesize {t_name="nds_bios_system",
 t_inputs=[PortName "CLK",PortName "RST",PortName "IOTX",PortName "CART_OUT",PortProduct "" (mapNames ["KEYS","PEN","TOUCH_X","TOUCH_Y","CAL_X","CAL_Y","LID","MIC","FW_DONE","FW_RDATA","FW_BUSY","RTC_SEED","RTC_TOGGLE","CART_INSERTED","CART_ID","CART_MASK","ROM_READY","ROM_VALID","ROM_DATA","SAVE_PROFILE","SAVE_TYPE","SAVE_IR","SAVE_READY","SAVE_VALID","SAVE_BYTE","SAVE_FAULT","CAPTURE_READY","GX_LIVE","GX_VALID","GX_RESULT"])],
 t_output=PortProduct "" [PortName "IORX",PortName "CART_IN",PortProduct "" [PortProduct "" (mapNames ["FW_ADDR","FW_READ","FW_WRITE","FW_LANE","FW_BYTE","FW_RELEASE"]),PortName "POWER_OFF",PortName "RTC_DATE",PortName "RTC_WRITTEN",PortName "ROM_REQ",PortName "ROM_ADDR",PortProduct "" (mapNames ["SAVE_REQ","SAVE_WRITE","SAVE_ADDR","SAVE_DATA","SAVE_TAKE"])]]}) #-}
biosSystemTopEntity :: Clock System -> Reset System -> Signal System I.IoTx -> Signal System KBus.CartResult -> Signal System Pins -> Signal System (I.IoRx,KBus.CartPins,Observed)
biosSystemTopEntity clk rst io cart pins=bundle (result,cartPins,observed)
 where
  (b9,b7,tick)=unbundle ((\(I.IoTx a b t)->(a,b,t)) <$> io)
  axis v=S.CalAxis (slice d39 d28 v) (slice d27 d16 v) (slice d15 d8 v) (slice d7 d0 v)
  sys=(\p->S.SystemPins (keys p) (pen p) (tx p) (ty p) (axis (cx p)) (axis (cy p)) (lid p) (mic p) (fwDone p) (fwWord p) (fwBusy p)) <$> pins
  (s',o)=unbundle (S.systemSpiStep <$> register clk rst enableGen S.initialSpi s' <*> tick <*> sys <*> b9 <*> b7)
  (sp9,sp7,f,power,si9,si7)=unbundle o
  calendarCe=register clk noReset enableGen False (not <$> calendarCe)
  (rtcReply,date)=rtcLink clk rst calendarCe (rtcSeed <$> pins) (rtcToggle <$> pins) (sel isRtc <$> b7)
  gx=mealy clk rst enableGen X.gxStep X.initialGx (bundle (b9,(\p->X.GxIn (captureReady p) (gxLive p) (gxValid p) (gxResult p)) <$> pins))
  cartPins=(\a b p->KBus.CartPins a b (inserted p) (chipId p) (imageMask p) (romReady p) (romValid p) (romData p) (saveProfile p) (saveType p) (saveIr p) (saveReady p) (saveValid p) (saveByte p) (saveFault p)) <$> b9 <*> b7 <*> pins
  sel fn b=selected (fn (C.busReqAddr b)) b
  s9=S.sysOwns False;s7=S.sysOwns True;k=K.nativeCardOwns;x=X.gxOwns
  isRtc a=a>=0x04000138 && a<0x0400013a
  bad7=rejectBus clk rst (sel (\a->not (s7 a || k a || isRtc a)) <$> b7)
  choose b fn a other=combineReply <$> (fn . C.busReqAddr <$> b) <*> a <*> other
  r9=choose b9 s9 sp9 (choose b9 k (KBus.r9 <$> cart) (X.gxBusReply <$> gx))
  r7=choose b7 s7 sp7 (choose b7 k (KBus.r7 <$> cart) (choose b7 isRtc rtcReply bad7))
  int9=(\p q z->p .|. (if q then bit 19 else 0) .|. if z then bit 21 else 0) <$> si9 <*> (KBus.irq9 <$> cart) <*> (X.gxIrq <$> gx)
  int7=(\p q->p .|. if q then bit 19 else 0) <$> si7 <*> (KBus.irq7 <$> cart)
  result=I.IoRx <$> ((\a->s9 a || k a || x a) . C.busReqAddr <$> b9) <*> r9 <*> r7 <*> int9 <*> int7 <*> (X.gxPost <$> gx) <*> (X.gxQuery <$> gx) <*> (X.gxQueryAddress <$> gx)
  observed=Observed <$> f <*> power <*> (R.rtcDateTime <$> date) <*> (R.rtcDateWritten <$> date) <*> (KBus.req <$> cart) <*> (KBus.addr <$> cart) <*> (KBus.saveBus <$> cart)
