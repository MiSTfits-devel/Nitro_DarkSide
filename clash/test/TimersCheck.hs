-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds #-}

-- | Gate for Nds.WholeCore.Timers.
--
--   TimersCheck                  directed literals + seeded random, DUT vs oracle
--   TimersCheck --vectors FILE   also write the oracle's per-cycle vectors for
--                                the generated-HDL testbench (tb_ds_timers.v)
--   TimersCheck --vhdl LOG       compare DUT against a tb_gba_timer_witness.vhd log
--
-- Expected values come from literals worked by hand from melonDS and from
-- TimersOracle, which shares no code with the DUT.
module Main (main) where

import Control.Monad (forM_, unless, when)
import Data.Bits
import Data.List (foldl', sort)
import qualified Data.Map.Strict as M
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

import qualified Clash.Prelude as C
import Nds.WholeCore.Timers
import TimersOracle

-- One clock of stimulus.
data Cyc = Cyc { cTick :: Bool, cValid :: Bool, cWrite :: Bool, cWord :: Int, cLanes :: Int, cData :: Int }

idle, noTick :: Cyc
idle = Cyc True False False 0 0 0
noTick = idle { cTick = False }

rd :: Int -> Cyc
rd n = idle { cValid = True, cWord = n }

wr :: Int -> Int -> Int -> Cyc
wr n lanes d = idle { cValid = True, cWrite = True, cWord = n, cLanes = lanes, cData = d }

toIn :: Cyc -> TimersIn
toIn c = TimersIn (cTick c) (cValid c) (cWrite c) (fromIntegral (cWord c))
                  (fromIntegral (cLanes c)) (fromIntegral (cData c))

-- Per cycle: read data, IRQ bits, visible counts (all before that edge).
runDut :: [Cyc] -> [(Int, Int, [Int])]
runDut = go initialTimers
 where
  go _ [] = []
  go s (c : cs) =
    let (s', o) = timersStep s (toIn c)
    in (fromIntegral (rdata o), fromIntegral (irq o), map fromIntegral (C.toList (timersCounts s)))
       : go s' cs

-- Per cycle expected read (reads only) and IRQ (cycle, timer) pairs visible
-- inside the script: an overflow on the clock of cycle t is visible at t + 1.
runOracle :: Mode -> [Cyc] -> ([Maybe Int], [(Int, Int)])
runOracle mode script = (reverse got, filter ((< len) . fst) irqs)
 where
  len = length script
  (o, got, clocks, cycleOf) = foldl' step (newOracle mode, [], 0 :: Int, M.empty) (zip [0 ..] script)
  step (orc, acc, now, tab) (t, c) =
    let (r, orc')
          | cValid c && cWrite c = (Nothing, oracleWrite now (cWord c) (cLanes c) (cData c) orc)
          | cValid c = let (v, x) = oracleRead now (cWord c) orc in (Just v, x)
          | otherwise = (Nothing, orc)
        (now', tab') = if cTick c then (now + 1, M.insert now t tab) else (now, tab)
    in (orc', r : acc, now', tab')
  irqs = sort [ (cycleOf M.! k + 1, n) | (k, n) <- oracleOverflows (oracleFlush clocks o) ]

dutIrqs :: [(Int, Int, [Int])] -> [(Int, Int)]
dutIrqs outs = [ (t, n) | (t, (_, b, _)) <- zip [0 ..] outs, n <- [0 .. 3], testBit b n ]

type Failures = [String]

-- DUT against the Hardware-mode oracle, cycle by cycle.
differential :: String -> [Cyc] -> Failures
differential name script = readFails <> irqFails
 where
  outs = runDut script
  (expected, eIrq) = runOracle Hardware script
  readFails = take 3
    [ printf "%s: cycle %d read timer %d: dut %08x oracle %08x" name t (cWord c) r e
    | (t, c, (r, _, _), Just e) <- zip4 [0 :: Int ..] script outs expected, r /= e ]
  dIrq = dutIrqs outs
  irqFails = [ printf "%s: irq dut %s oracle %s" name (show (take 8 (diff dIrq eIrq))) (show (take 8 (diff eIrq dIrq)))
             | dIrq /= eIrq ]
  diff a b = filter (`notElem` b) a

zip4 :: [a] -> [b] -> [c] -> [d] -> [(a, b, c, d)]
zip4 (a : as) (b : bs) (c : cs) (d : ds) = (a, b, c, d) : zip4 as bs cs ds
zip4 _ _ _ _ = []

-- Directed case: a script indexed by cycle, literal reads, literal IRQs.
data Directed = Directed
  { dName  :: String
  , dLen   :: Int
  , dOps   :: [(Int, Cyc)]
  , dReads :: [(Int, Int)]     -- (cycle, expected word) for 'rd' ops
  , dIrqs  :: Maybe [(Int, Int)]
  , dMode  :: Mode             -- oracle mode the literals hold for
  }

build :: Directed -> [Cyc]
build d = [ M.findWithDefault idle t ops | t <- [0 .. dLen d - 1] ]
 where ops = M.fromList (dOps d)

checkDirected :: Directed -> Failures
checkDirected d = literal "oracle" oracleReads oracleIrqs
               <> (if dMode d == Hardware then literal "dut" dutReads dIrq <> differential (dName d) script else [])
 where
  script = build d
  outs = runDut script
  dutReads = M.fromList [ (t, r) | (t, (r, _, _)) <- zip [0 ..] outs ]
  dIrq = dutIrqs outs
  (oexp, oracleIrqs) = runOracle (dMode d) script
  oracleReads = M.fromList [ (t, v) | (t, Just v) <- zip [0 ..] oexp ]
  literal who got gotIrq =
    [ printf "%s/%s: cycle %d expected %08x got %s" (dName d) who t v (maybe "-" (printf "%08x") (M.lookup t got) :: String)
    | (t, v) <- dReads d, M.lookup t got /= Just v ]
    <> [ printf "%s/%s: irq expected %s got %s" (dName d) who (show e) (show gotIrq)
       | Just e <- [dIrqs d], e /= gotIrq ]

directed :: [Directed]
directed =
  [ -- Write lands before the same edge's clock; a read sees only earlier clocks.
    Directed "start-then-count" 7 ((0, wr 0 0xf 0x00c0fffd) : [ (t, rd 0) | t <- [1 .. 6] ])
      [(1, 0x00c0fffe), (2, 0x00c0ffff), (3, 0x00c0fffd), (4, 0x00c0fffe), (5, 0x00c0ffff), (6, 0x00c0fffd)]
      (Just [(3, 0), (6, 0)]) Hardware
  , -- Stop written on the clock that would overflow: no overflow, no IRQ.
    Directed "stop-wins-over-overflow" 6 [(0, wr 0 0xf 0x00c0fffe), (1, wr 0 0x4 0x00400000), (2, rd 0), (5, rd 0)]
      [(2, 0x0040ffff), (5, 0x0040ffff)] (Just []) Hardware
  , -- Reload written on the overflowing clock is the value reloaded.
    Directed "reload-write-on-overflow" 4 [(0, wr 0 0xf 0x00c0fffe), (1, wr 0 0x3 0x1234), (2, rd 0), (3, rd 0)]
      [(2, 0x00c01234), (3, 0x00c01235)] (Just [(2, 0)]) Hardware
  , -- A cascade start on its source's overflow clock already takes that carry.
    Directed "cascade-start-on-carry" 5 [(0, wr 0 0xf 0x0080fffe), (1, wr 1 0xf 0x00c40010), (2, rd 1), (3, rd 0), (4, rd 1)]
      [(2, 0x00c40011), (3, 0x0080ffff), (4, 0x00c40012)] (Just []) Hardware
  , -- F/64 phase is from the start write, not a free-running divider.
    Directed "f64-phase-from-start" 130 [(0, wr 0 0xf 0x00810000), (63, rd 0), (64, rd 0), (127, rd 0), (128, rd 0)]
      [(63, 0x00810000), (64, 0x00810001), (127, 0x00810001), (128, 0x00810002)] (Just []) Hardware
  , -- Changing the prescaler while running keeps the 10-bit fraction (512 here).
    Directed "prescaler-switch-keeps-fraction" 546 [(0, wr 0 0xf 0x00810000), (32, wr 0 0x4 0x00830000), (543, rd 0), (544, rd 0)]
      [(543, 0x00830000), (544, 0x00830001)] (Just []) Hardware
  , -- TICK low: the write still applies, no clock is counted.
    Directed "tick-gating" 6 [(0, (wr 0 0xf 0x0080fff0) { cTick = False }), (1, noTick), (2, noTick), (3, noTick), (4, rd 0), (5, rd 0)]
      [(4, 0x0080fff0), (5, 0x0080fff1)] (Just []) Hardware
  , -- TM0CNT_H bit 2 is stored and read back but timer 0 still runs.
    Directed "tm0-countup-ignored" 11 [(0, wr 0 0xf 0x00840100), (10, rd 0)] [(10, 0x0084010a)] (Just []) Hardware
  , -- melonDS proper: timer 0 with bit 2 never runs (documented departure).
    Directed "tm0-countup-melon-frozen" 11 [(0, wr 0 0xf 0x00840100), (10, rd 0)] [(10, 0x00840100)] (Just []) Melon
  , -- Byte lanes; unused CNT bits read 0; lane 3 alone changes nothing.
    Directed "lanes-and-masks" 8
      [ (0, wr 2 0xf 0xffffabcd), (1, rd 2), (2, wr 2 0x2 0x00001200), (3, wr 2 0x8 0), (4, rd 2)
      , (5, wr 2 0x4 0), (6, wr 2 0x4 0x00830000), (7, rd 2) ]
      [(1, 0x00c7abcd), (4, 0x00c7abcd), (7, 0x008312cd)] (Just []) Hardware
  , -- Start 1->1 does not reload; stop freezes; 0->1 reloads.
    Directed "restart" 11
      [ (0, wr 0 0xf 0x00800010), (5, wr 0 0x4 0x00800000), (6, rd 0), (7, wr 0 0x4 0), (8, rd 0)
      , (9, wr 0 0x4 0x00800000), (10, rd 0) ]
      [(6, 0x00800016), (8, 0x00000017), (10, 0x00800011)] (Just []) Hardware
  , -- Carries ripple through all four timers within one clock.
    Directed "four-timer-ripple" 9
      [(0, wr 3 0xf 0x00c4ffff), (1, wr 2 0xf 0x00c4ffff), (2, wr 1 0xf 0x00c4fffe), (3, wr 0 0xf 0x00c0ffff), (5, rd 1)]
      [(5, 0x00c4fffe)]
      (Just [(4, 0), (5, 0), (5, 1), (5, 2), (5, 3), (6, 0), (7, 0), (7, 1), (7, 2), (7, 3), (8, 0)]) Hardware
  ]

-- splitmix64
next64 :: Word -> (Word, Word)
next64 s = (z3 `xor` (z3 `shiftR` 31), s')
 where
  s' = s + 0x9e3779b97f4a7c15
  z1 = (s' `xor` (s' `shiftR` 30)) * 0xbf58476d1ce4e5b9
  z3 = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb

randomScript :: Word -> Int -> [Cyc]
randomScript seed len = go (seed * 0x2545f4914f6cdd1d + 1) len
 where
  go _ 0 = []
  go s k =
    let (r, s') = next64 s
        f lo w = fromIntegral ((r `shiftR` lo) .&. (bit w - 1)) :: Int
        tickOn = f 0 7 < 109
        kind = f 7 6
        n = f 13 2
        lanes = [0xf, 0xf, 0xf, 0xc, 0x3, 0x4, 0x4, 0x1, 0x2, 0x8, 0x6, 0x5] !! (f 15 4 `mod` 12)
        reload = case f 19 3 of
          x | x < 5 -> 0xfff0 .|. f 22 4
            | x < 7 -> 0xff00 .|. f 22 8
            | otherwise -> f 22 16
        cnt = (if f 38 3 /= 0 then 0x80 else 0) .|. (if f 41 2 < 2 then 0x04 else 0)
              .|. (if f 43 2 /= 0 then 0x40 else 0) .|. ([0, 0, 0, 1, 1, 2, 3, 0] !! f 45 3)
              .|. (if f 48 3 == 0 then f 51 10 `shiftL` 3 else 0)
        c | kind < 32 = (rd n) { cTick = tickOn }
          | kind < 42 = (wr n lanes (reload .|. cnt `shiftL` 16)) { cTick = tickOn }
          | otherwise = idle { cTick = tickOn }
    in c : go s' (k - 1)

-- Vector line: rst tick valid write word lanes data chkR rdata chkI irq (hex).
vectors :: [[Cyc]] -> [String]
vectors = concatMap one
 where
  one script =
    printf "1 0 0 0 0 0 00000000 0 00000000 0 0" :
    [ printf "0 %d %d %d %d %x %08x %d %08x 1 %x" (b (cTick c)) (b (cValid c)) (b (cWrite c)) (cWord c) (cLanes c) (cData c)
             (b chk) (maybe 0 id e) (irqAt t)
    | (t, c, e) <- zip3 [0 :: Int ..] script expected, let chk = cValid c && not (cWrite c) ]
   where
    (expected, irqs) = runOracle Hardware script
    irqMap = M.fromListWith (.|.) [ (t, bit n :: Int) | (t, n) <- irqs ]
    irqAt t = M.findWithDefault 0 t irqMap
  b x = if x then 1 else 0 :: Int

-- Shipping-RTL witness. Schedules match tb_gba_timer_witness.vhd.
scenarioA, scenarioB :: Int -> [Cyc]
scenarioA len = [ maybe idle id (lookup t ws) | t <- [0 .. len - 1] ]
 where ws = [(0, wr 3 0xf 0x00c4fffe), (1, wr 2 0xf 0x00c4fffc), (2, wr 1 0xf 0x00c4fff8), (3, wr 0 0xf 0x00c0fff0)]
scenarioB len = [ maybe idle id (lookup t ws) | t <- [0 .. len - 1] ]
 where ws = [(0, wr 0 0xf 0x00c1fff0), (1, wr 1 0xf 0x00c2fffc), (2, wr 2 0xf 0x00c3fffe), (3, wr 3 0xf 0x00c08000)]

vhdlWitness :: FilePath -> IO Failures
vhdlWitness path = do
  ls <- map words . lines <$> readFile path
  let rows tag = [ map readHex' rest | (t : _ : rest) <- ls, t == tag ]
      a = rows "A"; bRows = rows "B"; cRows = rows "C"
      lenA = length a; lenB = length bRows
      dutA = runDut (scenarioA lenA)
      dutB = runDut (scenarioB lenB)
      -- Shipping RTL: start write on cycle w loads Reload at w+2 (startwait)
      -- and debugout is two registers behind the readback, so its counts trail
      -- ours by 4; its IRP is combinational on the overflow clock, ours is
      -- registered, so IRP trails by 1.
      failsA = take 4
        [ printf "A t=%d vhdl %s dut %s" t (show row) (show (cs, ib))
        | (t, row) <- zip [0 :: Int ..] a, t >= 10
        , let (_, _, cs) = dutA !! (t - 4); (_, ib, _) = dutA !! (t - 1)
        , take 4 row /= cs || row !! 4 /= ib ]
      irqCount outs n = length [ () | (_, b, _) <- outs, testBit b n ]
      emptyA = [ printf "A: timer %d never overflowed" n | n <- [0 .. 3], irqCount dutA n == 0 ]
      -- Prescaled: phase differs by design; periods and counts must agree.
      periods = [1024, 1024, 2048, 32768] :: [Int]
      edges xs n = [ t | (t, b) <- zip [0 :: Int ..] xs, testBit b n ]
      gaps es = zipWith (-) (drop 1 es) es
      vB = map head bRows
      dB = [ b | (_, b, _) <- dutB ]
      failsB = concat
        [ [ printf "B timer %d: %s gaps %s (period %d)" n who (show (take 4 g)) p
          | (who, xs) <- [("vhdl", vB), ("dut", dB)], let g = gaps (edges xs n), length g < 1 || any (/= p) g ]
          <> [ printf "B timer %d: overflow counts vhdl %d dut %d" n (length (edges vB n)) (length (edges dB n))
             | abs (length (edges vB n) - length (edges dB n)) > 1 ]
        | (n, p) <- zip [0 ..] periods ]
      -- Reload written on the overflow clock: the shipping RTL reloads the old
      -- value (eProcReg updates on the same edge), we reload the new one.
      vC = map head cRows      -- debugout0 = readback two cycles earlier
      dutC = runDut [ maybe idle id (lookup t [(0, wr 0 0xf 0x00c0fff0), (15, wr 0 0x3 0x1234)]) | t <- [0 :: Int .. 40] ]
      countC t = let (_, _, cs) = dutC !! t in head cs
      failsC = [ printf "C: expected vhdl readback 17/18/34 = ffff/fff0/1234, dut 15/16 = ffff/1234; got vhdl %x/%x/%x dut %x/%x"
                   (vC !! 19) (vC !! 20) (vC !! 36) (countC 15) (countC 16)
               | length vC < 40 || [vC !! 19, vC !! 20, vC !! 36] /= [0xffff, 0xfff0, 0x1234]
                 || [countC 15, countC 16] /= [0xffff, 0x1234] ]
  printf "vhdl witness: A %d cycles (irqs %s), B %d cycles (irqs %s)\n" lenA
    (show [ irqCount dutA n | n <- [0 .. 3] ]) lenB (show [ length (edges vB n) | n <- [0 .. 3] ])
  pure (failsA <> emptyA <> failsB <> failsC)
 where
  readHex' s = foldl' (\acc ch -> acc * 16 + hexDigit ch) 0 s :: Int
  hexDigit ch | ch >= '0' && ch <= '9' = fromEnum ch - 48
              | ch >= 'a' && ch <= 'f' = fromEnum ch - 87
              | ch >= 'A' && ch <= 'F' = fromEnum ch - 55
              | otherwise = error ("bad hex digit " <> [ch])

randomCases :: [(Word, Int)]
randomCases = [ (s, 3000) | s <- [1 .. 300] ] <> [ (1000 + s, 60000) | s <- [1 .. 4] ]

report :: String -> Failures -> IO Bool
report name fs = do
  if null fs then printf "PASS %s\n" name else forM_ fs (hPutStrLn stderr . ("FAIL " <>))
  pure (null fs)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--vhdl", path] -> do
      ok <- vhdlWitness path >>= report "vhdl witness"
      unless ok exitFailure
    _ -> do
      oks <- mapM (\d -> report ("directed " <> dName d) (checkDirected d)) directed
      let rs = [ (s, differential (printf "random seed %d" s) (randomScript s l)) | (s, l) <- randomCases ]
          bad = concatMap snd rs
          cycles = sum (map snd randomCases)
          stats = foldl' (\acc (s, l) -> acc + length (snd (runOracle Hardware (randomScript s l)))) 0 randomCases
      okR <- report (printf "random %d scripts, %d cycles, %d oracle irqs" (length rs) cycles stats) bad
      case args of
        ["--vectors", path] -> do
          let scripts = map build directed' <> [ randomScript s l | (s, l) <- take 40 randomCases ]
                        <> [randomScript 1001 60000]
              directed' = filter ((== Hardware) . dMode) directed
          writeFile path (unlines (vectors scripts))
          printf "wrote %d vector lines to %s\n" (length scripts + sum (map length scripts)) path
        _ -> pure ()
      when (not (and oks) || not okR) exitFailure
