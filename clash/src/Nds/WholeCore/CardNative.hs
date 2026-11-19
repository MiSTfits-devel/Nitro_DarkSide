-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}

-- | Shared DS cartridge slot for the native two-CPU machine. Each CPU has
-- its own card controller and transfer IRQ; EXMEMCNT bit 11 selects which
-- controller talks to the inserted cartridge. The image port is shared and
-- permits one ordered request in flight. Reset must flush that port.
--
-- This deliberately implements only the NTR read-only commands supported
-- by Card, not KEY1, KEY2 seed registers or card-bus timing. Backup SPI is
-- delegated to a separate engine and cache; its faults remain observable.
-- Switching ownership during an active transfer is not yet specified.
module Nds.WholeCore.CardNative
  ( NativeCardState, NativeCardIn(..), NativeCardOut(..)
  , initialNativeCard, nativeCardOwns, nativeCardStep, nativeCard, nativeCardTopEntity
  ) where

import Prelude ()
import Clash.Prelude hiding (Word)
import Nds.WholeCore.Card

type Word = BitVector 32

data NativeCardState = NativeCardState
  { initialized :: Bool
  , ex9 :: BitVector 16, ex7low :: BitVector 7
  , exReply9 :: Maybe (Word, Bool), exReply7 :: Maybe (Word, Bool)
  , k9 :: CardState, k7 :: CardState
  , offered7 :: Maybe Bool, flight7 :: Maybe Bool
  , spiFlight :: Maybe Bool, spiData9 :: BitVector 8, spiData7 :: BitVector 8
  , spiFault9 :: Bool, spiFault7 :: Bool, spiLastOwner :: Bool
  } deriving (Generic, NFDataX)

data NativeCardIn = NativeCardIn
  { nativeBus9 :: CardBus, nativeBus7 :: CardBus, nativeImage :: CardIn
  , nativeSpiReady :: Bool, nativeSpiReplyValid :: Bool
  , nativeSpiReplyByte :: BitVector 8, nativeSpiReplyFault :: Bool
  } deriving (Generic, NFDataX)

data NativeCardOut = NativeCardOut
  { nativeReply9 :: CardReply, nativeReply7 :: CardReply
  , nativeRomValid :: Bool, nativeRomAddress :: Word
  , nativeIrq9 :: Bool, nativeIrq7 :: Bool
  , nativeOwner7 :: Bool
  , nativeSpiValid :: Bool, nativeSpiByte :: BitVector 8, nativeSpiHold :: Bool
  , nativeSpiSelected :: Bool, nativeSpiReplyReady :: Bool, nativeSpiFault :: Bool
  } deriving (Generic, NFDataX)

initialNativeCard :: NativeCardState
initialNativeCard = NativeCardState False 0x6000 0 Nothing Nothing initialCard initialCard Nothing Nothing Nothing 0 0 False False False

-- The ARM7 Wi-Fi wait-state register at 0x206 is not this device.
nativeCardOwns :: Word -> Bool
nativeCardOwns a = cardOwns a || (a >= 0x040001a2 && a < 0x040001a4)
  || (a >= 0x04000204 && a < 0x04000206)

isEx :: CardBus -> Bool
isEx b = busReqAddr b >= 0x04000204 && busReqAddr b < 0x04000206

isAux :: CardBus -> Bool
isAux b = busReqAddr b >= 0x040001a2 && busReqAddr b < 0x040001a4

-- A combined word access also touches AUXSPIDATA; it is not yet split.
badSpiWord :: CardBus -> Bool
badSpiWord b = busReqAddr b == 0x040001a0 && busReqWidth b == 4

-- melonDS's NTR EXMEMCNT handlers implement aligned halfword accesses;
-- byte/word reads are zero and byte/word writes have no effect.
exAccess :: Bool -> BitVector 16 -> CardBus -> (Word, Bool)
exAccess _ v b =
  (if busReqWrite b || busReqWidth b /= 2 then 0 else zeroExtend v,
   busReqWidth b /= 1 && busReqWidth b /= 2 && busReqWidth b /= 4
   || busReqWidth b == 2 && testBit (busReqAddr b) 0)
exWrite :: BitVector 16 -> CardBus -> BitVector 16 -> BitVector 16
exWrite allowed b old = (old .&. complement m) .|. (v .&. m)
 where
  sh = if testBit (busReqAddr b) 0 then 8 else 0
  mask = if busReqWidth b == 1 then 0xff else 0xffff :: BitVector 16
  m = shiftL mask sh .&. allowed
  v = shiftL (resize (busReqData b)) sh

