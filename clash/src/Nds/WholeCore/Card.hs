-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}

-- | ARM9 NTR game-card slot, read-only ROM path: AUXSPICNT, ROMCTRL, the
-- 8-byte command register and the data-in port, with the cartridge image in
-- an external ready/valid word store. Semantics follow melonDS 1.x
-- (NDSCart.cpp Interface::WriteROMCnt/ReadROMData/WriteSPICnt and
-- NDSCart/CartCommon.cpp ROMCommandStart/ROMCommandReceive/ROMRead32):
--
--   * 0x040001A0 AUXSPICNT, byte/half: SPICnt = (old & (~mask | 0x0080)) |
--     (val & 0xE043); bit 15 enables the slot, 13 selects SPI (backup) mode,
--     14 enables the transfer-done IRQ. Bit 7 (SPI busy) reads 0: there is
--     no backup SPI here and AUXSPIDATA is not routed.
--   * 0x040001A4 ROMCTRL, any width: stored = (old & (~mask | 0x20000000)) |
--     (val & mask & 0x7F7F7FFF); bit 29 (cart reset release) only sets, bit
--     23 (word ready) and bit 31 (busy) are status, bit 15 is write-only.
--     Setting bit 31 starts a transfer of 0, 4 (size 7) or 0x100 << size
--     bytes.
--   * 0x040001A8..AF command bytes, write-only, byte 0 at 0x1A8.
--   * 0x04100010 data in, word reads: pops the next word of the transfer.
--
-- Commands: after a raw power-up the cart is held in reset until ROMCTRL
-- bit 29 is set, then answers 9F (FFFFFFFF), 00 (header: words at
-- (addr + 4k) & 0xFFF) and 90 (chip ID). With 'cardDirectBoot' it powers up
-- released in main data mode, as melonDS SetupDirectBoot leaves it, and
-- answers B7 (ROM read: addr & mask, below 0x8000 redirected to 0x8000 +
-- (addr & 0x1FF), the word address wrapping inside its 4 KiB page) and B8
-- (chip ID). KEY2 is transparent to software and is not modelled.
--
-- Fail closed (link reply error): a transfer start with the slot disabled,
-- in SPI mode, with ROMCTRL bit 30 (card writes) set, with the cart absent
-- or in reset, with an unaligned address or any other command (including
-- 3C/3D, the KEY1 entry that needs BIOS keys); any ROMCTRL write while a
-- transfer runs; command-register reads; data-port writes, non-word
-- accesses and reads with no word ready.
--
-- Data words come from the store or are synthesised (FF, chip ID) into a
-- two-word FIFO; ROMCTRL bit 23 is "FIFO not empty". The store sees one
-- request at a time (address held until ready) and its reply is always
-- accepted. The transfer ends the cycle after its last word is popped:
-- busy clears and, with AUXSPICNT bit 14, 'cardIrq' pulses for one cycle
-- (ARM9 IF bit 19). Cart-bus timing (gap1/gap2, clock rate) is not modelled.
module Nds.WholeCore.Card
  ( CardIn(..), CardBus(..), CardReply(..), CardOut(..), CardState
  , noCartridge, initialCard, cardStep, cardStepNative, cardOwns, cardSpiControl
  ) where

import Prelude ()
import Clash.Prelude hiding (Word)

type Word = BitVector 32

-- | Cartridge straps and the image store's side of its ready/valid port.
data CardIn = CardIn
  { cardInserted      :: Bool
  , cardDirectBoot    :: Bool   -- ^ sampled once, in the first cycle after reset
  , cardChipId        :: Word
  , cardRomMask       :: Word   -- ^ image size - 1 (a power of two minus one)
  , cardRomReady      :: Bool   -- ^ the store accepts 'cardRomAddr'
  , cardRomReplyValid :: Bool   -- ^ the word for the one request in flight
  , cardRomReplyData  :: Word
  } deriving (Generic, NFDataX)

-- | An empty slot: every transfer start faults.
noCartridge :: CardIn
noCartridge = CardIn False False 0 0 False False 0

-- | CPU-side request on the link (address, width, right-justified data).
data CardBus = CardBus
  { busReqValid   :: Bool
  , busReqWrite   :: Bool
  , busReqAddr    :: Word
  , busReqWidth   :: BitVector 3
  , busReqData    :: Word
  , busReplyReady :: Bool
  } deriving (Generic, NFDataX)

data CardReply = CardReply
  { cardReqReady   :: Bool
  , cardReplyValid :: Bool
  , cardReplyData  :: Word
  , cardReplyFault :: Bool
  } deriving (Eq, Show, Generic, NFDataX)

