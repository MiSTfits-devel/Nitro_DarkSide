{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}

-- | Gate for "Nds.Gpu3D.PolygonHw" against the pure model
-- "Nds.Gpu3D.Polygon" (itself gated against melonDS by @polygon-check@).
--
-- Each argument is a stream written by @nds_gx3d_polygon_oracle@. Its
-- 'GeoEvent's, VBlanks and overflow acknowledges drive the Clash-simulated
-- hardware (the real top, block RAMs included) in a closed loop with a
-- behavioural memory: random ready, read latency 1..8, random gaps between
-- events, VBlank / acknowledge pulses while the block is still busy. The
-- model runs the same items. Compared:
--
-- * after every event ('poDone'): RAM_COUNT, the overflow flag and the
--   @submitTiming@ values (or their absence);
-- * at every swap ('poSwapped'): the frame descriptor, and the render list
--   decoded from the behavioural memory through "Nds.Gpu3D.PolyRam" against
--   the model's @vblank@ output, every 'GxPolygon' field; the render list
--   words and Y-range lanes against the polygons;
-- * that a VBlank without a pending swap produces no swap, and the final
--   state.
--
-- Also: the hardware event encoding round-trips every stream event, and a
-- unit check of the divider against 'quot'.
module Main (main) where

import Control.Monad (forM, unless, when)
import Data.Bits (shiftL, shiftR, xor, (.&.))
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.IntMap.Strict as IM
import Data.List (foldl')
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import Data.Word (Word64)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)

import Clash.Explicit.Prelude (BitVector, System)
import Clash.Explicit.Signal (enableGen, systemClockGen, systemResetGen)
import Clash.Signal.Internal (Signal (..))

import Nds.Gpu3D.Mem
import Nds.Gpu3D.PolyRam
import Nds.Gpu3D.Polygon
import Nds.Gpu3D.PolygonHw
import Nds.Gpu3D.Types

------------------------------------------------------------------------------
-- Streams

data Item = IEv !GeoEvent | IVb | IAck
  deriving (Show)

ints :: BL.ByteString -> [Int]
ints s = case BL.readInt (BL.dropWhile (== ' ') s) of
  Just (n, rest) -> n : ints rest
  Nothing -> []

parseItems :: BL.ByteString -> [Item]
parseItems = concatMap item . BL.lines
  where
    fi :: (Integral a, Num c) => a -> c
    fi = fromIntegral
    item raw = case BL.words (BL.take 2 raw) of
      [] -> []
      [tag] | tag == BL.pack "VB" -> [IVb]
      _ -> case BL.head raw of
        'V' -> case ints (BL.drop 1 raw) of
          (x : y : z : w : r : g : bl : s : t : attr : tp : tpal : v0 : v1 : v2 : v3 : v4 : v5 : zdw : _) ->
            [IEv (GeVertex (ClipVertex (fi x) (fi y) (fi z) (fi w) (fi r) (fi g) (fi bl) (fi s) (fi t))
                           (PolyState (fi attr) (fi tp) (fi tpal) (fi v0, fi v1, fi v2, fi v3, fi v4, fi v5) (fi zdw)))]
          _ -> error "malformed V line"
        'B' -> [IEv (GeBegin (fi (head (ints (BL.drop 1 raw)))))]
        'E' -> [IEv GeEnd]
        'S' -> [IEv (GeSwap (fi (head (ints (BL.drop 1 raw)))))]
        'A' -> [IAck]
        _ -> []

------------------------------------------------------------------------------
-- Random numbers

next64 :: Word64 -> Word64
next64 x0 = let x1 = x0 `xor` (x0 `shiftL` 13)
                x2 = x1 `xor` (x1 `shiftR` 7)
            in x2 `xor` (x2 `shiftL` 17)

------------------------------------------------------------------------------
-- Testbench processes (Moore machines on Clash signals)

