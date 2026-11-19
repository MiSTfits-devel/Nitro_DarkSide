{-# LANGUAGE BangPatterns, DataKinds #-}
-- SPDX-License-Identifier: GPL-3.0-or-later
-- | All-Haskell native vertical slice: the production Clash ARM9 slice plus
-- its local I/O router ('Nds.WholeCore.Arm9Soc.socStep': ARM9 slice, DS
-- timers, ARM9 IME/IE/IF) executes an assembled boot ROM. Every request the
-- router passes on to its external link is served in-process by the
-- authoritative 'Nds.Gpu.Live' device. No melonDS, no trace, no oracle pixels:
-- the host only advances one monotone guest clock, services every device
-- deadline when due, feeds the device's ARM9 IRQ requests into IF, and reads
-- back the frames the device completed.
--
-- Scope (honest limits): one ARM9 slice with a 4 KiB boot ROM and its local
-- RAM, timers and the IME/IE/IF latch driving the slice's IRQ input;
-- no FIQ, ARM7, cartridge, BIOS, DMA engine or IPC. Device effects are
-- accounted explicitly instead of being discarded:
--   * ARM9 IRQ set/clear masks go into the router's IF in the cycle they are
--     serviced (effects of a GPU write or IF acknowledge: the next cycle).
--     The resulting IRQ level is checked and reported. Whether the CPU takes
--     it depends on the program's CPSR I bit (the shipped fixtures keep the
--     reset I=1 and poll IF).
--   * ARM9 DMA start conditions are counted against four reset-disabled
--     channels. Any condition that needs a data transfer to produce correct
--     output (display FIFO, GX FIFO) fails the run instead.
--   * ARM7 effects are reported; this slice has no ARM7.
--
-- The host checks every router-served read reply, the IF register and the
-- IRQ level each cycle against its own model: TM0 count arithmetic from the
-- accepted start/stop cycles, and IF events (timer overflows, GPU sets and
-- clears, CPU write-one-to-clear). The model covers the register forms the
-- fixtures use; any other router-served access fails as unmodelled.
--
-- Clock: one 'socStep' per ARM9 tick; the GPU/LCD time domain (33 MHz, 2130
-- per scanline) is tick/2, and the timer clock ticks on odd cycles. Nominal,
-- not ARM946E-S cycle accurate.
--
-- Output: BGRA frames as NDSF records (same layout as TraceView/fbdump),
-- BMP snapshots, and a PASS/FAIL report with the acceptance checks.
module Main (main) where