data CardOut = CardOut
  { cardRomReqValid :: Bool
  , cardRomAddr     :: Word   -- ^ word-aligned byte address in the image
  , cardIrq         :: Bool   -- ^ one-cycle transfer-done pulse
  , cardBusy        :: Bool
  } deriving (Eq, Show, Generic, NFDataX)

data Source = Ones | Zero | Chip | Rom
  deriving (Eq, Generic, NFDataX)

data CardState = CardState
  { started  :: Bool
  , dataMode :: Bool
  , spiCnt   :: BitVector 16
  , romCnt   :: Word          -- ^ stored ROMCTRL bits; 31 and 23 are status
  , busy     :: Bool
  , command  :: Vec 8 (BitVector 8)
  , source   :: Source
  , page     :: Word
  , offset   :: BitVector 12
  , toFetch  :: Unsigned 13   -- ^ words still to request or synthesise
  , toPop    :: Unsigned 13   -- ^ words the CPU has still to read
  , fifo0    :: Word
  , fifo1    :: Word
  , count    :: Index 3
  , inflight :: Bool
  , reply    :: Maybe (Word, Bool)
  , irq      :: Bool
  } deriving (Generic, NFDataX)

initialCard :: CardState
initialCard = CardState False False 0 0 False (repeat 0) Ones 0 0 0 0 0 0 0 False Nothing False

-- | Addresses this slot serves (AUXSPIDATA at 0x040001A2 is not one).
cardOwns :: Word -> Bool
cardOwns a = (a >= 0x040001a0 && a < 0x040001a2) || (a >= 0x040001a4 && a < 0x040001b0)
  || (a >= 0x04100010 && a < 0x04100014)

cardStep :: CardState -> (CardBus, CardIn) -> (CardState, (CardReply, CardOut))
cardStep = cardStepWith False True False

-- | Native slot interface. An unselected CPU can still operate its own
-- controller, but receives ones; an empty powered DS slot receives zeroes.
-- These are disconnected-bus responses, not successful authentication.
-- The legacy 'cardStep' retains its original fail-closed fixture contract.
cardStepNative :: Bool -> Bool -> CardState -> (CardBus, CardIn) -> (CardState, (CardReply, CardOut))
cardStepNative = cardStepWith True

