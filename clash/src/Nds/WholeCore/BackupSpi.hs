-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}

-- | Byte-level cartridge backup SPI engine. AUXSPICNT, owner selection,
-- baud/busy timing and IRQ belong to the card controller. The backing port
-- is a single-outstanding byte transaction link, not an in-FPGA save image.
-- Both endpoints must be reset together and discard any pre-reset reply.
--
-- Profiles 1..7 implement the v1.0.1 512-byte EEPROM, 8/64/128-KiB
-- EEPROM/FRAM, and 256/512/1024-KiB flash protocols, including flash
-- page wrap, program AND, page/sector erase and optional IR prefix. Profile
-- zero has no chip and returns zero without a backing transaction. Invalid
-- profiles and NAND profiles 8+ return an explicit transfer fault; NAND
-- uses a separate card protocol and must not be mistaken for SPI flash.
-- Cache faults are returned to the card. A byte write acknowledgement means
-- cache commit, not that a later SD-card flush has completed.
module Nds.WholeCore.BackupSpi
  ( BackupState, BackupIn(..), BackupOut(..), initialBackup, backupStep
  , backupSpi, backupSpiTopEntity
  ) where

import Prelude ()
import Clash.Prelude
import qualified Clash.Explicit.Prelude as E

type Byte = BitVector 8
type Addr = BitVector 24

data BackupIn = BackupIn
  { xferValid :: Bool, xferByte :: Byte, xferHold :: Bool, xferSelected :: Bool
  , xferRespReady :: Bool
  , profileValid :: Bool, profileType :: BitVector 4, profileIr :: Bool
  , cacheReqReady :: Bool, cacheRespValid :: Bool, cacheRespData :: Byte, cacheRespFault :: Bool
  } deriving (Generic, NFDataX)

data BackupOut = BackupOut
  { xferReady :: Bool, xferRespValid :: Bool, xferRespByte :: Byte, xferRespFault :: Bool
  , cacheReqValid :: Bool, cacheReqWrite :: Bool, cacheReqAddr :: Addr
  , cacheReqData :: Byte, cacheRespReady :: Bool
  } deriving (Eq, Show, Generic, NFDataX)

data Phase = Idle | ReadReq | ReadWait | WriteReq | WriteWait | EraseReq | EraseWait | Response
  deriving (Eq, Generic, NFDataX)

data BackupState = BackupState
  { phase :: Phase, pos :: Unsigned 3, cmd :: Byte, irCmd :: Byte, address :: Addr
  , status :: Byte, held :: Bool, dropCS :: Bool
  , reply :: Byte, replyFault :: Bool, reqAddr :: Addr, reqData :: Byte
  , program :: Bool, clearWel :: Bool, remaining :: Unsigned 17, kind :: BitVector 4
  } deriving (Generic, NFDataX)

initialBackup :: BackupState
initialBackup = BackupState Idle 0 0 0 0 0 False False 0 False 0 0 False False 0 0

-- The v1.0.1 save bridge allocates the following exact physical sizes.
maskAddress :: BitVector 4 -> Addr -> Addr
maskAddress k a = a .&. case k of
  1 -> 0x0001ff; 2 -> 0x001fff; 3 -> 0x00ffff; 4 -> 0x01ffff
  5 -> 0x03ffff; 6 -> 0x07ffff; 7 -> 0x0fffff; _ -> 0

addrBytes :: BitVector 4 -> Unsigned 3
addrBytes k | k == 1 = 1
            | k == 2 || k == 3 = 2
            | otherwise = 3

isFlash :: BitVector 4 -> Bool
isFlash k = k >= 5 && k <= 7

-- Slot deselection resets framing; the controller clears WEL on a terminating
-- byte of a write, or after a completed erase.
release :: BackupState -> BackupState
release s = s { pos = 0, dropCS = False, held = False }

finish :: BackupState -> Byte -> Bool -> BackupState
finish s b bad = (if not (held s) || dropCS s then release ended else ended)
  { phase = Response, reply = b, replyFault = bad }
 where
  ended = if not (held s) && clearWel s then s { status = clearBit (status s) 1 } else s

