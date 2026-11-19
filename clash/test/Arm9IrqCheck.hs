-- SPDX-License-Identifier: GPL-3.0-or-later
-- IRQ fixtures on the pure Arm9Soc ('socStep'): the assembled program, a
-- timer clock on odd cycles, and this harness's external IF sources, each
-- enabled by an option and required to fire:
--   * --link-read: the only allowed link request, a word read of
--     0x06000000, is held for 8 cycles and answered 4 cycles after
--     acceptance with 13579bdf; IF bit 0 (VBlank) is raised in the cycle it
--     is first offered. Without it any link request fails.
--   * --store-irq ADDR MASK: IF |= MASK in the cycle the CPU first reports
--     a store to ADDR.
--   * --irq-before PC MASK: IF |= MASK so that the IRQ line is first high
--     in the first cycle in which the instruction at PC (its first
--     execution) is the oldest uncommitted instruction, so the IRQ must be
--     taken at the boundary just before it. Placed from the core's retire
--     stream, not from pipeline timing: a probe run without this source
--     finds the cycle P in which the instruction retired just before PC is
--     reported. Retire is reported in the cycle after commit, one
--     instruction per cycle in order, so PC is still uncommitted at P. IF
--     is a register (a source raised in cycle t drives the line from t+1),
--     so the real run raises it in cycle P-1. Everything before P is the
--     same in both runs; the real run requires the predecessor's retire
--     again at P and the IRQ vector (0xffff0018) as the very next retire.
-- Mailbox slot k is RAM word k and must equal EXPECTED in order; words 0x30
-- to 0x3f are scratch; no store may follow the last mailbox word. The run
-- must then stay quiet, or (--fault CODE ADDR) stop with exactly that fault.
module Main (main) where

import Control.Monad (unless, when)
import Data.Bits ((.&.), (.|.))
import Data.Word (Word32)
import Numeric (readHex)
import System.Environment (getArgs)
import Text.Printf (printf)
import Nds.WholeCore.Arm9Io
import Nds.WholeCore.Arm9Slice
import Nds.WholeCore.Arm9Soc

data Opts = Opts
  { optLink   :: Bool
  , optStore  :: Maybe (Word32, Word32)
  , optBefore :: Maybe (Word32, Word32)
  , optFault  :: Maybe (Word32, Word32)
  }

-- | Where the --irq-before source fires: raise MASK in cycle 'trigAt'; the
-- predecessor of the target retires at 'predAt' with PC 'predPc'.
data Trigger = Trigger { trigAt :: Int, predAt :: Int, predPc :: Word32, trigMask :: Word32 }

-- | A probe run (no --irq-before source, silent) looking for the first
-- retire of a PC, or the real run with the trigger, if any.
data Mode = Probe Word32 | Real (Maybe Trigger)

data Link = Link
  { seenAt      :: Maybe Int   -- ^ first cycle the read was offered
  , acceptedAt  :: Maybe Int
  , replied     :: Bool
  , storeFired  :: Bool
  , lastRetire  :: Maybe (Int, Word32)   -- ^ cycle and PC of the last reported retire
  , beforeFired :: Bool        -- ^ the IRQ vector retired right after the predecessor
  }

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

usage :: String
usage = "usage: arm9-irq-check ROM.hex EXPECTED [--link-read] [--store-irq ADDR MASK]"
  ++ " [--irq-before PC MASK] [--fault CODE ADDR]"

parse :: [String] -> Opts -> IO Opts
parse [] o = pure o
parse ("--link-read" : r) o = parse r o { optLink = True }
parse ("--store-irq" : a : m : r) o = do
  p <- (,) <$> hexWord a <*> hexWord m
  parse r o { optStore = Just p }
parse ("--irq-before" : a : m : r) o = do
  p <- (,) <$> hexWord a <*> hexWord m
  parse r o { optBefore = Just p }
parse ("--fault" : c : a : r) o = do
  p <- (,) <$> hexWord c <*> hexWord a
  parse r o { optFault = Just p }
parse _ _ = fail usage

irqVector :: Word32
irqVector = 0xffff0018

main :: IO ()
main = do
  args <- getArgs
  (romPath, expectPath, opts) <- case args of
    r : e : more -> (\o -> (r, e, o)) <$> parse more (Opts False Nothing Nothing Nothing)
    _ -> fail usage
  rom <- readWords romPath
  expected <- readWords expectPath
  trigger <- case optBefore opts of
    Nothing -> pure Nothing
    Just (pc, mask) -> do
      found <- simulate opts rom expected (Probe pc)
      case found of
        Just (p, prev) | p >= 1 -> pure (Just (Trigger (p - 1) p prev mask))
        _ -> fail (printf "--irq-before %08x: no instruction retired before it" pc)
  _ <- simulate opts rom expected (Real trigger)
  pure ()

