-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, FlexibleContexts #-}
{-# LANGUAGE NoImplicitPrelude, ScopedTypeVariables, TypeApplications, TypeOperators #-}
-- | Two ready/valid demand ports, in one continuously running clock domain.
-- Each accepted request gets one held reply, including writes. Arbitration
-- and decoding happen once, before any physical port is touched. A CPU or
-- DMA master presents aligned word data with little-endian byte enables.
-- Read replies contain the full aligned word (size extraction is upstream).
module Nds.Memory.Fabric
  ( module Nds.Memory.Map, CpuReq(..), FabricIn(..), FabricOut(..), memoryFabric ) where

import Clash.Explicit.Prelude
import Data.Maybe (isJust, fromMaybe)
import Nds.Memory.Map

type W32 = BitVector 32
type W64 = BitVector 64

data CpuReq = CpuReq { cpuArm7, cpuWrite :: Bool, cpuAddr :: W32,
                       cpuLanes :: BitVector 4, cpuData :: W32 }
  deriving (Generic, NFDataX, Eq, Show)
data FabricIn = FabricIn { cpuIn :: Maybe CpuReq, cpuTake :: Bool,
                           displayIn :: Maybe VideoReq, displayTake :: Bool,
                           sdDone :: Bool, sdReadData :: W64 }
  deriving (Generic, NFDataX)
data FabricOut = FabricOut { cpuReady, displayReady :: Bool,
    cpuReply :: Maybe W32, cpuLine :: W64, displayReply :: Maybe W64,
    sdReq, sdWrite :: Bool, sdHalfAddr :: Unsigned 26,
    sdLanes :: BitVector 4, sdData :: W32 }
  deriving (Generic, NFDataX)

data Phase = Free | Local | Issue | Await | Immediate
  deriving (Eq, Generic, NFDataX)
data State = State { phase :: Phase, controls :: Controls, lastCpu :: Bool,
    toCpu, highHalf, writing :: Bool, lanes :: BitVector 4, wdata :: W32,
    large :: BitVector 5, small :: BitVector 5, halfOff :: Unsigned 21,
    accum :: W64, heldCpu :: Maybe (Bool, W64), heldDisplay :: Maybe W64 }
  deriving (Generic, NFDataX)
initial :: State
initial = State Free (repeat 0) False False False False 0 0 0 0 0 0 Nothing Nothing

data Port = Port (Unsigned 13) (BitVector 5) (BitVector 4) (BitVector 4) W32
  deriving (Generic, NFDataX)

-- Bank order A..I; byte 247 is WRAMCNT, not H. Mask fields on write.
regChange :: CpuReq -> Controls -> Controls
regChange c = imap one
 where
  bytes = reverse (unpack (cpuData c) :: Vec 4 (BitVector 8))
  one i old = if cpuAddr c .&. 0xfffffffc == base && testBit (cpuLanes c) (fromEnum k)
                then (bytes !! k) .&. (controlMask !! i) else old
   where
    k = if i < 7 then fromIntegral i else fromIntegral i + 1 :: Unsigned 2
    base | i < 4 = 0x04000240 | i < 7 = 0x04000244 | otherwise = 0x04000248

regRead :: CpuReq -> Controls -> W32
regRead c v
  | cpuArm7 c = if a == 0x04000240 then resize (pack (owned 3) ++# pack (owned 2)) else 0
  | a == 0x04000240 = (v!!3) ++# (v!!2) ++# (v!!1) ++# (v!!0)
  | a == 0x04000244 = (0 :: BitVector 8) ++# (v!!6) ++# (v!!5) ++# (v!!4)
  | a == 0x04000248 = (0 :: BitVector 16) ++# (v!!8) ++# (v!!7)
  | otherwise = 0
 where
  a = cpuAddr c .&. 0xfffffffc
  owned k = v!!k .&. 0x87 == 0x82

-- Splash placement convention: A-D start at 0 with 128 KiB stride; the
-- independent 4 MiB main window starts at byte 0x800000. All bus addresses
-- hereafter are HALFWORD indices on rtl/sdram.sv channel 2.
physical :: BitVector 5 -> Unsigned 21 -> Unsigned 26
physical targets offs
  | testBit targets 4 = 0x400000 .|. resize offs
  | otherwise = unpack ((0 :: BitVector 8) ++# b ++# slice d15 d0 (pack offs))
 where b | testBit targets 0 = 0 | testBit targets 1 = 1 | testBit targets 2 = 2 | otherwise = 3 :: BitVector 2

step :: State -> FabricIn -> Vec 5 W64 -> (State, FabricOut, Port)
step s i q = (next, out, port)
 where
  p = phase s
  readLocal = fold (.|.) (imap (\k v -> if testBit (small s) (fromEnum k) then v else 0) q)
  -- Mask out read-during-write and unselected RAM outputs, which may be X.
  localData = if writing s then 0 else readLocal
  extData = if writing s then 0 else sdReadData i
  result | p == Local = localData | p == Await = accum s .|. extData | otherwise = accum s
  more = large s .&. (large s - 1)
  done = p == Immediate || (p == Local && large s == 0) || (p == Await && sdDone i && more == 0)
  answerCpu = if done && toCpu s then Just (highHalf s, result) else heldCpu s
  selected (upper, d) = if upper then slice d63 d32 d else slice d31 d0 d
  answerDisplay = if done && not (toCpu s) then Just result else heldDisplay s
  cHold = if cpuTake i then Nothing else answerCpu
  dHold = if displayTake i then Nothing else answerDisplay
  available = p == Free || done
  cEligible = isJust (cpuIn i) && not (isJust cHold)
  dEligible = isJust (displayIn i) && not (isJust dHold)
  cReady = available && not (isJust cHold) && (not dEligible || not (lastCpu s))
  dReady = available && not (isJust dHold) && (not cEligible || lastCpu s)
  cFire = cReady && isJust (cpuIn i)
  fire = cFire || (dReady && isJust (displayIn i))
  c = fromMaybe (CpuReq False False 0 0 0) (cpuIn i)
  a = cpuAddr c
  v = if cFire then cpuVideo (cpuArm7 c) a else fromMaybe (VideoReq LCDC 0) (displayIn i)
  wr = cFire && cpuWrite c
  main = cFire && slice d31 d24 a == 2
  -- ARM7 C/D is a CPU aperture, never a display client even if a caller
  -- supplies that internal decoder selector on the video port.
  vr = if cFire then slice d31 d24 a == 6 else videoSpace v /= Arm7VRAM
  reg = cFire && (a .&. 0xfffffffc == 0x04000240 || a .&. 0xfffffffc == 0x04000244 || a .&. 0xfffffffc == 0x04000248)
  enables = cpuLanes c
  byteOnly = enables .&. (enables - 1) == 0
  hits = if vr && not (wr && not (cpuArm7 c) && byteOnly) then bankHits (controls s) v else 0
  big = pack main ++# slice d3 d0 hits
  little = slice d8 d4 hits
  off = videoOffset v
  foldedOff = case videoSpace v of
    MainBGExt -> off .&. 0x7fff; SubBGExt -> off .&. 0x7fff
    MainOBJExt -> off .&. 0x1fff; SubOBJExt -> off .&. 0x1fff; _ -> off
  hi = cFire && not reg && testBit a 2
  wordHalf = if main then unpack (slice d21 d1 a) else resize (off `shiftR` 1)
  offset = wordHalf .&. (if wr then complement 1 else complement 3)
  address = physical (large s) (halfOff s)
  immediate = reg || (big == 0 && little == 0)
  fastData = if reg && not wr then resize (regRead c (controls s)) else 0
  newPhase | immediate = Immediate | little /= 0 = Local | otherwise = Issue
  after = s { heldCpu = cHold, heldDisplay = dHold }
  next | fire = after { phase = newPhase, lastCpu = cFire, toCpu = cFire, highHalf = hi, writing = wr,
            lanes = enables, wdata = cpuData c, large = big, small = little, halfOff = offset,
            accum = fastData,
            controls = if reg && wr && not (cpuArm7 c) then regChange c (controls s) else controls s }
       | done = after { phase = Free }
       | p == Local = after { phase = Issue, accum = localData }
       | p == Issue = after { phase = Await }
       | p == Await && sdDone i = after { phase = Issue, large = more, accum = result }
       | otherwise = after
  port = Port (resize (foldedOff `shiftR` 3)) (if fire && wr then little else 0)
              (if testBit a 2 then 0 else enables) (if testBit a 2 then enables else 0) (cpuData c)
  out = FabricOut cReady dReady (selected <$> answerCpu) (maybe 0 snd answerCpu) answerDisplay (p == Issue) (writing s) address
                  (if writing s then lanes s else 15) (wdata s)

-- Eight disjoint byte lanes per bank; each physical byte exists once. No
-- initialization file/reset sweep, replicated read port, or giant Vec RAM.
-- Distinct address widths are important to infer E/F/G/H/I at actual depths.
smallBank :: forall depth n dom. (KnownDomain dom, KnownNat depth, 1 <= depth, KnownNat n)
          => Clock dom -> Reset dom -> SNat depth -> SNat n -> Int -> Signal dom Port -> Signal dom W64
smallBank clk rst depth _ bank cmd = pack . reverse <$> bundle (map lane indicesI :: Vec 8 (Signal dom (BitVector 8)))
 where
  addr (Port a _ _ _ _) = resize a :: Unsigned n
  lane k = blockRamU clk rst enableGen NoClearOnReset depth (const (errorX "unwritten VRAM")) (addr <$> cmd) (wr <$> cmd)
   where
    wr x@(Port _ mask lo hi d)
      | testBit mask bank && testBit (hi ++# lo) (fromEnum k) = Just (addr x, (reverse (unpack d :: Vec 4 (BitVector 8))) !! (fromIntegral k :: Unsigned 2))
      | otherwise = Nothing

memoryFabric :: forall dom. KnownDomain dom => Clock dom -> Reset dom -> Signal dom FabricIn -> Signal dom FabricOut
memoryFabric clk rst inp = out
 where
  st = register clk rst enableGen initial st'
  (st', out, cmd) = unbundle (step <$> st <*> inp <*> q)
  b :: (KnownNat depth, 1 <= depth, KnownNat n) => SNat depth -> SNat n -> Int -> Signal dom W64
  b d n k = smallBank clk rst d n k cmd
  q = bundle (b (SNat @8192) (SNat @13) 0 :> b (SNat @2048) (SNat @11) 1 :>
              b (SNat @2048) (SNat @11) 2 :> b (SNat @4096) (SNat @12) 3 :> b (SNat @2048) (SNat @11) 4 :> Nil)
{-# NOINLINE memoryFabric #-}
