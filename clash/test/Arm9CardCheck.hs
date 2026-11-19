-- SPDX-License-Identifier: GPL-3.0-or-later
-- Game-card fixtures on the pure Arm9Soc ('socStep'). The cartridge image
-- store is this harness: it refuses requests on every fifth cycle, answers
-- the k-th accepted request 1 + (k mod 4) cycles later, and checks that a
-- refused request is held with the same address and that the slot never
-- asks for a word outside the image. The timer clock ticks on odd cycles;
-- the GPU link must stay silent.
--
-- Mailbox slot k is RAM word k and must equal EXPECTED in order; words 0x30
-- and up (to the 4 KiB RAM end) are scratch; no store may follow the last
-- mailbox word. The run must then stay quiet, or (--fault CODE ADDR [--after
-- N]) stop with exactly that fault after N mailbox words (default: all).
-- --rom-log writes the accepted image addresses, one per line.
--
-- Execution from RAM: every instruction retired from 0x02000000-0x02000FFF
-- must be the word the guest last stored at that address (the harness
-- shadows every RAM store). --no-ram-exec forbids such retirements.
-- --trace FILE ("pc opcode" per line) requires the RAM retirements to be
-- exactly that sequence, its last entry then repeating. --load START SIZE
-- requires every word of that range to have been stored before the first
-- RAM retirement.
module Main (main) where

import Control.Monad (unless, when)
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits ((.&.), shiftR)
import qualified Data.Map.Strict as M
import Data.Word (Word32)
import Numeric (readHex)
import System.Environment (getArgs)
import System.IO (Handle, IOMode(WriteMode), hPutStrLn, withFile)
import Text.Printf (printf)
import Nds.WholeCore.Arm9Io (IoOut(..))
import Nds.WholeCore.Arm9Slice
import Nds.WholeCore.Arm9Soc

data Opts = Opts
  { optNoCart  :: Bool
  , optRomLog  :: Maybe FilePath
  , optFault   :: Maybe (Word32, Word32)
  , optAfter   :: Maybe Int
  , optTrace   :: Maybe FilePath
  , optLoad    :: Maybe (Word32, Word32)
  , optNoExec  :: Bool
  }

data Store = Store
  { held     :: Maybe Word32          -- ^ address of a refused request
  , inFlight :: Maybe (Int, Word32)   -- ^ reply cycle, data
  , served   :: Int
  }

