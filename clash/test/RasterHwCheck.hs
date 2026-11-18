{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}

-- | Clash-simulation gate for the rasteriser hardware ("Nds.Gpu3D.RasterHw",
-- Clash top @nds_gpu3d_raster@) against the renderer model.
--
-- @raster-hw-check CASE VRAM@ takes a @render_oracle@ case (one or more
-- frames, as @run_render_check.sh@ generates them) and its VRAM image,
-- encodes every frame with "Nds.Gpu3D.PolyRam" into a behavioural memory
-- (polygon bank alternating per frame) together with the texture and
-- palette slots, and runs the frames back to back on one simulated
-- rasteriser. Every port has random ready (probability READY, default 3/4)
-- and random in-order latency 1..LATMAX (default 12); MEM=ideal gives ready
-- always and latency 1. After every frame it compares
--
-- * all 192 output lines (256 words each, @GetLine@ with @RenderXPos@),
-- * the lower layer the frame leaves in memory (colour, depth, attribute),
-- * the stencil buffer and previous-mask flag snapshot
--
-- with 'renderFrameFrom' on the frame as polygon RAM holds it
-- ('decodeFrame'), chaining the model's carry. It reports the cycles from
-- start to done of every frame and the largest gap between consecutive
-- output lines.
module Main (main) where

