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
--   * --retire-irq PC MASK: IF |= MASK in the cycle the CPU first retires
--     the instruction at PC.
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
  , optRetire :: Maybe (Word32, Word32)
  , optFault  :: Maybe (Word32, Word32)
  }

data Link = Link
  { seenAt     :: Maybe Int   -- ^ first cycle the read was offered
  , acceptedAt :: Maybe Int
  , replied    :: Bool
  , storeFired :: Bool
  , retireFired :: Bool
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
  ++ " [--retire-irq PC MASK] [--fault CODE ADDR]"

parse :: [String] -> Opts -> IO Opts
parse [] o = pure o
parse ("--link-read" : r) o = parse r o { optLink = True }
parse ("--store-irq" : a : m : r) o = do
  p <- (,) <$> hexWord a <*> hexWord m
  parse r o { optStore = Just p }
parse ("--retire-irq" : a : m : r) o = do
  p <- (,) <$> hexWord a <*> hexWord m
  parse r o { optRetire = Just p }
parse ("--fault" : c : a : r) o = do
  p <- (,) <$> hexWord c <*> hexWord a
  parse r o { optFault = Just p }
parse _ _ = fail usage

main :: IO ()
main = do
  args <- getArgs
  (romPath, expectPath, opts) <- case args of
    r : e : more -> (\o -> (r, e, o)) <$> parse more (Opts False Nothing Nothing Nothing)
    _ -> fail usage
  rom <- readWords romPath
  expected <- readWords expectPath
  let total = length expected
      want = optFault opts
      scratch = 0x30 :: Int
      fetch addr
        | addr >= 0xffff0000 && addr < 0xffff0000 + 4 * w32 (length rom) =
            rom !! fromIntegral ((addr - 0xffff0000) `div` 4)
        | otherwise = 0xe7f000f0
      fires src fired hit = maybe False (const (hit && not fired)) src
      loop :: Int -> Int -> Maybe Int -> Link -> SocState -> IO ()
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
            retireHit = fires (optRetire opts) (retireFired link)
              (retireValid cpu0 && Just (w32 (retirePc cpu0)) == fmap fst (optRetire opts))
            irqSet = (if firstOffer then 1 else 0)
              .|. (if storeHit then maybe 0 snd (optStore opts) else 0)
              .|. (if retireHit then maybe 0 snd (optRetire opts) else 0)
            input = idle { socGpuReqReady = ready, socGpuReplyValid = replyValid
                         , socGpuReplyData = 0x13579bdf, socIrqSet = fromIntegral irqSet }
            (state', out) = socStep state input
            cpu = socCpu out
            io = socIo out
        when offered $
          check (printf "unexpected link request %s%d %08x" (if gpuReqWrite cpu then "W" else "R" :: String)
                   (w32 (gpuReqWidth cpu)) (w32 (gpuReqAddr cpu)))
            (optLink opts && not (gpuReqWrite cpu) && gpuReqWidth cpu == 4
             && w32 (gpuReqAddr cpu) == 0x06000000 && not (replied link))
        check "IRQ level differs from IME && IE & IF" (irqLine io == (regIME io && regIE io .&. regIF io /= 0))
        stores' <- if not (storeValid cpu) then pure stores else do
          let a = w32 (storeAddr cpu)
              v = w32 (storeData cpu)
              index = fromIntegral ((a - 0x02000000) `div` 4) :: Int
          check (printf "store %08x=%08x after the mailbox" a v) (stores < total)
          if index >= scratch && index < 64 then pure stores else do
            check (printf "store %d at %08x" stores a) (a == 0x02000000 + 4 * w32 stores)
            printf "ARM9 RAM[%d]=%08x\n" (stores * 4) v
            check (printf "slot %d: got %08x, expected %08x" stores v (expected !! stores))
              (v == expected !! stores)
            pure (stores + 1)
        let link' = link
              { seenAt = if firstOffer then Just tick else seenAt link
              , acceptedAt = if ready then Just tick else acceptedAt link
              , replied = replied link || (replyValid && extReplyReady io)
              , storeFired = storeFired link || storeHit
              , retireFired = retireFired link || retireHit }
            doneAt' = if stores' == total && doneAt == Nothing then Just tick else doneAt
            code = w32 (fault cpu)
            finished = do
              check "link read source not exercised" (not (optLink opts) || replied link')
              check "store IRQ source not exercised" (optStore opts == Nothing || storeFired link')
              check "retire IRQ source not exercised" (optRetire opts == Nothing || retireFired link')
        if code /= 0 then do
          check (printf "fault %d at %08x after %d stores" code (w32 (faultAddr cpu)) stores')
            (want == Just (code, w32 (faultAddr cpu)) && stores' == total)
          finished
          printf "PASS: fault %d at %08x after %d stores\n" code (w32 (faultAddr cpu)) total
        else case doneAt' of
          Just t | tick - t >= 500 -> do
            check "expected fault did not occur" (want == Nothing)
            finished
            printf "PASS: %d mailbox stores, IRQ fixture on pure Arm9Soc\n" total
          _ -> loop (tick + 1) stores' doneAt' link' state'
  loop 0 0 Nothing (Link Nothing Nothing False False False) initialSoc
