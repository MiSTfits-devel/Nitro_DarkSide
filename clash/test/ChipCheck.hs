-- | Native differential checker for the whole-chip model.
--
-- @chip-check SCRIPT VRAM ORACLE_OUT [SCRIPT VRAM ORACLE_OUT ...]@ replays
-- each op script (written by @tests/gen_chip_cases.py@, run by
-- @tools/gx3d_oracle/chip_oracle.cpp@) through 'Nds.Gpu3D.Chip' and compares
-- everything the oracle recorded:
--
-- * after every op, the status word (the ARM9 bus held by a GX FIFO stall,
--   IF bit 21, the number of GX entries the geometry engine took) and the
--   number of GXFIFO DMA triggers;
-- * every ARM9 read value;
-- * every @GetLine@ line of every @L@ op (192 x 256 words).
--
-- The interleaving is the oracle's: each op as one 'ChipIn' event, then, for
-- every op that is not a burst op (@+@ prefix), 'CiRun' (the geometry engine
-- catches up completely). @T@ is 'CiRun' alone. VCOUNT writes become
-- 'CiAbortFrame' by a copy of @GPU::SetVCount@'s next-line-counter compare
-- (that counter is the display timing's register, not the chip's).
module Main (main) where

import Control.Monad (forM, unless, when)
import Data.Array.Unboxed (UArray, bounds, (!))
import Data.Bits (complement, shiftL, testBit, (.&.), (.|.))
import Data.List (foldl')
import Data.Word (Word16, Word32)
import Numeric (readHex, showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu3D.Chip
import Nds.Gpu3D.GxFront (Size (..), fifoLevel)
import Nds.Gpu3D.Polygon (PolyPipeState (..))
import Nds.Gpu3D.Texture (TexMem)

import OracleIO (imageMemory, readWords)

data Op
  = OWrite Size Word32 Word32
  | ORead Size Word32
  | OPower Word32
  | OXPos Size Word32 Word32
  | OVCount Size Word32 Word32
  | OIrqAck Word32
  | OVBlank
  | ORender
  | OFrameEnd
  | OLines
  | OTime
  deriving (Show)

-- | One script line: the op and whether it is a burst op.
parseOp :: String -> Either String (Bool, Op)
parseOp line = case words line of
  (('+' : c) : rest) -> (,) True <$> op (c : rest)
  ws -> (,) False <$> op ws
  where
    op ws = case ws of
      ["W", s, a, v] -> OWrite <$> size s <*> hex a <*> hex v
      ["R", s, a] -> ORead <$> size s <*> hex a
      ["P", v] -> OPower <$> hex v
      ["X", s, a, v] -> OXPos <$> size s <*> hex a <*> hex v
      ["A", s, a, v] -> OVCount <$> size s <*> hex a <*> hex v
      ["I", v] -> OIrqAck <$> hex v
      ["V"] -> Right OVBlank
      ["S"] -> Right ORender
      ["F"] -> Right OFrameEnd
      ["L"] -> Right OLines
      ["T"] -> Right OTime
      _ -> Left ("bad op: " ++ line)
    size "8" = Right S8
    size "16" = Right S16
    size "32" = Right S32
    size s = Left ("bad width " ++ s)
    hex t = case readHex t of
      [(v, "")] -> Right (fromInteger v)
      _ -> Left ("bad number " ++ t)

-- | Per-case counters, in the order of the @stats:@ line.
data Stats = Stats
  { stOps, stWrites, stReads, stEntries, stSwaps, stFrames, stPolys, stLines
  , stAborted, stHeld, stIrq, stDma, stBurst, stMaxFifo, stFails :: !Int }

emptyStats :: Stats
emptyStats = Stats 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0

statList :: Stats -> [Int]
statList s =
  [ stOps s, stWrites s, stReads s, stEntries s, stSwaps s, stFrames s, stPolys s, stLines s
  , stAborted s, stHeld s, stIrq s, stDma s, stBurst s, stMaxFifo s, stFails s ]

data St = St
  { sChip  :: !Chip
  , sNextV :: !Word16           -- ^ @GPU::NextVCount@
  , sPos   :: !Int              -- ^ next oracle word
  , sStats :: !Stats
  , sDiffs :: ![String]         -- ^ the first failures, oldest first
  }

main :: IO ()
main = do
  args <- getArgs
  when (null args || length args `mod` 3 /= 0) $
    putStrLn "usage: chip-check SCRIPT VRAM ORACLE_OUT [...]" >> exitFailure
  results <- forM (triples args) $ \(s, v, o) -> checkCase s v o
  let fails = sum (map stFails results)
  unless (fails == 0) exitFailure
  where
    triples (a : b : c : rest) = (a, b, c) : triples rest
    triples _ = []

checkCase :: FilePath -> FilePath -> FilePath -> IO Stats
checkCase scriptPath imgPath outPath = do
  text <- readFile scriptPath
  ops <- case mapM parseOp (filter (not . null) (lines text)) of
    Left e -> putStrLn ("FAIL " ++ scriptPath ++ ": " ++ e) >> exitFailure
    Right o -> pure o
  img <- readWords imgPath
  oracle <- readWords outPath
  let mem = imageMemory img
      St _ _ pos st diffs = foldl' (stepOp mem oracle) (St initChip 0 0 emptyStats []) (zip [1 ..] ops)
      size = let (lo, hi) = bounds oracle in hi - lo + 1
      st' = if pos /= size then st { stFails = stFails st + 1 } else st
  putStrLn (scriptPath ++ ": " ++ show (stOps st') ++ " ops (" ++ show (stWrites st') ++ " writes, "
    ++ show (stReads st') ++ " reads, " ++ show (stBurst st') ++ " in bursts), "
    ++ show (stEntries st') ++ " GX entries, " ++ show (stDma st') ++ " DMA triggers, "
    ++ show (stSwaps st') ++ " swaps, " ++ show (stFrames st') ++ " frames rendered ("
    ++ show (stPolys st') ++ " polygons), " ++ show (stLines st') ++ " lines ("
    ++ show (stAborted st') ++ " aborted), max FIFO " ++ show (stMaxFifo st') ++ ", "
    ++ show (stHeld st') ++ " ops ending stalled, " ++ show (stIrq st') ++ " ops with IRQ, "
    ++ show (stFails st') ++ " failures")
  when (pos /= size) $
    putStrLn ("  oracle output has " ++ show size ++ " words, the replay consumed " ++ show pos)
  mapM_ (putStrLn . ("  " ++)) diffs
  putStrLn ("stats: " ++ unwords (map show (statList st')))
  pure st'

stepOp :: TexMem -> UArray Int Word32 -> St -> (Int, (Bool, Op)) -> St
stepOp mem oracle st (k, (burst, op)) =
  let ch = sChip st
      stats0 = (sStats st) { stOps = stOps (sStats st) + 1, stBurst = stBurst (sStats st) + fromEnum burst }
      -- the op itself
      (ch1, nextV, outs, stats1) = case op of
        OWrite sz a v -> (chipWrite sz a v ch, sNextV st, [], stats0 { stWrites = stWrites stats0 + 1 })
        ORead sz a -> (ch, sNextV st, [("read " ++ show sz ++ " 0x" ++ showHex a "", [chipRead sz a ch])]
                      , stats0 { stReads = stReads stats0 + 1 })
        OPower v -> (chipPower (testBit v 3) (testBit v 2) ch, sNextV st, [], stats0)
        OXPos sz a v -> let (x, m) = lane sz a v in (chipXPos x m ch, sNextV st, [], stats0)
        OVCount sz a v ->
          let (val, m) = lane sz a v
              nv = (sNextV st .&. complement m) .|. (val .&. m .&. 0x1FF)
          in (if nv /= sNextV st then chipAbortFrame ch else ch, nv, [], stats0)
        OIrqAck _ -> (chipIrqCheck ch, sNextV st, [], stats0)
        OVBlank ->
          let ch' = chipVBlank ch
              swapped = ppFlushReq (chPoly ch) && not (ppFlushReq (chPoly ch'))
          in (ch', sNextV st, [], stats0 { stSwaps = stSwaps stats0 + fromEnum swapped })
        ORender -> (chipRenderStart mem ch, sNextV st, []
                   , stats0 { stFrames = stFrames stats0 + 1, stPolys = stPolys stats0 + length (chRenderList ch) })
        OFrameEnd -> (chipFrameEnd ch, sNextV st, [], stats0)
        OLines -> (ch, sNextV st, [("lines", concatMap (`chipGetLine` ch) [0 .. 191])]
                  , stats0 { stLines = stLines stats0 + 192
                           , stAborted = stAborted stats0 + (if chAbort ch then 192 else 0) })
        OTime -> (ch, sNextV st, [], stats0)
      -- the drain
      fifoBefore = fifoLevel (chFront ch1)
      (ch2, Drain pops dma) = if burst then (ch1, Drain 0 0) else chipRun ch1
      status = (if chipStalled ch2 then 1 else 0) .|. (if chipIrq ch2 then 2 else 0)
               .|. (fromIntegral pops `shiftL` 8) :: Word32
      stats2 = stats1 { stEntries = stEntries stats1 + pops
                      , stDma = stDma stats1 + dma
                      , stHeld = stHeld stats1 + fromEnum (chipStalled ch2)
                      , stIrq = stIrq stats1 + fromEnum (chipIrq ch2)
                      , stMaxFifo = max (stMaxFifo stats1) fifoBefore }
      groups = ("status", [status]) : ("dma triggers", [fromIntegral dma]) : outs
      (pos', diffs) = foldl' compareGroup (sPos st, []) groups
      compareGroup (p, ds) (name, ws) =
        let n = length ws
            (_, hi) = bounds oracle
            have = [ if p + i <= hi then Just (oracle ! (p + i)) else Nothing | i <- [0 .. n - 1] ]
            bad = [ (i, w, o) | (i, w, o) <- zip3 [0 :: Int ..] ws have, o /= Just w ]
        in case bad of
             [] -> (p + n, ds)
             ((i, w, o) : _) ->
               (p + n, ds ++ ["op " ++ show k ++ " " ++ show op ++ ": " ++ name ++ describe name i
                        ++ " want=" ++ maybe "missing" (\x -> "0x" ++ showHex x "") o
                        ++ " got=0x" ++ showHex w "" ++ " (" ++ show (length bad) ++ " words differ)"])
      describe "lines" i = " at (" ++ show (i `mod` 256) ++ "," ++ show (i `div` 256) ++ ")"
      describe _ _ = ""
      stats3 = stats2 { stFails = stFails stats2 + length diffs }
  in st { sChip = ch2, sNextV = nextV, sPos = pos', sStats = stats3
        , sDiffs = take 12 (sDiffs st ++ diffs) }
  where
    -- An 8- or 16-bit access to a halfword register: value and lane mask.
    lane :: Size -> Word32 -> Word32 -> (Word16, Word16)
    lane sz a v = case (sz, a .&. 1) of
      (S8, 1) -> (fromIntegral v `shiftL` 8, 0xFF00)
      (S8, _) -> (fromIntegral v, 0x00FF)
      _ -> (fromIntegral v, 0xFFFF)