import Control.Monad (forM_, unless, when)
import Data.Array.Unboxed (bounds, (!))
import Data.Bits (complement, shiftL, shiftR, testBit, xor, (.&.), (.|.))
import qualified Data.IntMap.Strict as IM
import Data.List (foldl')
import qualified Data.Sequence as Seq
import Data.Sequence (Seq, ViewL (..), viewl, (|>))
import Data.Int (Int16, Int32)
import Data.Word (Word32, Word64, Word8)
import Numeric (showHex)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import Text.Printf (printf)

import Clash.Explicit.Prelude (BitVector, enableGen)
import qualified Clash.Explicit.Prelude as C
import Clash.Explicit.Signal (systemClockGen, systemResetGen)
import Clash.Signal.Internal (Signal (..))

import Nds.Gpu3D.Mem (MemReq (..))
import Nds.Gpu3D.PolyRam (FrameDesc (..), decodeFrame, encodeFrame)
import Nds.Gpu3D.Depth (interpolate, interpolateZ, setX)
import Nds.Gpu3D.Raster (SpanRule (..))
import Nds.Gpu3D.RasterHw
import Nds.Gpu3D.RasterHw.Front (frontEnd)
import Nds.Gpu3D.RasterHw.Line (snapOffset)
import Nds.Gpu3D.RasterHw.Pixel (spanValues)
import Nds.Gpu3D.RasterHw.Setup (JobMsg (..), setupEngine)
import Nds.Gpu3D.RasterHw.Types
import Nds.Gpu3D.Render
import Nds.Gpu3D.Types (GxPolygon (..), GxVertex (..), RenderFrame (..), RenderRegs (..))

import OracleIO

------------------------------------------------------------------------------
-- Memory map

basesOf :: Bases
basesOf = Bases
  { bPoly = 0x0000000, bTex = 0x0400000, bPal = 0x0500000, bLower = 0x0600000, bOut = 0x0700000 }

type Mem = IM.IntMap Word64

memRead :: Mem -> Word32 -> Word64
memRead m a = IM.findWithDefault 0 (fromIntegral (a `shiftR` 3)) m

memWrite :: Word32 -> Word64 -> Word64 -> Mem -> Mem
memWrite a be d m =
  let k = fromIntegral (a `shiftR` 3)
      old = IM.findWithDefault 0 k m
      mask = foldl' (.|.) 0 [ 0xFF `shiftL` (8 * b) | b <- [0 .. 7], testBit be b ]
  in IM.insert k ((old .&. complement mask) .|. (d .&. mask)) m

------------------------------------------------------------------------------
-- Random numbers (SplitMix)

newtype Rng = Rng Word64

next :: Rng -> (Word64, Rng)
next (Rng s) =
  let s' = s + 0x9E3779B97F4A7C15
      z1 = (s' `xor` (s' `shiftR` 30)) * 0xBF58476D1CE4E5B9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
  in (z2 `xor` (z2 `shiftR` 31), Rng s')

------------------------------------------------------------------------------
-- Ports

data Port = Port
  { ptReady :: !Bool
  , ptQueue :: !(Seq (Int, Word64))   -- ^ (due cycle, data), in request order
  , ptLast  :: !Int                   -- ^ due cycle of the last queued response
  }

port0 :: Port
port0 = Port False Seq.empty 0

data MemCfg = MemCfg
  { mcReady :: !Word64  -- ^ ready probability numerator over 1024
  , mcLat   :: !Int
  }

------------------------------------------------------------------------------
-- Driver

data Job = Job
  { jbRegs  :: RegsHw
  , jbDesc  :: FrameDesc
  , jbWords :: [(Word32, Word64)]
  }

data D = D
  { dCycle   :: !Int
  , dMem     :: !Mem
  , dPorts   :: ![Port]           -- ^ poly, tex, lower, out
  , dRng     :: !Rng
  , dJobs    :: [Job]
  , dStart   :: !(Maybe (RegsHw, FrameDesc))
  , dRunning :: !Bool
  , dT0      :: !Int
  , dIdle    :: !Int              -- ^ cycles to wait before the next start
  , dDoneAt  :: [Int]             -- ^ frame cycle counts, newest first
  , dSnaps   :: [Mem]             -- ^ memory after each frame, newest first
  , dLineEnd :: [[Int]]           -- ^ per frame, cycles of each line's last output word (newest first)
  , dCurLines :: [Int]
  , dFinished :: !Bool
  , dHang    :: !Bool
  }

stepD :: MemCfg -> D -> RasterOut -> D
stepD cfg d o
  | dFinished d = d
  | otherwise = d4
  where
    t = dCycle d
    [pPoly, pTex, pLow, pOut] = dPorts d
    -- transfers on the four ports
    serve (m, rng, acc) (p, req) =
      let (r1, rng1) = next rng
          (r2, rng2) = next rng1
          lat = 1 + fromIntegral (r2 `mod` fromIntegral (mcLat cfg))
          -- deliver the response due this cycle (the input already showed it)
          q0 = case viewl (ptQueue p) of
            (due, _) :< rest | due <= t -> rest
            _ -> ptQueue p
          (m', q1, lastDue) = case req of
            Just (MemRead a) | ptReady p ->
              let due = max (t + lat) (ptLast p + 1)
              in (m, q0 |> (due, memRead m (fromIntegral a)), due)
            Just (MemWrite a be dat) | ptReady p ->
              (memWrite (fromIntegral a) (fromIntegral (toInteger be)) (fromIntegral (toInteger dat)) m, q0, ptLast p)
            _ -> (m, q0, ptLast p)
          ready' = (r1 `mod` 1024) < mcReady cfg
      in (m', rng2, acc ++ [Port ready' q1 lastDue])
    (mem1, rng1, ports1) = foldl' serve (dMem d, dRng d, [])
      [(pPoly, roPolyReq o), (pTex, roTexReq o), (pLow, roLowReq o), (pOut, roOutReq o)]
    -- line completion (last word of a line)
    curLines = case roOutReq o of
      Just (MemWrite a _ _) | ptReady pOut && (fromIntegral a - bOut basesOf) .&. 0x3FF == 0x3F8 -> (t - dT0 d) : dCurLines d
      _ -> dCurLines d
    d1 = d { dCycle = t + 1, dMem = mem1, dRng = rng1, dPorts = ports1, dCurLines = curLines }
    d2 | dRunning d && roDone o =
           d1 { dRunning = False, dDoneAt = (t - dT0 d) : dDoneAt d, dSnaps = mem1 : dSnaps d
              , dLineEnd = curLines : dLineEnd d, dCurLines = [], dIdle = 4 }
       | dRunning d && t - dT0 d > 8000000 = d1 { dFinished = True, dHang = True }
       | otherwise = d1
    d3 = case dStart d2 of
      Just _ -> d2 { dStart = Nothing }
      Nothing -> d2
    d4 | dRunning d3 || dStart d /= Nothing = d3
       | dIdle d3 > 0 = d3 { dIdle = dIdle d3 - 1 }
       | otherwise = case dJobs d3 of
           [] -> d3 { dFinished = True }
           (j : js) ->
             let m = foldl' (\mm (a, w) -> IM.insert (fromIntegral (a `shiftR` 3)) w mm) (dMem d3) (jbWords j)
             in d3 { dJobs = js, dMem = m, dStart = Just (jbRegs j, jbDesc j), dRunning = True, dT0 = t + 1 }

toIn :: D -> RasterIn
toIn d =
  let [pPoly, pTex, pLow, pOut] = dPorts d
      resp p = case viewl (ptQueue p) of
        (due, w) :< _ | due <= dCycle d -> Just (fromIntegral w)
        _ -> Nothing
  in RasterIn
    { riStart = dStart d
    , riBases = basesOf
    , riPolyReady = ptReady pPoly, riPolyResp = resp pPoly
    , riTexReady = ptReady pTex, riTexResp = resp pTex
    , riLowReady = ptReady pLow, riLowResp = resp pLow
    , riOutReady = ptReady pOut }

driver :: MemCfg -> D -> Signal dom RasterOut -> Signal dom D
driver cfg d ~(o :- os) = d :- (let d' = stepD cfg d o in d' `seq` driver cfg d' os)

runFrames :: MemCfg -> Word64 -> Mem -> [Job] -> D
runFrames cfg seed mem0 jobs = finalState drv
  where
    clk = systemClockGen
    rst = systemResetGen
    en = enableGen
    outs = rasterHw clk rst en ins
    d0 = D 0 mem0 (replicate 4 port0) (Rng seed) jobs Nothing False 0 8 [] [] [] [] False False
    drv = driver cfg d0 outs
    ins = toIn <$> drv
    finalState (d :- ds) = if dFinished d then d else finalState ds

------------------------------------------------------------------------------
-- Comparison

-- | The output lines, lower layer and carried state in a memory.
hwLines :: Mem -> [Word32]
hwLines m =
  [ fromIntegral (if odd j then w `shiftR` 32 else w)
  | y <- [0 .. 191 :: Int], j <- [0 .. 255 :: Int]
  , let w = memRead m (fromIntegral (bOut basesOf) + fromIntegral (y * 1024 + (j `div` 2) * 8)) ]

hwLower :: Mem -> [(Word32, Word32, Word32)]
hwLower m =
  [ (c, dep, a)
  | y <- [0 .. 191 :: Int], x <- [0 .. 255 :: Int]
  , let base = fromIntegral (bLower basesOf) + fromIntegral (y * 3072)
        ca = memRead m (base + fromIntegral (x * 8))
        dw = memRead m (base + 2048 + fromIntegral ((x `div` 2) * 8))
        (c, a) = unpackCA (fromIntegral ca)
        dep = fromIntegral (if odd x then dw `shiftR` 32 else dw) .&. 0xFFFFFF ]

hwStencil :: Mem -> ([Word32], Bool)
hwStencil m =
  let base = fromIntegral (bLower basesOf + snapOffset)
      ws = [ memRead m (base + 8 * k) | k <- [0 .. 31] ]
      st = [ fromIntegral ((w `shiftR` (2 * (x `mod` 16))) .&. 3) | w <- ws, x <- [0 .. 15 :: Int] ]
  in (st, memRead m (base + 8 * 32) /= 0)

------------------------------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--jobs", casePath] -> checkJobs casePath
    [casePath, imgPath] -> check casePath imgPath
    _ -> putStrLn "usage: raster-hw-check CASE VRAM | raster-hw-check --jobs CASE" >> exitFailure

------------------------------------------------------------------------------
-- Jobs: front end and setup engine alone, every span value per position

data JD = JD
  { jdCycle :: !Int
  , jdPort  :: !Port
  , jdRng   :: !Rng
  , jdJobs  :: [JobMsg]
  , jdDone  :: !Bool
  }

-- | The front end and setup engine on one frame (random polygon port),
-- every job they hand over in order.
simJobs :: MemCfg -> Mem -> FrameDesc -> RegsHw -> [JobMsg]
simJobs cfg mem desc regs = reverse (jdJobs (final drv))
  where
    clk = systemClockGen
    rst = systemResetGen
    en = enableGen
    start = fromListS (replicate 4 False ++ [True] ++ repeat False)
    (polyReq, recHead, rbWrite) = frontEnd clk rst en start (pure (bPoly basesOf)) (pure (fdBank desc))
      (pure (fdCount desc)) (C.fmap (ptReady . jdPort) drv) (C.fmap respOf drv) pop
    (pop, job) = setupEngine clk rst en start (pure (rhDispCnt regs)) (pure (rhAlphaRef regs)) recHead rbWrite
      (pure True)
    respOf d = case viewl (ptQueue (jdPort d)) of
      (due, w) :< _ | due <= jdCycle d -> Just (fromIntegral w)
      _ -> Nothing
    drv = go (JD 0 port0 (Rng 7) [] False) (C.bundle (polyReq, job))
    go d ~((rq, jb) :- rest) = d :- (let d' = stepJ d rq jb in d' `seq` go d' rest)
    stepJ d rq jb =
      let t = jdCycle d
          p = jdPort d
          (r1, rng1) = next (jdRng d)
          (r2, rng2) = next rng1
          lat = 1 + fromIntegral (r2 `mod` fromIntegral (mcLat cfg))
          q0 = case viewl (ptQueue p) of
            (due, _) :< rst' | due <= t -> rst'
            _ -> ptQueue p
          (q1, lastDue) = case rq of
            Just (MemRead a) | ptReady p ->
              let due = max (t + lat) (ptLast p + 1) in (q0 |> (due, memRead mem (fromIntegral a)), due)
            _ -> (q0, ptLast p)
          jobs' = maybe (jdJobs d) (: jdJobs d) jb
          done = case jb of
            Just (JobLineEnd 191) -> True
            _ -> t > 20000000
      in d { jdCycle = t + 1, jdPort = Port ((r1 `mod` 1024) < mcReady cfg) q1 lastDue, jdRng = rng2
           , jdJobs = jobs', jdDone = done }
    final (d :- ds) = if jdDone d then d else final ds

fromListS :: [a] -> Signal dom a
fromListS (x : xs) = x :- fromListS xs
fromListS [] = error "fromListS"

-- | The model's polygon lines of a frame, in order: line, polygon at the
-- line (edges advanced) and its span setup ('Nothing' for an alpha-rejected
-- mask), with a line end after every line.
modelJobs :: RenderFrame -> [Either Int32 (Int32, RPoly, Maybe SpanSetup)]
modelJobs rf = go 0 [ setupPolygon p | p <- rfPolys rf, not (gpDegenerate p) ]
  where
    regs = rfRegs rf
    disp = rrDispCnt regs
    go y ps
      | y > 191 = []
      | otherwise =
          let step rp
                | not (polygonActive y rp) = (rp, [])
                | otherwise =
                    let rp1 = advanceEdges y rp
                        alpha = if rpWire rp1 then 31 else rpAlpha rp1
                        rejected = gpShadowMask (rpPoly rp1) && alpha <= fromIntegral (rrAlphaRef regs)
                    in if rejected
                         then (rp1, [Right (y, rp1, Nothing)])
                         else (stepEdges rp1, [Right (y, rp1, Just (spanSetup disp y rp1))])
              rs = map step ps
          in concatMap snd rs ++ [Left y] ++ go (y + 1) (map fst rs)

-- | The case's frames plus its first frame with every vertex's W at 1 and Z a
-- ramp ('wOne'). W = 1 is a legal 24-bit 'gpFinalW' from the geometry
-- engine, and it is the only value that separates the two W tests: a span whose
-- ends both have W = 1 is flat in W (@wA == wB@) with the low bit set, so the
-- edge interpolator sees @w & 0x7E == 0@ (linear) while the span interpolator
-- sees @w & 0x7F == 1@ (perspective, 'Render.spanSetup'). The generated
-- cases never put W at an odd value equal at both ends of a span.
withWOne :: [RenderFrame] -> [RenderFrame]
withWOne fs = case fs of
  (f : _) -> fs ++ [ wOne f ]
  [] -> []

-- | The frame with every vertex's W at 1 and Z a ramp, not W-buffered.
wOne :: RenderFrame -> RenderFrame
wOne rf = rf { rfPolys = [ wOnePoly p | p <- rfPolys rf ] }
  where
    wOnePoly p = p
      { gpFinalW = replicate (length (gpVerts p)) 1
      , gpFinalZ = take (length (gpFinalZ p)) [ 0x1000 + 0x800 * i | i <- [0 :: Int32 ..] ]
      , gpWBuffer = False }

checkJobs :: FilePath -> IO ()
checkJobs casePath = do
  text <- readFile casePath
  frames0 <- either (\e -> putStrLn ("FAIL " ++ e) >> exitFailure) pure (parseRenderCase text)
  let frames = withWOne frames0
  readyQ <- envInt "READY" 768
  latMax <- envInt "LATMAX" 12
  let cfg = MemCfg (fromIntegral readyQ) latMax
  results <- mapM (oneFrame cfg) (zip [0 :: Int ..] frames)
  let (nJobs, nPos, nBad) = foldl' (\(a, b, c) (x, y, z) -> (a + x, b + y, c + z)) (0, 0, 0) results
  printf "raster-hw-jobs: %d frames, %d polygon lines, %d positions compared, %d mismatches\n"
    (length frames) (nJobs :: Int) (nPos :: Int) (nBad :: Int)
  when (nBad /= 0) exitFailure
  where
    oneFrame cfg (fi, f0) = do
      let bank = 0
          ws = encodeFrame (bPoly basesOf) bank (rfPolys f0)
          mem = IM.fromList [ (fromIntegral (a `shiftR` 3), fromIntegral (toInteger w)) | (a, w) <- ws ]
          desc = FrameDesc bank (fromIntegral (length (rfPolys f0)))
          rd a = fromIntegral (IM.findWithDefault 0 (fromIntegral (a `shiftR` (3 :: Int))) mem) :: BitVector 64
          f = f0 { rfPolys = decodeFrame rd (bPoly basesOf) desc }
          hw = simJobs cfg mem desc (regsHw (rfRegs f))
          want = modelJobs f
          cmp (Left y) (JobLineEnd y') = if fromIntegral y' == y then [] else ["line end " ++ show y ++ " vs " ++ show y']
          cmp (Right (y, rp, msp)) (JobSpan j) = jobDiff y rp msp j
          cmp w g = ["order: want " ++ either (\y -> "end " ++ show y) (\(y, _, _) -> "span y=" ++ show y) w
                     ++ " got " ++ (case g of JobLineEnd y -> "end " ++ show y; JobSpan j -> "span y=" ++ show (sjY j))]
          diffs = concat (zipWith cmp want hw) ++ [ "job count " ++ show (length want) ++ " vs " ++ show (length hw) | length want /= length hw ]
          npos = sum [ length (spanValues j) | JobSpan j <- hw ]
      forM_ (take 8 diffs) $ \m -> putStrLn ("  frame " ++ show fi ++ ": " ++ m)
      pure (length [ () | Right _ <- want ], npos, length diffs)

-- | Differences between one hardware job and the model's span setup.
jobDiff :: Int32 -> RPoly -> Maybe SpanSetup -> SpanJob -> [String]
jobDiff y rp msp j =
  let tag = "y=" ++ show y ++ " poly " ++ show (gpAttr (rpPoly rp)) ++ " n=" ++ show (rpN rp) ++ ": "
  in case msp of
    Nothing -> [ tag ++ "rejected mask drawn" | sjDraw j ]
    Just sp ->
      let rule = spRule sp
          (pl, pm, pr) = spPieces sp
          rng r = if rValid r then Just (fromIntegral (rLo r), fromIntegral (rHi r)) else Nothing
          hdr = [ tag ++ "pieces " ++ show (pl, pm, pr) ++ " vs " ++ show (rng (sjLeft j), rng (sjInner j), rng (sjRight j))
                | (pl, pm, pr) /= (rng (sjLeft j), rng (sjInner j), rng (sjRight j)) ]
             ++ [ tag ++ "start " ++ show (srStart rule) ++ " vs " ++ show (sjX0 j) | fromIntegral (sjX0 j) /= srStart rule ]
             ++ [ tag ++ "yedge" | spYEdge sp /= sjYEdge j ]
             ++ [ tag ++ "coverage words " ++ show (srLCov rule, srRCov rule) ++ " vs " ++ show (sjLCov j, sjRCov j)
                | (srLCov rule, srRCov rule) /= (sjLCov j, sjRCov j) ]
          i0 = spInterp sp
          mask = gpShadowMask (rpPoly rp)
          c6 v = fromIntegral ((fromIntegral v :: Word32) `shiftR` 3) :: Word8
          vals = [ (x, z, c, s, t) | (x, Just _, z, c, s, t) <- spanValues j ]
          bad = [ tag ++ "x=" ++ show x ++ " want z=" ++ show wz ++ " rgb=" ++ show wc ++ " st=" ++ show (ws, wt)
                  ++ " got z=" ++ show z ++ " rgb=" ++ show c ++ " st=" ++ show (s, t)
                | (x, z, c, s, t) <- vals
                , let i = setX (fromIntegral x) i0
                      at (a, b) = interpolate a b i
                      wz = uncurry interpolateZ (spZ sp) i
                      wc = (c6 (at (spR sp)), c6 (at (spG sp)), c6 (at (spB sp)))
                      ws = fromIntegral (at (spS sp)) :: Int16
                      wt = fromIntegral (at (spT sp)) :: Int16
                , wz /= z || (not mask && (wc /= c || ws /= s || wt /= t)) ]
      in hdr ++ take 3 bad

envInt :: String -> Int -> IO Int
envInt k def = maybe def read <$> lookupEnv k

check :: FilePath -> FilePath -> IO ()
check casePath imgPath = do
  text <- readFile casePath
  frames0 <- either (\e -> putStrLn ("FAIL " ++ e) >> exitFailure) pure (parseRenderCase text)
  let frames = withWOne frames0
  img <- readWords imgPath
  memMode <- maybe "random" id <$> lookupEnv "MEM"
  readyQ <- envInt "READY" 768
  latMax <- envInt "LATMAX" 12
  seed <- envInt "SEED" 1
  let texMem = imageMemory img
      cfg = if memMode == "ideal" then MemCfg 1024 1 else MemCfg (fromIntegral readyQ) latMax
      (lo, hi) = bounds img
      imgWord i = if i >= lo && i <= hi then fromIntegral (img ! i) :: Word64 else 0
      vramWords =
        [ (bTex basesOf + fromIntegral (8 * w), imgWord (2 * w) .|. (imgWord (2 * w + 1) `shiftL` 32))
        | w <- [0 .. 0xFFFF :: Int] ] ++
        [ (bPal basesOf + fromIntegral (8 * w), imgWord (0x20000 + 2 * w) .|. (imgWord (0x20000 + 2 * w + 1) `shiftL` 32))
        | w <- [0 .. 0x3FFF :: Int] ]
      mem0 = IM.fromList [ (fromIntegral (a `shiftR` 3), w) | (a, w) <- vramWords ]
      enc k f =
        let bank = fromIntegral (k `mod` 2 :: Int)
            ws = [ (fromIntegral a, fromIntegral (toInteger w)) | (a, w) <- encodeFrame (bPoly basesOf) bank (rfPolys f) ]
            desc = FrameDesc bank (fromIntegral (length (rfPolys f)))
            wm = IM.fromList [ (fromIntegral (a `shiftR` 3), w) | (a, w) <- ws ]
            rd a = fromIntegral (IM.findWithDefault 0 (fromIntegral (a `shiftR` (3 :: Int))) wm) :: BitVector 64
            polys = decodeFrame rd (bPoly basesOf) desc
        in (Job (regsHw (rfRegs f)) desc ws, f { rfPolys = polys })
      encoded = zipWith enc [0 ..] frames
      jobs = map fst encoded
      mframes = map snd encoded
      live = filter (not . gpDegenerate) . rfPolys
      changed = sum [ length (filter id (zipWith (/=) (concatMap colours (live a)) (concatMap colours (live b))))
                    | (a, b) <- zip frames mframes ]
      colours p = concat [ [gvR v, gvG v, gvB v] | v <- gpVerts p ]
      -- Degenerate polygons are never drawn; their out-of-range coordinates
      -- need not survive the round trip.
      otherDiff = or [ map gpDegenerate (rfPolys a) /= map gpDegenerate (rfPolys b)
                       || map strip (live a) /= map strip (live b) | (a, b) <- zip frames mframes ]
      strip p = p { gpVerts = [ v { gvR = 0, gvG = 0, gvB = 0 } | v <- gpVerts p ] }
  when otherDiff $ putStrLn "FAIL PolyRam round trip changed fields other than vertex colours" >> exitFailure
  let d = runFrames cfg (fromIntegral seed) mem0 jobs
      outs = snd (foldl' (\(c, acc) f -> let (o, c') = renderFrameFrom c texMem f in (c', acc ++ [(o, c')])) (resetCarry, []) mframes)
      snaps = reverse (dSnaps d)
      cycles = reverse (dDoneAt d)
      lineEnds = map reverse (reverse (dLineEnd d))
  when (dHang d) $ putStrLn ("FAIL hang after " ++ show (length cycles) ++ " frames") >> exitFailure
  unless (length snaps == length frames) $ putStrLn "FAIL missing frames" >> exitFailure
  results <- mapM (\(fi, (o, c), m, cyc, le) -> do
      let wantL = [ roLines o ! i | i <- [0 .. 49151] ]
          gotL = hwLines m
          lineBad = [ (i, w, g) | (i, w, g) <- zip3 [0 :: Int ..] wantL gotL, w /= g ]
          lw = caLower c
          wantLow = [ (lyColour lw ! i, lyDepth lw ! i, lyAttr lw ! i) | i <- [0 .. 49151] ]
          lowBad = [ (i, w, g) | (i, w, g) <- zip3 [0 :: Int ..] wantLow (hwLower m), w /= g ]
          (st, pm) = hwStencil m
          wantSt = [ fromIntegral (caStencil c ! i) | i <- [0 .. 511] ]
          stBad = length (filter id (zipWith (/=) st wantSt)) + (if pm /= caPrevMask c then 1 else 0)
          gaps = zipWith (-) (drop 1 le) le
          maxGap = if null gaps then 0 else maximum gaps
          firstLine = if null le then 0 else head le
      forM_ (take 6 lineBad) $ \(i, w, g) ->
        printf "  frame %d line y=%d x=%d want=0x%s got=0x%s\n" (fi :: Int) (i `div` 256) (i `mod` 256) (showHex w "") (showHex g "")
      forM_ (take 6 lowBad) $ \(i, (wc, wd, wa), (gc, gd, ga)) ->
        printf "  frame %d lower y=%d x=%d want=(%x,%x,%x) got=(%x,%x,%x)\n" fi (i `div` 256) (i `mod` 256) wc wd wa gc gd ga
      when (stBad > 0) $ printf "  frame %d stencil/flag mismatches %d\n" fi stBad
      pure (length lineBad + length lowBad + stBad, cyc :: Int, max maxGap firstLine, length le))
    (zip5 [0 ..] outs snaps cycles lineEnds)
  let bad = sum [ b | (b, _, _, _) <- results ]
      cyc = [ c | (_, c, _, _) <- results ]
      gapMax = maximum (0 : [ g | (_, _, g, _) <- results ])
      linesSeen = [ n | (_, _, _, n) <- results ]
  unless (all (== 192) linesSeen) $ printf "  output lines written per frame: %s\n" (show linesSeen)
  printf "raster-hw-check: %d frames, %d polygons, %d colours rounded by PolyRam, cycles/frame max %d mean %d [%s], worst line %d cycles, %d words compared (lines, lower C/D/A, stencil), %d mismatches\n"
    (length frames) (sum (map (length . rfPolys) frames)) changed (maximum cyc) (sum cyc `div` length cyc)
    (unwords (map show cyc)) gapMax (length frames * (49152 * 4 + 513)) bad
  when (bad /= 0 || any (/= 192) linesSeen) exitFailure

zip5 :: [a] -> [b] -> [c] -> [d] -> [e] -> [(a, b, c, d, e)]
zip5 (a : as) (b : bs) (c : cs) (d : ds) (e : es) = (a, b, c, d, e) : zip5 as bs cs ds es
zip5 _ _ _ _ _ = []
