-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, NoImplicitPrelude #-}
-- Native NTR ARM7 SPI/keypad port. Firmware bytes live exclusively behind
-- the board's v1.0.1 word-addressed, acknowledged firmware cache interface.
module Nds.WholeCore.SystemSpi
  ( SystemPins(..), CalAxis(..), FirmwarePort(..), SpiState, initialSpi, sysOwns, systemSpiStep ) where
import Clash.Prelude hiding (Word, sample)
import qualified Clash.Prelude as C
import Data.Maybe (isJust, isNothing)
import Nds.WholeCore.Card (CardBus(..),CardReply(..))

type Word = BitVector 32
type B = BitVector 8
type ADC = BitVector 12
data CalAxis = CalAxis { adc1,adc2 :: ADC, pixel1,pixel2 :: B } deriving (Eq, Show, Generic, NFDataX)
data SystemPins = SystemPins
  { keysPressed :: BitVector 12, penDown :: Bool, touchX,touchY :: B, calX,calY :: CalAxis
  , lidClosed :: Bool, micAdc :: ADC, fwDone :: Bool, fwData :: Word, fwBusy :: Bool
  } deriving (Generic,NFDataX)
data FirmwarePort = FirmwarePort { fwAddr :: BitVector 16, fwRead,fwWrite :: Bool, fwLane :: BitVector 2
                                 , fwByte :: B, fwRelease :: Bool } deriving (Eq,Show,Generic,NFDataX)
idleFw :: FirmwarePort
idleFw = FirmwarePort 0 False False 0 0 False

-- The host validates endpoints before launching. Compute signed affine
-- interpolation (C++ truncation toward zero) with one unsigned restoring
-- division step per clock. 20 clocks fit inside even the fastest SPI byte.
data Conversion = Conversion (Unsigned 5) (Unsigned 20) (Unsigned 8) (Unsigned 8) Bool ADC Bool
  deriving (Generic,NFDataX)
startConversion :: B -> CalAxis -> Bool -> Conversion
startConversion px (CalAxis a b p q) lowRes = Conversion 20 numerator 0 denominator negative a lowRes
 where
  dist x y = if x>=y then x-y else y-x
  numerator = (unpack (dist px p) :: Unsigned 8) `mul` (unpack (dist b a) :: Unsigned 12)
  denominator = unpack (dist q p)
  negative = ((px<p) /= (b<a)) /= (q<p)
