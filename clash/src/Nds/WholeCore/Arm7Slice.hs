-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds #-}

-- | The DS ARM7 build of the CPU slice ('Nds.WholeCore.Arm9Slice' with
-- 'arm7Arch': ARMv4T, exception vectors and the 4 KiB boot ROM window at
-- 0x00000000, the ARM7 link spans). Same ports, local RAM and microarchitecture
-- as @nds_arm9_slice@.
module Nds.WholeCore.Arm7Slice
  ( initialSlice7, sliceStep7, arm7SliceTopEntity
  ) where

import Clash.Prelude hiding (Word)
import Nds.WholeCore.Arm9Slice

type Word = BitVector 32

initialSlice7 :: SliceState
initialSlice7 = initialCore arm7Arch

sliceStep7 :: SliceState -> SliceIn -> (SliceState, SliceOut)
sliceStep7 = coreStep arm7Arch

{-# ANN arm7SliceTopEntity
  (Synthesize
    { t_name = "nds_arm7_slice"
    , t_inputs = [ PortName "CLK", PortName "RST", PortName "EN", PortName "BOOT_WORD"
                 , PortName "GPU_REQ_READY", PortName "GPU_REPLY_VALID"
                 , PortName "GPU_REPLY_DATA", PortName "GPU_REPLY_FAULT", PortName "IRQ" ]
    , t_output = PortProduct "" [ PortName "BOOT_ADDR", PortName "GPU_REQ_VALID"
        , PortName "GPU_REQ_WRITE", PortName "GPU_REQ_ADDR", PortName "GPU_REQ_WIDTH"
        , PortName "GPU_REQ_LANES", PortName "GPU_REQ_DATA", PortName "GPU_REPLY_READY"
        , PortName "STORE_VALID", PortName "STORE_ADDR", PortName "STORE_DATA"
        , PortName "FAULT", PortName "FAULT_ADDR", PortName "RETIRE_VALID"
        , PortName "RETIRE_PC", PortName "RETIRE_OPCODE" ]
    }) #-}
arm7SliceTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System Word -> Signal System Bool -> Signal System Bool
  -> Signal System Word -> Signal System Bool -> Signal System Bool -> Signal System SliceOut
arm7SliceTopEntity clk rst en boot reqReady replyValid replyData replyFault irq =
  coreSlice arm7Arch clk rst en (SliceIn <$> boot <*> reqReady <*> replyValid <*> replyData <*> replyFault <*> irq)
