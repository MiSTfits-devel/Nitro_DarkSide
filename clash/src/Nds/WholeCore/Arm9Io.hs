-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}

-- | ARM9 local I/O router behind the Clash ARM9 slice's blocking bus link.
--
-- The slice offers one request at a time on its gpuReq*/gpuReply* ready/valid
-- ports. This router serves two device groups locally and passes every
-- other request through unchanged to an external GPU link:
--
--   * TM0CNT..TM3CNT 0x04000100..0x0400010F: 'Nds.WholeCore.Timers', not
--     reimplemented here. Lanes and the lane-positioned data go straight to
--     its word port.
--   * ARM9 IME 0x04000208, IE 0x04000210, IF 0x04000214, with melonDS
--     ARM9IORead/Write8/16/32 width semantics: IME at 0x208 for any width
--     (bit 0); IE for word, or a half at 0x210/0x212; IF word/half writes
--     are write-one-to-clear. Byte IE/IF writes are ignored and byte IE/IF
--     reads return 0, as in melonDS. Other offsets in the span read 0 and
--     ignore writes.
--
-- IF sources: the timers' registered overflow pulses (bit 3 + n) and
-- external set/clear masks (GPU VBlank/HBlank/VCount/GX FIFO). Per cycle
-- IF' = ((IF & ~extClear) | extSet | timerPulses) & ~cpuW1C: a CPU clear in
-- the same cycle wins, which matches melonDS's run-events-before-I/O order.
--
-- 'irqLine' is the ARM9 interrupt request level IME && (IE & IF) /= 0;
-- 'Nds.WholeCore.Arm9Soc' drives the slice's IRQ input with it.
--
-- Timing: a local request is accepted when no local reply is pending. It
-- observes register/timer state at the start of the accept cycle (Timers'
-- rdata is pre-write, pre-tick). Its reply is registered, so it is presented
-- from the next cycle until the CPU takes it.
module Nds.WholeCore.Arm9Io
  ( IoState, IoIn(..), IoOut(..)
  , initialIo, ioStep, ioTimers, ioLocal
  ) where

import Prelude ()
import Clash.Prelude hiding (Word)
import Nds.WholeCore.Timers (TimersState, TimersIn(..), TimersOut(..), initialTimers, timersStep)

type Word = BitVector 32

