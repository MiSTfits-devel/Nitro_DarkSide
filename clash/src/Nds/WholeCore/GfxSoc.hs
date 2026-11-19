-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}

-- | CPU + VRAM display prototype: the unchanged "Nds.WholeCore.Arm9Slice"
-- drives "Nds.Gpu2D.VramDisplay" over its GPU link; the display is scanned
-- out as 640x480 VGA. The boot ROM stays outside, as for the slice: supply
-- the aligned little-endian word combinationally from @BOOT_ADDR & ~3@.
-- The probe outputs exist for simulation evidence and drive nothing else.
module Nds.WholeCore.GfxSoc (Probe(..), gfxSoc, gfxSocTopEntity) where

import Prelude ()
import Clash.Prelude hiding (Word, slice)
import Nds.Gpu2D.VramDisplay
import Nds.WholeCore.Arm9Slice

type Word = BitVector 32

data Probe = Probe
  { reqFire    :: Bool
  , reqIsWrite :: Bool
  , reqAt      :: Word
  , reqBytes   :: BitVector 3
  , reqValue   :: Word
  , replyFire  :: Bool
  , replyValue :: Word
  , replyError :: Bool
  , cpuFault   :: BitVector 3
  , cpuFaultAt :: Word
  , storeFire  :: Bool
  , storeAt    :: Word
  , storeValue :: Word
  , retireFire :: Bool
  , retireOp   :: Word
  } deriving (Generic, NFDataX)

gfxSoc
  :: Clock System -> Reset System -> Signal System Word
  -> (Signal System Word, Signal System (BitVector 28), Signal System Probe)
gfxSoc clk rst bootIn = (bootAddr <$> cpu, video, probe <$> cpu <*> gpu)
 where
  cpu = withClockResetEnable clk rst enableGen (slice (cpuIn <$> bootIn <*> gpu))
  (gpu, video) = vramDisplay clk rst (linkIn <$> cpu)
  -- No interrupt controller in this prototype: the IRQ level is low.
  cpuIn word g = SliceIn
    { bootWord = word, gpuReqReady = reqReady g, gpuReplyValid = replyValid g
    , gpuReplyData = replyWord g, gpuReplyFault = replyErr g, irqRequest = False }
  linkIn c = LinkIn
    { reqValid = gpuReqValid c, reqWrite = gpuReqWrite c, reqAddr = gpuReqAddr c
    , reqWidth = gpuReqWidth c, reqData = gpuReqData c, replyReady = gpuReplyReady c }
  probe c g = Probe
    { reqFire = gpuReqValid c && reqReady g, reqIsWrite = gpuReqWrite c
    , reqAt = gpuReqAddr c, reqBytes = gpuReqWidth c, reqValue = gpuReqData c
    , replyFire = replyValid g && gpuReplyReady c, replyValue = replyWord g
    , replyError = replyErr g, cpuFault = fault c, cpuFaultAt = faultAddr c
    , storeFire = storeValid c, storeAt = storeAddr c, storeValue = storeData c
    , retireFire = retireValid c, retireOp = retireOpcode c }

{-# ANN gfxSocTopEntity
  (Synthesize
    { t_name = "nds_gfx_soc"
    , t_inputs = [PortName "CLK", PortName "RST", PortName "BOOT_WORD"]
    , t_output = PortProduct ""
        [ PortName "BOOT_ADDR", PortName "VIDEO"
        , PortProduct "" [ PortName "REQ_FIRE", PortName "REQ_WRITE", PortName "REQ_ADDR"
          , PortName "REQ_WIDTH", PortName "REQ_DATA", PortName "REPLY_FIRE"
          , PortName "REPLY_DATA", PortName "REPLY_FAULT", PortName "CPU_FAULT"
          , PortName "CPU_FAULT_ADDR", PortName "STORE_VALID", PortName "STORE_ADDR"
          , PortName "STORE_DATA", PortName "RETIRE_VALID", PortName "RETIRE_OPCODE" ] ]
    }) #-}
gfxSocTopEntity
  :: Clock System -> Reset System -> Signal System Word
  -> (Signal System Word, Signal System (BitVector 28), Signal System Probe)
gfxSocTopEntity = gfxSoc
