-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}

-- | Composition of the Clash ARM9 slice with its local I/O router
-- ('Nds.WholeCore.Arm9Io': DS timers plus ARM9 IME/IE/IF) and the read-only
-- NTR game-card slot ('Nds.WholeCore.Card'). Requests the router does not
-- serve go on to the card when 'cardOwns' their address, otherwise out on
-- the external GPU link, which keeps the slice's ready/valid protocol. The
-- router's IRQ level (IME && IE & IF) drives the CPU's IRQ input; the CPU
-- takes the exception at its next instruction boundary when CPSR.I is
-- clear. The card's transfer-done pulse sets IF bit 19.
--
-- 'socStep' is the pure cycle function for hosts and witnesses: one call is
-- one clock, built from the same 'sliceStep', 'ioStep' and 'cardStep'
-- transitions. The slice's and the card's outputs are registered (Moore),
-- and so is the router's IRQ level, so wiring them together has no
-- combinational loop. 'arm9SocTopEntity' is the synthesizable top built from
-- the same parts.
--
-- Not included: FIQ, other exceptions, DMA, ARM7, IPC, backup SPI, KEY1 and
-- BIOS.
module Nds.WholeCore.Arm9Soc
  ( SocState, SocIn(..), SocOut(..), CardIn(..), CardOut(..), noCartridge
  , initialSoc, socStep, socBootAddr, socTimers, arm9Soc, arm9SocTopEntity
  ) where

import Prelude ()
import Clash.Prelude hiding (Word, slice)
import Nds.WholeCore.Arm9Io
import Nds.WholeCore.Arm9Slice
import Nds.WholeCore.Card
import Nds.WholeCore.Timers (TimersState)

type Word = BitVector 32

data SocState = SocState SliceState IoState CardState
  deriving (Generic, NFDataX)

data SocIn = SocIn
  { socBootWord       :: Word
  , socGpuReqReady    :: Bool
  , socGpuReplyValid  :: Bool
  , socGpuReplyData   :: Word
  , socGpuReplyFault  :: Bool
  , socTimerTick      :: Bool
  , socIrqSet         :: Word
  , socIrqClear       :: Word
  , socCardIn         :: CardIn
  } deriving (Generic, NFDataX)

-- | The CPU view, the router's view and the card's image-store port. The
-- external GPU request is valid when 'extReqValid' is set (card requests
-- never are); its address, width, lanes, data and direction are the CPU's
-- gpuReq* fields.
data SocOut = SocOut
  { socCpu  :: SliceOut
  , socIo   :: IoOut
  , socCard :: CardOut
  } deriving (Eq, Show, Generic, NFDataX)

initialSoc :: SocState
initialSoc = SocState initialSlice initialIo initialCard

socBootAddr :: SocState -> Word
socBootAddr (SocState c _ _) = sliceBootAddr c

socTimers :: SocState -> TimersState
socTimers (SocState _ io _) = ioTimers io

-- | Card requests are the router's external requests the card owns. The
-- router sees the card's registered ready/reply instead of the GPU's for
-- them; the card's IRQ pulse joins the external IF set mask as bit 19.
routerIn :: SliceOut -> SocIn -> CardReply -> CardOut -> IoIn
routerIn c i r o = IoIn
  { cpuReqValid = gpuReqValid c, cpuReqWrite = gpuReqWrite c, cpuReqAddr = gpuReqAddr c
  , cpuReqWidth = gpuReqWidth c, cpuReqLanes = gpuReqLanes c, cpuReqData = gpuReqData c
  , cpuReplyReady = gpuReplyReady c
  , extReqReady = if cardOwns (gpuReqAddr c) then cardReqReady r else socGpuReqReady i
  , extReplyValid = cardReplyValid r || socGpuReplyValid i
  , extReplyData = if cardReplyValid r then cardReplyData r else socGpuReplyData i
  , extReplyFault = if cardReplyValid r then cardReplyFault r else socGpuReplyFault i
  , timerTick = socTimerTick i
  , extIrqSet = socIrqSet i .|. (if cardIrq o then bit 19 else 0)
  , extIrqClear = socIrqClear i }

cardBus :: SliceOut -> IoOut -> CardBus
cardBus c o = CardBus
  { busReqValid = extReqValid o && cardOwns (gpuReqAddr c), busReqWrite = gpuReqWrite c
  , busReqAddr = gpuReqAddr c, busReqWidth = gpuReqWidth c, busReqData = gpuReqData c
  , busReplyReady = extReplyReady o }