backupStep :: BackupState -> BackupIn -> (BackupState, BackupOut)
backupStep original i = (next, out)
 where
  -- Loss of selection aborts a held command, but an accepted byte/cache
  -- operation completes before its reply is exposed. No pre-reset reply may
  -- be delivered by the adapter after a coordinated reset.
  s | not (xferSelected i) && phase original == Idle = release original
    | not (xferSelected i) = original { dropCS = True }
    | otherwise = original
  out = BackupOut
    { xferReady = phase original == Idle && xferSelected i
    , xferRespValid = phase original == Response
    , xferRespByte = reply original, xferRespFault = replyFault original
    , cacheReqValid = phase original == ReadReq || phase original == WriteReq || phase original == EraseReq
    , cacheReqWrite = phase original == WriteReq || phase original == EraseReq
    , cacheReqAddr = reqAddr original
    , cacheReqData = if phase original == EraseReq then 0xff else reqData original
    , cacheRespReady = phase original == ReadWait || phase original == WriteWait || phase original == EraseWait
    }
  next = case phase s of
    Idle | xferValid i && xferSelected i -> receive s i
         | otherwise -> s
    ReadReq | cacheReqReady i -> s { phase = ReadWait }
            | otherwise -> s
    ReadWait | cacheRespValid i && cacheRespFault i -> finish s 0 True
      | cacheRespValid i ->
      if program s then s { phase = WriteReq, reqData = reqData s .&. cacheRespData i }
      else finish s (cacheRespData i) False
      | otherwise -> s
    WriteReq | cacheReqReady i -> s { phase = WriteWait }
             | otherwise -> s
    WriteWait | cacheRespValid i -> finish s 0 (cacheRespFault i)
              | otherwise -> s
    EraseReq | cacheReqReady i -> s { phase = EraseWait }
             | otherwise -> s
    EraseWait | cacheRespValid i && cacheRespFault i -> finish s 0 True
      | cacheRespValid i ->
      if remaining s == 1
      then finish (s { remaining = 0, status = clearBit (status s) 1 }) 0 False
      else s { phase = EraseReq, remaining = remaining s - 1
             , reqAddr = maskAddress (kind s) (reqAddr s + 1) }
      | otherwise -> s
    Response | xferRespReady i -> (if dropCS s then release s else s) { phase = Idle }
             | otherwise -> s

receive :: BackupState -> BackupIn -> BackupState
receive s i
  | not (profileValid i) || profileType i > 7 = finish start 0 True
  | profileType i == 0 = finish start 0 False
  | profileIr i && pos s == 0 = finish (start { irCmd = b }) 0 False
  | profileIr i && irCmd s /= 0 = finish start (if irCmd s == 8 then 0xaa else 0) False
  | effective == 0 = case b of
      0x04 -> finish (start { status = clearBit (status s) 1 }) 0 False
      0x06 -> finish (start { status = setBit (status s) 1 }) 0 False
      _ -> finish (start { cmd = b, address = 0 }) 0xff False
  | otherwise = command start
 where
  b = xferByte i
  k = profileType i
  effective = if profileIr i then pos s - 1 else pos s
  start = s { pos = if pos s == maxBound then maxBound else pos s + 1
            , held = xferHold i, dropCS = False, kind = k
            , clearWel = effective /= 0 && (not (profileIr i) || (pos s /= 0 && irCmd s == 0)) && wr }
  n = addrBytes k
  flash = isFlash k
  wr = cmd s == 0x02 || cmd s == 0x0a
  rd = cmd s == 0x03 || cmd s == 0x0b
  assembling = effective <= n
  shifted = maskAddress k ((address s `shiftL` 8) .|. zeroExtend b)
  tinyAddr = zeroExtend b .|. if cmd s == 0x0a || cmd s == 0x0b then 0x100 else 0
  a = if k == 1 then tinyAddr else shifted
  -- Flash writes wrap within the 256-byte page; EEPROM reads/writes are linear.
  advanced = if flash && wr then (address s .&. 0xffff00) .|. ((address s + 1) .&. 0xff)
             else maskAddress k (address s + 1)
  command t
    | cmd s == 0x01 = finish (if effective == 1 && not flash
                              then t { status = (status s .&. 1) .|. (b .&. 0x0c) } else t) 0 False
    | cmd s == 0x05 = finish t (status s .|. if k == 1 then 0xf0 else 0) False
    | wr && assembling = finish (t { address = a }) 0 False
    | wr && not (k == 1 || flash || cmd s == 0x02) = finish t 0 False
    | wr && not (testBit (status s) 1) = finish (t { address = advanced }) 0 False
    | wr = t { phase = if flash && cmd s == 0x02 then ReadReq else WriteReq
             , reqAddr = maskAddress k (address s), reqData = b
             , program = flash && cmd s == 0x02, address = advanced }
    | rd && assembling = finish (t { address = a }) 0 False
    | rd && flash && cmd s == 0x0b && effective == n + 1 = finish t 0 False
    | rd = t { phase = ReadReq, reqAddr = maskAddress k (address s), program = False
             , address = maskAddress k (address s + 1) }
    | flash && (cmd s == 0xd8 || cmd s == 0xdb) && assembling =
        if effective == 3 && testBit (status s) 1
        then t { phase = EraseReq, address = a
               , reqAddr = maskAddress k (a .&. if cmd s == 0xd8 then 0xff0000 else 0xffff00)
               , remaining = if cmd s == 0xd8 then 65536 else 256 }
        else finish (t { address = a }) 0 False
    | otherwise = finish t 0xff False