nativeCardStep :: NativeCardState -> NativeCardIn -> (NativeCardState, NativeCardOut)
nativeCardStep s i = (if initialized s then next else boot, output)
 where
  b9 = nativeBus9 i
  b7 = nativeBus7 i
  img = nativeImage i
  boot = initialNativeCard { initialized = True, ex9 = if cardDirectBoot img then 0xe880 else 0x6000 }
  owner = testBit (ex9 s) 11
  e7 = (ex9 s .&. 0xff80) .|. zeroExtend (ex7low s)
  -- Probe registered card outputs without consuming a store request.
  quiet = img { cardRomReady = False, cardRomReplyValid = False }
  disabled b = b { busReqValid = False, busReplyReady = False }
  (_, (probe9, out9)) = cardStepNative (not owner) (spiFlight s == Just False) (k9 s) (disabled b9, quiet)
  (_, (probe7, out7)) = cardStepNative owner (spiFlight s == Just True) (k7 s) (disabled b7, quiet)
  pending9 = exReply9 s /= Nothing
  pending7 = exReply7 s /= Nothing
  ctrl9 = cardSpiControl (k9 s)
  ctrl7 = cardSpiControl (k7 s)
  active c = testBit c 15 && testBit c 13
  spiSelected = initialized s && cardInserted img && owner == spiLastOwner s
             && active (if owner then ctrl7 else ctrl9)
  auxWants p c b = isAux b && busReqAddr b == 0x040001a2
    && (busReqWidth b == 1 || busReqWidth b == 2)
    && busReqWrite b && active c && spiFlight s /= Just p
    && cardInserted img && owner == p
  auxReady p c b = not (auxWants p c b) ||
    (spiFlight s == Nothing && spiSelected && nativeSpiReady i)
  local b = isEx b || isAux b || badSpiWord b
  localReady p c b pending probe = initialized s && not pending && not (cardReplyValid probe)
    && (not (isAux b) || auxReady p c b)
  localTake9 = local b9 && busReqValid b9 && localReady False ctrl9 b9 pending9 probe9
  localTake7 = local b7 && busReqValid b7 && localReady True ctrl7 b7 pending7 probe7
  exTake9 = localTake9 && isEx b9
  exTake7 = localTake7 && isEx b7
  exResult9 = exAccess False (ex9 s) b9
  exResult7 = exAccess True e7 b7
  auxResult p c b dat err
    | badSpiWord b = (0, True)
    | busReqAddr b /= 0x040001a2 = (0, False)
    | busReqWidth b /= 1 && busReqWidth b /= 2 = (0, True)
    | busReqWrite b || not (active c) || spiFlight s == Just p = (0, False)
    | otherwise = (zeroExtend dat, err)
  result9 = if isEx b9 then exResult9 else auxResult False ctrl9 b9 (spiData9 s) (spiFault9 s)
  result7 = if isEx b7 then exResult7 else auxResult True ctrl7 b7 (spiData7 s) (spiFault7 s)
  er9 = if localTake9 then Just result9 else if busReplyReady b9 then Nothing else exReply9 s
  er7 = if localTake7 then Just result7 else if busReplyReady b7 then Nothing else exReply7 s
  ex9' = if exTake9 && busReqWrite b9 && busReqWidth b9 == 2 && not (snd exResult9)
           then exWrite 0x88ff b9 (ex9 s) else ex9 s
  low7 = if exTake7 && busReqWrite b7 && busReqWidth b7 == 2 && not (snd exResult7)
           then resize (exWrite 0x007f b7 (zeroExtend (ex7low s))) else ex7low s
  bus9 = b9 { busReqValid = busReqValid b9 && cardOwns (busReqAddr b9) && not (badSpiWord b9) && not pending9
            , busReplyReady = busReplyReady b9 && not pending9 }
  bus7 = b7 { busReqValid = busReqValid b7 && cardOwns (busReqAddr b7) && not (badSpiWord b7) && not pending7
            , busReplyReady = busReplyReady b7 && not pending7 }
  choice = case offered7 s of
    Just p -> Just p
    Nothing | cardRomReqValid out9 -> Just False
            | cardRomReqValid out7 -> Just True
            | otherwise -> Nothing
  canIssue = flight7 s == Nothing
  selectedReq = case choice of
    Just False -> cardRomReqValid out9
    Just True -> cardRomReqValid out7
    Nothing -> False
  req = initialized s && canIssue && selectedReq
  accepted = req && cardRomReady img
  returned = flight7 s /= Nothing && cardRomReplyValid img
  offer' = if not canIssue || accepted then Nothing else if req then choice else Nothing
  flight' = if returned then Nothing else if accepted then choice else flight7 s
  inputFor p = img { cardRomReady = req && choice == Just p && cardRomReady img
                   , cardRomReplyValid = flight7 s == Just p && cardRomReplyValid img }
  (k9', (r9, _)) = cardStepNative (not owner) (spiFlight s == Just False) (k9 s) (bus9, inputFor False)
  (k7', (r7, _)) = cardStepNative owner (spiFlight s == Just True) (k7 s) (bus7, inputFor True)
  selectedBus = if owner then b7 else b9
  selectedCtrl = if owner then ctrl7 else ctrl9
  selectedPending = if owner then pending7 else pending9
  selectedProbe = if owner then probe7 else probe9
  spiValid = initialized s && spiSelected && spiFlight s == Nothing && busReqValid selectedBus
    && not selectedPending && not (cardReplyValid selectedProbe)
    && auxWants owner selectedCtrl selectedBus
  spiAccepted = spiValid && nativeSpiReady i
  spiReturned = spiFlight s /= Nothing && nativeSpiReplyValid i
  spiFlight' = if spiReturned then Nothing else if spiAccepted then Just owner else spiFlight s
  localWrite p c b taken = taken && isAux b && busReqAddr b == 0x040001a2
    && (busReqWidth b == 1 || busReqWidth b == 2) && busReqWrite b
    && active c && spiFlight s /= Just p
  disc9 = localWrite False ctrl9 b9 localTake9 && (owner || not (cardInserted img))
  disc7 = localWrite True ctrl7 b7 localTake7 && (not owner || not (cardInserted img))
  disconnectedByte = if cardInserted img then 0xff else 0
  data9' | spiReturned && spiFlight s == Just False = nativeSpiReplyByte i
         | disc9 = disconnectedByte
         | otherwise = spiData9 s
  data7' | spiReturned && spiFlight s == Just True = nativeSpiReplyByte i
         | disc7 = disconnectedByte
         | otherwise = spiData7 s
  fault9' | spiReturned && spiFlight s == Just False = nativeSpiReplyFault i
          | disc9 || (spiAccepted && not owner) = False
          | otherwise = spiFault9 s
  fault7' | spiReturned && spiFlight s == Just True = nativeSpiReplyFault i
          | disc7 || (spiAccepted && owner) = False
          | otherwise = spiFault7 s
  view p c b pending r
    | pending /= Nothing = CardReply False True (maybe 0 fst pending) (maybe False snd pending)
    | cardReplyValid r = r
    | local b = CardReply (localReady p c b False r) False 0 False
    | otherwise = r
  output = NativeCardOut (view False ctrl9 b9 (exReply9 s) r9) (view True ctrl7 b7 (exReply7 s) r7)
    req (case choice of Just True -> cardRomAddr out7; _ -> cardRomAddr out9)
    (cardIrq out9) (cardIrq out7) owner
    spiValid (resize (busReqData selectedBus)) (testBit selectedCtrl 6)
    spiSelected (spiFlight s /= Nothing) (spiFault9 s || spiFault7 s)
  next = NativeCardState True ex9' low7 er9 er7 k9' k7' offer' flight'
    spiFlight' data9' data7' fault9' fault7' owner

nativeCard :: KnownDomain dom => Clock dom -> Reset dom -> Enable dom
           -> Signal dom NativeCardIn -> Signal dom NativeCardOut
nativeCard clk rst en input = gate <$> active <*> outOfReset <*> raw
 where
  raw = withClockResetEnable clk rst en (mealy nativeCardStep initialNativeCard input)
  outOfReset = not <$> unsafeToActiveHigh rst
  active = (&&) <$> fromEnable en <*> outOfReset
  gate running released o = o
    { nativeReply9 = replyGate running (nativeReply9 o)
    , nativeReply7 = replyGate running (nativeReply7 o)
    , nativeRomValid = running && nativeRomValid o
    , nativeIrq9 = running && nativeIrq9 o, nativeIrq7 = running && nativeIrq7 o
    , nativeSpiValid = running && nativeSpiValid o
    , nativeSpiReplyReady = running && nativeSpiReplyReady o
    -- Pausing must not release a held SPI chip select.
    , nativeSpiSelected = released && nativeSpiSelected o }
  replyGate running r = r { cardReqReady = running && cardReqReady r
                          , cardReplyValid = running && cardReplyValid r }

{-# ANN nativeCardTopEntity
  (Synthesize
    { t_name = "nds_native_card"
    , t_inputs = [PortName "CLK", PortName "RST", PortName "EN"
                 , PortProduct ""
                     [ PortProduct "BUS9" [PortName "VALID", PortName "WRITE", PortName "ADDR", PortName "WIDTH", PortName "DATA", PortName "REPLY_READY"]
                     , PortProduct "BUS7" [PortName "VALID", PortName "WRITE", PortName "ADDR", PortName "WIDTH", PortName "DATA", PortName "REPLY_READY"]
                     , PortProduct "IMAGE" [PortName "INSERTED", PortName "DIRECT", PortName "CHIP_ID", PortName "MASK", PortName "READY", PortName "REPLY_VALID", PortName "REPLY_DATA"]
                     , PortName "SPI_READY", PortName "SPI_REPLY_VALID", PortName "SPI_REPLY_BYTE", PortName "SPI_REPLY_FAULT" ] ]
    , t_output = PortProduct ""
        [ PortProduct "R9" [PortName "READY", PortName "VALID", PortName "DATA", PortName "FAULT"]
        , PortProduct "R7" [PortName "READY", PortName "VALID", PortName "DATA", PortName "FAULT"]
        , PortName "ROM_VALID", PortName "ROM_ADDR", PortName "IRQ9", PortName "IRQ7", PortName "OWNER7"
        , PortName "SPI_VALID", PortName "SPI_BYTE", PortName "SPI_HOLD", PortName "SPI_SELECTED", PortName "SPI_REPLY_READY", PortName "SPI_FAULT" ]
    }) #-}
nativeCardTopEntity :: Clock System -> Reset System -> Enable System
                    -> Signal System NativeCardIn -> Signal System NativeCardOut
nativeCardTopEntity = nativeCard
