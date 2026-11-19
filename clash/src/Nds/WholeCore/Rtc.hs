-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, TypeApplications #-}
-- | ARM7 RTC GPIO (04000138h), native firmware boot. The battery domain has
-- configuration-time initialization, NOT guest reset. No host time API.
module Nds.WholeCore.Rtc (RtcOut(..), rtc, rtcWithPeriod) where

import Prelude ()
import Clash.Prelude
import qualified Clash.Explicit.Prelude as E
import Clash.Annotations.SynthesisAttributes (annotate, Attr(..))

type Byte = Unsigned 8
type Seed = BitVector 56

data RtcOut = RtcOut { rtcPins :: BitVector 16, rtcDateTime :: Seed, rtcDateWritten :: Bool }
  deriving (Generic, NFDataX, Eq, Show)

data Date = Date { year, month, day, weekday, hour, minute, second :: Byte }
  deriving (Generic, NFDataX)

epoch :: Date
epoch = Date 0 1 1 6 0 0 0

valid :: Byte -> Byte -> Byte -> Byte
valid lo hi x | x < lo || x > hi || x .&. 15 > 9 = lo
              | otherwise = x

monthEnd :: Byte -> Byte -> Byte
monthEnd y m = case m of
  2 -> if not (testBit y 0) && testBit y 1 == testBit y 4 then 0x29 else 0x28
  4 -> 0x30; 6 -> 0x30; 9 -> 0x30; 0x11 -> 0x30
  _ -> 0x31

inc :: Byte -> Byte
inc x = if x .&. 15 == 9 then x+7 else x+1

nextMonth :: Date -> Date
nextMonth d | month d == 0x12 = d { day=1, month=1, year=if year d==0x99 then 0 else inc (year d) }
            | otherwise = d { day=1, month=inc (month d) }

advance :: Date -> Date
advance d | second d < 0x59 = d { second=inc (second d) }
          | minute d < 0x59 = d { second=0, minute=inc (minute d) }
          | hour d < 0x23 = d { second=0, minute=0, hour=inc (hour d) }
          | day d < monthEnd (year d) (month d) = midnight {day=inc (day d)}
          | otherwise = nextMonth midnight
 where midnight = d {second=0, minute=0, hour=0, weekday=if weekday d==6 then 0 else weekday d+1}

wireHour :: Bool -> Byte -> Byte
wireHour h24 h | h < 0x12 = h
               | h24 = h .|. 0x40
               | otherwise = (h - if h .&. 15 < 2 then 0x18 else 0x12) .|. 0x40

fromHour :: Bool -> Byte -> Byte
fromHour h24 x | h24 = valid 0 0x23 (x .&. 0x3f)
               | testBit x 6 = h + if h .&. 15 >= 8 then 0x18 else 0x12
               | otherwise = h
 where h = valid 0 0x11 (x .&. 0x3f)

dateBytes :: Date -> Vec 7 Byte
dateBytes d = year d :> month d :> day d :> weekday d :> hour d :> minute d :> second d :> Nil

fromHost :: Seed -> Date
fromHost seed = Date y m d w h mi se
 where
  bs = reverse (unpack seed :: Vec 7 Byte)
  y = valid 0 0x99 (bs !! (0::Int)); m = valid 1 0x12 (bs !! (1::Int))
  d = valid 1 (monthEnd y m) (bs !! (2::Int)); w = valid 0 6 (bs !! (3::Int))
  h = valid 0 0x23 (bs !! (4::Int)); mi = valid 0 0x59 (bs !! (5::Int)); se = valid 0 0x59 (bs !! (6::Int))

-- Positions saturate: extra parameter bytes cannot wrap into a new command.
data Wire = Wire { pins :: BitVector 16, inputShift :: Byte, inputBits :: Unsigned 3
                 , pos :: Unsigned 4, cmd :: Byte, response :: Vec 7 Byte
                 , outByte :: Index 7, outBit :: Unsigned 3 } deriving (Generic, NFDataX)

data Rtc = Rtc { date :: Date, divider :: Unsigned 25, seeded, written :: Bool
               , status1, status2 :: Byte, alarm1, alarm2 :: Vec 3 Byte, adjust, freeReg :: Byte
               , serial :: Wire } deriving (Generic, NFDataX)

idle :: Wire
idle = Wire 0 0 0 0 0 (repeat 0) 0 0

initial :: Rtc
initial = Rtc epoch 0 False False 0x82 0 (repeat 0) (repeat 0) 0 0 idle

sendRegister :: Rtc -> Byte -> Vec 7 Byte
sendRegister r c = case c of
  0x86 -> one (status1 r); 0xc6 -> one (status2 r)
  0xa6 -> dateBytes d
  0xe6 -> three (hour d :> minute d :> second d :> Nil)
  0x96 -> if testBit (status2 r) 2 then three (alarm1 r) else one (last (alarm1 r))
  0xd6 -> three (alarm2 r); 0xb6 -> one (adjust r); 0xf6 -> one (freeReg r)
  _ -> repeat 0
 where d = (date r) {hour=wireHour (testBit (status1 r) 1) (hour (date r))}
       one b = b :> repeat 0
       three bs = bs ++ repeat @4 0

