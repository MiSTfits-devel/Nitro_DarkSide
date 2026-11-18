{-# LANGUAGE DataKinds #-}

-- | Clash-simulation gate for the GX front-end hardware
-- ('Nds.Gpu3D.GxFrontHw.gxFrontHw') against the pure model
-- ('Nds.Gpu3D.GxFront'), which GxFrontCheck ties to melonDS.
--
-- A testbench driver runs closed-loop with the hardware, cycle by cycle. It
-- presents bus accesses (holding each until the hardware accepts it, with
-- garbage in the unaddressed lanes), offers the command stream a random
-- ready, and drives VBlank, POWCNT1, BG0HOFS, DISP3DCNT status bits, the
-- geometry status, RAM_COUNT and the result registers, sometimes in the
-- same cycle as a bus access. Each time the hardware performs an event the
-- driver steps the model with it, in the hardware's documented order
-- (VBlank latch, bus access, pop, POWCNT1, X position, status bits), and
-- compares:
--
-- * every cycle: read data (one cycle after each accepted read, nothing
--   otherwise), the STACK_ACK pulse, the latched render scalars,
--   DISP_1DOT_DEPTH, the enables, and the latched tables through all three
--   read ports (random addresses, whenever no copy is running);
-- * whenever the hardware is idle (bus ready or command offered): GXSTAT,
--   the stall, the IRQ line, the offered head entry, and the running counts
--   of CheckFIFODMA and CheckFIFOIRQ pulses;
-- * every popped entry.
--
-- Usage: gxfront-hw-check [SEED [RUNS [ITEMS]]]
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Bits (complement, shiftL, shiftR, testBit, xor, (.&.), (.|.))
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, isNothing)
import Data.Word (Word16, Word32, Word64, Word8)
import Numeric (showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Clash.Explicit.Prelude (BitVector, Unsigned, enableGen)
import Clash.Explicit.Signal (systemClockGen, systemResetGen)
import Clash.Signal.Internal (Signal (..))

import Nds.Gpu3D.GxFront
import Nds.Gpu3D.GxFrontHw
import Nds.Gpu3D.Types

------------------------------------------------------------------------------
-- Script

data BusOp = BusOp
  { boSize  :: !Size
  , boAddr  :: !Word32
  , boValue :: !Word32
  , boWrite :: !Bool
  , boJunk  :: !Word32   -- ^ fills the unaddressed write lanes
  } deriving (Show)

data Side
  = SV
  | SX !Word16 !Word16
  | SE !Bool !Bool
  | SF !Bool !Bool
  | SG !GeoStatus
  | SQ !Word16 !Word16
  | SZ !Word32 !Word32
  | SReady !(Maybe Bool)   -- ^ force the command ready (driver only)
  deriving (Show)

data Item = Item
  { itBus  :: !(Maybe BusOp)
  , itSide :: ![Side]
  , itGap  :: !Int
  } deriving (Show)

toReq :: BusOp -> BusReq
toReq b = BusReq
  { brAdr = fromIntegral (boAddr b .&. 0x00FFFFFC)
  , brDin = fromIntegral din
  , brRnw = not (boWrite b)
  , brAcc = case boSize b of S8 -> 0; S16 -> 1; S32 -> 2
  , brBEna = be
  }
  where
    low = fromIntegral (boAddr b .&. 3) :: Int
    (mask, be) = case boSize b of
      S8 -> (0xFF `shiftL` (8 * low), 1 `shiftL` low)
      S16 -> (0xFFFF `shiftL` (8 * low), 3 `shiftL` low)
      S32 -> (0xFFFFFFFF, 0xF)
    din = (boJunk b .&. complement mask) .|. ((boValue b `shiftL` (8 * low)) .&. mask)

------------------------------------------------------------------------------
-- Model harness: the front end and stubs for its neighbours.

data H = H
  { hSt   :: !GxFront
  , hGeo  :: !GeoStatus
  , hPipe :: !PipeStatus
  , hRes  :: !(M.Map Word32 Word32)
  }

geo0 :: GeoStatus
geo0 = GeoStatus False False 0 False False False False

h0 :: H
h0 = H initGxFront geo0 (PipeStatus 0 0) M.empty

frontIn :: H -> FrontIn
frontIn h = FrontIn (hGeo h) (hPipe h) (\a -> M.findWithDefault 0 a (hRes h))

------------------------------------------------------------------------------
-- Driver

data D = D
  { dItems    :: [Item]
  , dCur      :: !(Maybe BusOp)
  , dSide     :: ![Side]
  , dReady    :: !Bool
  , dForce    :: !(Maybe Bool)
  , dTbl      :: !(Unsigned 5, Unsigned 3, Unsigned 6)
  , dGap      :: !Int
  , dH        :: !H
  , dRng      :: !Word64
  , dFill     :: !Bool
  , dPendRead :: !(Maybe (BitVector 32))
  , dPendTbl  :: !(Maybe (Word16, Word16, Word8))
  , dVblPrev  :: !Bool
  , dDmaM, dDmaH, dChkM, dChkH :: !Int
  , dCycle    :: !Int
  , dDrain    :: !Int
  , dHeld     :: !Int   -- ^ cycles the current bus access has waited
  , dDone     :: !Bool
  , dErrs     :: ![String]
  , dNErr     :: !Int
  , dChecks   :: !Int
  , dWrites, dReads, dPops, dVbl, dSides :: !Int
  , dStallCyc, dCopyCyc, dFullCyc, dRefills, dTblChecks :: !Int
  }

d0 :: [Item] -> Word64 -> D
d0 items seed = D
  { dItems = items, dCur = Nothing, dSide = [], dReady = False, dForce = Nothing
  , dTbl = (0, 0, 0), dGap = 4, dH = h0, dRng = seed * 0x9E3779B97F4A7C15 + 1, dFill = True
  , dPendRead = Nothing, dPendTbl = Nothing, dVblPrev = False
  , dDmaM = 0, dDmaH = 0, dChkM = 0, dChkH = 0, dCycle = 0, dDrain = 0, dHeld = 0, dDone = False
  , dErrs = [], dNErr = 0, dChecks = 0
  , dWrites = 0, dReads = 0, dPops = 0, dVbl = 0, dSides = 0
  , dStallCyc = 0, dCopyCyc = 0, dFullCyc = 0, dRefills = 0, dTblChecks = 0 }

xorshift :: Word64 -> Word64
xorshift x0 =
  let x1 = x0 `xor` (x0 `shiftL` 13)
      x2 = x1 `xor` (x1 `shiftR` 7)
  in x2 `xor` (x2 `shiftL` 17)

hex :: (Integral a, Show a) => a -> String
hex v = showHex v ""

scalarsOf :: RenderRegs -> RenderScalars
scalarsOf r = RenderScalars
  { rsDispCnt = rrDispCnt r, rsAlphaRef = rrAlphaRef r, rsClearAttr1 = rrClearAttr1 r
  , rsClearAttr2 = rrClearAttr2 r, rsFogColor = rrFogColor r, rsFogOffset = rrFogOffset r
  , rsFogShift = rrFogShift r, rsXPos = rrXPos r }

lanePlaced :: BusOp -> Word32 -> BitVector 32
lanePlaced b v = fromIntegral (v `shiftL` (8 * fromIntegral (boAddr b .&. 3)))

-- | One cycle: compare the hardware's outputs with the model, step the
-- model with the events the hardware performed, choose the next stimulus.
step :: D -> FrontOut -> D
step d o = d'
  where
    h = dH d
    st = hSt h
    busNow = dCur d
    accepted = isJust busNow && foBusReady o
    idle = foBusReady o || isJust (foCmd o)
    dmaH = dDmaH d + fromEnum (foDma o)
    chkH = dChkH d + fromEnum (foIrqCheck o)

    -- comparisons on the state as the cycle began
    rr = renderRegs st
    everyCycle =
      [ ("read data", foRdata o == dPendRead d, show (foRdata o) ++ " /= " ++ show (dPendRead d))
      , ("render scalars", foRender o == scalarsOf rr, show (foRender o) ++ " /= " ++ show (scalarsOf rr))
      , ("1dot depth", foZeroDotW o == zeroDotW st, hex (foZeroDotW o) ++ " /= " ++ hex (zeroDotW st))
      , ("enables", (foGeomEn o, foRendEn o) == (gfGeomEn st, gfRendEn st), "")
      ] ++
      [ ("tables", (foToon o, foEdge o, foFog o) == e, show (foToon o, foEdge o, foFog o) ++ " /= " ++ show e)
      | Just e <- [dPendTbl d] ]
    headM = headEntry st
    expCmd = if isJust headM && not accepted then headM else Nothing
    whenIdle =
      [ ("gxstat", foGxStat o == gxStat (hGeo h) st, hex (foGxStat o) ++ " /= " ++ hex (gxStat (hGeo h) st))
      , ("stall", foStall o == stalled st, show (foStall o))
      , ("irq", foIrq o == irqLine st, show (foIrq o))
      , ("head", fmap (\e -> CmdEntry (heCmd e) (heParam e)) (foCmd o) == expCmd
        , show (foCmd o) ++ " /= " ++ show expCmd)
      , ("dma pulses", dmaH == dDmaM d, show dmaH ++ " /= " ++ show (dDmaM d))
      , ("irq checks", chkH == dChkM d, show chkH ++ " /= " ++ show (dChkM d))
      ]
    checks0 = everyCycle ++ (if idle then whenIdle else [])

    -- events, in the hardware's order
    h1 = if dVblPrev d then h { hSt = vblank (hSt h) } else h
    (h2, busChecks, pendRead, nW, nR, chkB) = case busNow of
      Just b | accepted ->
        if boWrite b
          then
            let (s', fx) = mmioWrite (boSize b) (boAddr b) (boValue b) (hSt h1)
                g = hGeo h1
                g' = if wfAck fx then g { gsStackError = False, gsProjStack = False } else g
            in ( h1 { hSt = s', hGeo = g' }
               , [("ack", foAck o == wfAck fx, show (foAck o))]
               , Nothing, 1, 0, fromEnum (wfIrqCheck fx) )
          else
            ( h1, [("ack", not (foAck o), "ack on a read")]
            , Just (lanePlaced b (mmioRead (frontIn h1) (boSize b) (boAddr b) (hSt h1))), 0, 1, 0 )
      _ -> (h1, [("ack", not (foAck o), "ack without a write")], Nothing, 0, 0, 0)
    (h3, popChecks, nP, dmaP, chkP) = case foCmd o of
      Just e | dReady d -> case popEntry (hSt h2) of
        Just (ce, s', fx) ->
          ( h2 { hSt = s' }
          , [("pop", CmdEntry (heCmd e) (heParam e) == ce, show e ++ " /= " ++ show ce)]
          , 1, fromEnum (pfDma fx), fromEnum (pfRefill fx) )
        Nothing -> (h2, [("pop", False, "hardware popped an empty PIPE")], 1, 0, 0)
      _ -> (h2, [], 0, 0, 0)
    h4 = foldl sideModel h3 (dSide d)
    sideModel hh sd = case sd of
      SE g r -> hh { hSt = setPower g r (hSt hh) }
      _ -> hh
    h5 = foldl sideXF h4 (dSide d)
    sideXF hh sd = case sd of
      SX x m -> hh { hSt = setRenderXPos x m (hSt hh) }
      _ -> hh
    h6 = foldl sideRest h5 (dSide d)
    sideRest hh sd = case sd of
      SF u v -> hh { hSt = setDispCntFlags u v (hSt hh) }
      SG g -> hh { hGeo = g }
      SQ p v -> hh { hPipe = PipeStatus p v }
      SZ a v -> hh { hRes = M.insert a v (hRes hh) }
      _ -> hh
    vblNow = any (\sd -> case sd of SV -> True; _ -> False) (dSide d)
    force' = foldl (\f sd -> case sd of SReady r -> r; _ -> f) (dForce d) (dSide d)

    -- latched tables as the cycle began, at this cycle's read addresses
    (ta, ea, fa) = dTbl d
    pendTbl
      | foRenderBusy o = Nothing
      | otherwise = Just ( rrToonTable rr !! fromIntegral ta, rrEdgeTable rr !! fromIntegral ea
                         , rrFogDensity rr !! fromIntegral fa )

    allChecks = checks0 ++ busChecks ++ popChecks
    bad = [n ++ ": " ++ msg | (n, ok, msg) <- allChecks, not ok]
    errs = take 10 (dErrs d ++ map (\m -> "cycle " ++ show (dCycle d) ++ ": " ++ m) bad)

    -- next stimulus
    r1 = xorshift (dRng d)
    r2 = xorshift r1
    r3 = xorshift r2
    cur1 = if accepted then Nothing else busNow
    exhausted = null (dItems d) && isNothing cur1 && dGap d == 0
    (cur', side', gap', items')
      | isJust cur1 = (cur1, [], dGap d, dItems d)
      | dGap d > 0 = (Nothing, [], dGap d - 1, dItems d)
      | otherwise = case dItems d of
          Item b s g : rest -> (b, s, g, rest)
          [] -> (Nothing, [], 0, [])
    fill' = if r1 `mod` 400 == 0 then not (dFill d) else dFill d
    readyP = if exhausted then 100 else if dFill d then 12 else 88
    -- A geometry engine held off by a forced-low ready still drains a FIFO
    -- that has stalled the bus for long enough (it would never deadlock).
    held' = if isJust cur1 then dHeld d + 1 else 0
    ready' = case force' of
      Just f | not exhausted && (f || held' < 40) -> f
      _ -> fromIntegral (r2 `mod` 100) < (readyP :: Int)
    tbl' = (fromIntegral (r3 `mod` 32), fromIntegral ((r3 `shiftR` 8) `mod` 8), fromIntegral ((r3 `shiftR` 16) `mod` 34))
    drain' = if exhausted then dDrain d + 1 else 0
    quiet = isNothing (headEntry (hSt h6)) && not (stalled (hSt h6))
    -- a bus access never accepted, or a stream that never drains, is a hang
    hung = held' > 5000 || drain' > 20000
    done' = (exhausted && drain' > 64 && quiet) || hung
    hangErr = ["cycle " ++ show (dCycle d) ++ ": hang (bus held " ++ show held' ++ ", draining " ++ show drain' ++ ")" | hung]

    d' = d
      { dItems = items', dCur = cur', dSide = side', dReady = ready', dForce = force'
      , dTbl = tbl', dGap = gap', dH = h6, dRng = r3, dFill = fill'
      , dPendRead = pendRead, dPendTbl = pendTbl, dVblPrev = vblNow
      , dDmaM = dDmaM d + dmaP, dDmaH = dmaH, dChkM = dChkM d + chkB + chkP, dChkH = chkH
      , dCycle = dCycle d + 1, dDrain = drain', dHeld = held', dDone = done'
      , dErrs = take 10 (errs ++ hangErr), dNErr = dNErr d + length bad + length hangErr
      , dChecks = dChecks d + length allChecks
      , dWrites = dWrites d + nW, dReads = dReads d + nR, dPops = dPops d + nP
      , dVbl = dVbl d + fromEnum vblNow, dSides = dSides d + length (dSide d)
      , dStallCyc = dStallCyc d + fromEnum (foStall o)
      , dCopyCyc = dCopyCyc d + fromEnum (foRenderBusy o)
      , dFullCyc = dFullCyc d + fromEnum (fifoLevel st == fifoDepth)
      , dRefills = dRefills d + chkP
      , dTblChecks = dTblChecks d + fromEnum (isJust (dPendTbl d)) }

driver :: D -> Signal dom FrontOut -> Signal dom D
driver d ~(o :- os) = d :- (let d' = step d o in d' `seq` driver d' os)

runOnce :: [Item] -> Word64 -> D
runOnce items seed = finalState drv
  where
    clk = systemClockGen
    rst = systemResetGen
    en = enableGen
    outs = gxFrontHw clk rst en bus ready geo ps res vbl xpos power flags tbl
    drv = driver (d0 items seed) outs
    bus = fmap toReq . dCur <$> drv
    ready = dReady <$> drv
    geo = hGeo . dH <$> drv
    ps = hPipe . dH <$> drv
    res = (\d a -> M.findWithDefault 0 a (hRes (dH d))) <$> drv <*> (foResAddr <$> outs)
    vbl = (\d -> any (\s -> case s of SV -> True; _ -> False) (dSide d)) <$> drv
    xpos = (\d -> foldl (\acc s -> case s of SX x m -> Just (x, m); _ -> acc) Nothing (dSide d)) <$> drv
    power = (\d -> foldl (\acc s -> case s of SE g r -> Just (g, r); _ -> acc) Nothing (dSide d)) <$> drv
    flags = (\d -> foldl (\acc s -> case s of SF u v -> (u, v); _ -> acc) (False, False) (dSide d)) <$> drv
    tbl = dTbl <$> drv
    finalState (d :- ds) = if dDone d then d else finalState ds

------------------------------------------------------------------------------
-- Stimulus

newtype Rng = Rng Word64

next :: Rng -> (Word64, Rng)
next (Rng s) =
  let s' = s + 0x9E3779B97F4A7C15
      z1 = (s' `xor` (s' `shiftR` 30)) * 0xBF58476D1CE4E5B9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
  in (z2 `xor` (z2 `shiftR` 31), Rng s')

below :: Int -> Rng -> (Int, Rng)
below n r = let (x, r') = next r in (fromIntegral (x `mod` fromIntegral n), r')

word :: Rng -> (Word32, Rng)
word r = let (x, r') = next r in (fromIntegral (x `shiftR` 16), r')

pick :: [a] -> Rng -> (a, Rng)
pick xs r = let (i, r') = below (length xs) r in (xs !! i, r')

wr :: Size -> Word32 -> Word32 -> Item
wr s a v = Item (Just (BusOp s a v True 0xA5C3F00F)) [] 0

rd :: Size -> Word32 -> Item
rd s a = Item (Just (BusOp s a 0 False 0)) [] 0

side :: [Side] -> Item
side s = Item Nothing s 0

gap :: Int -> Item -> Item
gap g it = it { itGap = g }

validCmds :: [Word8]
validCmds = [0x10 .. 0x1C] ++ [0x20 .. 0x2B] ++ [0x30 .. 0x34] ++ [0x40, 0x41, 0x50, 0x60, 0x70, 0x71, 0x72]

-- | A packed GXFIFO word and its parameters (sometimes one off).
packedWords :: Rng -> ([Word32], Rng)
packedWords r0 =
  let (n, r1) = below 5 r0
      (cmds, r2) = go n r1
      bytes4 = take 4 (cmds ++ repeat 0)
      w = foldr (\b acc -> (acc `shiftL` 8) .|. fromIntegral b) 0 bytes4
      np = sum (map cmdNumParams bytes4)
      (skew, r3) = below 12 r2
      np' = max 0 (np + (if skew == 0 then -1 else if skew == 1 then 1 else 0))
      (ps, r4) = params np' r3
  in (w : ps, r4)
  where
    go :: Int -> Rng -> ([Word8], Rng)
    go 0 r = ([], r)
    go k r =
      let (kind, r1) = below 16 r
          (b, r2) = if kind == 0 then (\(x, r') -> (fromIntegral x, r')) (word r1) else pick validCmds r1
          (bs, r3) = go (k - 1) r2
      in (b : bs, r3)
    params :: Int -> Rng -> ([Word32], Rng)
    params 0 r = ([], r)
    params k r = let (x, r1) = word r; (xs, r2) = params (k - 1) r1 in (x : xs, r2)

resultAddrs :: [Word32]
resultAddrs = [0x04000620, 0x04000624 .. 0x04000634] ++ [0x04000640, 0x04000644 .. 0x040006A0]

regAddrs :: [Word32]
regAddrs =
  [ 0x04000060, 0x04000062, 0x04000340, 0x04000350, 0x04000352, 0x04000354, 0x04000356
  , 0x04000358, 0x0400035A, 0x0400035C, 0x04000600, 0x04000602, 0x04000610, 0x04000320
  , 0x04000604, 0x04000606, 0x04000630, 0x04000632, 0x04000634, 0x04000640 ]

align :: Size -> Word32 -> Word32
align S8 a = a
align S16 a = a .&. 0xFFFFFFFE
align S32 a = a .&. 0xFFFFFFFC

randomItems :: Int -> Rng -> [Item]
randomItems n r0
  | n <= 0 = []
  | otherwise =
      let (x, r1) = below 1000 r0
          (its, r2) = proposal x r1
          (g, r3) = below 100 r2
          (gl, r4) = below 40 r3
          (attach, r5) = below 12 r4
          (sd, r6) = sideEvent r5
          its' = case its of
            -- one event of each kind per cycle: the ports carry one each
            (i : rest) | attach == 0 && isJust (itBus i) && null (itSide i) -> i { itSide = [sd] } : rest
            _ -> its
          withGap = case reverse its' of
            (lastI : rest) -> reverse (lastI { itGap = if g < 70 then 0 else if g < 90 then gl `mod` 4 else gl } : rest)
            [] -> []
      in withGap ++ randomItems (n - length its) r6
  where
    proposal x r
      | x < 450 = fifoWrite r
      | x < 540 = let (s, r1) = pick [S8, S16, S32] r; (a, r2) = readAddr r1 in ([rd s (align s a)], r2)
      | x < 760 = regWrite r
      | x < 960 = let (sd, r1) = sideEvent r in ([side [sd]], r1)
      | otherwise = let (a, r1) = pick resultAddrs r; (v, r2) = word r1 in ([side [SZ a v]], r2)
    fifoWrite r =
      let (k, r1) = below 10 r
      in if k < 5 then let (ws, r2) = packedWords r1 in (map (wr S32 0x04000400) ws, r2)
         else if k < 9 then let (a, r2) = below 0x6C r1; (v, r3) = word r2
                            in ([wr S32 (0x04000440 + fromIntegral a * 4) v], r3)
         else let (s, r2) = pick [S8, S16] r1; (a, r3) = below 0x200 r2; (v, r4) = word r3
              in ([wr s (align s (0x04000400 + fromIntegral a)) v], r4)
    readAddr r =
      let (k, r1) = below 4 r
      in if k <= 1 then pick (0x04000600 : 0x04000602 : 0x04000603 : regAddrs ++ resultAddrs) r1
         else (\(a, r') -> (0x04000320 + fromIntegral a, r')) (below 0x384 r1)
    regWrite r =
      let (k, r1) = below 5 r
          (s, r2) = pick [S8, S16, S32] r1
          (v, r3) = word r2
          (a, r4) = case k of
            0 -> pick regAddrs r3
            1 -> (\(i, r') -> (0x04000330 + fromIntegral i, r')) (below 0x90 r3)
            2 -> pick [0x04000600, 0x04000601, 0x04000602, 0x04000603] r3
            3 -> (\(i, r') -> (0x04000320 + fromIntegral i, r')) (below 0x384 r3)
            _ -> (\(i, r') -> (0x04000060 + fromIntegral i, r')) (below 4 r3)
      in ([wr s (align s a) v], r4)
    sideEvent r =
      let (k, r1) = below 100 r
          (v, r2) = word r1
      in if k < 25 then (SV, r2)
         else if k < 33 then (SE (v .&. 15 /= 0) (v .&. 15 /= 1), r2)
         else if k < 45 then (SX (fromIntegral v) (case (v `shiftR` 16) `mod` 3 of 0 -> 0xFF; 1 -> 0xFF00; _ -> 0xFFFF), r2)
         else if k < 55 then (SF (testBit v 0) (testBit v 1), r2)
         else if k < 85 then
           (SG (GeoStatus (testBit v 0) (testBit v 1) (fromIntegral (v `shiftR` 2) .&. 0x3F) (testBit v 8)
                          (testBit v 9) (testBit v 10) (testBit v 11)), r2)
         else (SQ (fromIntegral v .&. 0x7FF) (fromIntegral (v `shiftR` 16) .&. 0x1FFF), r2)

-- | Directed sequences for the hardware's own sequencing: FIFO full and the
-- stall with every kind of suspended write, the VBlank copy racing table
-- writes, POWCNT1 during the copy and the clear, IRQ modes at the FIFO
-- thresholds.
directedItems :: [Item]
directedItems = concat
  [ [side [SE True True, SReady (Just False)]]
  , [wr S32 a (a * 0x9E3779B9) | a <- [0x04000330, 0x04000334 .. 0x040003BC]]
  , [Item (Just (BusOp S32 0x04000380 0x12345678 True 0)) [SV] 0]
  , [wr S8 0x04000381 0xEE, wr S16 0x04000332 0xBEEF, wr S32 0x04000360 0x01020304, gap 40 (side [SV])]
  , [gap 3 (side [SV]), gap 5 (side [SE True False]), side [SE True True], gap 40 (side [SV])]
  , [side [SV], side [SE True False], side [SE True True], gap 40 (side [SV])]
  , [wr S32 0x04000600 0x40000000]
  , replicate 261 (wr S32 0x04000444 0)
  , [wr S32 0x04000600 0x80000000, rd S32 0x04000600]
  , [side [SReady (Just True)], gap 400 (side [SReady (Just False)])]
  , replicate 258 (wr S32 0x04000454 1)
  , [wr S32 0x04000400 0x15151515, wr S32 0x04000400 0x00121110, wr S32 0x04000400 7, wr S32 0x04000400 8]
  , [wr S32 0x04000400 0x00000034] ++ map (wr S32 0x04000400) [1 .. 32]
  , [rd S16 0x04000602, side [SReady Nothing]]
  , [gap 20 (side [SReady (Just False)])]
  , replicate 256 (wr S32 0x040005C0 3) ++ [wr S32 0x04000448 1, wr S32 0x040005C8 2]
  , [wr S32 0x04000600 0xC0000000, side [SReady (Just True)], gap 600 (side [SReady Nothing])]
  , [side [SE False True], wr S32 0x04000444 9, wr S32 0x04000600 0x40000000, side [SE True True]]
  ]

------------------------------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs
  let (seed, runs, items) = case args of
        [] -> (1 :: Word64, 8 :: Int, 12000 :: Int)
        [s] -> (read s, 8, 12000)
        [s, r] -> (read s, read r, 12000)
        (s : r : n : _) -> (read s, read r, read n)
      scripts =
        ("directed", directedItems, 0)
          : [ ("random-" ++ show k, randomItems items (Rng (seed * 7919 + fromIntegral k)), seed + fromIntegral k)
            | k <- [1 .. runs] ]
  results <- mapM (\(name, its, sd) -> do
                     let d = runOnce its sd
                     putStrLn (name ++ ": " ++ show (dCycle d) ++ " cycles, " ++ show (dWrites d) ++ " writes, "
                               ++ show (dReads d) ++ " reads, " ++ show (dPops d) ++ " pops ("
                               ++ show (dRefills d) ++ " refills), " ++ show (dVbl d) ++ " vblanks, "
                               ++ show (dSides d) ++ " side events; cycles stalled " ++ show (dStallCyc d)
                               ++ ", FIFO full " ++ show (dFullCyc d) ++ ", copying " ++ show (dCopyCyc d)
                               ++ "; " ++ show (dTblChecks d) ++ " table reads; "
                               ++ show (dChecks d) ++ " checks, " ++ show (dNErr d) ++ " mismatches")
                     forM_ (dErrs d) (putStrLn . ("  " ++) . take 400)
                     pure d) scripts
  let total f = sum (map f results)
  putStrLn ("gxfront-hw: " ++ show (length results) ++ " runs, " ++ show (total dCycle) ++ " cycles, "
            ++ show (total dWrites + total dReads) ++ " bus accesses, " ++ show (total dPops) ++ " pops, "
            ++ show (total dChecks) ++ " checks, " ++ show (total dNErr) ++ " mismatches")
  unless (total dNErr == 0) exitFailure
