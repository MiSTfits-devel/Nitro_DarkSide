module Main (main) where
import Control.Exception (ErrorCall,bracket,evaluate,try)
import Control.Monad (foldM,unless,replicateM_)
import Data.Bits
import Data.List (isInfixOf)
import Data.Word
import Foreign.C.String
import Foreign.Marshal.Array
import Foreign.Ptr
import System.Environment (getArgs)
import GpuService
import qualified Nds.Gpu3D.Chip as C
import qualified Nds.Gpu3D.GxFront as F
import qualified Nds.Gpu3D.Timed as T

check :: String -> Bool -> IO ()
check label ok=unless ok (fail label)
request :: Ptr () -> [Word64] -> IO ([Word64],Maybe String)
request device = requestScoped device 0

requestScoped :: Ptr () -> Word64 -> [Word64] -> IO ([Word64],Maybe String)
requestScoped device scope fields=withArray (2:fields++[scope]) $ \input -> allocaArray 16 $ \out -> do
  _ <- nds_hs_gpu_call device input out
  values <- peekArray 16 out
  message <- if values!!14==0 then pure Nothing else Just <$> peekCString (wordPtrToPtr (fromIntegral (values!!14)))
  pure (values,message)
ok :: Ptr () -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> IO [Word64]
ok device op time cpu address width value=do
  (reply,message) <- request device [op,time,cpu,address,width,value]
  check ("service request failed: "++show message) (reply!!0==2 && reply!!1==0)
  pure reply

main :: IO ()
main=do
  args <- getArgs
  case args of
    [] -> serviceCheck >> continuationCheck
    ["--continuation-only"] -> continuationCheck
    _ -> fail "usage: gpu-service-check [--continuation-only]"

serviceCheck :: IO ()
serviceCheck=bracket nds_hs_gpu_create nds_hs_gpu_destroy $ \device -> do
  check "create real GPU service" (device/=nullPtr)
  let call=ok device
      write t a v=call 2 t 0 a 4 v
      readReg t a=call 1 t 0 a 4 0
      reset=call 5 0 0 0 0 0
      drainTo target reply
        | reply!!3<=target = call 0 (reply!!3) 0 0 0 0 >>= drainTo target
        | otherwise = pure reply
  _ <- call 2 0 0 0x04000304 2 0x820f
  _ <- call 2 0 0 0x04000004 2 0x10
  start <- call 8 0 0 0 0 0
  check "real LCD first HBlank1584" (start!!3==1584)
  _ <- call 0 1565 0 0 0 0
  queued <- write 1565 0x04000454 0
  check "real identity consume at1565" (queued!!3==1565)
  executed <- call 0 1565 0 0 0 0
  check "real identity cost19 coincidesLCD" (executed!!3==1584)
  check "consume has real empty-FIFO DMA and IRQ check" (executed!!8==bit 7 && executed!!5==bit 21 && executed!!4==0)
  before <- readReg 1566 0x04000600
  check "CPU reads geometry busy before completion" (before!!2==0x0e000000)
  geometry <- call 0 1584 0 0 0 0
  check "first1584 advancesGX only, leavesLCDdue" (geometry!!3==1584 && geometry!!4==0 && geometry!!8==0)
  display <- call 0 1584 0 0 0 0
  check "second1584 servicesrealHBlank IRQ/DMA" (display!!3==2130 && display!!4==bit 1 && display!!8==bit 2)
  after <- readReg 1584 0x04000600
  vcount <- call 1 1584 0 0x04000006 2 0
  status <- call 1 1584 0 0x04000004 2 0
  check "CPU observescompletedGX andrealLCDstate" (after!!2==0x06000000 && vcount!!2==0 && status!!2==0x16)

  -- A request armed after line0 must survive VBlank, then perform the real
  -- capture on the next frame's line0. Polling bit31 alone is not proof.
  _ <- reset
  _ <- call 2 0 0 0x04000304 2 0x820f
  _ <- call 2 0 0 0x04000240 1 0x80
  _ <- call 4 0 0 0x05000000 2 0x001f
  _ <- write 0 0x04000000 0x00010000
  _ <- call 8 0 0 0 0 0
  _ <- call 0 1584 0 0 0 0
  armed <- write 1584 0x04000064 0x80000000
  _ <- drainTo 408960 armed
  pending <- readReg 408960 0x04000064
  untouched <- call 3 408960 0 0x06800000 2 0
  check "late capture survives192 without a fake write" (pending!!2==0x80000000 && untouched!!2==0)
  _ <- drainTo 560190 untouched
  _ <- call 8 560190 0 0 0 0
  _ <- call 0 561774 0 0 0 0
  captured <- call 3 561774 0 0x06800000 2 0
  check "next frame line0 actually captures into CPU-visible VRAM" (captured!!2==0x801f)

  -- Real model failure crosses the same FFI boundary as the C++ caller,
  -- returns an explicit error and stays terminal until reset (no fallback).
  _ <- reset
  _ <- call 2 0 0 0x04000304 2 0x820f
  _ <- write 0 0x04000000 0x00010007
  _ <- call 8 0 0 0 0 0
  (bad,message) <- request device [0,1584,0,0,0,0]
  check "unsupported real renderer path failsclosed" (bad!!1/=0 && maybe False (isInfixOf "unsupported video mode 7") message)
  (held,_) <- request device [1,1584,0,0x04000304,2,0]
  check "terminal error cannot resume GPU" (held!!1/=0)
  _ <- reset
  _ <- call 0 100 0 0 0 0
  (backward,backMessage) <- request device [0,99,0,0,0,0]
  check "backwards actual timestamp rejected" (backward!!1/=0 && maybe False (isInfixOf "backwards") backMessage)
  _ <- reset
  clean <- call 1 0 0 0x04000304 2 0
  check "reset clears prior GPUstate andterminalerror" (clean!!2==0 && clean!!3==maxBound)
  putStrLn "gpu-service-check: real coincident1584, CPU status/DMA/IRQ, late-capture next-frame VRAM write, fail-closed/terminal/reset: PASS"

