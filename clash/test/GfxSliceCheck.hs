{-# LANGUAGE DataKinds #-}
-- SPDX-License-Identifier: GPL-3.0-or-later
-- | Run one ARM program on the pure ARM9 slice twice: against the pure
-- "Nds.Gpu2D.VramDisplay" transition (with scanout contention on the shared
-- read port) and against the authoritative ABI2 GPU service. The ordered GPU
-- transactions, replies and mailbox stores must agree. After the program
-- halts, the service renders one LCD frame; its top screen must equal the
-- VramDisplay top-LCD colour of every pixel. Writes the event log, the frame
-- (one RRGGBB per line) and a PPM to OUTDIR for the generated-HDL compare.
module Main (main) where

import Clash.Prelude (BitVector, Vec(..))
import qualified Clash.Prelude as C
import Control.Exception (bracket)
import Control.Monad (unless, when)
import Data.Bits ((.&.), shiftL, shiftR, testBit)
import qualified Data.ByteString as B
import qualified Data.IntMap.Strict as IM
import Data.Word (Word32, Word64)
import Foreign.C.String (peekCString)
import Foreign.Marshal.Array (allocaArray, peekArray, withArray)
import Foreign.Ptr (Ptr, nullPtr, wordPtrToPtr)
import Numeric (readHex)
import System.Environment (getArgs)
import System.FilePath ((</>))
import Text.Printf (printf)
import qualified GpuService as GPU
import Nds.Gpu2D.VramDisplay
import Nds.WholeCore.Arm9Slice

check :: String -> Bool -> IO ()
check label ok = unless ok (fail label)

word :: BitVector 32 -> Word32
word = fromIntegral

haltOpcode :: Word32
haltOpcode = 0xeafffffe

tickLimit :: Int
tickLimit = 20000000

-- | One line per event, identical to the generated-HDL host's log.
opLine :: Bool -> Int -> Word32 -> Word32 -> Bool -> String
opLine writing width addr value bad =
  printf "%s%d %08x %08x%s" (if writing then "W" else "R" :: String) width addr value
    (if bad then " FAULT" else "" :: String)

romWord :: IM.IntMap Word32 -> BitVector 32 -> BitVector 32
romWord rom addr
  | a .&. 0xfffff000 == 0xffff0000 = fromIntegral (IM.findWithDefault 0 (fromIntegral ((a - 0xffff0000) `shiftR` 2)) rom)
  | otherwise = 0
 where a = word addr

-- Common per-tick CPU observation: stores, halt, fault.
cpuEvents :: SliceOut -> ([String], Maybe Int)
cpuEvents out = (stores ++ faults, stop)
 where
  stores = [printf "S %08x %08x" (word (storeAddr out)) (word (storeData out)) | storeValid out]
  code = fromIntegral (fault out) :: Int
  faults = [printf "CPU FAULT %d %08x" code (word (faultAddr out)) | code /= 0]
  stop | code /= 0 = Just code
       | retireValid out && word (retireOpcode out) == haltOpcode = Just 0
       | otherwise = Nothing

-- | Pure VramDisplay model. Memory key: ((bank*2 + lane) << 15) + word.
type Mem = IM.IntMap (BitVector 16)

runModel :: IM.IntMap Word32 -> ([String], Int, Gpu, Mem)
runModel rom = go 0 initialSlice initialGpu IM.empty (C.repeat 0) Nothing []
 where
  go :: Int -> SliceState -> Gpu -> Mem -> Vec 2 (BitVector 32) -> Maybe (Bool, Int, Word32, Word32) -> [String] -> ([String], Int, Gpu, Mem)
  go tick s g mem rw held acc
    | tick >= tickLimit = (reverse ("TIMEOUT" : acc), tick, g, mem)
    | otherwise =
        let -- The display owns the read port on one clock in eight, as in
            -- the active part of every scanline, plus an irregular extra.
            busy = tick `mod` 8 == 0 || tick `mod` 13 == 5
            (g', gout) = gpuStep g (GpuIn linkIn busy rw)
            (s', out) = sliceStep s SliceIn
              { bootWord = romWord rom (sliceBootAddr s), gpuReqReady = reqReady gout
              , gpuReplyValid = replyValid gout, gpuReplyData = replyWord gout
              , gpuReplyFault = replyErr gout, irqRequest = False }
            linkIn = LinkIn (gpuReqValid out) (gpuReqWrite out) (gpuReqAddr out)
              (gpuReqWidth out) (gpuReqData out) (gpuReplyReady out)
            readAt = if busy then fromIntegral (tick `mod` 32768) else maybe 0 fromIntegral (ramRead gout)
            bankWord b = C.pack (lookupHalf mem b 1 readAt) C.++# C.pack (lookupHalf mem b 0 readAt)
            rw' = bankWord 0 :> bankWord 1 :> Nil
            mem' = maybe mem (applyWrite mem) (ramWrite gout)
            accepted = gpuReqValid out && reqReady gout
            held' | accepted = Just (gpuReqWrite out, fromIntegral (gpuReqWidth out), word (gpuReqAddr out), word (gpuReqData out))
                  | otherwise = held
            replied = replyValid gout && gpuReplyReady out
            opEvents = case held of
              Just (w, n, a, v) | replied -> [opLine w n a (if w then v else word (replyWord gout)) (replyErr gout)]
              _ -> []
            (cpu, stop) = cpuEvents out
            acc' = reverse (opEvents ++ cpu) ++ acc
            held'' = if replied then Nothing else held'
        in case stop of
             Just 0 -> (reverse ("HALT" : acc'), tick, g', mem')
             Just _ -> (reverse acc', tick, g', mem')
             Nothing -> go (tick + 1) s' g' mem' rw' held'' acc'

lookupHalf :: Mem -> Int -> Int -> Int -> BitVector 16
lookupHalf mem bank lane addr = IM.findWithDefault 0 (((bank * 2 + lane) `shiftL` 15) + addr) mem

applyWrite :: Mem -> VramWrite -> Mem
applyWrite mem w = foldr put mem [(b, l) | b <- [0, 1 :: Int], l <- [0, 1], testBit (wLanes w C.!! b) l]
 where
  addr = fromIntegral (wAddr w) :: Int
  put (b, l) = IM.insert (((fromIntegral b * 2 + l) `shiftL` 15) + addr) (if l == 1 then wHigh w else wLow w)

modelFrame :: Gpu -> Mem -> [Word32]
modelFrame g mem =
  [ fromIntegral (topColor lcdOn rg (half 0 x y :> half 1 x y :> Nil)) | y <- [0 .. 191], x <- [0 .. 255] ]
 where
  rg = gpuRegs g
  lcdOn = testBit (power rg) 0
  half b x y = lookupHalf mem b (x .&. 1) (y * 128 + x `shiftR` 1)

-- Authoritative ABI2 service, driven like test/Arm9SliceWitness.hs.
call :: Ptr () -> Bool -> [Word64] -> IO [Word64]
call device quiet fields = withArray (2 : fields ++ [0]) $ \req -> allocaArray 16 $ \out -> do
  status <- GPU.nds_hs_gpu_call device req out
  r <- peekArray 16 out
  msg <- if r !! 14 == 0 then pure "" else peekCString (wordPtrToPtr (fromIntegral (r !! 14)))
  check ("GPU ABI2 failure: " ++ msg) (status == 0 && r !! 0 == 2 && r !! 1 == 0)
  when quiet $ check "unexpected GPU scheduled work/effects"
    (r !! 3 == maxBound && all (== 0) (take 6 (drop 4 r)) && r !! 10 .&. (maxBound - 2) == 0 && all (== 0) (take 3 (drop 11 r)))
  pure r

runOracle :: Ptr () -> IM.IntMap Word32 -> Int -> IO ([String], Int)
runOracle gpu rom opLimit = go 0 initialSlice Nothing [] 0
 where
  go tick s pending acc ops
    | tick >= tickLimit = pure (reverse ("TIMEOUT" : acc), tick)
    | ops >= opLimit = pure (reverse acc, tick)
    | otherwise = do
        let ready = tick `mod` 4 /= 0 && pending == Nothing
            (s', out) = sliceStep s SliceIn
              { bootWord = romWord rom (sliceBootAddr s), gpuReqReady = ready
              , gpuReplyValid = pending /= Nothing, gpuReplyData = maybe 0 fromIntegral pending
              , gpuReplyFault = False, irqRequest = False }
            (cpu, stop) = cpuEvents out
            pendingAfter = if gpuReplyReady out then Nothing else pending
        (pending', opEvents) <- if not (gpuReqValid out && ready) then pure (pendingAfter, []) else do
          let a = word (gpuReqAddr out)
              w = fromIntegral (gpuReqWidth out) :: Int
              v = word (gpuReqData out)
              writing = gpuReqWrite out
              memOp = a `shiftR` 24 == 6
              op = if memOp then (if writing then 4 else 3) else (if writing then 2 else 1)
          r <- call gpu True [op, fromIntegral tick, 0, fromIntegral a, fromIntegral w, if writing then fromIntegral v else 0]
          let result = fromIntegral (r !! 2) :: Word32
          pure (Just result, [opLine writing w a (if writing then v else result) False])
        let acc' = reverse (cpu ++ opEvents) ++ acc
            ops' = ops + length opEvents
        case stop of
          Just 0 -> pure (reverse ("HALT" : acc'), tick)
          Just _ -> pure (reverse acc', tick)
          Nothing -> go (tick + 1) s' pending' acc' ops'

oracleFrame :: Ptr () -> Int -> IO [Word32]
oracleFrame gpu tick = do
  start <- call gpu False [8, fromIntegral tick, 0, 0, 0, 0]
  let drain r
        | testBit (r !! 10) 2 = pure r
        | r !! 3 == maxBound = fail "LCD frame stopped without completing"
        | otherwise = call gpu False [0, r !! 3, 0, 0, 0, 0] >>= drain
  r <- drain start
  check "frame pixels absent" (testBit (r !! 10) 3 && r !! 12 /= 0)
  map (.&. 0xffffff) <$> peekArray (256 * 192) (wordPtrToPtr (fromIntegral (r !! 12)) :: Ptr Word32)

main :: IO ()
main = do
  args <- getArgs
  (file, outDir, expected) <- case args of
    [f, o] -> pure (f, o, Nothing)
    [f, o, "--expect-fault", c, a] -> pure (f, o, Just (read c :: Int, fst (head (readHex a)) :: Word32))
    _ -> fail "usage: gfx-slice-check ROM.hex OUTDIR [--expect-fault CODE HEXADDR]"
  words' <- mapM parseWord . lines =<< readFile file
  check "ROM exceeds the 4 KiB boot window" (length words' <= 1024)
  let rom = IM.fromList (zip [0 ..] words')
      (modelLog, modelTicks, g, mem) = runModel rom
  writeFile (outDir </> "model.log") (unlines modelLog)
  check "model timed out" (last modelLog /= "TIMEOUT")
  bracket GPU.nds_hs_gpu_create GPU.nds_hs_gpu_destroy $ \gpu -> do
    check "GPU create failed" (gpu /= nullPtr)
    _ <- call gpu True [5, 0, 0, 0, 0, 0]
    case expected of
      Nothing -> do
        check "program faulted" (last modelLog == "HALT")
        (oracleLog, ticks) <- runOracle gpu rom maxBound
        writeFile (outDir </> "oracle.log") (unlines oracleLog)
        compareLogs modelLog oracleLog
        oracle <- oracleFrame gpu ticks
        let model = modelFrame g mem
            bad = [(i, m, o) | (i, m, o) <- zip3 [0 :: Int ..] model oracle, m /= o]
        case bad of
          (i, m, o) : _ -> fail (printf "%d frame mismatches; first (%d,%d) model %06x oracle %06x"
                                   (length bad) (i `mod` 256) (i `div` 256) m o)
          [] -> pure ()
        writeFile (outDir </> "frame.hex") (unlines (map (printf "%06x") oracle))
        B.writeFile (outDir </> "frame.ppm") (ppm oracle)
        printf "PASS: %d GPU transactions, %d stores, model/service logs equal; halted at tick %d (model %d)\n"
          (count "R" oracleLog + count "W" oracleLog) (count "S" oracleLog) ticks modelTicks
        printf "PASS: service top LCD == VramDisplay colour on all 49152 pixels (%d distinct colours)\n"
          (IM.size (IM.fromList [(fromIntegral c, ()) | c <- oracle]))
      Just (code, addr) -> do
        let faultLine = printf "CPU FAULT %d %08x" code addr :: String
            (prefix, rest) = break (" FAULT" `isSuffix`) modelLog
        check ("model did not end in " ++ faultLine) (drop 1 rest == [faultLine] && not (null rest))
        -- The service accepts the access this target rejects; everything
        -- before it, and the access itself, must be the same.
        (oracleLog, _) <- runOracle gpu rom (count "R" prefix + count "W" prefix + 1)
        writeFile (outDir </> "oracle.log") (unlines oracleLog)
        compareLogs prefix (take (length prefix) oracleLog)
        let rejected = head rest
            served = [l | l <- drop (length prefix) oracleLog, take 1 l `elem` ["R", "W"]]
        check "service did not see the rejected access" (not (null served) && take 12 (head served) == take 12 rejected)
        printf "PASS: %s (service accepted: %s)\n" faultLine (head served)
  where
    parseWord s = case readHex s of
      [(n, "")] -> pure (n :: Word32)
      _ -> fail ("bad ROM word: " ++ s)
    count p = length . filter ((== p) . take 1)
    isSuffix suffix s = reverse suffix == take (length suffix) (reverse s)

compareLogs :: [String] -> [String] -> IO ()
compareLogs model oracle = case [(i, m, o) | (i, m, o) <- zip3 [1 :: Int ..] model oracle, m /= o] of
  (i, m, o) : _ -> fail (printf "event %d: model %s, service %s" i m o)
  [] -> check (printf "event counts differ: model %d, service %d" (length model) (length oracle))
          (length model == length oracle)

ppm :: [Word32] -> B.ByteString
ppm pixels = B.append (B.pack (map (fromIntegral . fromEnum) "P6\n256 192\n255\n"))
  (B.pack (concatMap (\c -> map (\s -> fromIntegral (c `shiftR` s)) [16, 8, 0]) pixels))
