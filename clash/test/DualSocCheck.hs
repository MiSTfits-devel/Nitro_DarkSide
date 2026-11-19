-- SPDX-License-Identifier: GPL-3.0-or-later
-- Two-CPU fixture on the pure Nds.WholeCore.DualSoc ('dualStep'):
--
--   dual-soc-check BOOT9.hex BOOT7.hex CARD.hex EXPECT9 EXPECT7
--                  [--seed N] [--latency MIN MAX] [--stall PCT] [--card-stall PCT]
--
-- The ARM9 boot ROM (0xFFFF0000) and the ARM7 boot ROM (0) are served
-- combinationally; the card image (direct-boot strap, chip ID 0x1FC2) sits
-- behind the card's image port with random delays. Main RAM (4 KiB at
-- 0x02000000, zero at power-up) is behind the SoC's memory port: each
-- cycle the request is accepted with probability 1 - stall/100; an
-- accepted request takes effect at once, in acceptance order, and its
-- response (writes included) arrives in order, MIN..MAX cycles later.
--
-- Checks: no CPU fault and no external link request; ARM9 stores to
-- 0x02000000-0x020000FF and ARM7 stores to 0x02000100-0x020001FF are
-- mailbox slots, in slot order, equal to EXPECT9 / EXPECT7, and neither CPU
-- stores into the other's mailbox; after both mailboxes are complete 4000
-- quiet cycles pass. The memory port holds an unaccepted request unchanged,
-- never answers more than it accepted, and every request is inside the
-- RAM window. Bounded wait: while a core has a memory request outstanding
-- (from the cycle it is first offered to its acceptance), the arbiter grants
-- the other core at most once.
module Main (main) where

import Clash.Prelude (rnfX)
import Control.Monad (unless, when)
import Data.Bits ((.&.), (.|.), complement, shiftL, shiftR, xor)
import qualified Data.IntMap.Strict as IM
import Data.Word (Word32, Word64)
import Numeric (readHex)
import System.Environment (getArgs)
import Text.Printf (printf)
import Nds.WholeCore.Arm9Slice (SliceOut(..))
import Nds.WholeCore.Arm9Io (IoOut(..))
import Nds.WholeCore.Card (CardIn(..), CardOut(..))
import Nds.WholeCore.DualSoc

data Opts = Opts { optSeed :: Word64, optLatMin, optLatMax, optStall, optCardStall :: Int }

hexWord :: String -> IO Word32
hexWord s = case readHex s of
  [(n, "")] -> pure n
  _ -> fail ("bad hex word: " ++ s)

readWords :: FilePath -> IO [Word32]
readWords path = do
  text <- readFile path
  mapM hexWord [w | l <- lines text, (w:_) <- [words (takeWhile (/= '#') l)]]

check :: String -> Bool -> IO ()
check label ok = unless ok (fail label)

w32 :: Integral a => a -> Word32
w32 = fromIntegral

-- SplitMix64.
next64 :: Word64 -> (Word64, Word64)
next64 s = (z3, s')
 where
  s' = s + 0x9e3779b97f4a7c15
  z1 = (s' `xor` (s' `shiftR` 30)) * 0xbf58476d1ce4e5b9
  z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb
  z3 = z2 `xor` (z2 `shiftR` 31)

below :: Int -> Word64 -> (Int, Word64)
below n g = let (x, g') = next64 g in (fromIntegral (x `mod` fromIntegral (max 1 n)), g')

parse :: [String] -> Opts -> IO Opts
parse [] o = pure o
parse ("--seed" : n : r) o = parse r o { optSeed = read n }
parse ("--latency" : a : b : r) o = parse r o { optLatMin = read a, optLatMax = read b }
parse ("--stall" : p : r) o = parse r o { optStall = read p }
parse ("--card-stall" : p : r) o = parse r o { optCardStall = read p }
parse _ _ = fail "usage: dual-soc-check BOOT9 BOOT7 CARD EXPECT9 EXPECT7 [--seed N] [--latency MIN MAX] [--stall PCT] [--card-stall PCT]"

-- | Harness state besides the SoC.
data H = H
  { tick      :: !Int
  , rng       :: !Word64
  , ram       :: !(IM.IntMap Word32)
  , resps     :: ![(Int, Word32)]          -- ^ due cycle and data, in order
  , lastDue   :: !Int
  , heldReq   :: !(Maybe MemReq)
  , cardReq   :: !(Maybe (Int, Word32))    -- ^ image word in flight: due cycle, address
  , slots9    :: !Int
  , slots7    :: !Int
  , doneAt    :: !(Maybe Int)
  , wait9     :: !(Maybe Int)              -- ^ grants to the ARM7 while the ARM9 waits
  , wait7     :: !(Maybe Int)
  , maxWait   :: !Int
  , steps9    :: !Int
  , steps7    :: !Int
  , grants    :: !Int
  , accepted  :: !Int
  , lastStore :: !Int                     -- ^ cycle of the last mailbox store
  , staleMerges :: !Int                   -- ^ writes whose bytes outside their lanes were stale
  }

