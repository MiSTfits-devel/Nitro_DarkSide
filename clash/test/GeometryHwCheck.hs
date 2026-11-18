{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}

-- | Clash-simulation gate for the geometry-engine hardware
-- ('Nds.Gpu3D.GeometryHw.geometryHw') against the pure model
-- ('Nds.Gpu3D.Geometry'), which GeometryCheck ties to melonDS.
--
-- The input streams are the geometry gate's own: the oracle files
-- @geometry_oracle directed@ and @geometry_oracle random SEED STREAMS LENGTH@
-- write (each record's command and parameters; the melonDS state in them is
-- GeometryCheck's business). Every 'GeoCmd' becomes one entry per parameter
-- word, in FIFO order; in the random streams one multi-word command in 24
-- has one of its non-final entries retagged with another multi-word command,
-- so the hardware's @ExecParams@ gathering is exercised the way melonDS
-- gathers interleaved commands. The model is fed what that gathering
-- ('gather', @Nds.Gpu3D.Chip.gatherEntry@) makes of the accepted entries.
--
-- A driver runs closed-loop with the hardware, cycle by cycle, with random
-- gaps on the entry valid, a random event ready, a random polygon-pipeline
-- stall (in bursts), VBlank pulses (random, and soon after every swap), and
-- @DISP_1DOT_DEPTH@ / acknowledge inputs applied when the engine is idle. It
-- compares:
--
-- * every event the hardware transfers, in order, against the model's
--   events ('toHwEvent');
-- * after every input, once the engine is idle: 'GeoStatus' (busy bits
--   included) against 'geoStatus', then the result port at all 33 words
--   0x04000620-0x040006A0 (random low address bits) against 'geoReadResult';
-- * the cycle after a command's last entry is taken: busy high, test-busy
--   high exactly for BOX/POS/VEC_TEST and stack-busy exactly for PUSH/POP;
-- * that no entry is taken while the swap waits for VBlank.
--
-- @time@ mode runs the same streams back to back (entry always valid, event
-- always ready, no stall, no gathering interleave) and reports the cycles
-- each command class takes from its first entry to the cycle the engine
-- takes the next one, against melonDS's accounting.
--
-- Usage: geometry-hw-check check|time FILE [SEED]
module Main (main) where

import Control.Concurrent (forkIO, getNumCapabilities)
import Control.Concurrent.MVar
import Control.Exception (evaluate)
import Control.Monad (forM, forM_, replicateM_, unless, when)
import Data.Bits (bit, shiftL, shiftR, testBit, xor, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Unsafe as BU
import Data.IORef
import Data.List (foldl', sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, isNothing)
import Data.Word (Word32, Word64, Word8)
import Numeric (showFFloat, showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)

import Clash.Explicit.Prelude (BitVector, bundle, enableGen)
import Clash.Explicit.Signal (systemClockGen, systemResetGen)
import Clash.Signal.Internal (Signal (..))

import Nds.Gpu3D.Geometry
import Nds.Gpu3D.GeometryHw
import Nds.Gpu3D.GeometryHw.Event
import Nds.Gpu3D.GxFrontHw (HwEntry (..))
import Nds.Gpu3D.Types

------------------------------------------------------------------------------
-- Oracle file

tagStream, tagRecord, tagStreamEnd, tagFileEnd :: Word32
tagStream = 0x5354524D
tagRecord = 0x52454331
tagStreamEnd = 0x454E4453
tagFileEnd = 0x454E4446

-- | Words of melonDS state after each record (GeometryCheck's @stateNames@).
nStateWords :: Int
nStateWords = 297

wordsOf :: BL.ByteString -> [Word32]
wordsOf = go BS.empty . BL.toChunks
  where
    go acc [] = strict acc
    go acc (c : cs) =
      let joined = acc <> c
          n = (BS.length joined `div` 4) * 4
      in strict (BS.take n joined) ++ go (BS.drop n joined) cs
    strict bs = [word bs (4 * i) | i <- [0 .. BS.length bs `div` 4 - 1]]
    word bs o = byte bs o .|. (byte bs (o + 1) `shiftL` 8)
                  .|. (byte bs (o + 2) `shiftL` 16) .|. (byte bs (o + 3) `shiftL` 24)
    byte bs o = fromIntegral (BU.unsafeIndex bs o) :: Word32

-- | The streams of a file: each the list of its inputs.
parseStreams :: [Word32] -> Either String [[GeoIn]]
parseStreams = top []
  where
    top acc ws = case ws of
      (t : _ : rest) | t == tagStream -> stream acc [] rest
      [t, _] | t == tagFileEnd -> Right (reverse acc)
      _ -> Left "malformed oracle output at stream level"
    stream acc ins ws = case ws of
      (t : rest) | t == tagStreamEnd -> top (reverse ins : acc) rest
      (t : kind : op : n : rest) | t == tagRecord ->
        let (params, rest1) = splitAt (fromIntegral n) rest
            rest2 = drop nStateWords rest1
        in case rest2 of
             (nv : rest3) ->
               let rest4 = drop (if nv == 1 then 19 else 0) rest3
               in case rest4 of
                    (_ : _ : _ : rest5) ->
                      let inp = case kind of
                            0 -> GeoCmd (fromIntegral op) params
                            1 -> SetZeroDotW (head params)
                            _ -> AckStackError
                      in stream acc (inp : ins) rest5
                    _ -> Left "truncated record"
             _ -> Left "truncated record"
      _ -> Left "malformed oracle output in a stream"

------------------------------------------------------------------------------
-- Random numbers

newtype Rng = Rng Word64

next :: Rng -> (Word64, Rng)
next (Rng s) =
  let s' = s + 0x9E3779B97F4A7C15
      z1 = (s' `xor` (s' `shiftR` 30)) * 0xBF58476D1CE4E5B9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
  in (z2 `xor` (z2 `shiftR` 31), Rng s')

below :: Int -> Rng -> (Int, Rng)
below n r = let (x, r') = next r in (fromIntegral (x `mod` fromIntegral n), r')

chance :: Int -> Rng -> (Bool, Rng)
chance pct r = let (x, r') = below 100 r in (x < pct, r')

------------------------------------------------------------------------------
-- Stimulus

data Item = IEntry !HwEntry | IZero !Word32 | IAck
  deriving (Show)

multiWord :: [Word8]
multiWord = [0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x23, 0x34, 0x70, 0x71]

-- | One stream's items; @mutate@ retags entries inside multi-word commands.
itemsOf :: Bool -> Rng -> [GeoIn] -> [Item]
itemsOf mutate = go
  where
    go _ [] = []
    go r (i : is) = case i of
      SetZeroDotW v -> IZero v : go r is
      AckStackError -> IAck : go r is
      GeoCmd op ps
        | cmdNumParams op <= 1 -> IEntry (HwEntry op (headOr ps)) : go r is
        | otherwise ->
            let n = cmdNumParams op
                ws = take n (ps ++ repeat 0)
                (hit, r1) = if mutate then chance 4 r else (False, r)
                (k, r2) = below (n - 1) r1
                (m, r3) = below (length multiWord) r2
                tagOf j = if hit && j == k then multiWord !! m else op
            in [IEntry (HwEntry (tagOf j) w) | (j, w) <- zip [0 ..] ws] ++ go r3 is
    headOr ps = case ps of
      (p : _) -> p
      [] -> 0

-- | @ExecuteCommand@'s parameter gathering (@Nds.Gpu3D.Chip.gatherEntry@).
gather :: HwEntry -> [Word32] -> (Maybe GeoIn, [Word32])
gather (HwEntry c p) ps
  | n <= 1 = (Just (GeoCmd c [p]), ps)
  | length ps' >= n = (Just (GeoCmd c ps'), [])
  | otherwise = (Nothing, ps')
  where
    n = cmdNumParams c
    ps' = ps ++ [p]

------------------------------------------------------------------------------
-- Driver

data Phase
  = PFeed
  | PWait !Int        -- ^ settle cycles left, then wait for idle
  | PSweep !Int       -- ^ result word being checked
  deriving (Eq, Show)

-- | Busy flags the cycle after a command's last entry must show.
data BusyChk = BusyChk { bcRuns :: !Bool, bcTest :: !Bool, bcStack :: !Bool }

data Timing = Timing { tmCount :: !Int, tmSum :: !Int, tmMin :: !Int, tmMax :: !Int, tmHist :: !(M.Map Int Int) }

mergeT :: Timing -> Timing -> Timing
mergeT (Timing c1 s1 a1 b1 h1) (Timing c2 s2 a2 b2 h2) =
  Timing (c1 + c2) (s1 + s2) (min a1 a2) (max b1 b2) (M.unionWith (+) h1 h2)

-- | The smallest cycle count reached by fraction @f@ of the samples.
percentile :: Double -> Timing -> Int
percentile f t = go 0 (M.toAscList (tmHist t))
  where
    need = ceiling (f * fromIntegral (tmCount t)) :: Int
    go _ [] = tmMax t
    go acc ((k, n) : rest) = if acc + n >= need then k else go (acc + n) rest

data D = D
  { dItems   :: [Item]
  , dModel   :: !GeoState
  , dGather  :: [Word32]
  , dExpect  :: [HwGeoEvent]
  , dPhase   :: !Phase
  , dPresent :: !(Maybe HwEntry)     -- ^ driven this cycle
  , dReady   :: !Bool
  , dStall   :: !Bool
  , dVbl     :: !Bool
  , dAck     :: !Bool
  , dZero    :: !Word32
  , dAddr    :: !Word32
  , dRng     :: !Rng
  , dTime    :: !Bool                -- ^ time mode
  , dCycle   :: !Int
  , dIdle    :: !Int                 -- ^ cycles waiting for idle (hang detection)
  , dBusyChk :: !(Maybe BusyChk)
  , dErrs    :: [String]
  , dNErr    :: !Int
  , dDone    :: !Bool
  -- counters
  , dInputs  :: !Int
  , dEntries :: !Int
  , dEvents  :: !Int
  , dVerts   :: !Int
  , dReads   :: !Int
  , dStatus  :: !Int
  , dGaps    :: !Int
  , dNotRdy  :: !Int
  , dStallC  :: !Int
  , dSwaps   :: !Int
  , dSwapCyc :: !Int
  , dVblPrev :: !Bool                -- ^ VBlank driven in the previous cycle
  , dSwapPrevO :: !Bool              -- ^ the swap waited in the previous cycle
  , dSwapExp :: !(Maybe Int)         -- ^ cycle an 'HeSwap' was taken; the engine must wait
  , dRegroup :: !Int
  -- timing
  , dCmdStart :: !(Maybe (Int, String))  -- ^ first-entry cycle and class of the command
  , dPending  :: !(Maybe (Int, String))  -- ^ executed command waiting for ready
  , dTimes    :: !(M.Map String Timing)
  , dSlowest  :: !(Int, Int)            -- ^ slowest command: cycles, first-entry cycle
  }

d0 :: Bool -> [Item] -> Word64 -> D
d0 tm items seed = D
  { dItems = items, dModel = initGeoState, dGather = [], dExpect = [], dPhase = PFeed
  , dPresent = Nothing, dReady = True, dStall = False, dVbl = False, dAck = False
  , dZero = gZeroDotW initGeoState, dAddr = 0x04000620, dRng = Rng seed, dTime = tm
  , dCycle = 0, dIdle = 0, dBusyChk = Nothing, dErrs = [], dNErr = 0, dDone = False
  , dInputs = 0, dEntries = 0, dEvents = 0, dVerts = 0, dReads = 0, dStatus = 0, dGaps = 0
  , dNotRdy = 0, dStallC = 0, dSwaps = 0, dSwapCyc = 0, dVblPrev = False, dSwapPrevO = False, dSwapExp = Nothing, dRegroup = 0
  , dCmdStart = Nothing, dPending = Nothing, dTimes = M.empty, dSlowest = (0, 0) }

err :: String -> D -> D
err m d = d { dErrs = if length (dErrs d) < 12 then dErrs d ++ ["cycle " ++ show (dCycle d) ++ ": " ++ m] else dErrs d
            , dNErr = dNErr d + 1 }

hexs :: Word32 -> String
hexs w = "0x" ++ showHex w ""

-- | The class of a command for the timing table, from the model state it
-- runs in.
cmdClass :: GeoState -> Word8 -> [Word32] -> String
cmdClass s op ps = case op of
  0x11 -> "PUSH " ++ grp
  0x12 -> "POP " ++ grp
  0x13 -> "STORE " ++ grp
  0x14 -> "RESTORE " ++ grp
  0x15 -> "IDENTITY " ++ md
  0x16 -> "LOAD_4x4 " ++ md
  0x17 -> "LOAD_4x3 " ++ md
  0x18 -> "MULT_4x4 " ++ md
  0x19 -> "MULT_4x3 " ++ md
  0x1A -> "MULT_3x3 " ++ md
  0x1B -> "SCALE " ++ md
  0x1C -> "TRANS " ++ md
  0x21 -> "NORMAL " ++ show nl ++ " light" ++ (if nl == 1 then "" else "s") ++ (if tm == 2 then ", texcoord mode 2" else "")
  0x22 -> if tm == 1 then "TEXCOORD mode 1" else "TEXCOORD"
  _ | op >= 0x23 && op <= 0x28 ->
        (if op == 0x23 then "VTX_16" else "VTX_10/XY/XZ/YZ/DIFF")
        ++ (if gClipDirty s then ", stale clip" else "") ++ (if tm == 3 then ", texcoord mode 3" else "")
  0x32 -> "LIGHT_VECTOR"
  0x34 -> "SHININESS"
  0x70 -> "BOX_TEST" ++ (if gClipDirty s then ", stale clip" else "")
  0x71 -> "POS_TEST" ++ (if gClipDirty s then ", stale clip" else "")
  0x72 -> "VEC_TEST"
  0x10 -> "MTX_MODE"
  0x20 -> "COLOR"
  0x29 -> "POLYGON_ATTR"
  0x2A -> "TEXIMAGE_PARAM"
  0x2B -> "PLTT_BASE"
  0x30 -> "DIF_AMB"
  0x31 -> "SPE_EMI"
  0x33 -> "LIGHT_COLOR"
  0x40 -> "BEGIN_VTXS"
  0x41 -> "END_VTXS"
  0x50 -> "SWAP_BUFFERS"
  0x60 -> "VIEWPORT"
  _ -> "other"
  where
    m = gMtxMode s
    grp | m == 0 = "proj" | m == 3 = "tex" | otherwise = "pos/vec"
    md = "mode " ++ show m
    tm = gTexParam s `shiftR` 30
    nl = length [() | i <- [0 .. 3 :: Int], testBit (gCurPolyAttr s) i]
    _ = ps

isRunning :: Word8 -> Bool
isRunning op = op `elem` ([0x11 .. 0x1C] ++ [0x21] ++ [0x23 .. 0x28] ++ [0x32, 0x34, 0x40, 0x41, 0x50, 0x70, 0x71, 0x72])

-- | One clock cycle: the hardware's outputs for the inputs @d@ drove.
cycleStep :: D -> (GeoHwOut, Word32) -> D
cycleStep d (o, res) = finish (sideAndPhase afterEntry)
  where
    st = goStatus o
    busy = gsBusy st
    -- events
    evX = isJust (goEvent o) && dReady d
    afterEv = case goEvent o of
      Just ev | dReady d -> case dExpect d of
        (e : es) | e == ev -> d { dExpect = es, dEvents = dEvents d + 1
                                , dVerts = dVerts d + (case ev of HeVertex _ _ -> 1; _ -> 0)
                                , dSwaps = dSwaps d + (case ev of HeSwap _ -> 1; _ -> 0) }
                 | otherwise -> err ("event mismatch: hardware " ++ show ev ++ " model " ++ show e) d { dExpect = es }
        [] -> err ("unexpected event " ++ show ev) d
      _ -> d
    _ = evX
    -- busy flags the cycle after a command's last entry
    -- the swap wait: from the cycle the swap event is taken until a VBlank
    -- driven in a later cycle
    released = case dSwapExp d of
      Just t -> dVblPrev d && dCycle d - 1 >= t + 1
      Nothing -> False
    swapExp' = case (goEvent o, dReady d) of
      (Just (HeSwap _), True) -> Just (dCycle d)
      _ | released -> Nothing
        | otherwise -> dSwapExp d
    afterBusy0 = foldl' (flip err) afterEv { dSwapExp = swapExp' }
      ( [ "entry ready while the swap waits for VBlank" | goCmdReady o && goSwapWait o ]
        ++ [ "swap released without a VBlank" | dSwapPrevO d && not (goSwapWait o) && not (dVblPrev d) ]
        ++ [ "swap wait " ++ show (goSwapWait o) ++ ", expected " ++ show (not released)
           | isJust (dSwapExp d) && goSwapWait o /= not released ] )
    afterBusy = case dBusyChk afterBusy0 of
      Nothing -> afterBusy0
      Just bc ->
        let bad = [ "busy low after a running command" | bcRuns bc && not busy ]
                  ++ [ "test-busy " ++ show (gsTestBusy st) | gsTestBusy st /= bcTest bc ]
                  ++ [ "stack-busy " ++ show (gsStackBusy st) | gsStackBusy st /= bcStack bc ]
        in foldl' (flip err) afterBusy0 { dBusyChk = Nothing } bad
    -- read sweep
    afterRead = case dPhase afterBusy of
      PSweep _ ->
        let want = geoReadResult (dModel afterBusy) (dAddr afterBusy)
            d1 = afterBusy { dReads = dReads afterBusy + 1 }
        in if want == res then d1
           else err ("result " ++ hexs (dAddr afterBusy) ++ ": hardware " ++ hexs res ++ " model " ++ hexs want) d1
      _ -> afterBusy
    -- timing: the engine is ready again after an executed command
    afterTime = case dPending afterRead of
      Just (t0, cls) | goCmdReady o ->
        let n = dCycle afterRead - t0
            tm = M.insertWith mergeT cls (Timing 1 n n n (M.singleton n 1)) (dTimes afterRead)
        in afterRead { dPending = Nothing, dTimes = tm
                     , dSlowest = if n > fst (dSlowest afterRead) then (n, t0) else dSlowest afterRead }
      _ -> afterRead
    -- entry transfer
    afterEntry = case dPresent afterTime of
      Just e | goCmdReady o ->
        let dA = afterTime { dItems = drop 1 (dItems afterTime), dEntries = dEntries afterTime + 1 }
            dB = dA
            start = maybe (Just (dCycle dB, "")) Just (dCmdStart dB)
            (mgi, g') = gather e (dGather dB)
        in case mgi of
             Nothing -> dB { dGather = g', dCmdStart = start }
             Just gi@(GeoCmd op ps) ->
               let (s', evs) = Nds.Gpu3D.Geometry.step (dModel dB) gi
                   cls = cmdClass (dModel dB) op ps
                   regroup = cmdNumParams (heCmd e) >= 2 && length ps /= cmdNumParams (heCmd e)
                   t0 = maybe (dCycle dB) fst start
               in dB { dGather = g', dModel = s', dExpect = dExpect dB ++ map toHwEvent evs
                     , dPhase = if dTime dB then PFeed else PWait 1
                     , dInputs = dInputs dB + 1
                     , dBusyChk = Just (BusyChk (isRunning op) (op `elem` [0x70, 0x71, 0x72]) (op == 0x11 || op == 0x12))
                     , dCmdStart = Nothing
                     , dPending = if dTime dB && not regroup then Just (t0, cls) else Nothing
                     , dRegroup = dRegroup dB + (if regroup then 1 else 0) }
             Just _ -> dB
      _ -> afterTime
    -- side inputs, waiting, sweeping
    sideAndPhase dd = case dPhase dd of
      PFeed -> case dItems dd of
        (IZero v : rest)
          | busy || isJust (dPending dd) -> dd
          | otherwise ->
              let (s', _) = Nds.Gpu3D.Geometry.step (dModel dd) (SetZeroDotW v)
              in dd { dItems = rest, dModel = s', dZero = gZeroDotW s', dPhase = PWait 2
                    , dInputs = dInputs dd + 1 }
        (IAck : rest)
          | busy || isJust (dPending dd) -> dd
          | otherwise ->
              let (s', _) = Nds.Gpu3D.Geometry.step (dModel dd) AckStackError
              in dd { dItems = rest, dModel = s', dAck = True, dPhase = PWait 2, dInputs = dInputs dd + 1 }
        _ -> dd
      PWait n | n > 0 -> dd { dPhase = PWait (n - 1) }
      PWait _
        | busy || not (null (dExpect dd)) -> dd { dIdle = dIdle dd + 1 }
        | otherwise ->
            let want = geoStatus (dModel dd)
                d1 = dd { dStatus = dStatus dd + 1, dIdle = 0 }
                d2 = if st == want then d1
                     else err ("status: hardware " ++ show st ++ " model " ++ show want) d1
            in if dTime dd then d2 { dPhase = PFeed } else d2 { dPhase = PSweep 0 }
      PSweep k
        | k >= 32 -> dd { dPhase = PFeed }
        | otherwise -> dd { dPhase = PSweep (k + 1) }
    -- next cycle's drive
    finish dd =
      let r0 = dRng dd
          (gapRoll, r1) = chance 70 r0
          (rdyRoll, r2) = chance 65 r1
          (stallFlip, r3) = chance 12 r2
          (vblRoll, r4) = chance 6 r3
          (spurious, r5) = below 400 r4
          (lowBits, r6) = below 4 r5
          (junkAddr, r7) = below 0x90 r6
          tm = dTime dd
          feeding = dPhase dd == PFeed
          present = case dItems dd of
            (IEntry e : _) | feeding && (tm || gapRoll) -> Just e
            _ -> Nothing
          sweepAddr = case dPhase dd of
            PSweep k -> 0x04000620 + 4 * fromIntegral k + fromIntegral lowBits
            _ -> 0x04000600 + fromIntegral junkAddr
          swapWaiting = goSwapWait o && isNothing (goEvent o)
          vbl = (swapWaiting && (tm || vblRoll)) || (not tm && spurious == 0)
          stall = not tm && (if stallFlip then not (dStall dd) else dStall dd)
          hung = dIdle dd > 200000
          finished = null (dItems dd) && dPhase dd == PFeed && null (dExpect dd) && not busy
                       && isNothing (dPending dd)
      in (if hung then err "hang: the engine never went idle" else id) dd
           { dPresent = present
           , dReady = tm || rdyRoll
           , dStall = stall
           , dVbl = vbl
           , dAck = dAck dd && not (dAck d)
           , dVblPrev = dVbl d
           , dSwapPrevO = goSwapWait o
           , dSwapCyc = dSwapCyc dd + (if goSwapWait o then 1 else 0)
           , dAddr = sweepAddr
           , dRng = r7
           , dCycle = dCycle dd + 1
           , dDone = finished || hung
           , dGaps = dGaps dd + (case (dItems dd, present) of (IEntry _ : _, Nothing) | feeding -> 1; _ -> 0)
           , dNotRdy = dNotRdy dd + (if isJust (goEvent o) && not (dReady d) then 1 else 0)
           , dStallC = dStallC dd + (if dStall d then 1 else 0)
           }

driver :: D -> Signal dom (GeoHwOut, Word32) -> Signal dom D
driver d ~(o :- os) = d :- (let d' = cycleStep d o in d' `seq` driver d' os)

runStream :: Bool -> [Item] -> Word64 -> D
runStream tm items seed = fst (runTrace tm items seed)

-- | The run and, per cycle, the driver state, the hardware registers and the
-- result word.
runTraceRes :: Bool -> [Item] -> Word64 -> (D, [(D, Hw, Word32)])
runTraceRes tm items seed = (finalState drv, takeUntilDone (zip3 (sample' drv) (sample' hw) (sample' res)))
  where
    clk = systemClockGen
    rst = systemResetGen
    en = enableGen
    (hw, outs, res) = geometryHwState clk rst en inp (dAddr <$> drv)
    drv = driver (d0 tm items seed) (bundle (outs, res))
    inp = (\d -> GeoHwIn (dPresent d) (dReady d) (dStall d) (dVbl d) (dAck d) (dZero d)) <$> drv
    finalState (d :- ds) = if dDone d then d else finalState ds
    sample' (x :- xs) = x : sample' xs
    takeUntilDone ((d, h, w) : rest) = (d, h, w) : (if dDone d then [] else takeUntilDone rest)
    takeUntilDone [] = []

-- | The run and, per cycle, the driver state and the hardware registers.
runTrace :: Bool -> [Item] -> Word64 -> (D, [(D, Hw)])
runTrace tm items seed = (fin, [ (d, h) | (d, h, _) <- tr ])
  where
    (fin, tr) = runTraceRes tm items seed

-- | The cycle trace the Verilog testbench replays (tests/tb_geometry_cosim.sv):
-- one line per cycle holding the inputs the driver drove, the outputs
-- 'geometryHw' produced and the result word. Bare hex digits (iverilog's @%h@),
-- the event as one wide field, the level as a decimal cycle number.
--
-- The first cycle of a stream drives reset, and the bench releases it before the
-- clock edge that ends the cycle, which is when Clash's register captures the
-- cycle's input.
dumpLines :: [Item] -> Word64 -> [String]
dumpLines items sd = map line tr
  where
    (_, tr) = runTraceRes False items sd
    -- iverilog's $fscanf mis-assigns past ten conversions in a call, so a line
    -- stays inside that: input flags, command, ZeroDotWLimit, result address,
    -- expected-output flags, status, result word, the event as one wide field,
    -- cycle.
    line (d, h, res) = unwords
      [ hx 2 iflags
      , hx 8 (maybe 0 heCmd (dPresent d))
      , hx 8 (maybe 0 heParam (dPresent d))
      , hx 8 (dZero d `mod` 256)
      , hx 8 (dAddr d)
      , hx 1 eflags
      , hx 8 (statusBits (goStatus o) .&. 0x07FFFFFF)
      , hx 8 (if chk then res else 0)
      , hx 83 (eventBits (goEvent o))
      , show (dCycle d)
      ]
      where
        o = geoOut h
        chk = case dPhase d of PSweep _ -> True; _ -> False
        flag c n = if c then bit n else 0
        iflags :: Word8
        iflags = flag (dCycle d == 0) 0 .|. flag (isJust (dPresent d)) 1
                 .|. flag (dReady d) 2 .|. flag (dStall d) 3
                 .|. flag (dVbl d) 4 .|. flag (dAck d) 5
        eflags :: Word8
        eflags = flag (goCmdReady o) 0 .|. flag (isJust (goEvent o)) 1
                 .|. flag (goSwapWait o) 2 .|. flag chk 3

-- | @n@ bare hex digits.
hx :: (Integral a) => Int -> a -> String
hx n v = let s = showHex (toInteger v) "" in replicate (n - length s) '0' ++ s

------------------------------------------------------------------------------
-- melonDS cycle accounting

-- | Cycles the vendored melonDS charges a command run in isolation (idle
-- pipelines): one per entry plus the command's own @AddCycles@; the 7-cycle
-- vertex and normal pipelines that later commands may wait on are left out.
melonCycles :: String -> Maybe Int
melonCycles cls = lookup cls table
  where
    table =
      [ ("MTX_MODE", 1), ("PUSH proj", 17), ("PUSH pos/vec", 17), ("PUSH tex", 17)
      , ("POP proj", 36), ("POP pos/vec", 36), ("POP tex", 18)
      , ("STORE proj", 17), ("STORE pos/vec", 17), ("STORE tex", 17)
      , ("RESTORE proj", 36), ("RESTORE pos/vec", 36), ("RESTORE tex", 18)
      ] ++ concat
      [ [ ("IDENTITY mode " ++ show m, if m == 3 then 1 else 19)
        , ("LOAD_4x4 mode " ++ show m, if m == 3 then 26 else 34)
        , ("LOAD_4x3 mode " ++ show m, if m == 3 then 19 else 30)
        , ("MULT_4x4 mode " ++ show m, mult m)
        , ("MULT_4x3 mode " ++ show m, mult m)
        , ("MULT_3x3 mode " ++ show m, mult m)
        , ("SCALE mode " ++ show m, if m == 3 then 33 else 35)
        , ("TRANS mode " ++ show m, mult m) ]
      | m <- [0 .. 3 :: Int] ] ++
      [ ("COLOR", 1), ("TEXCOORD", 1), ("TEXCOORD mode 1", 1)
      , ("POLYGON_ATTR", 1), ("TEXIMAGE_PARAM", 1), ("PLTT_BASE", 1)
      , ("DIF_AMB", 4), ("SPE_EMI", 4), ("LIGHT_VECTOR", 6), ("LIGHT_COLOR", 2), ("SHININESS", 32)
      , ("BEGIN_VTXS", 1), ("END_VTXS", 1), ("VIEWPORT", 1)
      , ("POS_TEST", 7), ("POS_TEST, stale clip", 7), ("VEC_TEST", 5)
      , ("BOX_TEST", 257), ("BOX_TEST, stale clip", 257), ("other", 1)
      ] ++
      [ ("NORMAL " ++ show n ++ " light" ++ (if n == 1 then "" else "s") ++ t, 1 + max 1 n)
      | n <- [0 .. 4 :: Int], t <- ["", ", texcoord mode 2"] ] ++
      [ (v ++ s ++ t, c) | (v, c) <- [("VTX_16", 5), ("VTX_10/XY/XZ/YZ/DIFF", 4)]
      , s <- ["", ", stale clip"], t <- ["", ", texcoord mode 3"] ]
    mult m = if m == 3 then 33 else if m == 2 then 65 else 35

-- | GBATEK's per-command cycles (the table older melonDS kept as
-- @CmdNumCycles@).
gbatekCycles :: String -> Maybe Int
gbatekCycles cls = case words (takeWhile (/= ',') cls) of
  ("MTX_MODE" : _) -> Just 1
  ("PUSH" : _) -> Just 17
  ("POP" : _) -> Just 36
  ("STORE" : _) -> Just 17
  ("RESTORE" : _) -> Just 36
  ("IDENTITY" : _) -> Just 19
  ("LOAD_4x4" : _) -> Just 34
  ("LOAD_4x3" : _) -> Just 30
  ["MULT_4x4", _, m] -> Just (35 + extra m)
  ["MULT_4x3", _, m] -> Just (31 + extra m)
  ["MULT_3x3", _, m] -> Just (28 + extra m)
  ("SCALE" : _) -> Just 22
  ["TRANS", _, m] -> Just (22 + extra m)
  ("NORMAL" : n : _) -> Just (9 + max 0 (read n - 1))
  ("TEXCOORD" : _) -> Just 1
  ("VTX_16" : _) -> Just 9
  ("VTX_10/XY/XZ/YZ/DIFF" : _) -> Just 8
  ("DIF_AMB" : _) -> Just 4
  ("SPE_EMI" : _) -> Just 4
  ("LIGHT_VECTOR" : _) -> Just 6
  ("SHININESS" : _) -> Just 32
  ("BOX_TEST" : _) -> Just 103
  ("POS_TEST" : _) -> Just 9
  ("VEC_TEST" : _) -> Just 5
  [_] -> Just 1
  _ -> Nothing
  where
    extra m = if m == "2" then 30 else 0

------------------------------------------------------------------------------
-- Main

-- | Run the streams on all capabilities, in order of results.
parallelMap :: (a -> b) -> [a] -> IO [b]
parallelMap f xs = do
  caps <- getNumCapabilities
  queue <- newIORef (zip [0 :: Int ..] xs)
  outs <- forM xs (const newEmptyMVar)
  done <- newEmptyMVar
  let worker = do
        job <- atomicModifyIORef' queue (\q -> case q of
                 [] -> ([], Nothing)
                 (j : js) -> (js, Just j))
        case job of
          Nothing -> putMVar done ()
          Just (i, x) -> do
            y <- evaluate (f x)
            putMVar (outs !! i) y
            worker
  replicateM_ caps (forkIO worker)
  replicateM_ caps (takeMVar done)
  mapM readMVar outs

main :: IO ()
main = do
  args <- getArgs
  (mode, path, seed, rest) <- case args of
    [m, p] -> pure (m, p, 1, [])
    (m : p : s : r) -> pure (m, p, read s, r)
    _ -> putStrLn "usage: geometry-hw-check check|time FILE [SEED] | dump FILE SEED OUTFILE [STREAM...] | trace FILE SEED STREAM FROM TO" >> exitFailure
  bytes <- BL.readFile path
  streams <- either (\e -> putStrLn ("geometry-hw-check: " ++ e) >> exitFailure) pure
               (parseStreams (wordsOf bytes))
  when (mode == "dump") $ do
    let (outFile : picked) = rest
        randomS = length streams > 11
        chosen = [ (k, s) | (k, s) <- zip [0 :: Int ..] streams
                 , null picked || k `elem` map read picked ]
    writeFile outFile $ unlines
      [ l | (k, s) <- chosen, l <- dumpLines (itemsOf randomS (Rng (seed * 7919 + fromIntegral k)) s)
                    (seed * 1000003 + fromIntegral k) ]
    -- the bench must compare something, or it proves nothing
    when (null chosen) exitFailure
    exitSuccess
  when (mode == "trace" || mode == "ttrace") $ do
    let [k, from, to] = map read rest :: [Int]
        randomS = length streams > 11
        timed = mode == "ttrace"
        items = itemsOf (randomS && not timed) (Rng (seed * 7919 + fromIntegral k)) (streams !! k)
        (_, tr) = runTrace timed items (seed * 1000003 + fromIntegral k)
    forM_ (take (to - from) (drop from tr)) $ \(d, h) ->
      putStrLn (show (dCycle d) ++ " " ++ show (hCtl h) ++ " cmd=" ++ showHex (hCmd h) "" ++ " mode=" ++ show (hMode h)
                ++ " possp=" ++ show (hPosSP h) ++ " in=" ++ show (dPresent d)
                ++ " phase=" ++ show (dPhase d) ++ " out=" ++ show (hOut h))
    exitFailure
  let tm = mode == "time"
      random = length streams > 11
      jobs = [ (itemsOf (random && not tm) (Rng (seed * 7919 + fromIntegral k)) s, seed * 1000003 + fromIntegral k)
             | (k, s) <- zip [0 :: Int ..] streams ]
      run (items, sd) = let d = runStream tm items sd
                        in dNErr d `seq` length (dErrs d) `seq` M.size (dTimes d) `seq` d
  results <- parallelMap run jobs
  forM_ (zip [0 :: Int ..] results) $ \(k, d) ->
    forM_ (dErrs d) $ \e -> putStrLn ("stream " ++ show k ++ ": " ++ e)
  let total f = sum (map f results)
  if tm
    then do
      let times = M.unionsWith mergeT (map dTimes results)
      putStrLn "class | n | min | mean | p50 | p99 | max | melonDS | x3 | max/melonDS | GBATEK | max/GBATEK"
      forM_ (sortOn fst (M.toList times)) $ \(cls, t@(Timing c s a b _)) -> do
        let mean = fromIntegral s / fromIntegral c :: Double
            mel = melonCycles cls
            gb = gbatekCycles cls
            ratio x = maybe "-" (\v -> showFFloat (Just 2) (fromIntegral b / fromIntegral v :: Double) "") x
        putStrLn (cls ++ " | " ++ show c ++ " | " ++ show a ++ " | " ++ showFFloat (Just 1) mean ""
                  ++ " | " ++ show (percentile 0.5 t) ++ " | " ++ show (percentile 0.99 t) ++ " | " ++ show b ++ " | " ++ maybe "-" show mel ++ " | " ++ maybe "-" (show . (* 3)) mel
                  ++ " | " ++ ratio mel ++ " | " ++ maybe "-" show gb ++ " | " ++ ratio gb)
      let ((sn, st0), sk) = maximum [ (dSlowest d, k) | (k, d) <- zip [0 :: Int ..] results ]
      putStrLn ("slowest command: " ++ show sn ++ " cycles from cycle " ++ show st0
                ++ " of stream " ++ show sk)
      putStrLn ("geometry-hw-check time: " ++ show (length results) ++ " streams, "
                ++ show (total dInputs) ++ " inputs, " ++ show (total dCycle) ++ " cycles, "
                ++ show (total dNErr) ++ " mismatches")
    else
      putStrLn ("geometry-hw-check: " ++ show (length results) ++ " streams, "
                ++ show (total dInputs) ++ " inputs (" ++ show (total dEntries) ++ " entries, "
                ++ show (total dRegroup) ++ " regrouped), "
                ++ show (total dEvents) ++ " events (" ++ show (total dVerts) ++ " vertices, "
                ++ show (total dSwaps) ++ " swaps), " ++ show (total dStatus) ++ " status checks, "
                ++ show (total dReads) ++ " result reads, " ++ show (total dCycle) ++ " cycles ("
                ++ show (total dGaps) ++ " entry gaps, " ++ show (total dNotRdy) ++ " event waits, "
                ++ show (total dStallC) ++ " stall cycles), " ++ show (total dNErr) ++ " mismatches")
  unless (total dNErr == 0) exitFailure
  when (total dInputs == 0) exitFailure