-- | Output from the state alone; the state update reads the input.
moore :: (s -> i -> s) -> (s -> o) -> s -> Signal System i -> Signal System o
moore f g s ~(i :- is) = g s :- (let s' = f s i in s' `seq` moore f g s' is)

-- | Event source: items in order, a random gap before each, a VBlank or
-- acknowledge item is a one-cycle pulse.
data Src = Src ![Item] !Int !Word64

srcOut :: Src -> (Maybe HwGeoEvent, Bool, Bool)
srcOut (Src items gap _)
  | gap > 0 = (Nothing, False, False)
  | otherwise = case items of
      IEv ev : _ -> (Just (toHwEvent ev), False, False)
      IVb : _ -> (Nothing, True, False)
      IAck : _ -> (Nothing, False, True)
      [] -> (Nothing, False, False)

srcStep :: Int -> Src -> Bool -> Src
srcStep gapMax (Src items gap r) ready
  | gap > 0 = Src items (gap - 1) r
  | otherwise = case items of
      IEv _ : rest | ready -> pop rest
                   | otherwise -> Src items 0 r
      _ : rest -> pop rest
      [] -> Src [] 0 r
  where
    r' = next64 r
    pop rest = Src rest (if r' .&. 3 == 0 then fromIntegral ((r' `shiftR` 8) `mod` fromIntegral (gapMax + 1)) else 0) r'

-- | Behavioural memory: word map, in-order read responses after 1..8
-- cycles, random ready.
data Mem = Mem !(IM.IntMap (BitVector 64)) ![(Int, BitVector 64)] !Int !Word64 !Int

memOut :: Mem -> (Bool, Maybe (BitVector 64), IM.IntMap (BitVector 64))
memOut (Mem cells q now r _) =
  ( r .&. 0xFF < 180
  , case q of
      (due, w) : _ | due <= now -> Just w
      _ -> Nothing
  , cells )

