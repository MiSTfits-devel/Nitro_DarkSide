-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, NoImplicitPrelude #-}
module Nds.WholeCore.TileMemoryBus (BusOut(..), memoryBus, owns) where
import Clash.Explicit.Prelude hiding (Word)
import Data.Maybe (fromMaybe, isJust)
import qualified Nds.Memory.Fabric as F
import qualified Nds.WholeCore.DualSoc as D
import Nds.WholeCore.Arm9Slice (SliceOut(..))
import Nds.WholeCore.Arm9Io (IoOut(..))
import Nds.WholeCore.TileSoc (LinkOut(..),Txn(..))
type Word = BitVector 32
-- The raw CPU9 link is right-aligned; the fabric always uses word lanes.
owns :: Word -> Bool
owns a = slice d31 d24 a==6 || (a>=0x04000240 && a<=0x04000249)
data Access = Access Bool Word (BitVector 3) Word deriving (Generic,NFDataX)
shiftOf :: Word -> Int
shiftOf a = 8*fromEnum (unpack (slice d1 d0 a) :: Unsigned 2)
lanesOf :: BitVector 3 -> BitVector 4
lanesOf w = case w of 1->1; 2->3; _->15
aligned :: Access -> F.CpuReq
aligned (Access wr a w v) = F.CpuReq False wr (a .&. 0xfffffffc) (lanesOf w `shiftL` (shiftOf a `div` 8)) (v `shiftL` shiftOf a)
result :: Access -> Word -> Word
result (Access wr a w _) v = if wr then 0 else (v `shiftR` shiftOf a) .&. mask
 where -- WRAMCNT lane 247 belongs to the shared CPU wrapper's overlay.
       mask = case w of 1->255; 2->65535; _->maxBound

data G = Free | Offer Access | Waiting Access | Received Access Word | Deliver Word deriving (Generic,NFDataX)
data B = Idle | Send Bool F.CpuReq | Wait Bool Bool deriving (Generic,NFDataX) -- GPU link?, mutating VRAM?
data S = S G B (Maybe Txn) deriving (Generic,NFDataX)
data BusOut = BusOut { fabricReq :: Maybe F.CpuReq, fabricTake :: Bool,
  mainReady, mainValid :: Bool, mainData :: Word, gpuLink :: LinkOut, memTxn :: Maybe Txn,
  mutation, invalidation :: Bool } deriving (Generic,NFDataX)
mutates :: F.CpuReq -> Bool
mutates q = F.cpuWrite q && slice d31 d24 (F.cpuAddr q)/=2
step :: S -> D.DualOut -> Bool -> Bool -> Bool -> F.FabricOut -> (S,BusOut)
step (S g b lastTx) d arm7 ce hold f = (S g' b' tx, BusOut req takeReply mainR mainV val link lastTx busy invalidate)
 where
  c = D.cpu9 d; io = D.io9 d; m = D.memReq d
  acc = Access (gpuReqWrite c) (gpuReqAddr c) (gpuReqWidth c) (gpuReqData c)
  mg = case g of Offer a -> Just (aligned a); _ -> Nothing
  mr = F.CpuReq arm7 (D.memReqWrite m) (D.memReqAddr m) (D.memReqLanes m) (D.memReqData m)
  grantG = case b of Idle -> isJust mg; _ -> False
  mainR = case b of Idle -> not grantG && not (D.memReqValid m && mutates mr && hold); _ -> False
  grantM = mainR && D.memReqValid m
  req = case b of Send _ q -> Just q; _ -> Nothing
  takeReply = case b of Wait _ _ -> True; _ -> False
  mainV = case b of Wait False _ -> isJust (F.cpuReply f); _ -> False
  val = fromMaybe 0 (F.cpuReply f)
  completeG = case b of Wait True _ -> isJust (F.cpuReply f); _ -> False
  b' = case b of
    Idle | Just q <- mg -> Send True q
         | grantM -> Send False mr
    Send gg q | F.cpuReady f -> Wait gg (mutates q)
    Wait _ _ | isJust (F.cpuReply f) -> Idle
    _ -> b
  ready = case g of Free -> not (gpuReqWrite c && hold); _ -> False
  reply = case g of Deliver x -> Just x; _ -> Nothing
  link = LinkOut ready (isJust reply) (fromMaybe 0 reply) False 0
  accepted = ce && ready && extReqValid io && owns (gpuReqAddr c)
  g' = case g of
    Free | accepted -> Offer acc
    Offer a | grantG -> Waiting a
    Waiting a | completeG -> Received a (result a val)
    Received _ v | ce -> Deliver v
    Deliver _ | ce && extReplyReady io -> Free
    _ -> g
  -- VRAMCNT and VRAM writes take effect logically at acceptance. A new
  -- HBlank job waits for any such write to be acknowledged by the fabric.
  busy = case (g,b) of
    (Offer (Access True _ _ _),_) -> True
    (Waiting (Access True _ _ _),_) -> True
    (_,Send _ q) -> mutates q
    (_,Wait _ mut) -> mut
    _ -> False
  invalidate = (accepted && gpuReqWrite c) || (grantM && mutates mr)
  tx | not ce = lastTx
     | accepted, Access True a w v <- acc = Just (Txn True a w v False)
     | Received (Access False a w _) v <- g = Just (Txn False a w v False)
     | otherwise = Nothing
memoryBus :: Clock System -> Reset System -> Signal System D.DualOut -> Signal System Bool -> Signal System Bool -> Signal System Bool
          -> Signal System F.FabricOut -> Signal System BusOut
memoryBus clk rst d a ce hold f = o
 where s = register clk rst enableGen (S Free Idle Nothing) s'
       (s',o) = unbundle (step <$> s <*> d <*> a <*> ce <*> hold <*> f)
{-# NOINLINE memoryBus #-}