parameter :: Rtc -> Byte -> Unsigned 4 -> Byte -> Rtc
parameter r c p x = case c of
  0x06 | p==1 -> if testBit x 0
                  then initial { date=epoch, seeded=seeded r, written=not (written r), serial=serial r, status1=x .&. 14 }
                  else r {status1=status1 r .&. 0xf0 .|. (x .&. 14)}
  0x46 | p==1 -> r {status2=x}
  0x26 | p<=7 -> field p
  0x66 | p<=3 -> field (p+4)
  0x16 | testBit (status2 r) 2 && p<=3 -> r {alarm1=put (alarm1 r)}
       | not (testBit (status2 r) 2) && p==1 -> r {alarm1=replace (2::Int) x (alarm1 r)}
  0x56 | p<=3 -> r {alarm2=put (alarm2 r)}
  0x36 | p==1 -> r {adjust=x}
  0x76 | p==1 -> r {freeReg=x}
  _ -> r
 where
  put bs = replace (p-1) x bs
  d = date r
  field i = case i of
    1 -> r {date=d {year=valid 0 0x99 x}}
    2 -> r {date=d {month=valid 1 0x12 (x .&. 0x1f)}}
    3 -> let v=valid 1 0x31 (x .&. 0x3f)
         in r {date=if v>monthEnd (year d) (month d) then nextMonth d else d {day=v}}
    4 -> r {date=d {weekday=valid 0 6 (x .&. 7)}}
    5 -> r {date=d {hour=fromHour (testBit (status1 r) 1) x}}
    6 -> r {date=d {minute=valid 0 0x59 (x .&. 0x7f)}}
    _ -> r {date=d {second=valid 0 0x59 (x .&. 0x7f)}, written=not (written r), divider=0}

-- Exactly one call per accepted MMIO write, not per idle bus cycle. As in
-- melonDS Write and the product VHDL, selected clock-low writes transfer bits;
-- GPIO reads merely observe the latched level. CS rising takes priority.
writePins :: Rtc -> BitVector 2 -> BitVector 16 -> Rtc
writePins r be val
  | be == 0 = r
  | not (testBit merged 2) = latch w
  | not (testBit (pins w) 2) = latch idle
  | testBit merged 1 = latch w
  | not dir = r {serial=w { pins=replaceBit (0::Int) serialBit merged, outBit=outBit w+1,
                             outByte=if outBit w==7 && outByte w<6 then outByte w+1 else outByte w }}
  | inputBits w /= 7 = latch wIn
  | pos w /= 0 = parameter (latch wDone) (cmd w) (pos w) received
  | otherwise = (latch wDone {cmd=c, response=sendRegister r c})
                 {status1=if c==0x86 then status1 r .&. 15 else status1 r}
 where
  w = serial r
  merged = (if testBit be 1 then slice d15 d8 val else slice d15 d8 (pins w)) ++#
           (if testBit be 0 then slice d7 d0 val else slice d7 d0 (pins w))
  dir = testBit merged 4
  latch v = r {serial=v {pins=if dir then merged else replaceBit (0::Int) (lsb (pins w)) merged}}
  serialBit = (unpack (pack (response w !! outByte w)) :: Vec 8 Bit) !! complement (outBit w)
  received = (inputShift w `shiftR` 1) .|. (if testBit merged 0 then 0x80 else 0)
  wIn = w {inputShift=received, inputBits=inputBits w+1}
  wDone = wIn {inputShift=0, pos=if pos w==15 then 15 else pos w+1}
  c = if received .&. 0xf0==0x60 then unpack (pack (reverse (unpack (pack received) :: Vec 8 Bit))) else received

step :: Unsigned 25 -> Rtc -> (Bool,Bool,Maybe Seed,Bool,BitVector 2,BitVector 16) -> Rtc
step terminal s (rst,tick,seed,wr,be,val) = case seed of
  Just b -> guest {date=fromHost b, divider=0, seeded=True, status1=clearBit (status1 guest) 7}
  Nothing -> guest
 where
  clocked | not tick = s
          | divider s==terminal = s {divider=0, date=advance (date s)}
          | otherwise = s {divider=divider s+1}
  guest | rst = clocked {serial=idle, status1=if seeded s then 2 else 0x82, status2=0}
        | wr = writePins clocked be val
        | otherwise = clocked

-- | Production period. Calendar enable must not stop during guest reset.
rtc :: Clock System -> Signal System Bool -> Signal System Bool -> Signal System Seed -> Signal System Bool
    -> Signal System Bool -> Signal System (BitVector 2) -> Signal System (BitVector 16) -> Signal System RtcOut
rtc = rtcWithPeriod 33513982

-- | Period specialization for deterministic HDL tests. Seed data is bundled:
-- sender writes four UIO22 words, toggles once and holds until settled. Two
-- data stages and three toggle stages precede the change detector. UIO47 is
-- a separate snapshot consumer of rtcDateTime and rtcDateWritten.
rtcWithPeriod :: Unsigned 25 -> Clock System -> Signal System Bool -> Signal System Bool -> Signal System Seed -> Signal System Bool
              -> Signal System Bool -> Signal System (BitVector 2) -> Signal System (BitVector 16) -> Signal System RtcOut
rtcWithPeriod period clk rst tick seed toggle wr lanes val = observe <$> state
 where
  delayS :: NFDataX a => a -> Signal System a -> Signal System a
  delayS = E.delay clk enableGen
  sync :: NFDataX a => a -> Signal System a -> Signal System a
  sync x s = annotate (Attr "preserve" :>
    StringAttr "altera_attribute" "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF; -name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" :> Nil) (delayS x s)
  data2 = sync 0 (sync 0 seed)
  t3 = sync False (sync False (sync False toggle))
  seedEvent = (\now old b -> if now/=old then Just b else Nothing) <$> t3 <*> delayS False t3 <*> data2
  state = delayS initial (step (period-1) <$> state <*> bundle (rst,tick,seedEvent,wr,lanes,val))
  observe s = RtcOut (pins (serial s)) (pack (reverse (dateBytes (date s)))) (written s)
