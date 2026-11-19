-- SPDX-License-Identifier: GPL-3.0-or-later
-- Nds.WholeCore.Ipc driven by an operation list (sim/tests/hs_ipc_ops.py),
-- printing the same per-operation log as sim/tb_ipc_product.vhd: index,
-- read data (0 for writes), the ARM9 and the ARM7 IRQ bits raised. Each
-- operation is one request on that CPU's port; the window is four cycles
-- (request, reply taken, two idle), as on the product bench.
--
--   ipc-ops-check OPS
module Main (main) where

import Control.Monad (foldM_)
import Data.Bits ((.|.))
import Data.Word (Word32)
import Numeric (readHex)
import System.Environment (getArgs)
import Text.Printf (printf)
import Nds.WholeCore.Card (CardBus(..), CardReply(..))
import Nds.WholeCore.Ipc

idleBus :: CardBus
idleBus = CardBus False False 0 4 0 False

main :: IO ()
main = do
  [path] <- getArgs
  ops <- map words . lines <$> readFile path
  let run :: (IpcState, Int) -> [String] -> IO (IpcState, Int)
      run (st, n) [c, kind, a, d] = do
        let addr = fst (head (readHex a)) :: Word32
            dat = fst (head (readHex d)) :: Word32
            width = if last kind == '4' then 4 else 2
            req = CardBus True (head kind == 'W') (fromIntegral addr) width (fromIntegral dat) True
            on9 = c == "9"
            buses k
              | k == 0 = if on9 then (req, idleBus) else (idleBus, req)
              | otherwise = (idleBus { busReplyReady = True }, idleBus { busReplyReady = True })
            cycle1 (s, rd, i9, i7) k =
              let (s', out) = ipcStep s (buses k)
                  r = if on9 then ipcReply9 out else ipcReply7 out
                  rd' = if cardReplyValid r then w32 (cardReplyData r) else rd
              in (s', rd', i9 .|. w32 (ipcIrq9 out), i7 .|. w32 (ipcIrq7 out))
            (st', rd, i9, i7) = foldl cycle1 (st, 0, 0, 0) [0 .. 4 :: Int]
        printf "%d %08X %08X %08X\n" n (if head kind == 'R' then rd else 0) i9 i7 :: IO ()
        pure (st', n + 1)
      run acc _ = pure acc
  foldM_ run (initialIpc, 0) ops
 where
  w32 :: Integral a => a -> Word32
  w32 = fromIntegral
