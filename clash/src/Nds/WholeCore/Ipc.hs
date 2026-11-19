-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}

-- | DS inter-processor communication between the ARM9 and the ARM7: IPCSYNC
-- (0x04000180), IPCFIFOCNT (0x04000184), IPCFIFOSEND (0x04000188) and
-- IPCFIFORECV (0x04100000), one register set per CPU, with two 16-word
-- FIFOs (each CPU's send FIFO is the other's receive FIFO).
--
-- Behaviour follows melonDS (NDS::ARM9IOWrite16/ARM7IOWrite16 at 0x180 and
-- 0x184, ARM9IOWrite32/ARM7IOWrite32 at 0x188, ARM9IORead16/ARM7IORead16 at
-- 0x184, ARM9IORead32/ARM7IORead32 at 0x4100000) and GBATEK ("DS Inter
-- Process Communication"):
--
--   * IPCSYNC: bits 0-3 read the other CPU's output, bits 8-11 are this
--     CPU's output, bit 14 enables the sync IRQ, writing bit 13 requests IF
--     bit 16 on the other CPU if its bit 14 is set.
--   * IPCFIFOCNT: 0/1 send FIFO empty/full, 2 send-empty IRQ enable, 3
--     (write) clears the send FIFO, 8/9 receive FIFO empty/full, 10
--     receive-not-empty IRQ enable, 14 error (write 1 to acknowledge), 15
--     FIFO enable.
--   * A send with bit 15 set pushes, or sets the error flag when the FIFO is
--     full; with bit 15 clear it is ignored without error. A receive with
--     bit 15 set pops, or sets the error flag when the FIFO is empty; with
--     bit 15 clear it returns the oldest word without popping.
--   * IF bit 17 is raised when (CNT.2 and send FIFO empty) goes 0 to 1, IF
--     bit 18 when (CNT.10 and receive FIFO not empty) goes 0 to 1 (GBATEK's
--     edge rule, also the product nds_ipc's).
--
-- Where the two references differ this module follows GBATEK:
--
--   * An empty receive with bit 15 set returns the most recently received
--     word, or zero if none was received since reset or since the other
--     CPU cleared that FIFO (melonDS returns FIFO::Peek(), the slot at the
--     read pointer).
--   * Clearing a non-empty send FIFO while CNT.2 is already set raises IF
--     bit 17 (the edge rule); melonDS raises it only when the same write
--     also sets CNT.2.
--
-- Access widths: IPCSYNC and IPCFIFOCNT take halfword (at +0 or +2, where
-- +2 reads 0 and ignores writes) or word accesses (the low half acts);
-- IPCFIFOSEND and IPCFIFORECV take word accesses (a SEND read returns 0, a
-- RECV write is ignored). Any byte access, or a halfword access to SEND or
-- RECV, gets an error reply (CPU fault 4) instead of a guessed behaviour.
--
-- When both CPUs access IPC in the same cycle the ARM9's access takes effect
-- first. The IRQ edges are evaluated once per cycle, after both. Each port
-- is the same one-request ready/valid protocol as 'Nds.WholeCore.Card': a
-- request is accepted when no reply is pending, and its reply is registered
-- and held until taken. The IRQ outputs are registered one-cycle IF-set
-- masks, one per CPU.
module Nds.WholeCore.Ipc
  ( IpcState, IpcOut(..), initialIpc, ipcStep, ipcOwns
  ) where

import Prelude ()
import Clash.Prelude hiding (Word)
import Nds.WholeCore.Card (CardBus(..), CardReply(..))

type Word = BitVector 32

-- | The IPC spans of the I/O map (both CPUs).
ipcOwns :: Word -> Bool
ipcOwns a = (a >= 0x04000180 && a < 0x0400018c) || (a >= 0x04100000 && a < 0x04100004)

data Fifo = Fifo
  { entries :: Vec 16 Word
  , rdPtr   :: Index 16
  , wrPtr   :: Index 16
  , count   :: Index 17
  } deriving (Generic, NFDataX)

-- | One CPU's registers. 'lastRecv' is the word an empty receive returns.
data Side = Side
  { syncOut  :: BitVector 4
  , syncIen  :: Bool
  , sendIrq  :: Bool
  , recvIrq  :: Bool
  , errFlag  :: Bool
  , enable   :: Bool
  , lastRecv :: Word
  , cond17   :: Bool
  , cond18   :: Bool
  , pending  :: Maybe (Word, Bool)   -- ^ registered reply: data, error
  } deriving (Generic, NFDataX)

-- | 'send9' is the ARM9's send FIFO (the ARM7's receive FIFO).
data IpcState = IpcState
  { side9  :: Side
  , side7  :: Side
  , send9  :: Fifo
  , send7  :: Fifo
  , irqQ9  :: Word
  , irqQ7  :: Word
  } deriving (Generic, NFDataX)

data IpcOut = IpcOut
  { ipcReply9 :: CardReply
  , ipcReply7 :: CardReply
  , ipcIrq9   :: Word   -- ^ IF bits to set on the ARM9 this cycle
  , ipcIrq7   :: Word
  } deriving (Generic, NFDataX)

emptyFifo :: Fifo
emptyFifo = Fifo (repeat 0) 0 0 0

initialSide :: Side
initialSide = Side 0 False False False False False 0 False False Nothing

initialIpc :: IpcState
initialIpc = IpcState initialSide initialSide emptyFifo emptyFifo 0 0

irqSync, irqSendEmpty, irqRecv :: Word
irqSync = bit 16
irqSendEmpty = bit 17
irqRecv = bit 18

-- | Effects of one CPU's accepted access on (own side, other side, own send
-- FIFO, other's send FIFO), plus the reply and an IPCSYNC IRQ request for
-- the other CPU.
access :: CardBus -> (Side, Side, Fifo, Fifo) -> ((Side, Side, Fifo, Fifo), (Word, Bool), Bool)
access b (me, other, mine, theirs) = case (addr, width) of
  _ | width == 1 -> unchanged True
  (0x04000180, w) | w /= 1 -> syncAccess
  (0x04000182, 2) -> unchanged False
  (0x04000184, w) | w /= 1 -> cntAccess
  (0x04000186, 2) -> unchanged False
  (0x04000188, 4)
    | not (busReqWrite b) -> unchanged False
    | not (enable me) -> unchanged False
    | count mine == 16 -> ((me { errFlag = True }, other, mine, theirs), (0, False), False)
    | otherwise -> ((me, other, push mine, theirs), (0, False), False)
  (0x04100000, 4)
    | busReqWrite b -> unchanged False
    | not (enable me) -> ((me, other, mine, theirs), (if count theirs == 0 then lastRecv me else oldest, False), False)
    | count theirs == 0 -> ((me { errFlag = True }, other, mine, theirs), (lastRecv me, False), False)
    | otherwise -> ((me { lastRecv = oldest }, other, mine, pop theirs), (oldest, False), False)
  _ -> unchanged True
 where
  addr = busReqAddr b
  width = busReqWidth b
  d = busReqData b
  unchanged fault = ((me, other, mine, theirs), (0, fault), False)
  oldest = entries theirs !! rdPtr theirs
  push f = f { entries = replace (wrPtr f) d (entries f), wrPtr = satSucc SatWrap (wrPtr f), count = count f + 1 }
  pop f = f { rdPtr = satSucc SatWrap (rdPtr f), count = count f - 1 }
  syncAccess
    | busReqWrite b =
        ( (me { syncOut = slice d11 d8 d, syncIen = testBit d 14 }, other, mine, theirs)
        , (0, False), testBit d 13 && syncIen other )
    | otherwise =
        ( (me, other, mine, theirs)
        , (zeroExtend (syncOut other) .|. shiftL (zeroExtend (syncOut me)) 8 .|. (if syncIen me then bit 14 else 0), False)
        , False )
  cntAccess
    | busReqWrite b =
        let cleared = testBit d 3
            mine' = if cleared then emptyFifo { entries = entries mine } else mine
            other' = if cleared then other { lastRecv = 0 } else other
            me' = me { sendIrq = testBit d 2, recvIrq = testBit d 10, enable = testBit d 15
                     , errFlag = errFlag me && not (testBit d 14) }
        in ((me', other', mine', theirs), (0, False), False)
    | otherwise =
        ( (me, other, mine, theirs)
        , ( flag (count mine == 0) 0 .|. flag (count mine == 16) 1 .|. flag (sendIrq me) 2
            .|. flag (count theirs == 0) 8 .|. flag (count theirs == 16) 9 .|. flag (recvIrq me) 10
            .|. flag (errFlag me) 14 .|. flag (enable me) 15
          , False )
        , False )
  flag c n = if c then bit n else 0

-- | One port's handshake: accept when no reply is pending; a pending reply
-- is dropped once taken.
portReady :: Side -> Bool
portReady s = pending s == Nothing

ipcStep :: IpcState -> (CardBus, CardBus) -> (IpcState, IpcOut)
ipcStep s (b9, b7) = (s', out)
 where
  take9 = busReqValid b9 && portReady (side9 s)
  take7 = busReqValid b7 && portReady (side7 s)
  -- Replies already presented are released when the CPU takes them.
  release b sd = if busReplyReady b then sd { pending = Nothing } else sd
  s9a = release b9 (side9 s)
  s7a = release b7 (side7 s)
  -- ARM9 first, then ARM7.
  ((s9b, s7b, f9b, f7b), r9, syncTo7) =
    if take9 then access b9 (s9a, s7a, send9 s, send7 s) else ((s9a, s7a, send9 s, send7 s), (0, False), False)
  ((s7c, s9c, f7c, f9c), r7, syncTo9) =
    if take7 then access b7 (s7b, s9b, f7b, f9b) else ((s7b, s9b, f7b, f9b), (0, False), False)
  -- Edge conditions after both accesses.
  c17_9 = sendIrq s9c && count f9c == 0
  c18_9 = recvIrq s9c && count f7c /= 0
  c17_7 = sendIrq s7c && count f7c == 0
  c18_7 = recvIrq s7c && count f9c /= 0
  edge new old m = if new && not old then m else 0
  irq9 = edge c17_9 (cond17 s9c) irqSendEmpty .|. edge c18_9 (cond18 s9c) irqRecv
    .|. (if syncTo9 then irqSync else 0)
  irq7 = edge c17_7 (cond17 s7c) irqSendEmpty .|. edge c18_7 (cond18 s7c) irqRecv
    .|. (if syncTo7 then irqSync else 0)
  s9' = s9c { cond17 = c17_9, cond18 = c18_9, pending = if take9 then Just r9 else pending s9c }
  s7' = s7c { cond17 = c17_7, cond18 = c18_7, pending = if take7 then Just r7 else pending s7c }
  s' = IpcState s9' s7' f9c f7c irq9 irq7
  reply sd = CardReply
    { cardReqReady = portReady sd
    , cardReplyValid = pending sd /= Nothing
    , cardReplyData = maybe 0 fst (pending sd)
    , cardReplyFault = maybe False snd (pending sd) }
  out = IpcOut (reply (side9 s)) (reply (side7 s)) (irqQ9 s) (irqQ7 s)
