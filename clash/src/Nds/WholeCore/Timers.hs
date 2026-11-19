-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}

-- | One CPU's four DS timers (TM0CNT..TM3CNT at 0x04000100..0x0400010F) as a
-- standalone synthesizable endpoint. Not wired into the console, the IRQ
-- controller or any scheduler ABI; see docs/WHOLECORE_TIMERS.md.
--
-- Each timer keeps melonDS's 26-bit counter (16-bit count over a 10-bit
-- prescaler fraction, NDS.cpp RunTimer/HandleTimerOverflow). One TICK is one
-- 33.514 MHz timer clock and adds 1024, 16, 4 or 1 for F/1, F/64, F/256 and
-- F/1024. Per clock edge a bus write is applied first and that edge's tick
-- second, the order melonDS gets from RunTimers before every I/O access.
module Nds.WholeCore.Timers
  ( TimersState, TimersIn(..), TimersOut(..)
  , initialTimers, timersStep, timersCounts, timers, dsTimers, dsTimersTopEntity
  ) where

import Prelude ()
import Clash.Prelude
import qualified Clash.Explicit.Prelude as E

data TimersIn = TimersIn
  { tick     :: Bool          -- ^ one timer clock (melonDS ARM9Timestamp >> ARM9ClockShift)
  , reqValid :: Bool
  , reqWrite :: Bool
  , reqWord  :: Index 4       -- ^ (address - 0x04000100) >> 2
  , reqLanes :: BitVector 4   -- ^ byte enables of the 32-bit word
  , reqData  :: BitVector 32
  } deriving (Generic, NFDataX)

data TimersOut = TimersOut
  { rdata :: BitVector 32     -- ^ addressed word, pre-write, pre-tick
  , irq   :: BitVector 4      -- ^ one-cycle overflow pulses, bit n = timer n
  } deriving (Eq, Show, Generic, NFDataX)

data Timer = Timer
  { reload  :: BitVector 16
  , control :: BitVector 8    -- ^ TMxCNT_H & 0x00C7
  , counter :: Unsigned 26
  } deriving (Generic, NFDataX)

data TimersState = TimersState (Vec 4 Timer) (BitVector 4)
  deriving (Generic, NFDataX)

initialTimers :: TimersState
initialTimers = TimersState (repeat (Timer 0 0 0)) 0

-- | Visible 16-bit counts, for witnesses only.
timersCounts :: TimersState -> Vec 4 (BitVector 16)
timersCounts (TimersState ts _) = map (slice d25 d10 . pack . counter) ts

timersStep :: TimersState -> TimersIn -> (TimersState, TimersOut)
timersStep (TimersState ts pulses) i = (TimersState ticked irqs, TimersOut word pulses)
 where
  word = let t = ts !! reqWord i in zeroExtend (control t) ++# slice d25 d10 (pack (counter t))
  written = imap (\n t -> if reqValid i && reqWrite i && n == reqWord i then writeTimer t else t) ts
  writeTimer t = t { reload = reload', control = control', counter = counter' }
   where
    lanes = reqLanes i
    bytes = unpack (reqData i) :: Vec 4 (BitVector 8)
    old = unpack (reload t) :: Vec 2 (BitVector 8)
    pick l = if testBit lanes l then bytes !! (3 - l) else old !! (1 - l)
    reload' = pick 1 ++# pick 0
    -- Lane 3 holds only unused TMxCNT_H bits 8-15.
    control' = if testBit lanes 2 then slice d23 d16 (reqData i) .&. 0xc7 else control t
    counter'
      | not (testBit (control t) 7) && testBit control' 7 = unpack (reload' ++# 0)
      | otherwise = counter t
  (ticked, ovf) = if tick i then unzip (snd (mapAccumL advance False (zip indicesI written)))
                            else (written, repeat False)
  irqs = pack (reverse (zipWith (\t o -> o && testBit (control t) 6) ticked ovf))

-- | Carry-in is the previous timer's overflow on this tick; carry-out is ours.
advance :: Bool -> (Index 4, Timer) -> (Bool, (Timer, Bool))
advance carry (n, t)
  | not (testBit ctl 7) = (False, (t, False))
  | cascade && not carry = (False, (t, False))
  | otherwise = (over, (t { counter = counter' }, over))
 where
  ctl = control t
  -- TM0CNT_H bit 2 is stored but unused (shipping rtl/gba_timer_module.vhd).
  cascade = n /= 0 && testBit ctl 2
  step :: Unsigned 27
  step | cascade = 1024
       | otherwise = case slice d1 d0 ctl of
           0 -> 1024
           1 -> 16
           2 -> 4
           _ -> 1
  total = zeroExtend (counter t) + step
  over = testBit total 26
  -- Increments never exceed 1024, so the wrapped residue is only fraction.
  -- melonDS keeps it on a prescaled overflow and drops it on a cascaded one.
  frac = if cascade then 0 else truncateB total .&. 0x3ff
  counter'
    | over = unpack (reload t ++# 0) .|. frac
    | otherwise = truncateB total

timers :: HiddenClockResetEnable dom => Signal dom TimersIn -> Signal dom TimersOut
timers = dsTimers hasClock hasReset hasEnable

dsTimers
  :: KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom TimersIn -> Signal dom TimersOut
dsTimers clk rst en input = out
 where
  state = E.register clk rst en initialTimers next
  (next, out) = unbundle (timersStep <$> state <*> input)

{-# ANN dsTimersTopEntity
  (Synthesize
    { t_name = "nds_ds_timers"
    , t_inputs = [ PortName "CLK", PortName "RST", PortName "EN", PortName "TICK"
                 , PortName "REQ_VALID", PortName "REQ_WRITE", PortName "REQ_WORD"
                 , PortName "REQ_LANES", PortName "REQ_DATA" ]
    , t_output = PortProduct "" [ PortName "RDATA", PortName "IRQ" ]
    }) #-}
dsTimersTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System Bool -> Signal System Bool -> Signal System Bool
  -> Signal System (Index 4) -> Signal System (BitVector 4) -> Signal System (BitVector 32)
  -> Signal System TimersOut
dsTimersTopEntity clk rst en tk valid write wordI lanes dat =
  dsTimers clk rst en (TimersIn <$> tk <*> valid <*> write <*> wordI <*> lanes <*> dat)