convert :: Conversion -> Either Conversion ADC
convert (Conversion n x r d neg base low) = if n==1 then Right result else Left (Conversion (n-1) x' r' d neg base low)
 where
  rem9 = resize r `shiftL` 1 .|. (if testBit x 19 then 1 else 0) :: Unsigned 9
  takeBit = rem9>=resize d
  r' = resize (if takeBit then rem9-resize d else rem9)
  x' = shiftL x 1 .|. (if takeBit then 1 else 0)
  origin = resize (unpack base :: Unsigned 12) :: Unsigned 20
  sample | neg = if x'>origin then 0 else resize (origin-x')
         | x'>4095-origin = 4095
         | otherwise = resize (origin+x') :: Unsigned 12
  result = if low then pack sample .&. 0xff0 else pack sample

data Flash = FCommand | FAddress B (Unsigned 2) (BitVector 18) | FStream B (BitVector 18) | FStatus | FId (Unsigned 2) | FIgnore
  deriving (Generic,NFDataX)
data Pending = Reading (BitVector 2) | Writing deriving (Generic,NFDataX)
data SpiState = SpiState
  { ctrl :: BitVector 16, clocksLeft :: Unsigned 10, pending :: Maybe Pending
  , flash :: Flash, wel :: Bool, dirty :: Bool, fOut :: B
  , pmRegs :: Vec 8 B, pmIndex :: Maybe B, pmUsed :: Bool, pOut :: B
  , tPhase :: Unsigned 2, sample :: ADC, conversion :: Maybe Conversion, tOut :: B
  , key9,key7,rcnt :: BitVector 16, lastKeys :: BitVector 10, wasClosed :: Bool
  , reply9,reply7 :: Maybe (Word,Bool)
  } deriving (Generic,NFDataX)
initialSpi :: SpiState
initialSpi = SpiState 0 0 Nothing FCommand False False 0 (replace (4::Index 8) 0x40 (repeat 0)) Nothing False 0 0 0 Nothing 0 0 0 0 0 False Nothing Nothing

sysOwns :: Bool -> Word -> Bool
sysOwns arm7 a = case C.slice d31 d2 a of
  0x0100004c -> True                 -- 04000130 KEYINPUT/KEYCNT
  0x0100004d -> arm7                 -- 04000134 RCNT/EXTKEYIN
  0x01000070 -> arm7                 -- 040001c0 SPICNT/SPIDATA
  _ -> False

type Result = (CardReply,CardReply,FirmwarePort,Bool,Word,Word)
-- | One master clock. tick is the 33.51 MHz enable. The bus requests and
-- firmware response strobes are sampled every master clock, not just on tick.
systemSpiStep :: SpiState -> Bool -> SystemPins -> CardBus -> CardBus -> (SpiState,Result)
systemSpiStep s tick pins b9 b7 = (final,(reply (reply9 s),reply (reply7 s),port,power,irq9,irq7))
 where
  reply v = CardReply (isNothing v) (isJust v) (maybe 0 fst v) (maybe False snd v)
  accept seven b r = busReqValid b && isNothing r && sysOwns seven (busReqAddr b)
  a9 = accept False b9 (reply9 s); a7 = accept True b7 (reply7 s)
  keyWord k = k ++# (0 :: BitVector 6) ++# complement (resize (keysPressed pins) :: BitVector 10)
  ext = pack (lidClosed pins) ++# pack (not (penDown pins)) ++# (0xf :: BitVector 4) ++# complement (C.slice d11 d10 (keysPressed pins))
  sysWord = (0 :: B) ++# ext ++# rcnt s
  dev = C.slice d9 d8 (ctrl s)
  busy = clocksLeft s/=0 || isJust (pending s)
  spiData | busy || not (testBit (ctrl s) 15) = 0
          | dev==0 = pOut s | dev==1 = fOut s | dev==2 = tOut s | otherwise = 0
  spiWord = (0::B) ++# spiData ++# (ctrl s .|. if busy then 0x80 else 0)
  shiftFor b = fromIntegral (C.slice d1 d0 (busReqAddr b) ++# (0::BitVector 3)) :: Int
  mask b = case busReqWidth b of 1->0xff; 2->0xffff; _->maxBound :: Word
  aligned b = case busReqWidth b of 1->True; 2->not (testBit (busReqAddr b) 0); 4->C.slice d1 d0 (busReqAddr b)==0; _->False
  readWord b w = shiftR w (shiftFor b) .&. mask b
  writeMask b = shiftL (mask b) (shiftFor b)
  writeData b = shiftL (busReqData b) (shiftFor b)
  merged b v = (v .&. complement (writeMask b)) .|. (writeData b .&. writeMask b)
  address b = C.slice d31 d2 (busReqAddr b)
  w7 = a7 && busReqWrite b7 && aligned b7
  w9 = a9 && busReqWrite b9 && aligned b9
  spiStore = w7 && address b7==0x01000070
  cnt' = if spiStore then resize (merged b7 spiWord) .&. 0xcb03 else ctrl s
  transfer = spiStore && testBit (writeMask b7) 16 && testBit (ctrl s) 15 && not busy
  val = C.slice d23 d16 (writeData b7)
  calibration = if testBit val 6 then calX pins else calY pins
  invalidCal = penDown pins && testBit val 7 && (C.slice d6 d4 val==1 || C.slice d6 d4 val==5) &&
               (adc1 calibration==adc2 calibration || pixel1 calibration==pixel2 calibration)
  badCommand = transfer && (dev==3 || (dev==2 && invalidCal) || (dev==1 && case flash s of
                FCommand -> not (val==2 || val==3 || val==4 || val==5 || val==6 || val==10 || val==0x9f); _->False))
  nextReply accepted b value bad old
    | accepted = Just (if busReqWrite b then 0 else readWord b value, not (aligned b) || bad)
    | busReplyReady b = Nothing
    | otherwise = old
  keyUpdate on b old = if on && address b==0x0100004c then C.slice d31 d16 (merged b (keyWord old)) .&. 0xc3ff else old
  rc' = if w7 && address b7==0x0100004d then resize (merged b7 sysWord) else rcnt s
  remain = if tick && clocksLeft s/=0 then clocksLeft s-1 else clocksLeft s
  storage = if fwDone pins then Nothing else pending s
  readByte i = resize (shiftR (fwData pins) (fromIntegral (i ++# (0::BitVector 3))))
  fresh = s { clocksLeft=remain, pending=storage, ctrl=cnt', key9=keyUpdate w9 b9 (key9 s),key7=keyUpdate w7 b7 (key7 s),rcnt=rc'
            , lastKeys=resize (keysPressed pins), wasClosed=lidClosed pins
            , fOut=case pending s of Just (Reading lane) | fwDone pins -> readByte lane; _ -> fOut s
            , reply9=nextReply a9 b9 (keyWord (key9 s)) False (reply9 s)
            , reply7=nextReply a7 b7 (case address b7 of 0x0100004c -> keyWord (key7 s); 0x0100004d -> sysWord; _ -> spiWord) badCommand (reply7 s) }
  progress = case conversion s of
    Nothing -> fresh
    Just c -> case convert c of Left c' -> fresh {conversion=Just c'}; Right q -> fresh {conversion=Nothing,sample=q}
  (sent,fw,power) = if not transfer || badCommand then (progress,idleFw,False) else
    let started=progress {clocksLeft=shiftL 64 (fromIntegral (C.slice d1 d0 (ctrl s)))} in case dev of
      0 -> let (next,off)=powerByte val started in (next,idleFw,off)
      1 -> let (next,f)=flashByte val pins started in (next,f,False)
      _ -> (touchByte val pins started,idleFw,False)
  deselect = (testBit (ctrl s) 15 && (not (testBit cnt' 15) || C.slice d9 d8 cnt'/=dev)) || (transfer && not (testBit (ctrl s) 11))
  final | not deselect = sent
        | dev==0 = sent {pmIndex=Nothing,pmUsed=False}
        | dev==1 = sent {flash=FCommand,dirty=False}
        | otherwise = sent {tPhase=0}
  port=fw {fwRelease=deselect && dev==1 && dirty sent}
  spiIrq=busy && remain==0 && isNothing storage && testBit (ctrl s) 14
  keyPulse k = testBit k 14 && not (matches (lastKeys s)) && matches (resize (keysPressed pins))
   where sel=resize k :: BitVector 10
         matches pressed = if testBit k 15 then pressed .&. sel==sel else (pressed .&. sel)/=0
  irq9=if keyPulse (key9 s) then bit 12 else 0
  irq7=(if keyPulse (key7 s) then bit 12 else 0) .|. (if spiIrq then bit 23 else 0) .|. (if wasClosed s && not (lidClosed pins) then bit 22 else 0)

powerByte :: B -> SpiState -> (SpiState,Bool)
powerByte v s = case pmIndex s of
  Nothing -> (s {pmIndex=Just v,pmUsed=False,pOut=0},False)
  Just sel | pmUsed s -> (s {pOut=0},False)
           | testBit sel 7 -> (s {pmUsed=True,pOut=pmRegs s !! i},False)
           | otherwise -> (s {pmUsed=True,pOut=0,pmRegs=replace i ((pmRegs s !! i .&. complement m) .|. (v .&. m)) (pmRegs s)},i==0 && testBit v 6)
   where i=fromIntegral (C.slice d2 d0 sel) :: Index 8
         m=case i of 0->0x7f;2->1;3->3;4->0xf;_->0

flashByte :: B -> SystemPins -> SpiState -> (SpiState,FirmwarePort)
flashByte v p s = case flash s of
  FCommand -> (s {flash=cmd,fOut=0,wel=if v==4 then False else v==6 || wel s},idleFw)
   where cmd | v==3 || v==2 || v==10=FAddress v 0 0 | v==5=FStatus | v==0x9f=FId 0 | otherwise=FIgnore
  FStatus -> (s {fOut=(0::BitVector 6) ++# pack (wel s) ++# pack (fwBusy p)},idleFw)
  FId i -> (s {fOut=case i of 0->0x20;1->0x40;2->0x12;_->0, flash=FId (if i<3 then i+1 else i)},idleFw)
  FIgnore -> (s {fOut=0},idleFw)
  FAddress cmd n a -> let a'=shiftL a 8 .|. zeroExtend v in (s {fOut=0,flash=if n==2 then FStream cmd a' else FAddress cmd (n+1) a'},idleFw)
  FStream cmd a -> let rd=cmd==3; lane=C.slice d1 d0 a in
    if not rd && not (wel s) then (s {fOut=0,flash=FStream cmd (a+1)},idleFw) else
    (s {pending=Just (if rd then Reading lane else Writing), fOut=if rd then 0 else v, dirty=dirty s || not rd,flash=FStream cmd (a+1)},
     FirmwarePort (C.slice d17 d2 a) rd (not rd) lane v False)

touchByte :: B -> SystemPins -> SpiState -> SpiState
touchByte v p s = next {tOut=case tPhase s of 1->zeroExtend (C.slice d11 d5 (sample s)); 2->C.slice d4 d0 (sample s) ++# (0::BitVector 3); _->0}
 where
  low=testBit v 3
  ch=C.slice d6 d4 v
  selected=if ch==1 then touchY p else touchX p
  axis=if ch==1 then calY p else calX p
  raw | ch==1 = 0xfff | ch==5 = 0 | ch==6 = micAdc p | otherwise=0xfff
  next | not (testBit v 7) = s {tPhase=if tPhase s<3 then tPhase s+1 else 3}
       | penDown p && (ch==1 || ch==5) = s {tPhase=1,conversion=Just (startConversion selected axis low)}
       | otherwise = s {tPhase=1,conversion=Nothing,sample=if low then raw .&. 0xff0 else raw}
