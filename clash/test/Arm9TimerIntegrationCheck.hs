-- SPDX-License-Identifier: GPL-3.0-or-later
-- Independent mailbox expectations for an assembled ARM program running on
-- the actual CPU+timer/interrupt-router composition, not a peripheral script.
module Main (main) where

import Control.Monad (unless)
import Data.Bits ((.&.))
import Data.Word (Word32)
import Numeric (readHex)
import System.Environment (getArgs)
import Text.Printf (printf)
import Nds.WholeCore.Arm9Io
import Nds.WholeCore.Arm9Slice
import Nds.WholeCore.Arm9Soc

readWords :: FilePath -> IO [Word32]
readWords p = do
  ls <- lines <$> readFile p
  mapM parse [w | l <- ls, (w:_) <- [words (takeWhile (/= '#') l)]]
 where
  parse s = case readHex s of
    [(n, "")] -> pure n
    _ -> fail ("invalid hex word: " ++ s)

check :: String -> Bool -> IO ()
check label ok = unless ok (fail label)

main :: IO ()
main = do
  args <- getArgs
  (romPath, expectedPath) <- case args of
    [r, e] -> pure (r, e)
    _ -> fail "usage: Arm9TimerIntegrationCheck ROM.hex EXPECTED"
  rom <- readWords romPath
  expected <- readWords expectedPath
  check "empty fixture or expectations" (not (null rom) && not (null expected))
  let fetch addr
        | addr >= 0xffff0000 && (addr - 0xffff0000) `div` 4 < fromIntegral (length rom) =
            rom !! fromIntegral ((addr - 0xffff0000) `div` 4)
        | otherwise = 0xe7f000f0
      loop tick stores acks sawIrq doneAt state = do
        check "timeout" (tick < 20000)
        let addr = fromIntegral (socBootAddr state) :: Word32
            input = SocIn (fromIntegral (fetch addr)) False False 0 False (odd tick) 0 0 noCartridge
            (next, output) = socStep state input
            cpu = socCpu output
            io = socIo output
            ack = fromIntegral (ifAck io) :: Word32
            enabled = regIME io && (regIE io .&. regIF io /= 0)
        check "unexpected CPU fault" (fault cpu == 0)
        check "timer/interrupt request escaped to GPU" (not (extReqValid io))
        check "IRQ level differs from IME && IE & IF" (irqLine io == enabled)
        let acks' = if ack == 0 then acks else acks ++ [ack]
            seen' = sawIrq || irqLine io
        stores' <- if not (storeValid cpu) then pure stores else do
          let a = fromIntegral (storeAddr cpu) :: Word32
              v = fromIntegral (storeData cpu) :: Word32
          check (printf "unexpected store %08x=%08x" a v) (stores < length expected)
          check "mailbox address/order" (a == 0x02000000 + 4 * fromIntegral stores)
          check (printf "mailbox[%d] got %08x expected %08x" stores v (expected !! stores))
            (v == expected !! stores)
          printf "ARM9 RAM[%d]=%08x\n" (stores * 4) v
          pure (stores + 1)
        let doneAt' = if stores' == length expected && doneAt == Nothing then Just tick else doneAt
        case doneAt' of
          Just t | tick - t >= 50 -> do
            check "missing IRQ assertion" seen'
            check "IRQ failed to deassert after W1C" (not (irqLine io) && regIF io == 0)
            check ("unexpected IF acknowledgements " ++ show acks') (acks' == [8, 16])
            putStrLn "PASS: composed ARM9 timer/IF witness"
          _ -> loop (tick + 1) stores' acks' seen' doneAt' next
  loop (0 :: Int) 0 [] False Nothing initialSoc
