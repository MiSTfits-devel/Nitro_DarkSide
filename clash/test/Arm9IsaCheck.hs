-- SPDX-License-Identifier: GPL-3.0-or-later
-- CPU-only ISA fixture: run the production core (the ARM9 build, or with
-- --arm7 the ARMv4T ARM7 build whose boot ROM is at 0) on an assembled
-- image and compare ordered mailbox stores against hand-derived
-- expectations. Mailbox slot k is RAM word k; with --scratch N, word
-- indices N and above are free scratch (results must be read back into the
-- mailbox). No store of any kind may follow the last mailbox word. The GPU
-- link is never ready; after the mailbox the run must stay quiet, fault
-- exactly (--fault CODE ADDR) or hold one exact link offer (--offer R|W
-- WIDTH ADDR DATA).
module Main (main) where

import Control.Monad (unless, when)
import Data.Word (Word32)
import Numeric (readHex)
import System.Environment (getArgs)
import Text.Printf (printf)
import Nds.WholeCore.Arm9Slice

data Want = Quiet | Fault Word32 Word32 | Offer Bool Word32 Word32 Word32
  deriving Eq

hexWord :: String -> IO Word32
hexWord s = case readHex s of
  [(n, "")] -> pure n
  _ -> fail ("bad hex word: " ++ s)

-- First token of each line; '#' starts a comment.
readWords :: FilePath -> IO [Word32]
readWords path = do
  text <- readFile path
  mapM hexWord [w | l <- lines text, (w:_) <- [words (takeWhile (/= '#') l)]]

check :: String -> Bool -> IO ()
check label ok = unless ok (fail label)

main :: IO ()
main = do
  args <- getArgs
  (romPath, expectPath, rest) <- case args of
    r : e : more -> pure (r, e, more)
    _ -> fail usage
  let (arch, rest') = case rest of
        "--arm7" : more -> (arm7Arch, more)
        _ -> (arm9Arch, rest)
      base = fromIntegral (vectorBase arch) :: Word32
  (scratch, modeArgs) <- case rest' of
    "--scratch" : n : more -> (\n' -> (fromIntegral n', more)) <$> hexWord n
    _ -> pure (64 :: Int, rest')
  want <- case modeArgs of
    [] -> pure Quiet
    ["--fault", c, a] -> Fault <$> hexWord c <*> hexWord a
    ["--offer", k, w, a, d] | k `elem` ["R", "W"] ->
      Offer (k == "W") <$> hexWord w <*> hexWord a <*> hexWord d
    _ -> fail usage
  rom <- readWords romPath
  expected <- readWords expectPath
  check "mailbox overlaps scratch" (length expected <= scratch)
  let total = length expected
      fetch addr
        | addr >= base && addr - base < 4 * fromIntegral (length rom) =
            rom !! fromIntegral ((addr - base) `div` 4)
        | otherwise = 0xe7f000f0
      loop :: Int -> Int -> Int -> Maybe Int -> SliceState -> IO ()
      loop tick stores retired doneAt state = do
        check (printf "timeout after %d stores" stores) (tick < 40000)
        let addr = fromIntegral (sliceBootAddr state) :: Word32
            input = SliceIn { bootWord = fromIntegral (fetch (addr - addr `mod` 4))
                            , gpuReqReady = False, gpuReplyValid = False
                            , gpuReplyData = 0, gpuReplyFault = False, irqRequest = False }
            (state', out) = coreStep arch state input
            code = fromIntegral (fault out) :: Word32
            faultAddress = fromIntegral (faultAddr out) :: Word32
            reqAddr = fromIntegral (gpuReqAddr out) :: Word32
            reqWidth = fromIntegral (gpuReqWidth out) :: Word32
            reqData = fromIntegral (gpuReqData out) :: Word32
            reqLanes = fromIntegral (gpuReqLanes out) :: Word32
        stores' <- if not (storeValid out) then pure stores else do
          let a = fromIntegral (storeAddr out) :: Word32
              v = fromIntegral (storeData out) :: Word32
              index = fromIntegral ((a - 0x02000000) `div` 4) :: Int
          check (printf "store %08x=%08x after the mailbox" a v) (stores < total)
          if index >= scratch && index < 64
            then (printf "scratch[%d]=%08x\n" index v :: IO ()) >> pure stores else do
            check (printf "store %d at %08x" stores a) (a == 0x02000000 + 4 * fromIntegral stores)
            printf "ARM9 RAM[%d]=%08x\n" (stores * 4) v
            check (printf "slot %d: got %08x, expected %08x" stores v (expected !! stores))
              (v == expected !! stores)
            pure (stores + 1)
        let retired' = retired + (if retireValid out then 1 else 0)
            doneAt' = if stores' == total && doneAt == Nothing then Just tick else doneAt
        if gpuReqValid out then do
          let got = Offer (gpuReqWrite out) reqWidth reqAddr reqData
          check (printf "unexpected GPU offer %s%d %08x %08x after %d stores"
                   (if gpuReqWrite out then "W" else "R" :: String) reqWidth reqAddr reqData stores')
            (want == got && stores' == total)
          check "GPU offer lanes" (reqLanes == ((2 ^ reqWidth - 1) * 2 ^ (reqAddr `mod` 4)))
          printf "PASS: GPU offer %s%d %08x %08x after %d stores\n"
            (if gpuReqWrite out then "W" else "R" :: String) reqWidth reqAddr reqData total
        else if code /= 0 then do
          check (printf "fault %d at %08x after %d stores" code faultAddress stores')
            (want == Fault code faultAddress && stores' == total)
          printf "PASS: fault %d at %08x after %d stores\n" code faultAddress total
        else case doneAt' of
          Just t | tick - t >= 500 -> do
            when (want /= Quiet) (fail "expected fault/offer did not occur")
            printf "PASS: %d mailbox stores, %d retired instructions, no GPU access\n" total retired'
          _ -> loop (tick + 1) stores' retired' doneAt' state'
  loop 0 0 0 Nothing (initialCore arch)
 where
  usage = "usage: arm9-isa-check ROM.hex EXPECTED [--arm7] [--scratch N] [--fault CODE ADDR | --offer R|W WIDTH ADDR DATA]"