main :: IO ()
main = do
  args <- getArgs
  (b9p, b7p, cardp, e9p, e7p, rest) <- case args of
    a : b : c : d : e : more -> pure (a, b, c, d, e, more)
    _ -> fail "usage: dual-soc-check BOOT9 BOOT7 CARD EXPECT9 EXPECT7 [options]"
  opts <- parse rest (Opts 1 1 1 0 0)
  boot9 <- IM.fromList . zip [0 ..] <$> readWords b9p
  boot7 <- IM.fromList . zip [0 ..] <$> readWords b7p
  image <- IM.fromList . zip [0 ..] <$> readWords cardp
  exp9 <- readWords e9p
  exp7 <- readWords e7p
  let rom base m a
        | a >= base && a - base < 0x1000 = IM.findWithDefault 0 (fromIntegral ((a - base) `shiftR` 2)) m
        | otherwise = 0xe7f000f0
      straps = CardIn True True 0x00001fc2 0xffff False False 0
      loop :: H -> DualState -> IO ()
      loop h st = do
        check (printf "timeout: ARM9 %d/%d, ARM7 %d/%d mailbox words" (slots9 h) (length exp9) (slots7 h) (length exp7))
          (tick h < 3000000)
        let t = tick h
            -- The boot ROMs answer the address the current state presents.
            probe = snd (dualStep st (DualIn 0 0 False False 0 False 0 straps False False 0))
            bootAddr9 = w32 (bootAddr (cpu9 probe))
            bootAddr7 = w32 (bootAddr (cpu7 probe))
            (rStall, g1) = below 100 (rng h)
            (rCard, g2) = below 100 g1
            (rLat, g3) = below (optLatMax opts - optLatMin opts + 1) g2
            (rCardLat, g4) = below 4 g3
            memReady = rStall >= optStall opts
            respNow = case resps h of
              (due, d) : _ | due <= t -> Just d
              _ -> Nothing
            cardReady = rCard >= optCardStall opts && cardReq h == Nothing
            cardReply = case cardReq h of
              Just (due, a) | due <= t -> Just (IM.findWithDefault 0 (fromIntegral (a `shiftR` 2)) image)
              _ -> Nothing
            input = DualIn
              { boot9Word = fromIntegral (rom 0xffff0000 boot9 bootAddr9)
              , boot7Word = fromIntegral (rom 0 boot7 bootAddr7)
              , gpuReqReady9 = False, gpuReplyValid9 = False, gpuReplyData9 = 0, gpuReplyFault9 = False
              , irqSet9 = 0
              , cardIn = straps { cardRomReady = cardReady, cardRomReplyValid = cardReply /= Nothing
                                , cardRomReplyData = maybe 0 fromIntegral cardReply }
              , memReqReady = memReady
              , memRespValid = respNow /= Nothing
              , memRespData = maybe 0 fromIntegral respNow }
            (st', out) = dualStep st input
            c9 = cpu9 out
            c7 = cpu7 out
            req = memReq out
            av = arb out
        -- CPUs
        check (printf "ARM9 fault %d at %08x (cycle %d)" (w32 (fault c9)) (w32 (faultAddr c9)) t) (fault c9 == 0)
        check (printf "ARM7 fault %d at %08x (cycle %d)" (w32 (fault c7)) (w32 (faultAddr c7)) t) (fault c7 == 0)
        check (printf "unexpected external link request at %08x" (w32 (gpuReqAddr c9))) (not (extReqValid (io9 out)))
        -- Memory port protocol
        case heldReq h of
          Just r -> check (printf "memory request changed while not accepted (cycle %d)" t) (req == r)
          Nothing -> pure ()
        when (memReqValid req) $
          check (printf "memory request outside the RAM window: %08x" (w32 (memReqAddr req)))
            (w32 (memReqAddr req) .&. 0xfffff000 == 0x02000000 && w32 (memReqAddr req) .&. 3 == 0)
        let acc = memReqValid req && memReady
            ix = fromIntegral ((w32 (memReqAddr req) .&. 0xfff) `shiftR` 2) :: Int
            old = IM.findWithDefault 0 ix (ram h)
            lanes = w32 (memReqLanes req)
            laneMask = foldr (.|.) 0 [0xff `shiftL` (8 * k) | k <- [0 .. 3], lanes .&. (1 `shiftL` k) /= 0]
            ram' | acc && memReqWrite req = IM.insert ix ((old .&. complement laneMask) .|. (w32 (memReqData req) .&. laneMask)) (ram h)
                 | otherwise = ram h
            -- A write whose bytes outside its lanes differ from memory: the
            -- other CPU wrote that word between this core's read and its
            -- write, so a whole-word write here would have lost its bytes.
            stale = acc && memReqWrite req && (w32 (memReqData req) .&. complement laneMask) /= (old .&. complement laneMask)
            due = max (lastDue h + 1) (t + optLatMin opts + rLat)
            resps0 = case (resps h, respNow) of
              (_ : more, Just _) -> more
              (q, _) -> q
            resps' = if acc then resps0 ++ [(due, if memReqWrite req then 0 else old)] else resps0
        -- Bounded wait: grants to the other core while one waits.
        let granted7 = grant av == Just True
            granted9 = grant av == Just False
            track waiting want mine other = case waiting of
              _ | mine -> Nothing
              Just n -> Just (if other then n + 1 else n)
              Nothing | want -> Just (if other then 1 else 0)
              Nothing -> Nothing
            w9' = track (wait9 h) (want9 av) granted9 granted7
            w7' = track (wait7 h) (want7 av) granted7 granted9
            worst = maximum [maxWait h, maybe 0 id w9', maybe 0 id w7']
        check (printf "arbiter starvation: the ARM9 waited through %d ARM7 grants (cycle %d)" (maybe 0 id w9') t)
          (maybe 0 id w9' <= 1)
        check (printf "arbiter starvation: the ARM7 waited through %d ARM9 grants (cycle %d)" (maybe 0 id w7') t)
          (maybe 0 id w7' <= 1)
        -- Card image port
        let cardReq'
              | cardRomReqValid (card out) && cardReady = Just (t + 1 + rCardLat, w32 (cardRomAddr (card out)))
              | cardReply /= Nothing = Nothing
              | otherwise = cardReq h
        -- Mailboxes
        s9 <- mailbox "ARM9" c9 0x02000000 exp9 (slots9 h)
        s7 <- mailbox "ARM7" c7 0x02000100 exp7 (slots7 h)
        check "ARM9 stored into the ARM7 mailbox" (not (storeValid c9 && inBox 0x02000100 (w32 (storeAddr c9))))
        check "ARM7 stored into the ARM9 mailbox" (not (storeValid c7 && inBox 0x02000000 (w32 (storeAddr c7))))
        -- A guest that stops storing (a mailbox phase waiting forever) fails
        -- here, before the run grows to the cycle limit.
        let progress = s9 /= slots9 h || s7 /= slots7 h
        check (printf "no mailbox progress for 400000 cycles: ARM9 %d/%d, ARM7 %d/%d" s9 (length exp9) s7 (length exp7))
          (progress || t - lastStore h < 400000)
        let complete = s9 == length exp9 && s7 == length exp7
            doneAt' = if complete && doneAt h == Nothing then Just t else doneAt h
            h' = h { tick = t + 1, rng = g4, ram = ram', resps = resps'
                   , lastDue = if acc then due else lastDue h
                   , heldReq = if memReqValid req && not memReady then Just req else Nothing
                   , cardReq = cardReq', slots9 = s9, slots7 = s7, doneAt = doneAt'
                   , wait9 = w9', wait7 = w7', maxWait = worst
                   , steps9 = steps9 h + fromEnum (step9 av), steps7 = steps7 h + fromEnum (step7 av)
                   , grants = grants h + fromEnum (grant av /= Nothing), accepted = accepted h + fromEnum acc
                   , staleMerges = staleMerges h + fromEnum stale }
        case doneAt' of
          Just d | t - d >= 4000 -> do
            check "no write ever carried stale bytes outside its lanes: the byte-lane interleaving was not exercised"
              (staleMerges h' > 0)
            printf "PASS: ARM9 %d and ARM7 %d mailbox words; %d cycles, %d ARM9 and %d ARM7 steps, %d memory requests (%d byte writes kept the other CPU's newer bytes); at most %d grant(s) to the other core while one waited\n"
              s9 s7 t (steps9 h') (steps7 h') (accepted h') (staleMerges h') (maxWait h')
          _ -> rnfX st' `seq` loop h' { lastStore = if progress then t else lastStore h } st'
      mailbox :: String -> SliceOut -> Word32 -> [Word32] -> Int -> IO Int
      mailbox name c base expect n
        | storeValid c && inBox base (w32 (storeAddr c)) = do
            let a = w32 (storeAddr c)
                v = w32 (storeData c)
                k = fromIntegral ((a - base) `div` 4)
            check (printf "%s store after its mailbox: %08x=%08x" name a v) (n < length expect)
            check (printf "%s mailbox store out of order: slot %d, expected slot %d" name k n) (k == n)
            printf "%s RAM[%d]=%08x\n" name (4 * k) v
            check (printf "%s slot %d: got %08x, expected %08x" name k v (expect !! k)) (v == expect !! k)
            pure (n + 1)
        | otherwise = pure n
      inBox base a = a >= base && a < base + 0x100
  loop (H 0 (optSeed opts) IM.empty [] 0 Nothing Nothing 0 0 Nothing Nothing Nothing 0 0 0 0 0 0 0) initialDual
