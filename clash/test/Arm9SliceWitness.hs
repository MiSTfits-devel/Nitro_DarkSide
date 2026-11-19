{-# LANGUAGE DataKinds #-}
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Execute the production transition function against the real ABI2 GPU service.
module Main (main) where

import Clash.Prelude (BitVector)
import Control.Exception (bracket)
import Control.Monad (unless, when)
import Data.Bits ((.&.), shiftL)
import Data.Word (Word32, Word64)
import Foreign.C.String (peekCString)
import Foreign.Marshal.Array (allocaArray, peekArray, withArray)
import Foreign.Ptr (Ptr, nullPtr, wordPtrToPtr)
import Numeric (readHex)
import System.Environment (getArgs)
import Text.Printf (printf)
import qualified GpuService as GPU
import Nds.WholeCore.Arm9Slice

check :: String -> Bool -> IO ()
check label ok = unless ok (fail label)

call :: Ptr () -> [Word64] -> IO Word32
call device fields = withArray (2 : fields ++ [0]) $ \req -> allocaArray 16 $ \out -> do
  status <- GPU.nds_hs_gpu_call device req out
  r <- peekArray 16 out
  msg <- if r !! 14 == 0 then pure "" else peekCString (wordPtrToPtr (fromIntegral (r !! 14)))
  check ("GPU ABI2 failure: " ++ msg) (status == 0 && r !! 0 == 2 && r !! 1 == 0)
  check "unexpected GPU scheduled work/effects" (r !! 3 == maxBound && all (==0) (take 6 (drop 4 r)) && r !! 10 .&. complementFifo == 0 && all (==0) (take 3 (drop 11 r)))
  pure (fromIntegral (r !! 2))
  where complementFifo = maxBound - 2 :: Word64

word :: BitVector 32 -> Word32
word = fromIntegral

main :: IO ()
main = do
  args <- getArgs
  (file, negative) <- case args of
    [p] -> pure (p, False)
    [p,"--unsupported"] -> pure (p, True)
    _ -> fail "usage: arm9-slice-witness ROM.hex [--unsupported]"
  contents <- lines <$> readFile file
  rom <- mapM parseWord contents
  bracket GPU.nds_hs_gpu_create GPU.nds_hs_gpu_destroy $ \gpu -> do
    check "GPU create failed" (gpu /= nullPtr)
    _ <- call gpu [5,0,0,0,0,0]
    loop gpu rom negative 0 initialSlice Nothing Nothing 0 0
  where
    parseWord s = case readHex s of
      [(n, "")] -> pure n
      _ -> fail ("bad ROM word: " ++ s)

-- A reply is held until accepted; request readiness periodically stalls.
loop :: Ptr () -> [Word32] -> Bool -> Int -> SliceState -> Maybe Word32 -> Maybe (Bool, Word32, Word32, Word32, Word32) -> Int -> Int -> IO ()
loop gpu rom negative tick state pending held stores requests = do
  check "slice timed out" (tick < 10000)
  let addr = word (sliceBootAddr state)
      index = fromIntegral ((addr - 0xffff0000) `div` 4)
      instr = if addr >= 0xffff0000 && addr .&. 3 == 0 && index < length rom then rom !! index else 0xe7f000f0
      ready = tick `mod` 4 /= 0 && pending == Nothing
      input = SliceIn { bootWord = fromIntegral instr, gpuReqReady = ready
                      , gpuReplyValid = maybe False (const True) pending
                      , gpuReplyData = fromIntegral (maybe 0 id pending), gpuReplyFault = False
                      , irqRequest = False }
      (state', out) = sliceStep state input
      faultCode = fromIntegral (fault out) :: Int
      faultAddress = word (faultAddr out)
      request = (gpuReqWrite out, word (gpuReqAddr out), fromIntegral (gpuReqWidth out), fromIntegral (gpuReqLanes out), word (gpuReqData out))
  case held of
    Just previous -> check "request changed while backpressured" (gpuReqValid out && request == previous)
    Nothing -> pure ()
  if faultCode /= 0 then do
    check (printf "unexpected fault %d at %08x" faultCode faultAddress)
      (negative && faultCode == 3 && faultAddress == 0x04000247 && requests == 2 && stores == 1 && not (gpuReqValid out))
    putStrLn "PASS: unsupported WRAMCNT fails closed"
  else do
    when (storeValid out) $ do
      let a = word (storeAddr out); v = word (storeData out)
      check "unexpected mailbox store order/address" (a == 0x02000000 + fromIntegral (stores * 4) && stores < 6)
      printf "ARM9 RAM[%d]=%08x\n" (stores * 4) v
    let acceptedReply = gpuReplyReady out && maybe False (const True) pending
        pendingAfter = if acceptedReply then Nothing else pending
        acceptedReq = gpuReqValid out && ready
    pending' <- if not acceptedReq then pure pendingAfter else do
      check "overlapping GPU requests" (pendingAfter == Nothing)
      let a = word (gpuReqAddr out)
          w = fromIntegral (gpuReqWidth out) :: Word32
          v = word (gpuReqData out)
          writing = gpuReqWrite out
          lanes = fromIntegral (gpuReqLanes out) :: Word32
          mem = a `div` 0x1000000 == 6
          io = (a == 0x04000304 && w `elem` [2,4]) || (a >= 0x04000240 && a + w <= 0x04000247) || (a >= 0x04000248 && a + w <= 0x0400024a)
      check "invalid GPU width/alignment/lanes" (w `elem` [1,2,4] && a .&. (w-1) == 0 && lanes == ((1 `shiftL` fromIntegral w) - 1) `shiftL` fromIntegral (a .&. 3))
      check "unowned GPU target" (mem || io)
      let op = if mem then (if writing then 4 else 3) else (if writing then 2 else 1)
      result <- call gpu [op, fromIntegral (tick `div` 2), 0, fromIntegral a, fromIntegral w, if writing then fromIntegral v else 0]
      printf "ARM9 -> Haskell cycle=%d %s%d %08x %08x\n" (tick `div` 2) (if writing then "W" else "R" :: String) w a (if writing then v else result)
      pure (Just result)
    let stores' = stores + if storeValid out then 1 else 0
        requests' = requests + if acceptedReq then 1 else 0
    if stores' == 6 then do
      check "unexpected completion in negative case" (not negative)
      check "wrong number of GPU requests" (requests' == 10 && pending' == Nothing)
      putStrLn "PASS: Clash ARM9 slice completed witness"
    else loop gpu rom negative (tick+1) state' pending'
           (if gpuReqValid out && not ready then Just request else Nothing) stores' requests'
