-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, NoImplicitPrelude #-}
-- ROM-free integration probe. Same native ARM9, GX bus owner and physical
-- LCD phase source as the board; no BIOS7, cartridge, SDRAM or display ACK.
module H3dGuest where
import Clash.Explicit.Prelude hiding (Word)
import qualified Prelude
import Nds.WholeCore.Arm9Slice
import Nds.WholeCore.Card
import Nds.WholeCore.Arm9Io
import Nds.WholeCore.Arm9Soc (SocOut(..))
import Nds.WholeCore.GxLink
import Nds.WholeCore.TileSoc

type Word = BitVector 32
type Obs = (Word,Bool,Word,BitVector 3,Word,Bool,Bool,Bool,Unsigned 9,Bool,Bool,BitVector 3,Bool,Word,Word)
{-# ANN topEntity (Synthesize {t_name="nds_h3d_guest",t_inputs=[PortName "CLK",PortName "RST",PortName "BOOT",PortName "SPACE",PortName "STATUS",PortName "RESULT_VALID",PortName "RESULT"],t_output=PortProduct "" (Prelude.map PortName ["BOOT_ADDR","WRITE9","ADDR9","WIDTH9","DATA9","QUERY9","TAKE9","HBLANK","LINE","FRAME_END","VBLANK","FAULT","STORE","STORE_ADDR","STORE_DATA"])}) #-}
topEntity :: Clock System -> Reset System -> Signal System Word -> Signal System Bool -> Signal System Word -> Signal System Bool -> Signal System Word -> Signal System Obs
topEntity clk rst boot space status valid res = observe <$> cpu <*> go <*> gpu <*> space <*> valid
 where
  en = toEnable space
  cpu = coreSlice (arm9Arch {nativeBios=True}) clk rst en input
  input = (\b c x l -> let r=gxBusReply x; use=gxOwns (gpuReqAddr c) in SliceIn b
                 (if use then cardReqReady r else loReqReady l) (cardReplyValid r || loReplyValid l)
                 (if cardReplyValid r then cardReplyData r else loReplyData l)
                 (cardReplyFault r || loReplyFault l) False) <$> boot <*> cpu <*> go <*> link
  bus c = CardBus (gpuReqValid c && gxOwns (gpuReqAddr c)) (gpuReqWrite c) (gpuReqAddr c) (gpuReqWidth c) (gpuReqData c) (gpuReplyReady c)
  go = mealy clk rst en gxStep initialGx (bundle (bus <$> cpu,GxIn <$> space <*> status <*> valid <*> res))
  display c = SocOut c (IoOut False False 0 False (gpuReqValid c && not (gxOwns (gpuReqAddr c))) (gpuReplyReady c) False 0 0 0 False) (CardOut False 0 False False)
  (link,gpu) = tileDisplay clk rst en (display <$> cpu)
  observe c x g advance result = (bootAddr c,advance && (posted || tw),if posted || qry then gpuReqAddr c else ta,
      if posted then gpuReqWidth c else w,if posted then gpuReqData c else val,advance && qry,advance && result,
      advance && goH g == fromIntegral hblankCycle,goVc g,advance && goVc g==192 && goH g==0,goVc g>=192 && goVc g<262,
      fault c,storeValid c,storeAddr c,storeData c)
   where
    posted=gxPost x; qry=gxQuery x
    (tw,ta,w,val)=case goTxn g of Just t -> (txWrite t && not (txFault t),txAddr t,txWidth t,txValue t); Nothing -> (False,0,0,0)