-- | One run from reset. A probe returns the cycle and PC of the retire
-- reported just before the first retire of its PC.
simulate :: Opts -> [Word32] -> [Word32] -> Mode -> IO (Maybe (Int, Word32))
simulate opts rom expected mode = loop 0 0 Nothing (Link Nothing Nothing False False Nothing False) initialSoc
 where
  total = length expected
  want = optFault opts
  scratch = 0x30 :: Int
  quiet = case mode of Probe _ -> True; Real _ -> False
  trigger = case mode of Real t -> t; Probe _ -> Nothing
  say :: String -> IO ()
  say line = unless quiet (putStrLn line)
  fetch addr
    | addr >= 0xffff0000 && addr < 0xffff0000 + 4 * w32 (length rom) =
        rom !! fromIntegral ((addr - 0xffff0000) `div` 4)
    | otherwise = 0xe7f000f0
  fires src fired hit = maybe False (const (hit && not fired)) src
  loop :: Int -> Int -> Maybe Int -> Link -> SocState -> IO (Maybe (Int, Word32))
  loop tick stores doneAt link state = do
    check (printf "timeout after %d stores" stores) (tick < 400000)
    let boot = fromIntegral (fetch (w32 (socBootAddr state)))
        idle = SocIn boot False False 0 False (odd tick) 0 0 noCartridge
        -- The fields the device reacts to depend only on registered state.
        probe = snd (socStep state idle)
        cpu0 = socCpu probe
        io0 = socIo probe
        offered = extReqValid io0
        firstOffer = optLink opts && offered && seenAt link == Nothing
        seen = maybe tick id (seenAt link)
        ready = optLink opts && offered && acceptedAt link == Nothing && tick - seen >= 8
        replyValid = maybe False (\a -> tick - a >= 4) (acceptedAt link) && not (replied link)
        storeHit = fires (optStore opts) (storeFired link)
          (storeValid cpu0 && Just (w32 (storeAddr cpu0)) == fmap fst (optStore opts))
        beforeHit = maybe False ((== tick) . trigAt) trigger
        irqSet = (if firstOffer then 1 else 0)
          .|. (if storeHit then maybe 0 snd (optStore opts) else 0)
          .|. (if beforeHit then maybe 0 trigMask trigger else 0)
        input = idle { socGpuReqReady = ready, socGpuReplyValid = replyValid
                     , socGpuReplyData = 0x13579bdf, socIrqSet = fromIntegral irqSet }
        (state', out) = socStep state input
        cpu = socCpu out
        io = socIo out
        retired = if retireValid cpu then Just (tick, w32 (retirePc cpu)) else Nothing
    when offered $
      check (printf "unexpected link request %s%d %08x" (if gpuReqWrite cpu then "W" else "R" :: String)
               (w32 (gpuReqWidth cpu)) (w32 (gpuReqAddr cpu)))
        (optLink opts && not (gpuReqWrite cpu) && gpuReqWidth cpu == 4
         && w32 (gpuReqAddr cpu) == 0x06000000 && not (replied link))
    check "IRQ level differs from IME && IE & IF" (irqLine io == (regIME io && regIE io .&. regIF io /= 0))
    -- --irq-before: the predecessor retires at the probed cycle again, and
    -- the IRQ vector is the next instruction to retire.
    beforeOk <- case (trigger, retired) of
      (Just t, _) | tick == predAt t -> do
        check (printf "run diverged from the --irq-before probe: cycle %d retired %s, expected %08x"
                 tick (maybe "nothing" (printf "%08x" . snd) retired :: String) (predPc t))
          (fmap snd retired == Just (predPc t))
        pure False
      (Just t, Just (_, pc)) | tick > predAt t && not (beforeFired link) && maybe False ((== predAt t) . fst) (lastRetire link) -> do
        check (printf "IRQ not taken just before the --irq-before instruction: %08x retired after %08x" pc (predPc t))
          (pc == irqVector)
        pure True
      _ -> pure False
    case (mode, retired) of
      (Probe target, Just (_, pc)) | pc == target -> pure (lastRetire link)
      _ -> do
        stores' <- if not (storeValid cpu) then pure stores else do
          let a = w32 (storeAddr cpu)
              v = w32 (storeData cpu)
              index = fromIntegral ((a - 0x02000000) `div` 4) :: Int
          check (printf "store %08x=%08x after the mailbox" a v) (stores < total)
          if index >= scratch && index < 64 then pure stores else do
            check (printf "store %d at %08x" stores a) (a == 0x02000000 + 4 * w32 stores)
            say (printf "ARM9 RAM[%d]=%08x" (stores * 4) v)
            check (printf "slot %d: got %08x, expected %08x" stores v (expected !! stores))
              (v == expected !! stores)
            pure (stores + 1)
        let link' = link
              { seenAt = if firstOffer then Just tick else seenAt link
              , acceptedAt = if ready then Just tick else acceptedAt link
              , replied = replied link || (replyValid && extReplyReady io)
              , storeFired = storeFired link || storeHit
              , lastRetire = maybe (lastRetire link) Just retired
              , beforeFired = beforeFired link || beforeOk }
            doneAt' = if stores' == total && doneAt == Nothing then Just tick else doneAt
            code = w32 (fault cpu)
            finished = do
              check "link read source not exercised" (not (optLink opts) || replied link')
              check "store IRQ source not exercised" (optStore opts == Nothing || storeFired link')
              check "--irq-before source not exercised" (optBefore opts == Nothing || beforeFired link')
        if quiet && (code /= 0 || maybe False (\t -> tick - t >= 500) doneAt') then pure Nothing
        else if code /= 0 then do
          check (printf "fault %d at %08x after %d stores" code (w32 (faultAddr cpu)) stores')
            (want == Just (code, w32 (faultAddr cpu)) && stores' == total)
          finished
          printf "PASS: fault %d at %08x after %d stores\n" code (w32 (faultAddr cpu)) total
          pure Nothing
        else case doneAt' of
          Just t | tick - t >= 500 -> do
            check "expected fault did not occur" (want == Nothing)
            finished
            printf "PASS: %d mailbox stores, IRQ fixture on pure Arm9Soc\n" total
            pure Nothing
          _ -> loop (tick + 1) stores' doneAt' link' state'