-- | The router's outputs as the GPU link sees them: no card requests.
gpuView :: SliceOut -> CardReply -> IoOut -> IoOut
gpuView c r o = o
  { extReqValid = extReqValid o && not (cardOwns (gpuReqAddr c))
  , extReplyReady = extReplyReady o && not (cardReplyValid r) }

cpuIn :: Word -> IoOut -> SliceIn
cpuIn boot o = SliceIn
  { bootWord = boot, gpuReqReady = cpuReqReady o, gpuReplyValid = cpuReplyValid o
  , gpuReplyData = cpuReplyData o, gpuReplyFault = cpuReplyFault o, irqRequest = irqLine o }

socStep :: SocState -> SocIn -> (SocState, SocOut)
socStep (SocState c io k) i =
  (SocState c' io' k', SocOut cOut (gpuView cOut kReply ioOut) kOut)
 where
  (c', cOut) = sliceStep c (cpuIn (socBootWord i) ioOut)
  (io', ioOut) = ioStep io (routerIn cOut i kReply kOut)
  (k', (kReply, kOut)) = cardStep k (cardBus cOut ioOut, socCardIn i)

arm9Soc
  :: KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom SocIn -> Signal dom SocOut
arm9Soc clk rst en input = SocOut <$> cOut <*> (gpuView <$> cOut <*> kReply <*> ioOut) <*> kOut
 where
  cOut = withClockResetEnable clk rst en (slice (cpuIn <$> (socBootWord <$> input) <*> ioOut))
  ioOut = withClockResetEnable clk rst en
    (mealy ioStep initialIo (routerIn <$> cOut <*> input <*> kReply <*> kOut))
  (kReply, kOut) = unbundle (withClockResetEnable clk rst en
    (mealy cardStep initialCard (bundle (cardBus <$> cOut <*> ioOut, socCardIn <$> input))))

{-# ANN arm9SocTopEntity
  (Synthesize
    { t_name = "nds_arm9_soc"
    , t_inputs = [ PortName "CLK", PortName "RST", PortName "EN", PortName "BOOT_WORD"
                 , PortName "GPU_REQ_READY", PortName "GPU_REPLY_VALID"
                 , PortName "GPU_REPLY_DATA", PortName "GPU_REPLY_FAULT"
                 , PortName "TIMER_TICK", PortName "EXT_IRQ_SET", PortName "EXT_IRQ_CLEAR"
                 , PortName "CARD_INSERTED", PortName "CARD_DIRECT_BOOT", PortName "CARD_CHIP_ID"
                 , PortName "CARD_ROM_MASK", PortName "CARD_ROM_READY"
                 , PortName "CARD_ROM_REPLY_VALID", PortName "CARD_ROM_DATA" ]
    , t_output = PortProduct ""
        [ PortProduct "CPU" [ PortName "BOOT_ADDR", PortName "REQ_VALID", PortName "REQ_WRITE"
            , PortName "REQ_ADDR", PortName "REQ_WIDTH", PortName "REQ_LANES", PortName "REQ_DATA"
            , PortName "REPLY_READY", PortName "STORE_VALID", PortName "STORE_ADDR"
            , PortName "STORE_DATA", PortName "FAULT", PortName "FAULT_ADDR"
            , PortName "RETIRE_VALID", PortName "RETIRE_PC", PortName "RETIRE_OPCODE" ]
        , PortProduct "IO" [ PortName "CPU_REQ_READY", PortName "CPU_REPLY_VALID"
            , PortName "CPU_REPLY_DATA", PortName "CPU_REPLY_FAULT", PortName "GPU_REQ_VALID"
            , PortName "GPU_REPLY_READY", PortName "IRQ", PortName "IF_ACK"
            , PortName "IE", PortName "IF", PortName "IME" ]
        , PortProduct "CARD" [ PortName "ROM_REQ_VALID", PortName "ROM_ADDR"
            , PortName "IRQ", PortName "BUSY" ] ]
    }) #-}
arm9SocTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System Word -> Signal System Bool -> Signal System Bool
  -> Signal System Word -> Signal System Bool -> Signal System Bool
  -> Signal System Word -> Signal System Word
  -> Signal System Bool -> Signal System Bool -> Signal System Word -> Signal System Word
  -> Signal System Bool -> Signal System Bool -> Signal System Word
  -> Signal System SocOut
arm9SocTopEntity clk rst en boot ready replyValid replyData replyFault tk set clr
                 inserted direct chipId romMask romReady romValid romData =
  arm9Soc clk rst en (SocIn <$> boot <*> ready <*> replyValid <*> replyData <*> replyFault
                             <*> tk <*> set <*> clr <*> card)
 where
  card = CardIn <$> inserted <*> direct <*> chipId <*> romMask <*> romReady <*> romValid <*> romData
