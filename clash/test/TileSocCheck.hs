{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}

-- | Gate for "Nds.WholeCore.TileSoc" (Clash top @nds_tile_soc@): the Clash
-- ARM9 runs an assembled boot-ROM program (sim/tests/hs_tile_arm9.S) that
-- programs Kirby's measured video mode on both 2D engines and animates it
-- from its VBlank IRQ; the shared tile engine draws both screens on DS line
-- timing.
--
-- > tilesoc-check check ROM.hex FRAMES [--expect cpu:ADDR | --expect gpu:BIT]
-- > tilesoc-check dump  ROM.hex FRAMES
--
-- check runs the pure SoC step (the ARM9's 'socStep', 'gpuStep', the
-- engine's 'tileStep' and models of every block RAM) for FRAMES frames from
-- reset and, in lockstep, feeds the authoritative "Nds.Gpu.Live" device the
-- same ordered GPU link transactions at the same cycle times (one cycle =
-- one Live time unit; frame k starts at cycle 1 + k * 560,190), servicing
-- every Live deadline first, as the ABI2 GPU service does. Every read must
-- return the value Live returns, every IF bit Live raises (VBlank/HBlank/
-- VCount) must be raised by the SoC in the same cycle and vice versa, and
-- when Live completes frame k, all 2 x 49,152 pixels of both screens must
-- equal the SoC's scanned-out frame k (taken from its video output).
--
-- The circuit itself is checked through its generated Verilog (dump plus
-- tests/tilesoc_cosim.cpp), not through Clash's Signal simulation of
-- 'tileSoc': that simulation keeps the ARM9 SoC's unused card and I/O
-- output streams alive (a heap profile showed CardState, IoIn and SliceOut
-- cells and Signal cons cells growing) and exhausts 3 GiB within a frame.
--
-- It also reports the CPU's speed (instructions per frame, cycles to finish
-- the scene setup), the IRQ entries and the animation (pixels that changed
-- from frame to frame). --expect makes the run a fail-closed check: it must
-- stop with that CPU fault address (link error) or GPU fault bit.
--
-- dump prints the pure model's top-level outputs, one line per cycle, for
-- the Verilator replay (tests/tilesoc_cosim.cpp, which compares as it
-- reads; nothing is written to disk).
module Main (main) where

import qualified Clash.Prelude as C
import Clash.Prelude (BitVector, rnfX)
import qualified Clash.Sized.Vector as V