import Clash.Prelude (BitVector, rnfX)
import Control.Exception (evaluate)
import Control.Monad (forM_, unless, when)
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import Data.IORef
import Data.List (foldl', nub)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import Data.Word (Word8, Word16, Word32, Word64)
import Foreign.Marshal.Array (mallocArray, peekArray)
import Foreign.Marshal.Utils (fillBytes)
import Numeric (readHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO
import Text.Printf (printf, hPrintf)
import Nds.Gpu.Live
import Nds.Gpu.LiveMemory (readGpuMemory, writeGpuMemory)
import Nds.WholeCore.Arm9Io (IoOut(..), ioLocal)
import Nds.WholeCore.Arm9Slice (SliceOut(..))
import Nds.WholeCore.Arm9Soc

data Config = Config
  { cfgRom :: FilePath, cfgFrames :: Int, cfgOut :: Maybe FilePath
  , cfgNdsf :: Maybe FilePath, cfgStall :: Int, cfgSoc :: Bool }

parseArgs :: [String] -> Config -> Either String Config
parseArgs [] c = Right c
parseArgs ("--frames":n:r) c = parseArgs r c { cfgFrames = read n }
parseArgs ("--out":d:r) c = parseArgs r c { cfgOut = Just d }
parseArgs ("--ndsf":f:r) c = parseArgs r c { cfgNdsf = Just f }
parseArgs ("--stall-every":n:r) c = parseArgs r c { cfgStall = read n }
parseArgs ("--soc":r) c = parseArgs r c { cfgSoc = True }
parseArgs (f:r) c | take 2 f /= "--" && null (cfgRom c) = parseArgs r c { cfgRom = f }
parseArgs (a:_) _ = Left ("unknown argument " ++ a)

usage :: String
usage = "usage: native-slice-frames ROM.hex [--frames N] [--out DIR] [--ndsf FILE|-] [--stall-every N] [--soc]\n\
        \  --soc  also require the hs_native_soc.S timer/IRQ acceptance"

-- | Accepted GPU request held across the link until the reply is taken.
data Req = Req { rqWrite :: !Bool, rqAddr :: !Word32, rqWidth :: !Int, rqLanes :: !Int, rqData :: !Word32 }
  deriving (Eq, Show)

data Stats = Stats
  { stRetired :: !Int, stReqs :: !(M.Map String Int), stStalls :: !Int
  , stIrq9 :: !(M.Map Int Int), stDma9 :: !(M.Map Int Int)
  , stArm7 :: !Int, stDeadlines :: !Int, stFrameStarts :: !Int }

-- | Host model of the router-served state (module header). Written from the
-- DS register descriptions, independently of Nds.WholeCore.Arm9Io.
data Model = Model
  { mIF :: !Word32, mIE :: !Word32, mIME :: !Bool
  , mTm0 :: !(Maybe (Int, Maybe Int, Word32))  -- ^ start cycle, stop cycle, reload
  , mExpect :: !(Maybe (Maybe Word32))          -- ^ outstanding router reply (read value)
  , mChecked :: !Int, mPulses :: !Int, mW1C :: !Int, mExtSets :: !(M.Map Int Int)
  , mRises :: !Int, mFalls :: !Int, mPrevIrq :: !Bool
  , mMail :: !(M.Map Word32 [Word32]) }        -- ^ local RAM stores, newest first

initialModel :: Model
initialModel = Model 0 0 False Nothing Nothing 0 0 0 M.empty 0 0 False M.empty

-- | Odd cycles in [a, b]: the timer clock ticks on odd ARM9 cycles.
odds :: Int -> Int -> Int
odds a b | b < a = 0
         | otherwise = (b + 1) `div` 2 - a `div` 2

-- | TM0 count at the start of cycle d. A start write counts its own cycle's
-- tick; a stop write does not.
tm0Count :: Model -> Int -> Word32
tm0Count m d = case mTm0 m of
  Nothing -> 0
  Just (c, stop, r) ->
    r + fromIntegral (odds c (maybe d (min d) stop - 1) `mod` fromIntegral (0x10000 - r))

-- | Whether TM0 overflowed on the tick of cycle d-1; the timer block
-- registers that pulse, so IF sees it in cycle d.
tm0Pulse :: Model -> Int -> Bool
tm0Pulse m d = case mTm0 m of
  Nothing -> False
  Just (c, stop, r) ->
    let o = d - 1; n = odds c o
    in odd o && o >= c && maybe True (o <) stop && n > 0 && n `mod` fromIntegral (0x10000 - r) == 0

modelCycle :: Int -> SocOut -> Word32 -> Word32 -> Model -> Either String Model
modelCycle d out es ec m = do
  let cpu = socCpu out; io = socIo out
      level = mIME m && (mIE m .&. mIF m) /= 0
      check ok msg = if ok then Right () else Left (printf "cycle %d: %s" d (msg :: String))
  check (word (regIF io) == mIF m) (printf "IF %08x, model %08x" (word (regIF io)) (mIF m))
  check (irqLine io == level) (printf "IRQ level %s, model %s" (show (irqLine io)) (show level))
  m1 <- case mExpect m of
    Just ex | gpuReplyReady cpu && cpuReplyValid io -> do
      forM_ ex $ \v -> check (word (cpuReplyData io) == v)
        (printf "router reply %08x, model %08x" (word (cpuReplyData io)) v)
      pure m { mExpect = Nothing, mChecked = mChecked m + maybe 0 (const 1) ex }
    _ -> pure m
  let a = word (gpuReqAddr cpu); w = fromIntegral (gpuReqWidth cpu) :: Int; v = word (gpuReqData cpu)
      accepted = gpuReqValid cpu && ioLocal (gpuReqAddr cpu) && cpuReqReady io
      unmodelled = Left (printf "cycle %d: unmodelled router access %s%d %08x" d
                          (if gpuReqWrite cpu then "W" else "R" :: String) w a)
  (m2, cleared) <-
    if not accepted then pure (m1, 0)
    else do
      check (mExpect m1 == Nothing) "overlapping router requests"
      if gpuReqWrite cpu then do
        let running = case mTm0 m of Just (_, Nothing, _) -> True; _ -> False
            ctl = (v `shiftR` 16) .&. 0xc7; r = v .&. 0xffff
        m' <- case (a, w) of
          (0x04000100, 4)
            | testBit ctl 7 && not running && ctl == 0xc0 -> pure m1 { mTm0 = Just (d, Nothing, r) }
            | not (testBit ctl 7) && running, Just (c, _, r0) <- mTm0 m, r0 == r -> pure m1 { mTm0 = Just (c, Just d, r0) }
            | not (testBit ctl 7) && not running -> pure m1
            | otherwise -> unmodelled
          (0x04000214, 4) -> pure m1 { mW1C = mW1C m1 + 1 }
          (0x04000210, 4) -> pure m1 { mIE = v }
          (0x04000208, 4) -> pure m1 { mIME = testBit v 0 }
          _ -> unmodelled
        pure (m' { mExpect = Just Nothing }, if (a, w) == (0x04000214, 4) then v else 0)
      else do
        value <- case (a, w) of
          (0x04000100, 2) -> pure (tm0Count m d)
          (0x04000214, 4) -> pure (mIF m)
          (0x04000210, 4) -> pure (mIE m)
          (0x04000208, 4) -> pure (if mIME m then 1 else 0)
          _ -> unmodelled
        pure (m1 { mExpect = Just (Just value) }, 0)
  let pulse = tm0Pulse m d
      newIF = ((mIF m .&. complement ec) .|. es .|. (if pulse then bit 3 else 0)) .&. complement cleared
      stored = storeValid cpu
  pure m2 { mIF = newIF
          , mPulses = mPulses m2 + fromEnum pulse
          , mExtSets = foldl' (\s b -> M.insertWith (+) b 1 s) (mExtSets m2) [b | b <- [0..31], testBit es b]
          , mRises = mRises m2 + fromEnum (level && not (mPrevIrq m))
          , mFalls = mFalls m2 + fromEnum (not level && mPrevIrq m)
          , mPrevIrq = level
          , mMail = if stored then M.insertWith (++) (word (storeAddr cpu)) [word (storeData cpu)] (mMail m2) else mMail m2 }

main :: IO ()
main = do
  args <- getArgs
  cfg <- either (\e -> hPutStrLn stderr (e ++ "\n" ++ usage) >> exitFailure) pure
           (parseArgs args (Config "" 8 Nothing Nothing 5 False))
  when (null (cfgRom cfg)) (hPutStrLn stderr usage >> exitFailure)
  rom <- mapM parseWord . words =<< readFile (cfgRom cfg)
  when (length rom > 1024) (fail "ROM exceeds the 4 KiB boot window")
  ndsf <- traverse (\p -> if p == "-" then pure stdout else openBinaryFile p WriteMode) (cfgNdsf cfg)
  let report = if cfgNdsf cfg == Just "-" then stderr else stdout
  pixels <- mallocArray (256*384)
  fillBytes pixels 0 (256*384*4)
  live0 <- newLive 0 pixels
  -- The LCD frame starts at guest time 0 with whatever the device holds.
  (live1, fx0) <- startFrame 0 0 live0
  stats <- newIORef (Stats 0 M.empty 0 M.empty M.empty 0 0 1)
  account stats fx0
  frames <- newIORef ([] :: [(Word64, Maybe (Maybe Int), Int)])
  captured <- newIORef (0 :: Int)
  let romArr = listArray (0, length rom - 1) rom :: UArray Int Word32
      fetch addr
        | addr >= 0xffff0000 && addr .&. 3 == 0 && idx < length rom = romArr ! idx
        | otherwise = 0xe7f000f0 -- permanently undefined: faults if executed
        where idx = fromIntegral ((addr - 0xffff0000) `div` 4)

      -- Service every deadline <= now, in order, including equal-time chains,
      -- and collect the ARM9 IF set/clear masks they produce. A completed
      -- frame is captured, then the next frame starts at exactly the EndFrame
      -- time (263 lines * 2130 after the previous start).
      service now live es ec = case deadline live of
        Just d | d <= now -> do
          (live', fx) <- advanceLive d live
          modifyIORef' stats (\s -> s { stDeadlines = stDeadlines s + 1 })
          account stats fx
          let es' = es .|. irqSet9 fx; ec' = ec .|. irqClear9 fx
          if frameCompleted fx then do
            px <- peekArray (256*384) (livePixels live')
            let kind = classify px; colours = length (nub (take 4096 px))
            _ <- evaluate kind
            modifyIORef' frames ((liveFrame live', kind, colours) :)
            modifyIORef' captured (+ 1)
            hPrintf report "frame %d completed at guest time %d (tick %d): %s (%d+ distinct colours in first 16 lines)\n"
              (liveFrame live') d (2*d) (describe kind) colours
            forM_ ndsf (\h -> emitNdsf h (fromIntegral (liveFrame live')) px)
            forM_ (cfgOut cfg) $ \dir -> writeBmp (printf "%s/frame-%03d.bmp" dir (liveFrame live')) px
            (live'', fx') <- startFrame d 0 live'
            modifyIORef' stats (\s -> s { stFrameStarts = stFrameStarts s + 1 })
            account stats fx'
            service now live'' (es' .|. irqSet9 fx') (ec' .|. irqClear9 fx')
          else service now live' es' ec'
        _ -> pure (live, es, ec)

      gpu now live r = do
        let a = rqAddr r; w = rqWidth r; v = rqData r
            mem = a `shiftR` 24 == 6
            kind = (if mem then "VRAM " else "IO ") ++ (if rqWrite r then "W" else "R") ++ show w
        modifyIORef' stats (\s -> s { stReqs = M.insertWith (+) kind 1 (stReqs s) })
        unless (w `elem` [1,2,4] && a .&. fromIntegral (w-1) == 0
                && rqLanes r == (((1 `shiftL` w) - 1) `shiftL` fromIntegral (a .&. 3)))
          (fail (printf "malformed GPU request %s" (show r)))
        if mem then do
          -- Same synchronization obligation as the ABI2 service memory ops.
          when (maybe False (<= now) (deadline live)) (fail "GPU memory request before due deadline")
          (st, fx) <- advanceLive now live
          unless (fx == noEffects) (fail "GPU memory synchronization produced an effect")
          if rqWrite r then do
            m <- either fail pure (writeGpuMemory (liveMaps st) (livePower st) (liveMemory st) 0 w a v)
            pure (st { liveMemory = m }, 0, noEffects)
          else do
            x <- either fail pure (readGpuMemory (liveMaps st) (livePower st) (liveMemory st) 0 w a)
            pure (st, x, noEffects)
        else if rqWrite r then do
          (st, fx) <- writeIORegister now 0 w a v live
          account stats fx
          pure (st, 0, fx)
        else do
          (st, x) <- readIORegister now 0 w a live
          pure (st, x, noEffects)

      loop :: Int -> SocState -> Live -> Maybe Word32 -> Maybe Req -> Word64 -> Word64 -> Model
           -> IO (Int, Model)
      loop !tick soc live pending held carrySet carryClear model = do
        done <- (>= cfgFrames cfg) <$> readIORef captured
        if done then pure (tick, model) else do
          let now = fromIntegral (tick `div` 2) :: Word64
          (live', es, ec) <- service now live carrySet carryClear
          let ready = (cfgStall cfg <= 0 || tick `mod` cfgStall cfg /= 0) && pending == Nothing
              input = SocIn { socBootWord = fromIntegral (fetch (word (socBootAddr soc)))
                            , socGpuReqReady = ready
                            , socGpuReplyValid = isJust pending
                            , socGpuReplyData = maybe 0 fromIntegral pending
                            , socGpuReplyFault = False
                            , socTimerTick = odd tick
                            , socIrqSet = fromIntegral es
                            , socIrqClear = fromIntegral ec
                            , socCardIn = noCartridge }
              (soc', out) = socStep soc input
              cpu = socCpu out; io = socIo out
              req = Req (gpuReqWrite cpu) (word (gpuReqAddr cpu)) (fromIntegral (gpuReqWidth cpu))
                        (fromIntegral (gpuReqLanes cpu)) (word (gpuReqData cpu))
          -- Clash Vec 'replace' leaves per-register thunks that chain old CPU
          -- states in a pure run; force the whole state regularly.
          when (tick .&. 1023 == 0) (evaluate (rnfX soc'))
          when (fault cpu /= 0)
            (fail (printf "ARM9 slice fault %d at %08x (tick %d)" (fromIntegral (fault cpu) :: Int) (word (faultAddr cpu)) tick))
          model' <- either fail pure (modelCycle tick out (fromIntegral es) (fromIntegral ec) model)
          forM_ held $ \h -> unless (extReqValid io && req == h) (fail "GPU request changed while backpressured")
          when (retireValid cpu) (modifyIORef' stats (\s -> s { stRetired = stRetired s + 1 }))
          when (extReqValid io && not ready) (modifyIORef' stats (\s -> s { stStalls = stStalls s + 1 }))
          let afterReply = if extReplyReady io then Nothing else pending
          (live'', pending', fxW) <-
            if extReqValid io && ready then do
              when (afterReply /= Nothing) (fail "overlapping GPU requests")
              (st, x, fx) <- gpu now live' req
              pure (st, Just x, fx)
            else pure (live', afterReply, noEffects)
          -- A CPU IF write lets the GPU recheck its GX FIFO IRQ (melonDS HsIFAck).
          (live3, fxA) <- if ifAck io /= 0 then acknowledgeIF now 0 live'' else pure (live'', noEffects)
          account stats fxA
          loop (tick + 1) soc' live3 pending' (if extReqValid io && not ready then Just req else Nothing)
               (irqSet9 fxW .|. irqSet9 fxA) (irqClear9 fxW .|. irqClear9 fxA) model'

  (ticks, model) <- loop 0 initialSoc live1 Nothing Nothing (irqSet9 fx0) (irqClear9 fx0) initialModel
  forM_ ndsf $ \h -> do
    emitEnd h 0 (printf "native slice stopped after %d ticks" ticks)
    when (h /= stdout) (hClose h)
  caps <- reverse <$> readIORef frames
  st <- readIORef stats
  ok <- acceptance report caps
  socOk <- if cfgSoc cfg then socAcceptance report model else pure True
  hPrintf report "ticks %d, guest GPU time %d, instructions retired %d\n" ticks (ticks `div` 2) (stRetired st)
  hPrintf report "GPU link requests %s, backpressured cycles %d\n" (show (M.toList (stReqs st))) (stStalls st)
  hPrintf report "device deadlines serviced %d, LCD frame starts %d\n" (stDeadlines st) (stFrameStarts st)
  hPrintf report "router replies checked against host model %d; TM0 overflow pulses %d; IF W1C writes %d\n"
    (mChecked model) (mPulses model) (mW1C model)
  hPrintf report "GPU ARM9 IRQ sets into IF %s; IRQ level rises %d, falls %d (level drives the CPU IRQ input; taken only if CPSR.I=0)\n"
    (show (M.toList (mExtSets model))) (mRises model) (mFalls model)
  hPrintf report "ARM9 DMA start conditions %s (all four channels reset-disabled: no transfer)\n"
    (show (M.toList (stDma9 st)))
  hPrintf report "ARM7 effects observed %d (no ARM7 in this slice)\n" (stArm7 st)
  if ok && socOk
    then hPutStrLn report ("PASS: Clash ARM9 slice" ++ (if cfgSoc cfg then " + timers/IRQ latch" else "")
                           ++ " drove the authoritative Haskell GPU to completed frames")
    else hPutStrLn report "FAIL" >> exitFailure
 where
  parseWord s = case readHex s of
    [(n, "")] -> pure (n :: Word32)
    _ -> fail ("bad ROM word: " ++ s)

word :: BitVector 32 -> Word32
word = fromIntegral

account :: IORef Stats -> Effects -> IO ()
account ref e = do
  let bitsOf x = [i | i <- [0..63], testBit x i]
      needsTransfer = [i | i <- bitsOf (dma9 e), i `elem` [4, 7]]
  unless (null needsTransfer)
    (fail ("DMA condition needing a transfer this slice cannot perform: " ++ show needsTransfer))
  modifyIORef' ref $ \s -> s
    { stIrq9 = foldl' (\m i -> M.insertWith (+) i 1 m) (stIrq9 s) (bitsOf (irqSet9 e))
    , stDma9 = foldl' (\m i -> M.insertWith (+) i 1 m) (stDma9 s) (bitsOf (dma9 e))
    , stArm7 = stArm7 s + length (bitsOf (irqSet7 e) ++ bitsOf (irqClear7 e) ++ bitsOf (dma7 e)) }

-- | hs_native_soc.S mailbox acceptance (values the CPU actually loaded and
-- stored to local RAM), on top of the per-cycle model checks.
socAcceptance :: Handle -> Model -> IO Bool
socAcceptance report m = do
  let mail off = M.findWithDefault [] (0x02000000 + off) (mMail m)
      timerSeen = mail 4; vblankSeen = mail 24; polls = mail 8
  hPrintf report "mailbox: IE %s IME %s; per frame (oldest first) IF@timer %s polls %s TM0 start/detect/stop %s/%s/%s IF after W1C %s IF@VBlank %s t %s\n"
    (hexes (mail 32)) (hexes (mail 36)) (hexes (reverse timerSeen)) (show (reverse polls))
    (hexes (reverse (mail 0))) (hexes (reverse (mail 12))) (hexes (reverse (mail 20)))
    (hexes (reverse (mail 16))) (hexes (reverse vblankSeen)) (show (reverse (mail 28)))
  let checks =
        [ ("router-served replies matched the host model", mChecked m > 0)
        , ("IE/IME read back 0x9 / 1", mail 32 == [9] && mail 36 == [1])
        , ("CPU saw the TM0 IRQ latched in IF at least 3 times", length timerSeen >= 3 && all (`testBit` 3) timerSeen)
        , ("TM0 overflowed at least 3 times", mPulses m >= 3)
        , ("CPU saw the GPU VBlank IRQ latched in IF at least 3 times", length vblankSeen >= 3 && all (`testBit` 0) vblankSeen)
        , ("IRQ level rose and fell at least 3 times", mRises m >= 3 && mFalls m >= 3) ]
  forM_ checks $ \(n, ok) -> hPutStrLn report ((if ok then "  ok   " else "  FAIL ") ++ n)
  pure (all snd checks)
 where hexes = show . map (printf "%x" :: Word32 -> String)

-- | The fixture's pattern, written independently of the ARM program.
expected :: Int -> Int -> Int -> Word16
expected t x y = fromIntegral (r .|. (g `shiftL` 5) .|. (b `shiftL` 10))
  where r = (((x + 4*t) `xor` y) `shiftR` 3) .&. 31
        g = ((y `shiftR` 2) + t) .&. 31
        b = ((191 - y) `shiftR` 3) .&. 31

-- | 8-bit channel back to the 5-bit DS value (holds for both 5->8 and 5->6->8 expansion).
to15 :: Word32 -> Word16
to15 p = fromIntegral (c 16 .|. (c 8 `shiftL` 5) .|. (c 0 `shiftL` 10))
  where c sh = (p `shiftR` (sh + 3)) .&. 31

-- | Top screen: the reset-black bank A shown before the first flip, exactly
-- one complete buffer t of the pattern, or neither (Nothing).
classify :: [Word32] -> Maybe (Maybe Int)
classify px
  | all (== 0) top = Just Nothing
  | otherwise = case [t | t <- [0..63], and (zipWith (==) top [expected t x y | y <- [0..191], x <- [0..255]])] of
      [t] -> Just (Just t)
      _ -> Nothing
  where top = map to15 (take (256*192) px)

describe :: Maybe (Maybe Int) -> String
describe Nothing = "MISMATCH (not a complete pattern buffer)"
describe (Just Nothing) = "reset-black bank A (before first flip)"
describe (Just (Just t)) = "complete buffer t=" ++ show t

-- | Acceptance: every captured frame completed through the LCD path and is
-- classified; buffers advance one t at a time and at least three distinct
-- buffers were displayed.
acceptance :: Handle -> [(Word64, Maybe (Maybe Int), Int)] -> IO Bool
acceptance report kinds = do
  let shown = [t | (_, Just (Just t), _) <- kinds]
      steps = zipWith (\a b -> (b - a) `mod` 64) shown (drop 1 shown)
      allValid = all (\(_, k, _) -> k /= Nothing) kinds
      prefixBlack = all (\(_, k, _) -> k == Just Nothing) (takeWhile (\(_, k, _) -> k /= Just (Just 0)) kinds)
  hPrintf report "displayed buffers in order: %s\n" (show shown)
  let checks = [ ("every frame completed via LCD EndFrame and is classified", allValid && not (null kinds))
               , ("only reset-black frames precede buffer t=0", prefixBlack)
               , ("buffers advance by 0 or 1 between frames", all (`elem` [0, 1]) steps)
               , ("at least three distinct buffers displayed", length (nub shown) >= 3) ]
  forM_ checks $ \(n, ok) -> hPutStrLn report ((if ok then "  ok   " else "  FAIL ") ++ n)
  pure (all snd checks)

emitNdsf :: Handle -> Word32 -> [Word32] -> IO ()
emitNdsf h frame px = do
  BB.hPutBuilder h (BB.string7 "NDSF" <> BB.word32LE frame <> BB.word32LE 0 <> BB.word32LE 0
                    <> BB.word32LE 0 <> foldMap BB.word32LE px)
  hFlush h

emitEnd :: Handle -> Word32 -> String -> IO ()
emitEnd h status msg = do
  let bytes = B.pack (map (fromIntegral . fromEnum) msg)
  BB.hPutBuilder h (BB.string7 "NDSE" <> BB.word32LE status <> BB.word32LE (fromIntegral (B.length bytes))
                    <> BB.word64LE 0 <> BB.byteString bytes)
  hFlush h

-- | 24-bit bottom-up BMP of the 256x384 dual-screen frame (top screen first).
writeBmp :: FilePath -> [Word32] -> IO ()
writeBmp path px = withBinaryFile path WriteMode $ \h -> BB.hPutBuilder h $
  BB.string7 "BM" <> BB.word32LE (54 + size) <> BB.word32LE 0 <> BB.word32LE 54
  <> BB.word32LE 40 <> BB.int32LE 256 <> BB.int32LE 384 <> BB.word16LE 1 <> BB.word16LE 24
  <> BB.word32LE 0 <> BB.word32LE size <> BB.word32LE 2835 <> BB.word32LE 2835
  <> BB.word32LE 0 <> BB.word32LE 0
  <> foldMap row [383, 382 .. 0]
 where
  size = 256*384*3
  rows = chunks px
  row y = foldMap (\p -> BB.word8 (byte p 0) <> BB.word8 (byte p 8) <> BB.word8 (byte p 16)) (rows !! y)
  byte p sh = fromIntegral (p `shiftR` sh) :: Word8
  chunks [] = []
  chunks xs = let (a, b) = splitAt 256 xs in a : chunks b