-- Scope authentication is separate from the C++ real-instruction regression.
-- Ordinary stalled writes, DMA/no-scope, another instruction and another
-- clock cannot use the continuation operation.
continuationCheck :: IO ()
continuationCheck=bracket nds_hs_gpu_create nds_hs_gpu_destroy $ \device -> do
  let accepted scope fields=do
        (reply,message) <- requestScoped device scope fields
        check ("scoped service request failed: "++show message) (reply!!0==2 && reply!!1==0)
        pure reply
      prepare=do
        _ <- accepted 0 [5,0,0,0,0,0]
        _ <- accepted 0 [2,0,0,0x04000304,2,0x820f]
        _ <- accepted 0 [2,0,0,0x04000540,4,0]
        _ <- accepted 0 [0,0,0,0,0,0]
        replicateM_ 260 (accepted 0 [2,0,0,0x04000400,4,0])
        _ <- accepted 77 [2,0,0,0x04000400,4,0x71]
        full <- accepted 77 [2,0,0,0x04000404,4,0x22221111]
        check "ordinary scoped parameter really asserted stall" (testBit (full!!10) 0)
      rejected label scope fields expected=do
        prepare
        (reply,message) <- requestScoped device scope fields
        check label (reply!!1/=0 && maybe False (isInfixOf expected) message)
  prepare
  _ <- accepted 0 [0,0,0,0,0,0]
  _ <- accepted 77 [9,0,0,0x04000408,4,0x3333]
  lastBeat <- accepted 77 [9,0,0,0x0400040c,4,0x11]
  check "same-clock continuation remains queued under SWAP" (testBit (lastBeat!!10) 0)
  rejected "ordinary stalled write still rejected" 0
    [2,0,0,0x04000408,4,0x3333] "GX bus transaction issued while stalled"
  rejected "another instruction cannot continue" 78
    [9,0,0,0x04000408,4,0x3333] "no matching instruction stall origin"
  rejected "DMA/no-scope cannot continue" 0
    [9,0,0,0x04000408,4,0x3333] "no matching instruction stall origin"
  rejected "later clock cannot continue" 77
    [9,1,0,0x04000408,4,0x3333] "no matching instruction stall origin"
  _ <- accepted 0 [5,0,0,0,0,0]
  (withoutOrigin,message) <- requestScoped device 77 [9,0,0,0x04000408,4,0x3333]
  check "reset clears observed stall origin"
    (withoutOrigin!!1/=0 && maybe False (isInfixOf "no matching instruction stall origin") message)
  pendingStatusCheck
  putStrLn "gpu-continuation-check: same-clock FIFO append, 5 admission guards, timed/standalone refill busy/results: PASS"