data Exec = Exec
  { shadow  :: M.Map Word32 Word32    -- ^ RAM words as the guest stored them
  , retired :: Int                    -- ^ instructions retired from RAM
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

parse :: [String] -> Opts -> IO Opts
parse [] o = pure o
parse ("--no-cart" : r) o = parse r o { optNoCart = True }
parse ("--rom-log" : f : r) o = parse r o { optRomLog = Just f }
parse ("--fault" : c : a : r) o = do
  c' <- hexWord c
  a' <- hexWord a
  parse r o { optFault = Just (c', a') }
parse ("--after" : n : r) o = parse r o { optAfter = Just (read n) }
parse ("--trace" : f : r) o = parse r o { optTrace = Just f }
parse ("--load" : s : n : r) o = do
  s' <- hexWord s
  n' <- hexWord n
  parse r o { optLoad = Just (s', n') }
parse ("--no-ram-exec" : r) o = parse r o { optNoExec = True }
parse _ _ = fail usage

usage :: String
usage = "usage: arm9-card-check ROM.hex EXPECTED CARD.hex raw|direct [--no-cart] [--rom-log FILE]"
  ++ " [--fault CODE ADDR [--after N]] [--trace FILE] [--load START SIZE] [--no-ram-exec]"

inRamAddr :: Word32 -> Bool
inRamAddr a = a .&. 0xfffff000 == 0x02000000

main :: IO ()
main = do
  args <- getArgs
  (romPath, expectPath, cardPath, direct, rest) <- case args of
    r : e : c : m : more | m `elem` ["raw", "direct"] -> pure (r, e, c, m == "direct", more)
    _ -> fail usage
  opts <- parse rest (Opts False Nothing Nothing Nothing Nothing Nothing False)
  romWords <- readWords romPath
  expected <- readWords expectPath
  image <- readWords cardPath
  traceWords <- maybe (pure []) (\f -> do
    text <- readFile f
    mapM hexWord (concatMap (words . takeWhile (/= '#')) (lines text))) (optTrace opts)
  let rom = listArray (0, length romWords - 1) romWords :: UArray Int Word32
      card = listArray (0, length image - 1) image :: UArray Int Word32
      trace = pairs traceWords
      pairs (p : w : more) = (p, w) : pairs more
      pairs _ = []
      imageMask = w32 (4 * length image - 1)
      total = length expected
      stopAt = maybe total id (optAfter opts)
      scratch = 0x30 :: Int
      fetch addr
        | addr >= 0xffff0000 && addr < 0xffff0000 + 4 * w32 (length romWords) =
            rom ! fromIntegral ((addr - 0xffff0000) `div` 4)
        | otherwise = 0xe7f000f0
      straps = CardIn
        { cardInserted = not (optNoCart opts), cardDirectBoot = direct, cardChipId = 0x00001fc2
        , cardRomMask = fromIntegral imageMask, cardRomReady = False, cardRomReplyValid = False
        , cardRomReplyData = 0 }
      -- One RAM retirement: the guest's stored word, the trace, the load.
      retire :: Exec -> Word32 -> Word32 -> IO Exec
      retire ex pc op = do
        check (printf "instruction retired from RAM at %08x" pc) (not (optNoExec opts))
        check (printf "RAM instruction %08x at %08x is not the word the guest stored (%s)" op pc
                 (maybe "nothing" (printf "%08x") (M.lookup pc (shadow ex)) :: String))
          (M.lookup pc (shadow ex) == Just op)
        when (retired ex == 0) $ case optLoad opts of
          Just (start, size) -> check (printf "executed from RAM before the load %08x+%x was stored" start size)
            (all (\a -> M.member a (shadow ex)) [start, start + 4 .. start + size - 4])
          Nothing -> pure ()
        unless (null trace) $ do
          let (tp, tw) = if retired ex < length trace then trace !! retired ex else last trace
          check (printf "RAM retirement %d: %08x %08x, expected %08x %08x" (retired ex) pc op tp tw)
            (pc == tp && op == tw)
        pure ex { retired = retired ex + 1 }
      run :: Handle -> IO ()
      run logH = loop 0 0 Nothing (Store Nothing Nothing 0) (Exec M.empty 0) initialSoc
       where
        loop :: Int -> Int -> Maybe Int -> Store -> Exec -> SocState -> IO ()
        loop tick stores doneAt st ex state = do
          check (printf "timeout after %d stores" stores) (tick < 2000000)
          let ready = tick `mod` 5 /= 2 && inFlight st == Nothing
              reply = case inFlight st of
                Just (at, d) | tick >= at -> Just d
                _ -> Nothing
              input = SocIn
                { socBootWord = fromIntegral (fetch (w32 (socBootAddr state)))
                , socGpuReqReady = False, socGpuReplyValid = False, socGpuReplyData = 0
                , socGpuReplyFault = False, socTimerTick = odd tick, socIrqSet = 0
                , socIrqClear = 0
                , socCardIn = straps { cardRomReady = ready, cardRomReplyValid = reply /= Nothing
                                     , cardRomReplyData = maybe 0 fromIntegral reply } }
              (state', out) = socStep state input
              cpu = socCpu out
              io = socIo out
              k = socCard out
              reqAddr = w32 (cardRomAddr k)
          check (printf "unexpected GPU request %08x" (w32 (gpuReqAddr cpu))) (not (extReqValid io))
          case held st of
            Just a -> check (printf "refused image request %08x changed or dropped" a)
                        (cardRomReqValid k && reqAddr == a)
            Nothing -> pure ()
          when (cardRomReqValid k) $
            check (printf "image request %08x outside the image or unaligned" reqAddr)
              (reqAddr .&. 3 == 0 && reqAddr <= imageMask && inFlight st == Nothing)
          ex1 <- if retireValid cpu && inRamAddr (w32 (retirePc cpu))
                   then retire ex (w32 (retirePc cpu)) (w32 (retireOpcode cpu)) else pure ex
          (stores', ex2) <- if not (storeValid cpu) then pure (stores, ex1) else do
            let a = w32 (storeAddr cpu)
                v = w32 (storeData cpu)
                index = fromIntegral ((a - 0x02000000) `div` 4) :: Int
                ex' = ex1 { shadow = M.insert a v (shadow ex1) }
            check (printf "store %08x=%08x after the mailbox" a v) (stores < stopAt)
            if index >= scratch && index < 1024 then pure (stores, ex') else do
              check (printf "store %d at %08x" stores a) (a == 0x02000000 + 4 * w32 stores)
              printf "ARM9 RAM[%d]=%08x\n" (stores * 4) v
              check (printf "slot %d: got %08x, expected %08x" stores v (expected !! stores))
                (v == expected !! stores)
              pure (stores + 1, ex')
          let accepted = cardRomReqValid k && ready
          when accepted $ hPutStrLn logH (printf "%08x" reqAddr)
          let st' = Store
                { held = if cardRomReqValid k && not ready then Just reqAddr else Nothing
                , inFlight = if accepted
                    then Just (tick + 1 + served st `mod` 4, card ! fromIntegral (reqAddr `shiftR` 2))
                    else if reply /= Nothing then Nothing else inFlight st
                , served = served st + (if accepted then 1 else 0) }
              doneAt' = if stores' == stopAt && doneAt == Nothing then Just tick else doneAt
              code = w32 (fault cpu)
          if code /= 0 then do
            check (printf "fault %d at %08x after %d stores" code (w32 (faultAddr cpu)) stores')
              (optFault opts == Just (code, w32 (faultAddr cpu)) && stores' == stopAt)
            printf "PASS: fault %d at %08x after %d stores\n" code (w32 (faultAddr cpu)) stores'
          else case doneAt' of
            Just t | tick - t >= 500 -> do
              check "expected fault did not occur" (optFault opts == Nothing)
              check "card still busy" (not (cardBusy k))
              check (printf "%d RAM retirements, trace has %d" (retired ex2) (length trace))
                (retired ex2 >= length trace)
              printf "PASS: %d mailbox stores, %d image words served, %d instructions retired from RAM\n"
                stores' (served st') (retired ex2)
            _ -> loop (tick + 1) stores' doneAt' st' ex2 state'
  withFile (maybe "/dev/null" id (optRomLog opts)) WriteMode run