import Control.Monad (forM_, unless, when)
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.))
import qualified Data.ByteString.Builder as BB
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.IORef
import Data.List (sortOn)
import Data.Maybe (isNothing)
import qualified Data.Sequence as Seq
import Data.Sequence (Seq, ViewL (..), viewl, (|>))
import Data.Word (Word32, Word64)
import Foreign.Marshal.Array (mallocArray, peekArray)
import Numeric (readHex, showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (BufferMode (..), hPutStrLn, hSetBinaryMode, hSetBuffering, stderr, stdout)
import Text.Printf (printf)

import Nds.Gpu.Live
import Nds.Gpu.LiveMemory (readGpuMemory, writeGpuMemory)
import Nds.Gpu2D.TileHw
import Nds.WholeCore.Arm9Soc (SocState, initialSoc, socStep)
import Nds.WholeCore.Arm9Slice (SliceOut (..))
import Nds.WholeCore.Arm9Soc (SocOut (..))
import Nds.WholeCore.TileSoc

------------------------------------------------------------------------------
-- ROM

type Rom = UArray Int Word32

loadRom :: FilePath -> IO Rom
loadRom p = do
  ws <- map (fst . head . readHex) . filter (not . null) . lines <$> readFile p
  when (length ws > 1024) $ die' (p ++ ": more than 1024 words (the 4 KiB boot window)")
  pure (listArray (0, 1023) (ws ++ replicate (1024 - length ws) 0))

-- | The boot ROM as emu.sv serves it: 4 KiB at 0xffff0000, zero elsewhere.
romWord :: Rom -> Word32 -> Word32
romWord rom a = if a .&. 0xfffff000 == 0xffff0000 then rom ! fromIntegral ((a `shiftR` 2) .&. 1023) else 0

------------------------------------------------------------------------------
-- Pure SoC with block-RAM models

data ERam = ERam
  { eMap, eRow, ePal, eLb, eObj :: !(IM.IntMap Integer)
  , eDesc :: !(IM.IntMap Desc)
  , eOam, eExt :: ![IM.IntMap Integer] }

data P = P
  { pCpu :: !SocState, pGpu :: !Gpu, pEng :: !St
  , pE :: !ERam, pEQ :: !RamQ
  , pV :: ![IM.IntMap (BitVector 16)], pVQ :: !VramQ
  , pD :: !(IM.IntMap (BitVector 16)), pDQ :: !(BitVector 16)
  , pCyc :: !Int }

descZero :: Desc
descZero = C.unpack 0

pInit :: P
pInit = P initialSoc initialGpu stInit
  (ERam IM.empty IM.empty IM.empty IM.empty IM.empty IM.empty [IM.empty, IM.empty, IM.empty] [IM.empty, IM.empty])
  (RamQ 0 0 0 (C.repeat 0) 0 descZero 0 (C.repeat 0))
  (replicate 16 IM.empty) (C.repeat (C.repeat 0)) IM.empty 0 0

strictL :: [a] -> [a]
strictL xs = foldr seq () xs `seq` xs

-- | One read port and one write port per RAM; read data is the old
-- contents when the same address is written.
engRam :: ERam -> RamOps -> (ERam, RamQ)
engRam e ops = (e', q)
  where
    rd :: (Integral k, Num a) => IM.IntMap Integer -> k -> a
    rd m a = fromInteger (IM.findWithDefault 0 (fromIntegral a) m)
    wr :: (Integral k, Integral a) => IM.IntMap Integer -> Maybe (k, a) -> IM.IntMap Integer
    wr m w = case w of Just (a, v) -> IM.insert (fromIntegral a) (toInteger v) m; Nothing -> m
    q = RamQ (rd (eMap e) (opMapRd ops)) (rd (eRow e) (opRowRd ops)) (rd (ePal e) (opPalRd ops))
             (V.unsafeFromList (strictL [rd m (opOamRd ops) | m <- eOam e]))
             (rd (eLb e) (opLbRd ops)) (IM.findWithDefault descZero (fromIntegral (opDescRd ops)) (eDesc e))
             (rd (eObj e) (opObjRd ops))
             (V.unsafeFromList (strictL [rd m (opExtRd ops) | m <- eExt e]))
    e' = ERam (wr (eMap e) (opMapWr ops)) (wr (eRow e) (opRowWr ops)) (wr (ePal e) (opPalWr ops))
              (wr (eLb e) (opLbWr ops)) (wr (eObj e) (opObjWr ops))
              (case opDescWr ops of Just (a, v) -> IM.insert (fromIntegral a) v (eDesc e); Nothing -> eDesc e)
              (strictL (zipWith wr (eOam e) (C.toList (opOamWr ops))))
              (strictL (zipWith wr (eExt e) (C.toList (opExtWr ops))))

vramRam :: [IM.IntMap (BitVector 16)] -> VramOps -> ([IM.IntMap (BitVector 16)], VramQ)
vramRam ms ops = (strictL ms', q)
  where
    width b = if b == 0 || b == 2 then 4096 else 512 :: Int
    rdAddr b = fromIntegral (voRd ops C.!! b) `mod` width b
    q = V.unsafeFromList [ V.unsafeFromList [ IM.findWithDefault 0 (rdAddr b) (ms !! (4 * b + l)) | l <- [0 .. 3] ] | b <- [0 .. 3 :: Int] ]
    ms' = [ case (voWr ops C.!! b) C.!! l of
              Just (a, v) -> IM.insert (fromIntegral a `mod` width b) v (ms !! (4 * b + l))
              Nothing -> ms !! (4 * b + l)
          | b <- [0 .. 3 :: Int], l <- [0 .. 3 :: Int] ]

-- | One cycle of the pure SoC. Cycle 0 is the reset cycle: every register
-- keeps its reset value through it, as Clash's simulation and the Verilog do.
-- Also returns whether the tile engine is busy (not ready) this cycle.
stepP :: Rom -> P -> (P, TopOut, Bool)
stepP rom p = forced `seq` p' `seq` (p', top, not (toReady tout))
  where
    link = gpuLinkOut (pGpu p)
    (cpu', cpuOut) = socStep (pCpu p) (socInFrom (fromIntegral (romWord rom (fromIntegral (bootAddr (socCpu cpuOut))))) link)
    (gpu', gout) = gpuStep (pGpu p) (GpuIn cpuOut tout (pVQ p) (pDQ p))
    (eng', tout, eops) = tileStep (pEng p) (goTile gout) (pEQ p)
    (e', eq') = engRam (pE p) eops
    (v', vq') = vramRam (pV p) (goVram gout)
    dq' = IM.findWithDefault 0 (fromIntegral (goDispRd gout)) (pD p)
    d' = case goDispWr gout of Just (a, x) -> IM.insert (fromIntegral a) x (pD p); Nothing -> pD p
    rst = pCyc p == 0
    -- every register field is forced every 64 cycles: an unread field would
    -- otherwise keep an unbounded chain of old states alive (one unforced
    -- frame reached 1.9 GB resident); forcing every cycle walks the CPU's
    -- 1,024-word RAM vector each time (98 s per frame against 30 s)
    forced
      | pCyc p `mod` 64 == 0 = rnfX (pCpu p') `seq` rnfX (pGpu p') `seq` rnfX (pEng p') `seq` rnfX (pEQ p')
          `seq` rnfX (pVQ p') `seq` rnfX (pDQ p')
      | otherwise = ()
    p' = P (if rst then initialSoc else cpu') (if rst then initialGpu else gpu') (if rst then stInit else eng')
           e' eq' v' vq' d' dq' (pCyc p + 1)
    top = topOf cpuOut gout

------------------------------------------------------------------------------
-- The authoritative reference

frameCycles :: Word64
frameCycles = fromIntegral (lineCycles * lineCount)

data Ref = Ref
  { rLive :: !Live
  , rNextStart :: !Word64
  , rIrqs :: !(Seq (Word64, Word64))   -- IF bits Live raised, in order
  , rFrames :: !Int                     -- frames Live completed
  , rUnexpected :: ![String] }

-- | Effects the reference raised: IF set bits are kept for comparison; any
-- other effect than DMA requests (which this SoC has no DMA for) is noted.
noteFx :: Word64 -> Effects -> Ref -> Ref
noteFx t fx r = r { rIrqs = if irqSet9 fx /= 0 then rIrqs r |> (t, irqSet9 fx) else rIrqs r
                  , rUnexpected = [ "Live effect at " ++ show t ++ ": " ++ show fx
                                  | irqClear9 fx /= 0 || irqSet7 fx /= 0 || irqClear7 fx /= 0 ] ++ rUnexpected r }

newtype Frame = Frame (UArray Int Word32)

-- | Service every Live deadline and frame start up to time t; a completed
-- frame is handed to 'onFrame'.
refAdvance :: IORef Ref -> (Int -> [Word32] -> IO ()) -> Word64 -> IO ()
refAdvance ref onFrame t = loop
  where
    loop = do
      r <- readIORef ref
      let l = rLive r
          dl = deadline l
          fs = if isNothing (liveLCD l) then Just (rNextStart r) else Nothing
          nxt = case (dl, fs) of
            (Just a, Just b) -> Just (min a b)
            (Just a, Nothing) -> Just a
            (Nothing, b) -> b
      case nxt of
        Just te | te <= t ->
          if dl == Just te
            then do
              (l', fx) <- advanceLive te l
              let r' = noteFx te fx r { rLive = l' }
              writeIORef ref r'
              when (frameCompleted fx) $ do
                px <- peekArray (256 * 384) (livePixels l')
                onFrame (rFrames r') px
                modifyIORef' ref (\x -> x { rFrames = rFrames x + 1 })
              loop
            else do
              (l', fx) <- startFrame te 0 l
              writeIORef ref (noteFx te fx r { rLive = l', rNextStart = rNextStart r + frameCycles })
              loop
        _ -> pure ()

-- | Apply one completed SoC link transaction to Live at time t; return a
-- mismatch message for a read whose value differs.
refTxn :: IORef Ref -> (Int -> [Word32] -> IO ()) -> Word64 -> TopOut -> IO [String]
refTxn ref onFrame t o = do
  refAdvance ref onFrame t
  r <- readIORef ref
  let l = rLive r
      a = fromIntegral (tTxnAddr o) :: Word32
      w = fromIntegral (tTxnWidth o) :: Int
      v = fromIntegral (tTxnValue o) :: Word32
      io = a < 0x05000000
  if tTxnWrite o
    then if io
      then do
        (l', fx) <- writeIORegister t 0 w a v l
        writeIORef ref (noteFx t fx r { rLive = l' })
        pure []
      else do
        (l1, fx) <- advanceLive t l
        unless (fx == noEffects) (fail "Live produced an effect at a memory access")
        mem <- either fail pure (writeGpuMemory (liveMaps l1) (livePower l1) (liveMemory l1) 0 w a v)
        writeIORef ref r { rLive = l1 { liveMemory = mem } }
        pure []
    else do
      (l', val) <- if io
        then readIORegister t 0 w a l
        else do
          (l1, _) <- advanceLive t l
          x <- either fail pure (readGpuMemory (liveMaps l1) (livePower l1) (liveMemory l1) 0 w a)
          pure (l1, x)
      writeIORef ref r { rLive = l' }
      pure [ printf "read %08x (width %d) at cycle %d: SoC %08x, Live %08x" a w t v val | val /= v ]

------------------------------------------------------------------------------
-- Check

-- | Run totals, all strict: nothing in here may keep a cycle's outputs (and
-- through them its whole state) alive.
data Acc = Acc
  { aCyc :: !Int, aTxns :: !Int, aReads :: !Int, aWrites :: !Int, aRetired :: !Int
  , aPix :: ![Word32], aPixN :: !Int        -- picture pixels of the frame being scanned (reversed)
  , aIrqSoc :: !Int, aMism :: !Int, aMsgs :: ![String]
  , aMagic :: !(Maybe Int)                  -- cycle of the 0xCAFEBABE mailbox store
  , aIrqEntries :: ![(Int, Word32)]         -- (cycle, count) of the handler's count stores (reversed)
  , aLoopLast :: !Word32, aVcLast :: !Word32
  , aLoopAt :: ![Word32], aRetiredAt :: ![Int]   -- at frame starts (reversed)
  , aBusyWin :: !Int                        -- engine busy cycles since the last HBlank
  , aBusyMax :: !Int, aBusyMaxAt :: !Int, aBusySum :: !Int, aBusyWins :: !Int   -- from frame 1 on
  , aLastWr :: !Int, aGaps :: !(IM.IntMap Int)   -- cycle of the last GPU link write; gap counts
  , aFault :: !(Maybe String) }

die' :: String -> IO a
die' m = hPutStrLn stderr m >> exitFailure

checkMode :: FilePath -> Int -> Maybe String -> IO ()
checkMode romPath frames expect = do
  rom <- loadRom romPath
  pixels <- mallocArray (256 * 384)
  live0 <- newLive 0 pixels
  ref <- newIORef (Ref live0 1 Seq.empty 0 [])
  socFramesRef <- newIORef (Seq.empty :: Seq Frame)
  results <- newIORef ([] :: [(Int, Int, Int, Int)])   -- frame, mismatches, distinct colours, changed from previous
  firstDiffs <- newIORef ([] :: [String])
  prevFrame <- newIORef (Nothing :: Maybe (UArray Int Word32))
  let onFrame k px = do
        q <- readIORef socFramesRef
        case viewl q of
          Frame soc :< rest -> do
            writeIORef socFramesRef rest
            let liveArr = listArray (0, 256 * 384 - 1) px :: UArray Int Word32
                at y x = if x < 256 then liveArr ! (y * 256 + x) else liveArr ! (49152 + y * 256 + x - 256)
                diffs = [ (y, x, soc ! (y * 512 + x), at y x .&. 0xffffff)
                        | y <- [0 .. 191], x <- [0 .. 511], soc ! (y * 512 + x) /= at y x .&. 0xffffff ]
                cols = IS.size (IS.fromList [ fromIntegral (soc ! i) | i <- [0 .. 512 * 192 - 1] ])
            prev <- readIORef prevFrame
            let changed = maybe 0 (\pv -> length [ () | i <- [0 .. 512 * 192 - 1], pv ! i /= soc ! i ]) prev
            writeIORef prevFrame (Just soc)
            modifyIORef' results ((k, length diffs, cols, changed) :)
            unless (null diffs) $ modifyIORef' firstDiffs
              (++ take 3 [ printf "frame %d line %d x %d (%s screen): SoC %06x, Live %06x" k y (x `mod` 256)
                              (if x < 256 then "top" else "bottom" :: String) s lv | (y, x, s, lv) <- diffs ])
          EmptyL -> modifyIORef' firstDiffs (++ ["Live completed frame " ++ show k ++ " before the SoC scanned it out"])
      totalCycles = 1 + frames * fromIntegral frameCycles + 4
      loop !p !acc
        | aCyc acc >= totalCycles || isJustS (aFault acc) = pure acc
        | otherwise = do
            let (p', o, busy) = stepP rom p
                c = aCyc acc
                t = fromIntegral c :: Word64
            -- transactions complete one cycle before their probe
            txnMsgs <- if tTxnValid o && not (tTxnFault o)
              then refTxn ref onFrame (t - 1) o else pure []
            -- IF bits: Live's must come in the same cycles
            irqMsgs <- if tIrqSet o /= 0
              then do
                refAdvance ref onFrame t
                r <- readIORef ref
                case viewl (rIrqs r) of
                  (lt, lb) :< rest | lt == t && lb == fromIntegral (tIrqSet o) -> do
                    writeIORef ref r { rIrqs = rest }
                    pure []
                  _ -> pure [ printf "cycle %d: SoC raises IF bits %d, Live next %s" c (fromIntegral (tIrqSet o) :: Int)
                                (show (take 1 (foldr (:) [] (rIrqs r)))) ]
              else pure []
            -- a Live IF event the SoC missed shows as an old queue head
            r0 <- readIORef ref
            let missed = case viewl (rIrqs r0) of
                  (lt, lb) :< _ | lt < t -> [ printf "Live raised IF bits %d at cycle %d, the SoC did not" lb lt ]
                  _ -> []
            when (not (null missed)) $ modifyIORef' ref (\x -> x { rIrqs = Seq.drop 1 (rIrqs x) })
            when (c `mod` fromIntegral frameCycles == 0) (refAdvance ref onFrame t)
            -- video: picture pixels, 512 x 192 per frame
            let vbits = tVideo o
                ce = testBit vbits 27
                de = testBit vbits 26
                !rgb = fromIntegral (vbits .&. 0xffffff) :: Word32
                (pix', pixN') = if ce && de then (rgb : aPix acc, aPixN acc + 1) else (aPix acc, aPixN acc)
            (pix'', pixN'') <- if pixN' == 512 * 192
              then do
                let fr = Frame (listArray (0, 512 * 192 - 1) (reverse pix'))
                modifyIORef' socFramesRef (|> fr)
                pure ([], 0)
              else pure (pix', pixN')
            let faultNow
                  | tCpuFault o /= 0 = Just (printf "cpu:%08x" (fromIntegral (tTxnAddr o) :: Word32) ++ " (code " ++ show (fromIntegral (tCpuFault o) :: Int) ++ ")")
                  | tGpuFault o /= 0 = Just ("gpu:" ++ showHex (fromIntegral (tGpuFault o) :: Int) "")
                  | otherwise = Nothing
                storeOk = tStoreValid o && tStoreAddr o >= 0x02000000 && tStoreAddr o < 0x02000018
                !sAddr = fromIntegral (tStoreAddr o) :: Word32
                !sData = fromIntegral (tStoreData o) :: Word32
                frameStartNow = c `mod` fromIntegral frameCycles == 1
                hbNow = c >= 1 && (c - 1) `mod` lineCycles == hblankCycle
                winDone = hbNow && c > fromIntegral frameCycles
                wrNow = tTxnValid o && tTxnWrite o
                faultTxn = if tTxnValid o && tTxnFault o
                             then Just ("cpu:" ++ showHex (fromIntegral (tTxnAddr o) :: Word32) "") else Nothing
                msgs = txnMsgs ++ irqMsgs ++ missed
                acc' = acc
                  { aCyc = c + 1
                  , aTxns = aTxns acc + (if tTxnValid o then 1 else 0)
                  , aReads = aReads acc + (if tTxnValid o && not (tTxnWrite o) then 1 else 0)
                  , aWrites = aWrites acc + (if tTxnValid o && tTxnWrite o then 1 else 0)
                  , aRetired = aRetired acc + (if tRetire o then 1 else 0)
                  , aPix = pix'', aPixN = pixN''
                  , aIrqSoc = aIrqSoc acc + (if testBit (tIrqSet o) 0 then 1 else 0)
                  , aMism = aMism acc + length msgs
                  , aMsgs = if length (aMsgs acc) < 12 then aMsgs acc ++ take 4 msgs else aMsgs acc
                  , aMagic = case aMagic acc of
                      Nothing | storeOk && sAddr == 0x02000004 && sData == 0xCAFEBABE -> Just c
                      m -> m
                  , aIrqEntries = if storeOk && sAddr == 0x02000008 then (c, sData) : aIrqEntries acc else aIrqEntries acc
                  , aLoopLast = if storeOk && sAddr == 0x0200000c then sData else aLoopLast acc
                  , aVcLast = if storeOk && sAddr == 0x02000014 then sData else aVcLast acc
                  , aLoopAt = if frameStartNow then aLoopLast acc : aLoopAt acc else aLoopAt acc
                  , aRetiredAt = if frameStartNow then aRetired acc : aRetiredAt acc else aRetiredAt acc
                  -- engine busy cycles per HBlank-to-HBlank window (the
                  -- line's four jobs run from the HBlank), counted from frame
                  -- 1 on: the first window holds the 1,024-cycle line-buffer
                  -- clear after reset, and frame 0 shows black
                  , aBusyWin = if hbNow then (if busy then 1 else 0) else aBusyWin acc + (if busy then 1 else 0)
                  , aBusyMax = if winDone && aBusyWin acc > aBusyMax acc then aBusyWin acc else aBusyMax acc
                  , aBusyMaxAt = if winDone && aBusyWin acc > aBusyMax acc then c else aBusyMaxAt acc
                  , aBusySum = if winDone && aBusyWin acc > 0 then aBusySum acc + aBusyWin acc else aBusySum acc
                  , aBusyWins = if winDone && aBusyWin acc > 0 then aBusyWins acc + 1 else aBusyWins acc
                  , aLastWr = if wrNow then c else aLastWr acc
                  , aGaps = if wrNow && aLastWr acc > 0 then IM.insertWith (+) (c - aLastWr acc) 1 (aGaps acc) else aGaps acc
                  , aFault = case (faultTxn, faultNow) of
                      (Just f, _) -> Just f
                      (_, Just f) | tGpuFault o /= 0 -> Just f
                      (_, Just f) -> Just f
                      _ -> Nothing }
            loop p' acc'
  acc <- loop pInit (Acc 0 0 0 0 0 [] 0 0 0 [] Nothing [] 0 0 [] [] 0 0 0 0 0 0 IM.empty Nothing)
  -- finish the reference up to the end of the run
  refAdvance ref onFrame (fromIntegral (aCyc acc))
  r <- readIORef ref
  res <- reverse <$> readIORef results
  fd <- readIORef firstDiffs
  let pixMism = sum [ m | (_, m, _, _) <- res ]
      irqCounts = reverse (aIrqEntries acc)
      loopsAt = drop 1 (reverse (aLoopAt acc))
      retiredAt = reverse (aRetiredAt acc)
      perFrame = zipWith (-) (drop 1 retiredAt) retiredAt
      leftIrqs = [ x | x@(lt, _) <- foldr (:) [] (rIrqs r), lt < fromIntegral (aCyc acc) - 1 ]
  printf "program %s: %d cycles (%d frames of 263 x 2,130), %d instructions retired, %d GPU link transactions (%d writes, %d reads)\n"
    romPath (aCyc acc) frames (aRetired acc) (aTxns acc) (aWrites acc) (aReads acc)
  printf "CPU: scene programmed (mailbox 0xCAFEBABE) at cycle %s = frame %s; instructions per frame %s\n"
    (maybe "never" show (aMagic acc)) (maybe "-" (\c -> printf "%.2f" (fromIntegral c / fromIntegral frameCycles :: Double)) (aMagic acc))
    (show perFrame)
  printf "VBlank IRQs: %d raised by the SoC, %d handler entries counted (last count %s), first entries at cycles %s; VCount IRQ handler entries %d; main-loop count at frame starts %s\n"
    (aIrqSoc acc) (length irqCounts) (maybe "-" (show . snd) (safeLast irqCounts))
    (show (take 4 (map fst irqCounts))) (aVcLast acc) (show loopsAt)
  printf "tile engine (A and B shared), from frame 1 on: busy cycles per HBlank-to-HBlank window: max %d (window ending at frame %d line %d), mean %.1f over %d windows with jobs; %d cycles in a line\n"
    (aBusyMax acc) ((aBusyMaxAt acc - 1) `div` fromIntegral frameCycles) (((aBusyMaxAt acc - 1) `mod` fromIntegral frameCycles) `div` lineCycles)
    (if aBusyWins acc == 0 then 0 else fromIntegral (aBusySum acc) / fromIntegral (aBusyWins acc) :: Double) (aBusyWins acc) lineCycles
  let gaps = IM.toList (aGaps acc)
      common = take 3 (sortOn (negate . snd) gaps)
  printf "cycles between consecutive GPU link writes: min %s; most common %s\n"
    (maybe "-" (show . fst) (safeHead' gaps)) (show common)
  printf "frames compared with Nds.Gpu.Live: %d (both screens, %d pixels each); pixel mismatches %d\n"
    (length res) (2 * 49152 :: Int) pixMism
  forM_ res $ \(k, m, cols, ch) ->
    printf "  frame %2d: %d mismatches, %d distinct colours, %d pixels changed from the previous frame\n" k m cols ch
  mapM_ putStrLn (take 6 fd)
  printf "Live IF events not raised by the SoC: %d; other Live effects: %d; reads/IRQ mismatches: %d\n"
    (length leftIrqs) (length (rUnexpected r)) (aMism acc)
  mapM_ putStrLn (take 6 (aMsgs acc ++ take 3 (rUnexpected r)))
  let faultMsg = aFault acc
  printf "fault: %s\n" (maybe "none" id faultMsg)
  let expectOk = case (expect, faultMsg) of
        (Nothing, Nothing) -> True
        (Just e, Just f) -> takeWhile (/= ' ') f == e
        _ -> False
      completeFrames = isJustS expect || length res == frames
      -- once the scene shows, every frame must differ from the one before
      sceneFrames = [ (k, ch) | (k, _, cols, ch) <- res, cols > 1 ]
      still = if isJustS expect then [] else [ k | (k, ch) <- drop 1 sceneFrames, ch == 0 ]
      bad = pixMism + aMism acc + length leftIrqs + length (rUnexpected r)
            + (if expectOk then 0 else 1) + (if completeFrames then 0 else 1) + length still
  unless (null still) $ printf "frames that did not change (no animation): %s\n" (show still)
  printf "tilesoc check: %d failures%s\n" bad (maybe "" (\e -> " (expected fault " ++ e ++ ")") expect)
  when (bad /= 0) exitFailure

isJustS :: Maybe a -> Bool
isJustS = maybe False (const True)

safeHead' :: [a] -> Maybe a
safeHead' (x : _) = Just x
safeHead' [] = Nothing

safeLast :: [a] -> Maybe a
safeLast [] = Nothing
safeLast xs = Just (last xs)

------------------------------------------------------------------------------
-- Dump

dumpMode :: FilePath -> Int -> IO ()
dumpMode romPath frames = do
  rom <- loadRom romPath
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering (Just 65536))
  let totalCycles = 1 + frames * fromIntegral frameCycles + 4
      go !p !c
        | c >= totalCycles = pure ()
        | otherwise = do
            let (p', o, _) = stepP rom p
            BB.hPutBuilder stdout (line c o)
            go p' (c + 1)
  go pInit (0 :: Int)
  where
    h32 x = BB.word32HexFixed (fromIntegral x)
    line c o = h32 (tBootAddr o) <> sp <> h32 (tVideo o) <> sp
      <> BB.wordHex (fromIntegral (fromEnum (tTxnValid o) .|. (fromEnum (tTxnWrite o) `shiftL` 1) .|. (fromEnum (tTxnFault o) `shiftL` 2))) <> sp
      <> h32 (tTxnAddr o) <> sp <> BB.wordHex (fromIntegral (tTxnWidth o)) <> sp <> h32 (tTxnValue o) <> sp
      <> BB.wordHex (fromIntegral (tIrqSet o)) <> sp <> BB.wordHex (fromIntegral (tGpuFault o)) <> sp
      <> BB.wordHex (fromIntegral (tCpuFault o)) <> sp
      <> BB.wordHex (fromIntegral (fromEnum (tStoreValid o) .|. (fromEnum (tRetire o) `shiftL` 1))) <> sp
      <> h32 (tStoreAddr o) <> sp <> h32 (tStoreData o) <> sp <> BB.intDec c <> BB.char7 '\n'
    sp = BB.char7 ' '

------------------------------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs
  case args of
    ("check" : rom : n : rest) -> do
      let expect = case dropWhile (/= "--expect") rest of
            (_ : e : _) -> Just e
            _ -> Nothing
      checkMode rom (read n) expect
    ["dump", rom, n] -> dumpMode rom (read n)
    _ -> die' "usage: tilesoc-check check ROM.hex FRAMES [--expect cpu:ADDR|gpu:BIT] | dump ROM.hex FRAMES"