backupSpi :: HiddenClockResetEnable dom => Signal dom BackupIn -> Signal dom BackupOut
backupSpi = backupCore hasClock hasReset hasEnable

backupCore :: KnownDomain dom => Clock dom -> Reset dom -> Enable dom
           -> Signal dom BackupIn -> Signal dom BackupOut
backupCore clk rst en input = qualify <$> active <*> E.mealy clk rst en backupStep initialBackup input
 where
  active = (&&) <$> fromEnable en <*> (not <$> unsafeToActiveHigh rst)
  qualify True o = o
  qualify False o = o { xferReady = False, xferRespValid = False
                      , cacheReqValid = False, cacheRespReady = False }

{-# ANN backupSpiTopEntity
  (Synthesize { t_name = "nds_backup_spi"
    , t_inputs = [ PortName "CLK", PortName "RST", PortName "EN"
                 , PortName "XFER_VALID", PortName "XFER_BYTE", PortName "XFER_HOLD"
                 , PortName "SELECTED", PortName "XFER_REPLY_READY", PortName "PROFILE_VALID"
                 , PortName "PROFILE_TYPE", PortName "PROFILE_IR", PortName "CACHE_REQ_READY"
                 , PortName "CACHE_REPLY_VALID", PortName "CACHE_REPLY_DATA", PortName "CACHE_REPLY_FAULT" ]
    , t_output = PortProduct "" [ PortName "XFER_READY", PortName "XFER_REPLY_VALID"
        , PortName "XFER_REPLY_DATA", PortName "XFER_REPLY_FAULT", PortName "CACHE_REQ_VALID"
        , PortName "CACHE_REQ_WRITE", PortName "CACHE_REQ_ADDR", PortName "CACHE_REQ_DATA"
        , PortName "CACHE_REPLY_READY" ] }) #-}
backupSpiTopEntity :: Clock System -> Reset System -> Enable System
  -> Signal System Bool -> Signal System Byte -> Signal System Bool -> Signal System Bool
  -> Signal System Bool -> Signal System Bool -> Signal System (BitVector 4) -> Signal System Bool
  -> Signal System Bool -> Signal System Bool -> Signal System Byte -> Signal System Bool -> Signal System BackupOut
backupSpiTopEntity clk rst en valid byte hold selected responseReady pv pt ir cr rv rd rf =
  backupCore clk rst en
    (BackupIn <$> valid <*> byte <*> hold <*> selected <*> responseReady <*> pv <*> pt <*> ir <*> cr <*> rv <*> rd <*> rf)
