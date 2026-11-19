-- SPDX-License-Identifier: GPL-3.0-or-later

-- | Independent oracle for one CPU's DS timers, transcribed from melonDS
-- (third_party/melonDS/src/NDS.cpp: TimerStart, RunTimers, RunTimer,
-- HandleTimerOverflow, TimerGetCounter, the 0x04000100..0x0400010E
-- ARM9IORead/Write cases). Shares no code with Nds.WholeCore.Timers and has no
-- Clash dependency.
--
-- melonDS is lazy: timers only advance (RunTimers) when an access touches
-- them, by a whole batch of cycles. This model keeps that structure and jumps
-- each batch in closed form, overflow to overflow, logging the timer clock
-- index on which every overflow lands. Time is counted in timer clocks: an
-- access at time T sees clocks 0..T-1 and precedes clock T.
--
-- Two documented departures, both taken from the shipping
-- rtl/gba_timer_module.vhd ('Hardware' mode):
--   * TM0CNT_H bit 2 is ignored, so timer 0 with it set still runs on its
--     prescaler. melonDS ('Melon' mode) leaves it out of TimerCheckMask and,
--     with no cascade source, frozen.
--   * TMxCNT_H reads return bits & 0x00C7. melonDS returns the raw write.
-- melonDS has no 8-bit timer writes; a lane-masked write here merges into the
-- stored Reload/Cnt and calls TimerStart when either Cnt byte is written.
module TimersOracle
  ( Mode(..), Oracle, newOracle, oracleWrite, oracleRead, oracleFlush, oracleOverflows
  ) where

import Data.Bits

data Mode = Hardware | Melon deriving (Eq, Show)

data Timer = Timer
  { tReload  :: Int
  , tCnt     :: Int     -- raw 16-bit Cnt as written
  , tCounter :: Int     -- Counter: count << 10 | fraction
  , tShift   :: Int     -- CycleShift
  }

data Oracle = Oracle
  { oMode      :: Mode
  , oTimers    :: [Timer]
  , oCheckMask :: Int
  , oStamp     :: Int              -- TimerTimestamp
  , oLog       :: [(Int, Int)]     -- (clock index, timer) with IRQ enabled, newest first
  }

newOracle :: Mode -> Oracle
newOracle m = Oracle m (replicate 4 (Timer 0 0 0 10)) 0 0 []

-- | Overflows with Cnt bit 6 set, as (timer clock index, timer), oldest first.
oracleOverflows :: Oracle -> [(Int, Int)]
oracleOverflows = reverse . oLog

prescalerShift :: [Int]
prescalerShift = [0, 6, 8, 10]   -- TimerPrescaler[]

getT :: Oracle -> Int -> Timer
getT o n = oTimers o !! n

putT :: Int -> Timer -> Oracle -> Oracle
putT n t o = o { oTimers = [ if k == n then t else x | (k, x) <- zip [0 ..] (oTimers o) ] }

-- RunTimers: advance every timer in TimerCheckMask to 'now'.
runTimers :: Int -> Oracle -> Oracle
runTimers now o0 = (foldl run o0 [0 .. 3]) { oStamp = now }
 where
  cycles = now - oStamp o0
  run o n | testBit (oCheckMask o) n = runTimer n (oStamp o0) cycles o
          | otherwise = o

-- RunTimer, closed form: Counter += cycles << CycleShift, overflowing whenever
-- Counter >> 26. 'base' is the clock index of the first of 'left' clocks.
runTimer :: Int -> Int -> Int -> Oracle -> Oracle
runTimer n base left o
  | left <= 0 = o
  | k > left = putT n t { tCounter = tCounter t + left * inc } o
  | otherwise =
      let o' = putT n t { tCounter = tCounter t + k * inc - bit 26 } o
      in runTimer n (base + k) (left - k) (overflow n (base + k - 1) o')
 where
  t = getT o n
  inc = bit (tShift t) :: Int
  k = (bit 26 - tCounter t + inc - 1) `div` inc   -- clocks to the next overflow

-- HandleTimerOverflow on clock 'at'.
overflow :: Int -> Int -> Oracle -> Oracle
overflow n at o = chain (n + 1) (irq n (putT n t { tCounter = tCounter t + tReload t `shiftL` 10 } o))
 where
  t = getT o n
  irq k x = if testBit (tCnt (getT x k)) 6 then x { oLog = (at, k) : oLog x } else x
  chain k x
    | k > 3 = x
    | tCnt c .&. 0x84 /= 0x84 = x
    | (tCounter c + bit 10) `shiftR` 26 == 0 = putT k c { tCounter = tCounter c + bit 10 } x
    | otherwise = chain (k + 1) (irq k (putT k c { tCounter = tReload c `shiftL` 10 } x))
   where c = getT x k

-- TimerStart (runTimers already applied by the caller).
timerStart :: Int -> Int -> Oracle -> Oracle
timerStart n cnt o = o' { oCheckMask = mask }
 where
  t = getT o n
  edge = not (testBit (tCnt t) 7) && testBit cnt 7
  t' = t { tCnt = cnt
         , tShift = 10 - prescalerShift !! (cnt .&. 3)
         , tCounter = if edge then tReload t `shiftL` 10 else tCounter t }
  o' = putT n t' o
  runs = case oMode o of
    Hardware | n == 0 -> testBit cnt 7
    _ -> cnt .&. 0x84 == 0x80
  mask = if runs then setBit (oCheckMask o) n else clearBit (oCheckMask o) n

-- | Write the 32-bit word for timer 'n' at time 'now' with byte lanes.
-- With all lanes this is ARM9IOWrite32: Reload = val & 0xFFFF; TimerStart(val >> 16).
oracleWrite :: Int -> Int -> Int -> Int -> Oracle -> Oracle
oracleWrite now n lanes val o0
  | lanes .&. 0xc /= 0 = timerStart n (merge 2 (tCnt t)) o1
  | otherwise = o1
 where
  o = runTimers now o0
  t = getT o n
  merge sh old = foldl (\acc b -> if testBit lanes (sh + b)
                                    then (acc .&. complement (0xff `shiftL` (8 * b)))
                                         .|. (((val `shiftR` (8 * (sh + b))) .&. 0xff) `shiftL` (8 * b))
                                    else acc) old [0, 1]
  o1 = putT n t { tReload = merge 0 (tReload t) } o

-- | ARM9IORead32 of timer 'n' at time 'now': TimerGetCounter | Cnt << 16.
oracleRead :: Int -> Int -> Oracle -> (Int, Oracle)
oracleRead now n o0 = ((tCounter t `shiftR` 10) .|. (cnt `shiftL` 16), o)
 where
  o = runTimers now o0
  t = getT o n
  cnt = case oMode o of
    Hardware -> tCnt t .&. 0xc7
    Melon -> tCnt t

-- | Bring every running timer to 'now' so its overflows are logged.
oracleFlush :: Int -> Oracle -> Oracle
oracleFlush = runTimers