data IoIn = IoIn
  { -- CPU side (from the slice's gpuReq* outputs)
    cpuReqValid    :: Bool
  , cpuReqWrite    :: Bool
  , cpuReqAddr     :: Word
  , cpuReqWidth    :: BitVector 3
  , cpuReqLanes    :: BitVector 4
  , cpuReqData     :: Word          -- ^ right-aligned payload, as the slice sends it
  , cpuReplyReady  :: Bool
    -- GPU side (external link)
  , extReqReady    :: Bool
  , extReplyValid  :: Bool
  , extReplyData   :: Word
  , extReplyFault  :: Bool
    -- Timer clock and external IF sources
  , timerTick      :: Bool          -- ^ one 33.514 MHz timer clock
  , extIrqSet      :: Word
  , extIrqClear    :: Word
  } deriving (Generic, NFDataX)

data IoOut = IoOut
  { cpuReqReady    :: Bool
  , cpuReplyValid  :: Bool
  , cpuReplyData   :: Word
  , cpuReplyFault  :: Bool
  , extReqValid    :: Bool          -- ^ address/width/lanes/data are the CPU's
  , extReplyReady  :: Bool
  , irqLine        :: Bool
  , ifAck          :: Word          -- ^ IF bits a CPU write cleared this cycle
  , regIE          :: Word
  , regIF          :: Word
  , regIME         :: Bool
  } deriving (Eq, Show, Generic, NFDataX)

data IoState = IoState
  { timersSt :: TimersState
  , ie       :: Word
  , iflags   :: Word
  , ime      :: Bool
  , reply    :: Maybe Word
  } deriving (Generic, NFDataX)

initialIo :: IoState
initialIo = IoState initialTimers 0 0 False Nothing

-- | Timer state, for witnesses.
ioTimers :: IoState -> TimersState
ioTimers = timersSt

inTimers, inIrq :: Word -> Bool
inTimers a = a .&. 0xfffffff0 == 0x04000100
inIrq a = a >= 0x04000208 && a < 0x04000218

-- | Whether this router serves the address itself.
ioLocal :: Word -> Bool
ioLocal a = inTimers a || inIrq a

ioStep :: IoState -> IoIn -> (IoState, IoOut)
ioStep s i = (s', out)
 where
  addr = cpuReqAddr i
  width = cpuReqWidth i
  -- Not named "local": that is a SystemVerilog keyword in the generated HDL.
  served = cpuReqValid i && ioLocal addr
  accept = served && reply s == Nothing
  writing = accept && cpuReqWrite i
  shiftBits = unpack (resize (slice d1 d0 addr) ++# (0 :: BitVector 3)) :: Unsigned 5
  laneData = shiftL (cpuReqData i) (fromIntegral shiftBits)
  widthMask = case width of
    1 -> 0xff
    2 -> 0xffff
    _ -> 0xffffffff :: Word

  (timers', tOut) = timersStep (timersSt s) TimersIn
    { tick = timerTick i
    , reqValid = accept && inTimers addr
    , reqWrite = cpuReqWrite i
    , reqWord = fromIntegral (slice d3 d2 addr)
    , reqLanes = cpuReqLanes i
    , reqData = laneData }

  half x = if testBit addr 1 then shiftR x 16 else x .&. 0xffff
  irqRead
    | addr == 0x04000208 = zeroExtend (pack (ime s))
    | width == 1 = 0
    | addr .&. 0xfffffffc == 0x04000210 = if width == 4 then ie s else half (ie s)
    | addr .&. 0xfffffffc == 0x04000214 = if width == 4 then iflags s else half (iflags s)
    | otherwise = 0
  readValue
    | inTimers addr = shiftR (rdata tOut) (fromIntegral shiftBits) .&. widthMask
    | otherwise = irqRead

  -- Word or halfword value positioned in the 32-bit register.
  placed = if width == 4 then cpuReqData i else shiftL (cpuReqData i .&. 0xffff) (if testBit addr 1 then 16 else 0)
  regWrite base = writing && width /= 1 && addr .&. 0xfffffffc == base
  ime' = if writing && addr == 0x04000208 then testBit (cpuReqData i) 0 else ime s
  ie'
    | regWrite 0x04000210 = if width == 4 then placed
                            else (ie s .&. complement (shiftL 0xffff (if testBit addr 1 then 16 else 0))) .|. placed
    | otherwise = ie s
  cleared = if regWrite 0x04000214 then placed else 0
  timerBits = shiftL (zeroExtend (irq tOut)) 3 :: Word
  iflags' = ((iflags s .&. complement (extIrqClear i)) .|. extIrqSet i .|. timerBits) .&. complement cleared

  -- A pending local reply blocks new local accepts and masks the external reply.
  pending = reply s /= Nothing
  reply'
    | pending = if cpuReplyReady i then Nothing else reply s
    | accept = Just (if cpuReqWrite i then 0 else readValue)
    | otherwise = Nothing

  s' = IoState timers' ie' iflags' ime' reply'
  out = IoOut
    { cpuReqReady = if served then not pending else extReqReady i
    , cpuReplyValid = pending || extReplyValid i
    , cpuReplyData = maybe (extReplyData i) id (reply s)
    , cpuReplyFault = not pending && extReplyFault i
    , extReqValid = cpuReqValid i && not served
    , extReplyReady = not pending && cpuReplyReady i
    , irqLine = ime s && (ie s .&. iflags s) /= 0
    , ifAck = cleared
    , regIE = ie s
    , regIF = iflags s
    , regIME = ime s }
