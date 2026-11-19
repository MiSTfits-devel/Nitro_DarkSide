-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, NoImplicitPrelude, ScopedTypeVariables, TypeApplications #-}
-- | CPU-side WRAM and its single ARM9-owned mapping register. Both CPU
-- instruction fetch and data reach exactly the same byte-lane RAMs.
module Nds.WholeCore.CpuWram (cpuWram, wramControl) where

import Clash.Explicit.Prelude

type W = BitVector 32
type Mode = BitVector 2

-- ARM9's I/O link is single-outstanding and right-justified. Companion
-- VRAMCNT bytes are always handled by the downstream device. Capture the
-- mapping on request acceptance, not while a stalled request is offered;
-- a simultaneous memory acceptance uses the old mapping on that edge.
wramControl :: KnownDomain dom => Clock dom -> Reset dom -> Enable dom
            -> Signal dom Bool -> Signal dom Bool -> Signal dom W
            -> Signal dom (BitVector 4) -> Signal dom W -> Signal dom W
            -> Signal dom (Mode, W)
wramControl clk rst en accepted wr addr lanes dat extData = bundle (mode, merged)
 where
  selected = (\a be -> slice d31 d2 a == 0x01000091 && testBit be 3) <$> addr <*> lanes
  -- At 244/246/247 the register is at bit 24/8/0 of the IO reply.
  offset = (\a -> complement (slice d1 d0 a) ++# (0 :: BitVector 3)) <$> addr
  mode = register clk rst en 0 (mux ((\h w s -> h && w && s) <$> accepted <*> wr <*> selected)
           ((\v n -> resize (shiftR v (fromIntegral n))) <$> dat <*> offset) mode)
  overlay = register clk rst en Nothing (mux accepted
    ((\w s n m -> if not w && s then Just (n,m) else Nothing) <$> wr <*> selected <*> offset <*> mode) overlay)
  merged = (\v -> maybe v (\(n,m) -> (v .&. complement (shiftL 0xff (fromIntegral n))) .|.
                       shiftL (zeroExtend m) (fromIntegral n))) <$> extData <*> overlay
{-# NOINLINE wramControl #-}

-- | Insert between the wide CPU arbiter and external memory. External ports
-- may have up to four ordered transactions outstanding. Do not serialize
-- ordinary external traffic: wait for its last reply only when crossing to
-- WRAM, so a local one-cycle reply can never overtake an external one.
-- Reset cancels pending handshakes (external memory shares that reset) but
-- does not clear WRAM. Four byte lanes give stores real byte write enables.
cpuWram :: forall dom. KnownDomain dom => Clock dom -> Reset dom -> Enable dom -> Signal dom Mode
         -> Signal dom Bool -> Signal dom Bool -> Signal dom Bool -- ARM7, valid, write
         -> Signal dom (BitVector 32) -> Signal dom (BitVector 4) -> Signal dom (BitVector 32)
         -> Signal dom Bool -> Signal dom Bool -> Signal dom (BitVector 32) -- external ready, valid, word
         -> Signal dom (Bool, Bool, BitVector 32, Bool) -- CPU ready, valid, word; external valid
cpuWram clk rst en mode arm7 valid wr addr lanes dat extReady extValid extWord =
  bundle (ready, (||) <$> localReply <*> extReply, mux localReply localWord externalWord, external)
 where
  region = ((== 3) . slice d31 d24) <$> addr
  isPrivate = (\r seven a m -> r && seven && (testBit a 23 || m == 0)) <$> region <*> arm7 <*> addr <*> mode
  isShared = (\r priv seven m -> r && not priv && (seven || m /= 3)) <$> region <*> isPrivate <*> arm7 <*> mode
  -- An unassigned ARM9 window (mode 3) ignores writes and reads zero,
  -- matching the melonDS memory oracle, not an electrical open-bus model.
  status = (\s a w -> s && a == 0x04000240 && not w) <$> arm7 <*> addr <*> wr
  active = (&&) <$> fromEnable en <*> (not <$> unsafeToActiveHigh rst)
  allowExt = (\st d -> not st || d) <$> status <*> drained
  ready = (&&) <$> active <*> mux region drained ((&&) <$> allowExt <*> extReady)
  accepted = (&&) <$> valid <*> ready
  external = (\v r e allow -> v && not r && e && allow) <$> valid <*> region <*> active <*> allowExt
  localTake = (&&) <$> accepted <*> region
  extTake = (&&) <$> external <*> extReady
  pending = register clk rst en (0 :: Unsigned 3) next
  extReply = (&&) <$> extValid <*> ((/= 0) <$> pending)
  next = (\n takeR giveR -> if takeR == giveR then n else if takeR then n+1 else n-1)
         <$> pending <*> extTake <*> extReply
  drained = (\n r -> n == 0 || (n == 1 && r)) <$> pending <*> extReply
  localReply = register clk rst en False localTake
  -- Status is accepted only after all older external responses drain, so
  -- its captured WRAMSTAT belongs to exactly the next external response.
  statusTake = (&&) <$> extTake <*> status
  statusMode = register clk rst en Nothing (mux statusTake (Just <$> mode) (mux extReply (pure Nothing) statusMode))
  externalWord = (\w -> maybe w (\m -> w .&. 0xffff00ff .|. shiftL (zeroExtend m) 8)) <$> extWord <*> statusMode
  readSel takeBank = register clk rst en False ((\t b w -> t && b && not w) <$> localTake <*> takeBank <*> wr)
  localWord = mux (readSel isPrivate) privateWord (mux (readSel isShared) sharedWord (pure 0))
  privateIx = (unpack . slice d15 d2 <$> addr) :: Signal dom (Unsigned 14)
  sharedIx = (\s m a -> unpack (pack (if m == 0 || m == 3 then testBit a 14 else if s then m == 2 else m == 1)
                                  ++# slice d13 d2 a) :: Unsigned 13) <$> arm7 <*> mode <*> addr
  bytes = reverse . unpack <$> dat :: Signal dom (Vec 4 (BitVector 8))
  writes :: forall ix. Signal dom Bool -> Signal dom ix -> Index 4 -> Signal dom (Maybe (ix, BitVector 8))
  writes bank ix k = (\t b w be a v -> if t && b && w && testBit be (fromEnum k) then Just (a,v !! k) else Nothing)
                     <$> localTake <*> bank <*> wr <*> lanes <*> ix <*> bytes
  word bankLane = pack . reverse <$> bundle (map bankLane indicesI :: Vec 4 (Signal dom (BitVector 8)))
  privateWord = word (\k -> blockRam1 clk rst en NoClearOnReset (SNat @16384) 0 privateIx (writes isPrivate privateIx k))
  sharedWord = word (\k -> blockRam1 clk rst en NoClearOnReset (SNat @8192) 0 sharedIx (writes isShared sharedIx k))
{-# NOINLINE cpuWram #-}