-- CmdFIFORead first counts spilled test/push entries when it admits them.
-- The timed wrapper must retain those newly asserted flags as well as its
-- delayed retirement flags; the standalone chip already has the right counts.
pendingStatusCheck :: IO ()
pendingStatusCheck=do
  let write a v t=fst <$> either fail pure (T.timedWrite F.S32 a v t)
      advance time t=fst <$> either fail pure (T.timedAdvance time t)
      takeEntry chip _=maybe (fail "standalone pending FIFO did not progress") (pure . fst) (C.chipRunOne chip)
      drain t=case T.timedDeadline t of
        Nothing -> pure t
        Just time -> advance time t >>= drain
      fresh=T.timedPower True True (T.initTimedChip 0)
  mode <- write 0x04000440 1 fresh
  mode0 <- advance 0 mode
  mode1 <- advance 1 mode0
  swap <- write 0x04000540 0 mode1
  swap1 <- advance 1 swap
  full <- foldM (\t _ -> write 0x04000400 0 t) swap1 [1..260 :: Int]
  header <- write 0x04000400 0x71 full
  pending <- write 0x04000404 0x22221111 header
  ordinary <- try (evaluate (C.chipWrite F.S32 0x04000408 0x3333 (T.tcChip pending))) :: IO (Either ErrorCall C.Chip)
  check "standalone ordinary stall guard is unchanged"
    (case ordinary of Left e -> "ARM9 bus is held" `isInfixOf` show e; Right _ -> False)
  second <- fst <$> either fail pure (T.timedWriteContinuation 0x04000408 0x3333 pending)
  pushed <- fst <$> either fail pure (T.timedWriteContinuation 0x0400040c 0x11 second)
  reference <- foldM takeEntry (C.chipVBlank (T.tcChip pushed)) [1..4 :: Int]
  afterRefill <- foldM (\t time -> advance time t) (T.timedVBlank pushed) [326..329]
  let expectedBusy=C.chipRead F.S32 0x04000600 reference .&. 0x4001
      actualBusy=T.timedRead F.S32 0x04000600 afterRefill .&. 0x4001
  check "standalone refill asserts both pending-command busy bits" (expectedBusy==0x4001)
  check "timed refill preserves newly asserted test/push busy bits" (actualBusy==expectedBusy)
  done <- drain afterRefill
  let (referenceDone,_)=C.chipRun reference
      ports=[0x04000620,0x04000624,0x04000628,0x0400062c]
      actual=map (\a -> T.timedRead F.S32 a done) ports
      expected=map (\a -> C.chipRead F.S32 a referenceDone) ports
  check "timed and standalone final POS_RESULT are nonzero and exact"
    (actual==[0x1111,0x2222,0x3333,0x1000] && actual==expected)
  check "timed and standalone retire busy bits and retain one push"
    (T.timedRead F.S32 0x04000600 done==0x06000100 &&
     C.chipRead F.S32 0x04000600 referenceDone==0x06000100)
