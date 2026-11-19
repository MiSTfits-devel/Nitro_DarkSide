-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, NoImplicitPrelude #-}
module MemoryFabricTop where

import Clash.Explicit.Prelude
import Data.Maybe (fromMaybe, isJust)
import Nds.Memory.Fabric

data Pins = Pins Bool Bool W32 (BitVector 64) Bool Bool (BitVector 64) Bool Bool (Unsigned 26) (BitVector 4) W32
  deriving (Generic, NFDataX)
type W32 = BitVector 32
{-# ANN topEntity (Synthesize { t_name = "nds_memory_gate", t_inputs =
  [PortName "CLK",PortName "RST",PortName "CV",PortName "ARM7",PortName "WR",PortName "ADDR",PortName "BE",PortName "WD",PortName "CT",
   PortName "DV",PortName "SPACE",PortName "OFF",PortName "DT",PortName "DONE",PortName "Q"],
  t_output = PortProduct "" [PortName "CR", PortName "CA", PortName "CQ", PortName "CLINE", PortName "DR", PortName "DA", PortName "DQOUT", PortName "SREQ", PortName "SWRITE", PortName "SADDR", PortName "SBE", PortName "SDATA"] }) #-}
-- Explicit flat ports for a pin-level, independently driven Verilator gate.
topEntity :: Clock System -> Reset System -> Signal System Bool -> Signal System Bool -> Signal System Bool -> Signal System W32 -> Signal System (BitVector 4) -> Signal System W32 -> Signal System Bool -> Signal System Bool -> Signal System (Unsigned 4) -> Signal System (Unsigned 20) -> Signal System Bool -> Signal System Bool -> Signal System (BitVector 64) -> Signal System Pins
topEntity clk rst cv a7 wr addr be dat ct dv sp off dt done q = observe <$> memoryFabric clk rst input
 where
  cp = mux cv (Just <$> (CpuReq <$> a7 <*> wr <*> addr <*> be <*> dat)) (pure Nothing)
  dp = mux dv (Just <$> (VideoReq <$> (decode <$> sp) <*> off)) (pure Nothing)
  decode n = case n of
    0 -> MainBG; 1 -> SubBG; 2 -> MainOBJ; 3 -> SubOBJ; 4 -> LCDC; 5 -> Texture; 6 -> TexPalette
    7 -> MainBGExt; 8 -> SubBGExt; 9 -> MainOBJExt; 10 -> SubOBJExt; _ -> Arm7VRAM
  input = FabricIn <$> cp <*> ct <*> dp <*> dt <*> done <*> q
  observe o = Pins (cpuReady o) (isJust (cpuReply o)) (fromMaybe 0 (cpuReply o)) (cpuLine o)
    (displayReady o) (isJust (displayReply o)) (fromMaybe 0 (displayReply o)) (sdReq o) (sdWrite o)
    (sdHalfAddr o) (sdLanes o) (sdData o)
