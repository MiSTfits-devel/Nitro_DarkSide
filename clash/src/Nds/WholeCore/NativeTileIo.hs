-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, NoImplicitPrelude #-}
-- Guest-side MMIO endpoint helpers; each CPU has one outstanding request.
-- Select address for request readiness, but select a *held response* by
-- validity rather than decoding the CPU's address after acceptance.
module Nds.WholeCore.NativeTileIo (cpuBus, selected, combineReply, rtcLink, rejectBus, mapNames) where
import Clash.Explicit.Prelude hiding (Word)
import qualified Prelude as P
import qualified Nds.WholeCore.Card as C
import Nds.WholeCore.Arm9Io (IoOut(..))
import Nds.WholeCore.Arm9Slice (SliceOut(..))
import Nds.WholeCore.Rtc (RtcOut(..),rtc)

mapNames :: [P.String] -> [PortName]
mapNames=P.map PortName

type Word = BitVector 32
cpuBus :: SliceOut -> IoOut -> C.CardBus
cpuBus c i = C.CardBus (extReqValid i) (gpuReqWrite c) (gpuReqAddr c) (gpuReqWidth c) (gpuReqData c) (extReplyReady i)
selected :: Bool -> C.CardBus -> C.CardBus
selected yes b = b {C.busReqValid=yes && C.busReqValid b}
combineReply :: Bool -> C.CardReply -> C.CardReply -> C.CardReply
combineReply a x y = C.CardReply (C.cardReqReady (if a then x else y)) (C.cardReplyValid x || C.cardReplyValid y) (C.cardReplyData r) (C.cardReplyFault r)
 where r=if C.cardReplyValid x then x else y

-- No guest-visible success or stale data for unimplemented system registers.
rejectBus :: Clock System -> Reset System -> Signal System C.CardBus -> Signal System C.CardReply
rejectBus clk rst bus = (\p -> C.CardReply (not p) p 0 True) <$> pending
 where pending=register clk rst enableGen False ((\p b -> if p then not (C.busReplyReady b) else C.busReqValid b) <$> pending <*> bus)

rtcLink :: Clock System -> Reset System -> Signal System Bool -> Signal System (BitVector 56) -> Signal System Bool
        -> Signal System C.CardBus -> (Signal System C.CardReply,Signal System RtcOut)
rtcLink clk rst calendarCe seed toggle bus=(reply, dev)
 where
  dev=rtc clk (unsafeToActiveHigh rst) calendarCe seed toggle (wrote <$> op) (lanes <$> op) (aligned <$> op)
  accept b=(\old -> C.busReqValid b && case old of Nothing -> True; _ -> False)
  full=register clk rst enableGen Nothing ((\b r old -> if accept b old then Just (value b r,bad b) else if C.busReplyReady b then Nothing else old) <$> bus <*> dev <*> full)
  reply=(\r -> C.CardReply (maybe True (const False) r) (maybe False (const True) r) (maybe 0 fst r) (maybe False snd r)) <$> full
  bad b=not (C.busReqWidth b==1 || (C.busReqWidth b==2 && not (testBit (C.busReqAddr b) 0)) || (C.busReqWidth b==4 && slice d1 d0 (C.busReqAddr b)==0))
  value b r | C.busReqWrite b=0
            | C.busReqWidth b/=1=resize (rtcPins r)
            | testBit (C.busReqAddr b) 0=resize (slice d15 d8 (rtcPins r))
            | otherwise=resize (slice d7 d0 (rtcPins r))
  op=(\b old -> (accept b old && C.busReqWrite b && not (bad b), if C.busReqWidth b/=1 then 3 else if testBit (C.busReqAddr b) 0 then 2 else 1,
                   if testBit (C.busReqAddr b) 0 then shiftL (resize (C.busReqData b)) 8 else resize (C.busReqData b))) <$> bus <*> full
  wrote (x,_,_)=x; lanes (_,x,_)=x; aligned (_,_,x)=x