memStep :: Mem -> Maybe MemReq -> Mem
memStep m@(Mem cells q now r lastDue) req =
  let (ready, resp, _) = memOut m
      q1 = if isJust resp then drop 1 q else q
      r' = next64 r
      lat = 1 + fromIntegral ((r' `shiftR` 20) `mod` 8)
  in case req of
       Just (MemWrite a be d) | ready ->
         Mem (IM.insert (key a) (merge be d (IM.findWithDefault 0 (key a) cells)) cells) q1 (now + 1) r' lastDue
       Just (MemRead a) | ready ->
         let due = max (lastDue + 1) (now + lat)
         in Mem cells (q1 ++ [(due, IM.findWithDefault 0 (key a) cells)]) (now + 1) r' due
       _ -> Mem cells q1 (now + 1) r' lastDue
  where
    key a = fromIntegral (a `shiftR` 3)
    merge be d old = foldl' (\acc i -> if testBe be i then setByte i d acc else acc) old [0 .. 7]
    testBe be i = (be `shiftR` i) .&. 1 == 1
    setByte i d acc = let mask = 0xFF `shiftL` (8 * i) in (acc .&. complementBV mask) + (d .&. mask)
    complementBV x = maxBound - x

------------------------------------------------------------------------------
-- Checker

data Ck = Ck
  { ckModel    :: !PolyPipeState
  , ckItems    :: ![Item]
  , ckFails    :: !Int
  , ckMsgs     :: ![String]
  , ckStats    :: !(M.Map String Int)
  , ckAccept   :: !Int      -- cycle the current event was taken
  , ckLastDone :: !Int
  , ckVbl      :: !Int      -- cycle of the last VBlank pulse
  , ckBusy     :: !Int      -- busy cycles since the last swap
  , ckCycle    :: !Int
  , ckIdleRun  :: !Int      -- cycles without a pulse
  }

maxMsgs :: Int
maxMsgs = 10

failCk :: String -> Ck -> Ck
failCk msg ck = ck
  { ckFails = ckFails ck + 1
  , ckMsgs = if length (ckMsgs ck) < maxMsgs
               then ("cycle " ++ show (ckCycle ck) ++ ": " ++ msg) : ckMsgs ck
               else ckMsgs ck }

expect :: (Eq a, Show a) => String -> a -> a -> Ck -> Ck
expect what model hw ck
  | model == hw = ck
  | otherwise = failCk (what ++ "\n    model: " ++ show model ++ "\n    hw:    " ++ show hw) ck

bump :: String -> Int -> Ck -> Ck
bump k n ck = ck { ckStats = M.insertWith (+) k n (ckStats ck) }

bumpMax :: String -> Int -> Ck -> Ck
bumpMax k n ck = ck { ckStats = M.insertWith max k n (ckStats ck) }

mergeStats :: M.Map String Int -> M.Map String Int -> M.Map String Int
mergeStats = M.unionWithKey (\k a c -> if take 3 k == "max" then max a c else a + c)

-- | Apply the acknowledge and no-swap VBlank items in front of the next
-- pulse; a pending swap there is an error (the hardware skipped it).
skipQuiet :: Ck -> Ck
skipQuiet ck = case ckItems ck of
  IAck : rest -> skipQuiet ck { ckModel = clearOverflow (ckModel ck), ckItems = rest }
  IVb : rest | not (ppFlushReq (ckModel ck)) ->
    skipQuiet (bump "VBlanks without swap" 1 ck { ckModel = fst (vblank (ckModel ck)), ckItems = rest })
  _ -> ck

classify :: Maybe SubmitResult -> String
classify r = case r of
  Nothing -> "event without SubmitPolygon"
  Just Culled -> "rejected: culled"
  Just (ClippedAway _) -> "rejected: clipped away"
  Just (Overflow _) -> "rejected: RAM full"
  Just (ZeroDot _) -> "rejected: 1-dot"
  Just (Built n _ cs)
    | csSegments cs > 0 -> "built: clipped"
    | n == 3 -> "built: unclipped triangle"
    | n == 4 -> "built: unclipped quad"
    | otherwise -> "built: unclipped, strip reuse " ++ show n

onDone :: PolyOut -> Ck -> Ck
onDone o ck0 =
  let ck = skipQuiet ck0
  in case ckItems ck of
       IEv ev : rest ->
         let m' = step (ckModel ck) ev
             timing = fmap (\r -> let (p, f) = submitTiming (ppMode m') r in (fromIntegral p, fromIntegral f))
                           (ppLastSubmit m')
             lat = ckCycle ck - ckAccept ck
             cls = classify (ppLastSubmit m')
             ck1 = expect "RAM_COUNT" (pipeStatus m') (polyPipeStatus o)
                 . expect "overflow" (pipeOverflow m') (poOverflow o)
                 . expect "SubmitPolygon timing" timing (fmap (\(p, f) -> (fromIntegral p, fromIntegral f)) (poTiming o) :: Maybe (Int, Int))
                 $ ck { ckModel = m', ckItems = rest, ckLastDone = ckCycle ck }
         in bump ("cycles: " ++ cls) lat . bump ("count: " ++ cls) 1 . bumpMax ("max cycles: " ++ cls) lat
              $ bump "events" 1 ck1
       IVb : _ -> failCk "event finished, but the model swaps first" ck
       _ -> failCk "event finished with no event left" ck

onSwap :: IM.IntMap (BitVector 64) -> FrameDesc -> Ck -> Ck
onSwap cells fd ck0 =
  let ck = skipQuiet ck0
  in case ckItems ck of
       IVb : rest ->
         let st = ckModel ck
             bank = fromIntegral (ppBank st)
             (st', ml) = vblank st
             polys = maybe [] id ml
             mem a = IM.findWithDefault 0 (fromIntegral (a `shiftR` 3)) cells
             got = decodeFrame mem 0 fd
             entries = decodeYRanges mem 0 fd
             bad = [ (k, p, g) | (k, p, g) <- zip3 [0 :: Int ..] polys got, p /= g ]
             entryOk (p, (e, (yt, yb, dg))) =
               fromIntegral (reYTop e) == gpYTop p && fromIntegral (reYBottom e) == gpYBottom p
               && reTranslucent e == gpTranslucent p && reDegenerate e == gpDegenerate p
               && dg == gpDegenerate p
               && (gpDegenerate p || (fromIntegral yt == gpYTop p && fromIntegral yb == gpYBottom p))
             badEntries = length (filter (not . entryOk) (zip polys entries))
             sortCycles = ckCycle ck - max (ckLastDone ck) (ckVbl ck)
             ck1 = expect "frame descriptor (bank, count)" (bank :: Int, length polys)
                     (fromIntegral (fdBank fd), fromIntegral (fdCount fd)) ck
             ck2 = case bad of
               [] -> ck1
               (k, p, g) : _ -> failCk ("render list entry " ++ show k ++ " of " ++ show (length polys)
                                        ++ "\n    model: " ++ show p ++ "\n    hw:    " ++ show g) ck1
             ck3 = if badEntries == 0 then ck2 else failCk (show badEntries ++ " render-list/Y-range words disagree") ck2
             -- The structure as well as the values: the render list names the
             -- model's polygon RAM indices and every polygon slot holds the
             -- model's absolute vertex RAM index (melonDS reads the vertices
             -- through them at render start, after later commands).
             order = renderOrder st
             hwOrder = [ fromIntegral (rePoly e) | (e, _) <- entries ] :: [Int]
             slotsOf g n = [ fromIntegral (psIndex (decodeSlot (mem (polySlotAddr 0 (fromIntegral g) (fromIntegral k)))))
                           | k <- [0 .. n - 1] ] :: [Int]
             badRefs = [ g | g <- order, let p = readPoly st g
                           , slotsOf g (length (plVerts p)) /= plVerts p ]
             ck4 = expect "render list polygon RAM indices" order hwOrder ck3
             ck5a = case badRefs of
               [] -> ck4
               g : _ -> failCk ("polygon " ++ show g ++ " vertex RAM indices\n    model: "
                                ++ show (plVerts (readPoly st g)) ++ "\n    hw:    "
                                ++ show (slotsOf g (length (plVerts (readPoly st g))))) ck4
             -- PolyRam's own encoder (what the rasteriser's gate seeds its
             -- memory with) must read back as the same frame, at a non-zero
             -- base and in this bank.
             seeded = IM.fromList [ (fromIntegral (a `shiftR` 3), w) | (a, w) <- encodeFrame 0x123000 (fdBank fd) polys ]
             seededMem a = IM.findWithDefault 0 (fromIntegral (a `shiftR` 3)) seeded
             back = decodeFrame seededMem 0x123000 (FrameDesc (fdBank fd) (fromIntegral (length polys)))
             ck5 = if back == polys then ck5a else failCk "PolyRam encodeFrame/decodeFrame round trip" ck5a
         in bump "swaps" 1 . bump "render polygons compared" (length polys)
              . bump "cycles: VBlank sort" sortCycles . bumpMax "max cycles: VBlank sort" sortCycles
              . bumpMax "max polygons in one sort" (length polys)
              $ ck5 { ckModel = st', ckItems = rest }
       IEv _ : _ -> failCk "hardware swapped; the model has an event first" ck
       _ -> failCk "hardware swapped with no VBlank left (or no swap pending)" ck

remainingWork :: [Item] -> Bool
remainingWork = any work
  where
    work (IEv _) = True
    work _ = False

-- | True while a pulse is still owed: an event, or a VBlank with a swap
-- pending at that point (approximated by any VBlank after a swap event).
pulsesOwed :: PolyPipeState -> [Item] -> Bool
pulsesOwed st items = remainingWork items || go (ppFlushReq st) items
  where
    go _ [] = False
    go f (IVb : rest) = f || go False rest
    go _ (IEv (GeSwap _) : rest) = go True rest
    go f (_ : rest) = go f rest

runStream :: Word64 -> Int -> [Item] -> (Int, [String], M.Map String Int)
runStream seed gapMax items = finish (walk ck0 sampled)
  where
    clk = systemClockGen
    rst = systemResetGen
    en = enableGen
    out = polygonHw 0 clk rst en evS vblS ackS rdyS respS
    srcO = moore (srcStep gapMax) srcOut (Src items 600 (next64 (seed * 0x9E3779B97F4A7C15 + 1))) (poReady <$> out)
    memO = moore memStep memOut (Mem IM.empty [] 0 (next64 (seed * 0xD1B54A32D192ED03 + 7)) 0) (poMem <$> out)
    evS = (\(e, _, _) -> e) <$> srcO
    vblS = (\(_, v, _) -> v) <$> srcO
    ackS = (\(_, _, a) -> a) <$> srcO
    rdyS = (\(r, _, _) -> r) <$> memO
    respS = (\(_, r, _) -> r) <$> memO
    sampled = (,,) <$> out <*> srcO <*> memO
    ck0 = Ck initPolyPipe items 0 [] M.empty 0 0 0 0 0 0

    walk !ck ((o, (ev, vbl, _), (_, _, cells)) :- rest)
      | not (pulsesOwed (ckModel ck) (ckItems ck)) = ck
      | ckIdleRun ck > 3000000 = failCk "no progress for 3,000,000 cycles" ck
      | otherwise =
          let c = ckCycle ck
              ck1 = ck { ckBusy = ckBusy ck + (if poBusy o then 1 else 0)
                       , ckIdleRun = ckIdleRun ck + 1 }
              -- A finished event's pulse can share its cycle with the next
              -- event's transfer, so the pulses are handled first.
              ck2 | poDone o = onDone o ck1 { ckIdleRun = 0 }
                  | otherwise = ck1
              ck3 = case poSwapped o of
                Just fd -> onSwap cells fd ck2 { ckIdleRun = 0 }
                Nothing -> ck2
              -- Busy cycles of one VBlank-to-VBlank interval: the time the
              -- block needed for that frame's events (they are offered as
              -- fast as it takes them).
              ck4 | vbl = (if ckBusy ck3 > frameBudget then bump "frames over the 1,677,000-cycle budget" 1 else id)
                          (bumpMax "max busy cycles between VBlanks" (ckBusy ck3) ck3 { ckBusy = 0 })
                  | otherwise = ck3
              ck5 = ck4 { ckAccept = if poReady o && isJust ev then c else ckAccept ck4
                        , ckVbl = if vbl then c else ckVbl ck4
                        , ckCycle = c + 1 }
          in walk ck5 rest

    frameBudget = 1677000 :: Int

    finish ck =
      let ckq = skipQuiet ck
          ck1 = if null (ckItems ckq) then ckq else failCk (show (length (ckItems ckq)) ++ " items never processed") ckq
          ck2 = bump "cycles simulated" (ckCycle ck1) ck1
      in (ckFails ck2, reverse (ckMsgs ck2), ckStats ck2)

------------------------------------------------------------------------------
-- Divider unit check

divCheck :: Int -> (Int, Int)
divCheck n = (length cases, length bad)
  where
    run nn dd neg = go (divStart nn dd neg initDiv) (0 :: Int)
      where
        go st k
          | k > 0 && divIdle st = divResult st
          | k > 200 = error "divider did not finish"
          | otherwise = go (divAdvance st) (k + 1)
    rs = iterate next64 0x1234567
    gen (a : b : c : rest) =
      let nn = mask (fromIntegral (a `shiftR` 1)) (fromIntegral (b .&. 63) + 1)
          dd = max 1 (mask (fromIntegral (b `shiftR` 7)) (fromIntegral (c .&. 31) + 2))
      in (nn, dd, odd c) : gen rest
    gen _ = []
    mask :: Integer -> Int -> Integer
    mask v bits = v `mod` (2 ^ bits)
    edges = [ (nn, dd, neg) | nn <- [0, 1, 2 ^ 63, 2 ^ 64 - 1, 2 ^ 32, 2 ^ 46 - 1], dd <- [1, 2, 3, 2 ^ 32, 2 ^ 33 - 1, 0xFFFFFF]
                            , neg <- [False, True] ]
    cases = edges ++ take n (gen rs)
    bad = [ (nn, dd) | (nn, dd, neg) <- cases
                     , let want = (if neg then negate else id) (nn `quot` dd) `mod` (2 ^ (32 :: Int))
                     , toInteger (run (fromInteger nn) (fromInteger dd) neg) /= want ]

------------------------------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs
  let (gapMax, files) = case args of
        ("--gap" : g : fs) -> (read g, fs)
        fs -> (16, fs)
  when (null files) $ fail "usage: polygon-hw-check [--gap N] STREAM..."
  let (dn, dbad) = divCheck 200000
  putStrLn ("divider: " ++ show dn ++ " cases, " ++ show dbad ++ " wrong")
  -- The model reads only p & 3 of BEGIN_VTXS / SWAP_BUFFERS; the hardware
  -- encoding keeps exactly those bits.
  let lowParams ev = case ev of
        GeBegin p -> GeBegin (p .&. 3)
        GeSwap p -> GeSwap (p .&. 3)
        _ -> ev
  let named = ("synthetic (model-side edge cases)", syntheticItems)
  sources <- forM files $ \path -> do
    s <- BL.readFile path
    return (path, parseItems s)
  results <- forM (zip [1 :: Word64 ..] (named : sources)) $ \(k, (path, items)) -> do
    let evs = [ev | IEv ev <- items]
        lossy = length [() | ev <- evs, fromHwEvent (toHwEvent ev) /= lowParams ev]
        (nf, msgs, stats) = runStream k gapMax items
        nfail = nf + lossy
    putStrLn (path ++ ": " ++ show (length evs) ++ " events, "
              ++ show (M.findWithDefault 0 "swaps" stats) ++ " swaps, "
              ++ show (M.findWithDefault 0 "cycles simulated" stats) ++ " cycles, "
              ++ show nfail ++ " mismatches"
              ++ (if lossy > 0 then " (" ++ show lossy ++ " events lost in the hardware encoding)" else ""))
    mapM_ (putStrLn . ("  " ++)) msgs
    hFlush stdout
    return (nfail, stats)
  let failures = sum (map fst results) + dbad
      stats = foldr mergeStats M.empty (map snd results)
      cnt k = M.findWithDefault 0 k stats
      perKind = [ (drop 7 k, v) | (k, v) <- M.toList stats, take 7 k == "count: " ]
  putStrLn "totals:"
  mapM_ (\(k, v) -> putStrLn ("  " ++ k ++ ": " ++ show v))
        [ (k, v) | (k, v) <- M.toList stats, take 8 k /= "cycles: " ]
  putStrLn "mean cycles (event taken -> done):"
  mapM_ (\(k, n) -> putStrLn ("  " ++ k ++ ": " ++ showMean (cnt ("cycles: " ++ k)) n)) perKind
  putStrLn ("  VBlank sort: " ++ showMean (cnt "cycles: VBlank sort") (cnt "swaps"))
  putStrLn ("polygon-hw-check: " ++ show (length files) ++ " oracle streams + 1 synthetic, " ++ show (cnt "events") ++ " events, "
            ++ show (sum [v | (k, v) <- perKind, take 6 k == "built:"]) ++ " polygons built, "
            ++ show (cnt "swaps") ++ " swaps, " ++ show failures ++ " mismatches")
  unless (failures == 0) exitFailure
  where
    showMean :: Int -> Int -> String
    showMean total n
      | n == 0 = "-"
      | otherwise = show (fromIntegral total / fromIntegral n :: Double)

-- | Edge cases the oracle streams do not reach, generated on the model side
-- (the model is the reference; melonDS agreement is the model gate's job):
--
-- * normal components exactly at the culling shrink boundary (@-2^31@ fits,
--   @2^31@ does not), with the dot sign decided by a component the shift
--   truncates to 0, for each culling mode;
-- * VBlank pulses that arrive while a polygon is being built, with a swap
--   pending, and a second VBlank behind it;
-- * an overflow acknowledge that arrives while a polygon is being built
--   (after filling polygon and vertex RAM exactly to their limits).
syntheticItems :: [Item]
syntheticItems = cullBoundary ++ vblankBusy ++ overflowAck
  where
    ps attr = PolyState attr 0 0 (0, 191, 255, 0, 256, 192) 0xFFFFFF
    vtx attr x y z w = IEv (GeVertex (ClipVertex x y z w 0x1FFFF 0x10FFF 0xFFF 16 32) (ps attr))
    tri attr (x0, y0, w0) (x1, y1, w1) (x2, y2, w2) =
      [vtx attr x0 y0 0 w0, vtx attr x1 y1 0 w1, vtx attr x2 y2 0 w2]
    -- v1 = (0, 1, W); v0 - v1 = (-15, -2^31, 0), v2 - v1 = (0, 0, 1): normal
    -- (-2^31, 15, 0), no shrink, dot 15. Mirrored: v0 - v1 = (15, -2^31, 0),
    -- v2 - v1 = (0, 0, -1): normal (2^31, 15, 0) shrinks, dot 0.
    cullBoundary = IEv (GeBegin 0) : concat
      [ tri attr (-15, 1 - 2 ^ (31 :: Int), w) (0, 1, w) (0, 1, w + 1)
        ++ tri attr (15, 1 - 2 ^ (31 :: Int), w) (0, 1, w) (0, 1, w - 1)
      | attr <- [0x001F0000, 0x001F0040, 0x001F0080, 0x001F00C0], w <- [0x1000, 0x40000, 7] ]
      ++ [IEv GeEnd]
    small attr i = let x = fromIntegral ((i * 37) `mod` 3000) - 1500
                       y = fromIntegral ((i * 91) `mod` 2000) - 1000
                   in tri attr (x, y, 0x1000) (x + 64, y, 0x1000) (x, y + 64, 0x1000)
    big attr = tri attr (-9000, -9000, 0x1000) (9000, -9000, 0x1000) (0, 9000, 0x1000)
    vblankBusy = concat
      [ [IEv (GeSwap 0), IEv (GeBegin 0)] ++ small 0x001F00C0 (1 :: Int) ++ [IVb]
      , small 0x001F00C0 2 ++ [IEv (GeSwap 1)] ++ big 0x001F00C0 ++ [IVb, IVb]
      , [IEv (GeSwap 2)] ++ big 0x001F00C0 ++ small 0x001F00C0 3 ++ [IVb]
      , small 0x001F00C0 4 ++ [IVb] ]
    overflowAck = [IEv (GeBegin 0)] ++ concatMap (small 0x001F00C0) [0 .. 2049 :: Int]
      ++ small 0x001F00C0 5000 ++ [IAck] ++ small 0x001F00C0 5001 ++ big 0x001F00C0 ++ [IAck]
      ++ [IEv (GeSwap 0), IVb]
