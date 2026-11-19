module Main (main) where

import Control.Monad (unless)
import Data.Bits
import Data.Word
import qualified Nds.Gpu3D.Chip as C
import Nds.Gpu3D.GxFront (Size(..))
import Nds.Gpu3D.Timed

must :: Either String a -> IO a
must = either fail pure
check :: String -> Bool -> IO ()
check label ok = unless ok (fail label)
write :: Word32 -> Word32 -> TimedChip -> IO TimedChip
write a v t = fst <$> must (timedWrite S32 a v t)
advance :: Word64 -> TimedChip -> IO (TimedChip,[TimedEffect])
advance n = must . timedAdvance n
status :: TimedChip -> Word32
status = timedRead S32 0x04000600
fresh :: TimedChip
fresh = timedPower True True (initTimedChip 0)

main :: IO ()
main = do
  -- Matrix identity costs 1 entry cycle +18 projection work; it does not
  -- complete merely because the following CPU access polls GXSTAT.
  m <- write 0x04000454 0 fresh
  (m0,_) <- advance 0 m
  check "identity deadline19" (timedDeadline m0 == Just 19)
  (m18,_) <- advance 18 m0
  check "busy before matrix completion" (testBit (status m18) 27)
  (m19,_) <- advance 19 m18
  check "matrix completion clears busy" (not (testBit (status m19) 27))
  check "reject backwards time" (case timedAdvance 18 m19 of Left _ -> True; _ -> False)

  -- POS_TEST has two distinct FIFO accepts. Results become the executed
  -- command's values, while the queued test busy bit persists until its
  -- scheduled completion (1 + 1 + 5 cycles).
  p1 <- write 0x040005c4 0x22221111 fresh
  p2 <- write 0x040005c4 0x00003333 p1
  (p0,_) <- advance 0 p2
  check "first parameter deadline1" (timedDeadline p0 == Just 1)
  (pAt1,_) <- advance 1 p0
  check "position result from real geometry" (timedRead S32 0x04000620 pAt1 == 0x1111)
  check "test remains busy" (testBit (status pAt1) 0)
  check "POS completion deadline7" (timedDeadline pAt1 == Just 7)
  (p7,_) <- advance 7 pAt1
  check "test busy clears at7" (not (testBit (status p7) 0))

  -- Refill pulses must survive an MMIO transaction at the same timestamp.
  q <- write 0x04000600 0x80000000 fresh
  q1 <- write 0x04000480 0x1234 q
  (q0,effects) <- advance 0 q1
  check "empty FIFO IRQ and DMA pulse" (effects == [GxIrq True,GxDma])
  check "same-time busy/empty queue is exact" (status q0 == 0x8e000000 && timedRead S16 0x04000602 q0 == 0x8e00 && timedDeadline q0 == Just 1)
  check "cannot collapse skipped deadline" (case timedAdvance 2 q0 of Left _ -> True; _ -> False)
  (qAt1,_) <- advance 1 q0
  check "next-time completed/empty queue is exact" (status qAt1 == 0x86000000 && timedDeadline qAt1 == Nothing)

  -- A real 261st pending word stalls. VBlank releases swap, but the first
  -- command leaves PIPE level3, so only the next refill unstalls the bus.
  sw <- write 0x04000540 0 fresh
  (sw0,_) <- advance 0 sw
  full <- foldl (\io _ -> io >>= write 0x04000480 1) (pure sw0) [1..261 :: Int]
  check "FIFO actually stalls" (C.chipStalled (tcChip full))
  check "swap has no artificial progress deadline" (timedDeadline full == Nothing)
  let vb = timedVBlank full
  check "swap resumes325-cycle delay" (timedDeadline vb == Just 325)
  (s325,_) <- advance 325 vb
  check "no premature unstall before refill" (C.chipStalled (tcChip s325))
  (s326,_) <- advance 326 s325
  check "refill releases pending write" (not (C.chipStalled (tcChip s326)))
  putStrLn "timed-check: matrix19, POS7, same-time DMA/IRQ, exact FIFO stall/refill, monotonic/deadline guards: PASS"