cardStepWith :: Bool -> Bool -> Bool -> CardState -> (CardBus, CardIn) -> (CardState, (CardReply, CardOut))
cardStepWith native selected spiBusy s (b, i) = (if started s then s' else powerUp, (replyOut, out))
 where
  powerUp = initialCard
    { started = True, dataMode = cardDirectBoot i
    , romCnt = if cardDirectBoot i then 0x20000000 else 0
    , spiCnt = if cardDirectBoot i then 0x8000 else 0 }

  replyOut = CardReply
    { cardReqReady = started s && reply s == Nothing
    , cardReplyValid = reply s /= Nothing
    , cardReplyData = maybe 0 fst (reply s)
    , cardReplyFault = maybe False snd (reply s) }
  out = CardOut
    { cardRomReqValid = romWant, cardRomAddr = romAddr, cardIrq = irq s, cardBusy = busy s }

  romAddr = page s .|. zeroExtend (offset s)
  romWant = started s && busy s && source s == Rom && not (inflight s) && toFetch s /= 0 && count s < 2
  issued = romWant && cardRomReady i
  arrived = inflight s && cardRomReplyValid i
  synth = busy s && source s /= Rom && toFetch s /= 0 && count s < 2
  pushVal
    | arrived = Just (cardRomReplyData i)
    | synth = Just (case source s of Chip -> cardChipId i; Zero -> 0; _ -> 0xffffffff)
    | otherwise = Nothing

  -- CPU access: lanes and positioned data.
  addr = busReqAddr b
  width = busReqWidth b
  accept = busReqValid b && started s && reply s == Nothing
  writing = busReqWrite b
  shiftBits = fromIntegral (slice d1 d0 addr) * 8 :: Int
  widthMask = case width of
    1 -> 0xff
    2 -> 0xffff
    _ -> 0xffffffff :: Word
  laneMask = shiftL widthMask shiftBits
  laneData = shiftL (busReqData b .&. widthMask) shiftBits
  readField v = shiftR v shiftBits .&. widthMask

  isSpi = addr >= 0x040001a0 && addr < 0x040001a2
  isCtrl = addr >= 0x040001a4 && addr < 0x040001a8
  isCmd = addr >= 0x040001a8 && addr < 0x040001b0
  isData = addr >= 0x04100010 && addr < 0x04100014

  spiView = zeroExtend (if spiBusy then setBit (spiCnt s) 7 else spiCnt s) :: Word
  ctrlView = romCnt s .|. (if busy s then 0x80000000 else 0) .|. (if count s /= 0 then 0x00800000 else 0)
  spiMask = resize laneMask :: BitVector 16
  spiData = resize laneData :: BitVector 16
  spi' = (spiCnt s .&. complement spiMask .|. (spiCnt s .&. 0x0080)) .|. (spiData .&. spiMask .&. 0xe043)
  ctrlStored = (romCnt s .&. (complement laneMask .|. 0x20000000)) .|. (laneData .&. laneMask .&. 0x7f7f7fff)
  startReq = testBit (laneData .&. laneMask) 31
  cmdWritten = imap (\j old -> let k = fromIntegral j - fromIntegral (addr - 0x040001a8) :: Int
                               in if k >= 0 && k < bytes then slice d7 d0 (shiftR (busReqData b) (8 * k)) else old)
                    (command s)
  bytes = fromIntegral width :: Int

  -- Transfer start, from the command bytes and the new ROMCTRL value.
  c = command s
  cmdAddr = (c !! (1 :: Int)) ++# (c !! (2 :: Int)) ++# (c !! (3 :: Int)) ++# (c !! (4 :: Int)) :: Word
  size = slice d26 d24 ctrlStored
  wordsFor = case size of
    0 -> 0
    7 -> 1
    n -> shiftL 64 (fromIntegral n) :: Unsigned 13
  masked = cmdAddr .&. cardRomMask i
  redirected = if masked < 0x8000 then 0x8000 + (masked .&. 0x1ff) else masked
  b7Addr = redirected .&. cardRomMask i
  aligned = slice d1 d0 cmdAddr == 0
  decoded :: Maybe (Source, Word, BitVector 12)
  disconnected = native && (not (cardInserted i) || not selected)
  decoded
    | disconnected = Just (if cardInserted i then Ones else Zero, 0, 0)
    | otherwise = case (dataMode s, c !! (0 :: Int)) of
        (False, 0x9f) -> Just (Ones, 0, 0)
        (False, 0x00) | aligned -> Just (Rom, 0, slice d11 d0 cmdAddr)
        (False, 0x90) -> Just (Chip, 0, 0)
        (True, 0xb7) | aligned -> Just (Rom, b7Addr .&. complement 0xfff, slice d11 d0 b7Addr)
        (True, 0xb8) -> Just (Chip, 0, 0)
        _ -> Nothing
  startable = (disconnected || cardInserted i && testBit ctrlStored 29)
    && testBit (spiCnt s) 15 && not (testBit (spiCnt s) 13)
    && not (testBit ctrlStored 30) && decoded /= Nothing

  -- Outcome of an accepted access: reply (value, fault) and register updates.
  popping = accept && isData && not writing && width == 4 && count s /= 0
  (result, faulted)
    | isSpi = (if writing then 0 else readField spiView, False)
    | isCtrl && writing = (0, busy s || (startReq && not startable))
    | isCtrl = (readField ctrlView, False)
    | isCmd = (0, not writing)
    | otherwise = (fifo0 s, not popping)
  starting = accept && isCtrl && writing && not (busy s) && startReq && startable

  -- FIFO: pop first, then push.
  (f0a, f1a, ca) = if popping then (fifo1 s, fifo1 s, count s - 1) else (fifo0 s, fifo1 s, count s)
  (f0b, f1b, cb) = case pushVal of
    Nothing -> (f0a, f1a, ca)
    Just w -> if ca == 0 then (w, f1a, 1) else (f0a, w, ca + 1)

  ending = busy s && toPop s == 0
  run = s
    { spiCnt = if accept && isSpi && writing then spi' else spiCnt s
    , romCnt = if accept && isCtrl && writing && not faulted then ctrlStored else romCnt s
    , command = if accept && isCmd && writing then cmdWritten else command s
    , busy = busy s && not ending
    , offset = if issued then offset s + 4 else offset s
    , toFetch = if issued || synth then toFetch s - 1 else toFetch s
    , toPop = if popping then toPop s - 1 else toPop s
    , fifo0 = f0b, fifo1 = f1b, count = cb
    , inflight = (inflight s && not arrived) || issued
    , reply = if reply s /= Nothing
                then (if busReplyReady b then Nothing else reply s)
                else (if accept then Just (result, faulted) else Nothing)
    , irq = ending && testBit (spiCnt s) 14 }
  s' = if not starting then run else case decoded of
    Nothing -> run
    Just (src, base, off) -> run
      { busy = True, source = src, page = base, offset = off
      , toFetch = wordsFor, toPop = wordsFor, count = 0, inflight = False }

-- | The controller's stored AUXSPICNT bits (busy is supplied separately).
cardSpiControl :: CardState -> BitVector 16
cardSpiControl = spiCnt
