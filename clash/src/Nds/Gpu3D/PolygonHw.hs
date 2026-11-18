{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The polygon pipeline in hardware: "Nds.Gpu3D.Polygon" as one sequenced
-- datapath behind a 'HwGeoEvent' stream, with polygon and vertex RAM in
-- external memory ("Nds.Gpu3D.PolyRam" layout, one "Nds.Gpu3D.Mem" port).
--
-- = Interface
--
-- Inputs: the event stream (valid = @Just@, transferred when 'poReady' is
-- high), a VBlank pulse, a DISP3DCNT bit-13 acknowledge pulse, and the memory
-- port's ready and read responses. Outputs ('PolyOut'): RAM_COUNT, the
-- overflow flag, a 'poDone' pulse per finished event (with the
-- 'submitTimingHw' values when the event ran @SubmitPolygon@), the memory
-- request, busy, and a 'poSwapped' pulse carrying the 'FrameDesc' of the
-- render list a swapping VBlank produced.
--
-- Sequencing contract: a VBlank or acknowledge pulse is ordered after every
-- event transferred before it. The block latches the pulse, finishes the
-- event in progress, then applies it (a swapping VBlank sorts and swaps
-- before 'poReady' rises again). 'poSwapped' fires only after every memory
-- write of the render list has been accepted. Geometry- and rendering-
-- enable gating of @GPU3D::VBlank@ is the chip top's: it does not pulse
-- VBlank with geometry disabled, and renders an empty list while rendering
-- is disabled.
--
-- = Datapath
--
-- One 33x33 signed multiplier (registered in and out) and one iterative
-- restoring divider (64-bit dividend magnitude, 33-bit divisor magnitude,
-- two quotient bits per cycle, starting at the first possible quotient bit)
-- serve every multiply and divide of the model: the culling normal and dot
-- products, the clip interpolation (all eight attributes, exact for 64-bit
-- factors), the viewport transform and FinalZ.
--
-- On chip: a 32-slot x 16-field x 32-bit vertex pool in block RAM (four
-- temp-buffer slots, two strip-reuse slots holding the last strip polygon's
-- shared vertices, 26 clipper work slots); the clip buffers are two 10-entry
-- pointer arrays into the pool, so copying a vertex is a pointer copy; the
-- six plane-outside bits of every pool slot in registers; two 512 x 12-bit
-- histograms (block RAM) for the VBlank sort.
module Nds.Gpu3D.PolygonHw
  ( -- * Interface
    PolyOut (..)
  , polyPipeStatus
  , SubmitClass (..)
  , submitTimingHw
  , polygonHw
  , polygonTopEntity
    -- * Event encoding (from the geometry hardware)
  , HwGeoEvent (..)
  , HwVertex (..)
  , HwPolyState (..)
  , toHwEvent
  , fromHwEvent
    -- * The divider (exported for its unit check)
  , DivSt
  , initDiv
  , divStart
  , divAdvance
  , divIdle
  , divResult
  ) where

import Prelude

import Data.Bits (bit, complement, shiftL, shiftR, testBit, (.&.), (.|.))
import Data.Maybe (isJust, isNothing)
import GHC.Generics (Generic)

import Clash.Annotations.TopEntity (PortName (..), TopEntity (..))
import Clash.Explicit.Prelude
  ( BitVector, Bit, Clock, Enable, Index, KnownDomain, NFDataX, Reset, SNat (..)
  , Signal, Signed, System, Unsigned, Vec (..), blockRam, pack, register
  , resize, unbundle, unpack, (++#) )
import qualified Clash.Explicit.Prelude as C

import Nds.Gpu3D.GeometryHw.Event
  ( HwGeoEvent (..), HwPolyState (..), HwVertex (..), fromHwEvent, toHwEvent )
import Nds.Gpu3D.Mem (MemAddr, MemReq (..))
import Nds.Gpu3D.PolyRam
import Nds.Gpu3D.Types (PipeStatus (..))

------------------------------------------------------------------------------
-- Interface types

-- | What @SubmitPolygon@ did, as far as the geometry engine's timing cares.
data SubmitClass = SubBuilt4 | SubBuiltOther | SubRejected
  deriving (Eq, Show, Generic, NFDataX)

-- | 'Nds.Gpu3D.Polygon.submitTiming': @PolygonPipeline@ and
-- @VertexSlotsFree@ after @SubmitPolygon@, from the polygon mode.
submitTimingHw :: Unsigned 2 -> SubmitClass -> (Unsigned 6, BitVector 5)
submitTimingHw mode c = case c of
  SubBuilt4 -> (35, if strip then 0x1C else 0x1E)
  SubBuiltOther -> (26, if strip then 0x08 else 0x0E)
  SubRejected -> (8, 0x1E)
  where
    strip = testBit mode 1

data PolyOut = PolyOut
  { poReady    :: !Bool                -- ^ an event is taken this cycle if valid
  , poMem      :: !(Maybe MemReq)      -- ^ memory request (held until ready)
  , poPolygons :: !(Unsigned 12)       -- ^ RAM_COUNT polygons
  , poVertices :: !(Unsigned 13)       -- ^ RAM_COUNT vertices
  , poOverflow :: !Bool                -- ^ DISP3DCNT bit 13
  , poDone     :: !Bool                -- ^ an event finished this cycle
  , poTiming   :: !(Maybe (Unsigned 6, BitVector 5))
    -- ^ with 'poDone': the event ran @SubmitPolygon@ ('submitTimingHw')
  , poSwapped  :: !(Maybe FrameDesc)   -- ^ a VBlank swapped the banks
  , poBusy     :: !Bool
  } deriving (Eq, Show, Generic, NFDataX)

polyPipeStatus :: PolyOut -> PipeStatus
polyPipeStatus o = PipeStatus (fromIntegral (poPolygons o)) (fromIntegral (poVertices o))

------------------------------------------------------------------------------
-- Divider

-- | Restoring division of a 64-bit magnitude by a 33-bit magnitude,
-- truncating, low 32 quotient bits, negated on request. The run starts at
-- the highest quotient bit that can be set and retires two quotient bits a
-- cycle (two chained 34-bit subtract stages), so it takes
-- @ceil ((max 0 (bits n - bits d) + 1) / 2)@ cycles after a one-cycle setup.
data DivSt = DivSt
  { dvSetup :: !Bool
  , dvRun   :: !Bool
  , dvN     :: !(Unsigned 64)
  , dvD     :: !(Unsigned 33)
  , dvNeg   :: !Bool
  , dvR     :: !(Unsigned 34)
  , dvM     :: !(Unsigned 64)
  , dvQ     :: !(Unsigned 32)
  , dvCnt   :: !(Unsigned 7)
  } deriving (Eq, Show, Generic, NFDataX)

initDiv :: DivSt
initDiv = DivSt False False 0 0 False 0 0 0 0

divStart :: Unsigned 64 -> Unsigned 33 -> Bool -> DivSt -> DivSt
divStart n d neg st = st { dvSetup = True, dvRun = False, dvN = n, dvD = d, dvNeg = neg }

divIdle :: DivSt -> Bool
divIdle st = not (dvSetup st) && not (dvRun st)

-- | The result (valid while idle after a run).
divResult :: DivSt -> BitVector 32
divResult st = pack (if dvNeg st then negate (dvQ st) else dvQ st)

clz64 :: Unsigned 64 -> Unsigned 7
clz64 v = maybe 64 fromIntegral (C.findIndex (== 1) (C.bv2v (pack v)))

clz33 :: Unsigned 33 -> Unsigned 7
clz33 v = maybe 33 fromIntegral (C.findIndex (== 1) (C.bv2v (pack v)))

divAdvance :: DivSt -> DivSt
divAdvance st
  | dvSetup st =
      let ln = 64 - clz64 (dvN st)
          ld = 33 - clz33 (dvD st)
      in if ln < ld
           then st { dvSetup = False, dvRun = False, dvQ = 0 }
           else
             let s = ln - ld
                 x = (resize (dvN st) :: Unsigned 128) `shiftL` fromIntegral (63 - s)
             in st { dvSetup = False, dvRun = True
                   , dvR = resize (x `shiftR` 64), dvM = resize x, dvQ = 0, dvCnt = s + 1 }
  | dvRun st =
      let d = resize (dvD st) :: Unsigned 34
          stage (r, m, qq) =
            let r1 = (r `shiftL` 1) .|. (if testBit m 63 then 1 else 0)
                ge = r1 >= d
            in (if ge then r1 - d else r1, m `shiftL` 1, (qq `shiftL` 1) .|. (if ge then 1 else 0))
          one = stage (dvR st, dvM st, dvQ st)
          two = dvCnt st >= 2
          (r', m', q') = if two then stage one else one
          c = dvCnt st - (if two then 2 else 1)
      in st { dvR = r', dvM = m', dvQ = q', dvCnt = c, dvRun = c /= 0 }
  | otherwise = st

------------------------------------------------------------------------------
-- State

type Slot = Unsigned 5
type Field = Unsigned 4

-- Pool slots: 0-3 temp buffer, 4-5 strip-reuse vertices, 6-31 clipper work.
-- Fields: 0 X, 1 Y, 2 Z, 3 W (masked in the reuse slots), 4 R, 5 G, 6 B,
-- 7 S | T << 16, 8 W & 0xFFFFFF after the viewport, 9 FX | FY << 16.
slotR0, slotR1 :: Slot
slotR0 = 4
slotR1 = 5

workMask :: BitVector 32
workMask = 0xFFFFFFC0

data Phase
  = PInitClr
  | PIdle
  | PVtx
  | PAsm
  | PCullRd
  | PCullMul
  | PCullShrink
  | PCullDot
  | PType
  | PPass
  | PLive
  | PPassVtx
  | PSide
  | PIsFac
  | PIsAttr
  | PIsFin
  | PPassEnd
  | PPlaneEnd
  | PFix
  | PClipDone
  | PVp
  | PDot1
  | PBuild
  | PBounds
  | PStore
  | PHeader
  | PHist
  | PCopy
  | PFinish
  | PReject
  | PSubmitEnd
  | PVblPre
  | PVblA
  | PVblB
  | PVblClr
  | PVblDone
  deriving (Eq, Show, Generic, NFDataX)

data St = St
  { sPhase     :: !Phase
  , sJ         :: !(Unsigned 10)         -- sub-step / table counter
  , sK         :: !(Unsigned 4)          -- vertex loop
  , sI         :: !(Unsigned 12)         -- sort loop
    -- assembly
  , sMode      :: !(Unsigned 2)          -- PolygonMode
  , sVtxIn     :: !(Unsigned 3)          -- VertexNumInPoly
  , sOdd       :: !Bool                  -- NumConsecutivePolygons & 1
  , sPerm      :: !(Vec 4 (Unsigned 2))  -- TempVertexBuffer slot -> pool slot
  , sPost      :: !(Unsigned 2)          -- strip shuffle after SubmitPolygon
  , sReuse     :: !Bool                  -- stripReuse would succeed now
  , sReuseRef  :: !(Vec 2 (Unsigned 14)) -- its vertex RAM indices
    -- banks
  , sBank      :: !Bit
  , sNumV      :: !(Unsigned 13)
  , sNumP      :: !(Unsigned 12)
  , sNumO      :: !(Unsigned 12)
  , sFlush     :: !Bool
  , sFlushAttr :: !(BitVector 2)
  , sOverflow  :: !Bool
  , sVblPend   :: !Bool
  , sAckPend   :: !Bool
    -- event
  , sVtx       :: !HwVertex
  , sPs        :: !HwPolyState
  , sSlot      :: !Slot
    -- polygon
  , sN0        :: !(Unsigned 4)
  , sBufs      :: !(Vec 2 (Vec 10 Slot))
  , sCur       :: !Bit
  , sN         :: !(Unsigned 4)
  , sC         :: !(Unsigned 4)
  , sPi        :: !(Unsigned 4)
  , sSide      :: !Bit
  , sVin       :: !Slot
  , sVout      :: !Slot
  , sAt        :: !(Unsigned 3)
  , sFlags     :: !(Vec 32 (BitVector 6))
  , sFree      :: !(BitVector 32)
  , sDirty     :: !(BitVector 32)
  , sComp      :: !(Unsigned 2)
  , sHalf      :: !Bit
  , sR         :: !(Vec 10 (BitVector 32))
  , sAcc       :: !(Vec 3 (Signed 64))
  , sDot       :: !(Signed 64)
  , sNum       :: !(Signed 33)
  , sDen       :: !(Signed 34)
  , sEq        :: !(Vec 3 Bool)
  , sType      :: !Bool
  , sOk        :: !Bool
  , sRes       :: !(Vec 10 Slot)
  , sByIdx     :: !Bool
  , sCopy      :: !Bool
  , sNv1       :: !(Unsigned 13)
  , sVTop      :: !(Unsigned 4)
  , sVBot      :: !(Unsigned 4)
  , sYTop      :: !(Unsigned 8)
  , sYBot      :: !(Unsigned 8)
  , sXTop      :: !(Unsigned 9)
  , sXBot      :: !(Unsigned 9)
  , sZeroW     :: !Bool
  , sWSize     :: !(Unsigned 3)          -- polygon W width in nibbles
  , sZDiv      :: !Bool
  , sClass     :: !SubmitClass
    -- datapath
  , sMulA      :: !(Signed 33)
  , sMulB      :: !(Signed 33)
  , sMulP      :: !(Signed 66)
  , sDiv       :: !DivSt
    -- memory and sort
  , sMem       :: !(Maybe MemReq)
  , sW         :: !(BitVector 64)
  , sSum       :: !(Vec 2 (Unsigned 12))
    -- pulses
  , sDone      :: !Bool
  , sTiming    :: !(Maybe (Unsigned 6, BitVector 5))
  , sSwapped   :: !(Maybe FrameDesc)
  } deriving (Eq, Show, Generic, NFDataX)

initSt :: St
initSt = St
  { sPhase = PInitClr, sJ = 0, sK = 0, sI = 0
  , sMode = 0, sVtxIn = 0, sOdd = False, sPerm = 0 :> 1 :> 2 :> 3 :> Nil, sPost = 0
  , sReuse = False, sReuseRef = C.repeat 0
  , sBank = 0, sNumV = 0, sNumP = 0, sNumO = 0, sFlush = False, sFlushAttr = 0
  , sOverflow = False, sVblPend = False, sAckPend = False
  , sVtx = HwVertex 0 0 0 0 0 0 0 0 0
  , sPs = HwPolyState 0 0 0 0 0 0 0 0 0 0
  , sSlot = 0
  , sN0 = 0, sBufs = C.repeat (C.repeat 0), sCur = 0, sN = 0, sC = 0, sPi = 0, sSide = 0
  , sVin = 0, sVout = 0, sAt = 0, sFlags = C.repeat 0, sFree = 0, sDirty = 0
  , sComp = 0, sHalf = 0, sR = C.repeat 0, sAcc = C.repeat 0, sDot = 0, sNum = 0, sDen = 0
  , sEq = C.repeat True, sType = False, sOk = False, sRes = C.repeat 0
  , sByIdx = False, sCopy = False, sNv1 = 0
  , sVTop = 0, sVBot = 0, sYTop = 0, sYBot = 0, sXTop = 0, sXBot = 0, sZeroW = False
  , sWSize = 0, sZDiv = False, sClass = SubRejected
  , sMulA = 0, sMulB = 0, sMulP = 0, sDiv = initDiv
  , sMem = Nothing, sW = 0, sSum = C.repeat 0
  , sDone = False, sTiming = Nothing, sSwapped = Nothing
  }

-- | Block RAM ports driven by one step.
data Ports = Ports
  { oPoolRd :: !(Unsigned 9)
  , oPoolWr :: !(Maybe (Unsigned 9, BitVector 32))
  , oHaRd   :: !(Unsigned 9)
  , oHbRd   :: !(Unsigned 9)
  , oHaWr   :: !(Maybe (Unsigned 9, Unsigned 12))
  , oHbWr   :: !(Maybe (Unsigned 9, Unsigned 12))
  }

noPorts :: Ports
noPorts = Ports 0 Nothing 0 0 Nothing Nothing

data PolyIn = PolyIn
  { piEvent    :: !(Maybe HwGeoEvent)
  , piVBlank   :: !Bool
  , piAck      :: !Bool
  , piMemReady :: !Bool
  , piMemResp  :: !(Maybe (BitVector 64))
  , piPoolQ    :: !(BitVector 32)
  , piHaQ      :: !(Unsigned 12)
  , piHbQ      :: !(Unsigned 12)
  }

------------------------------------------------------------------------------
-- Arithmetic helpers (the model's, at hardware widths)

poolA :: Slot -> Field -> Unsigned 9
poolA s f = unpack (pack s ++# pack f)

s32 :: BitVector 32 -> Signed 32
s32 = unpack

-- | The six outside bits of a vertex: bit @2*comp@ is @comp > W@, bit
-- @2*comp+1@ is @comp < -W@ (the negation wrapping).
planeFlags :: BitVector 32 -> BitVector 32 -> BitVector 32 -> BitVector 32 -> BitVector 6
planeFlags x y z w =
  pack (lt z, gt z, lt y, gt y, lt x, gt x)
  where
    sw = s32 w
    nw = negate sw
    gt c = s32 c > sw
    lt c = s32 c < nw

outsideBit :: BitVector 6 -> Unsigned 2 -> Bit -> Bool
outsideBit f comp half = testBit f (2 * fromIntegral comp + fromIntegral half)

-- | The colour fix-up at the end of a clip plane.
fixColour :: BitVector 32 -> BitVector 32
fixColour c = (c .&. complement 0xFFF) + 0xFFF

-- | @(c << 12) + 0xFFF@ of a 5-bit vertex colour.
clipColour :: Unsigned 5 -> BitVector 32
clipColour c = (resize (pack c) `shiftL` 12) + 0xFFF

-- | @Color >> 12@ as the 20-bit code vertex RAM stores.
colourCode :: BitVector 32 -> BitVector 20
colourCode c = resize (pack (s32 c `shiftR` 12))

-- | @normalizedWSize@ of a 24-bit W, in nibbles (0..6).
wSizeOf :: BitVector 32 -> Unsigned 3
wSizeOf w
  | w24 == 0 = 0
  | otherwise = resize ((bw + 3) `shiftR` 2)
  where
    w24 = resize w :: BitVector 24
    lz = maybe 24 fromIntegral (C.findIndex (== 1) (C.bv2v w24)) :: Unsigned 5
    bw = 24 - lz

-- | The Z-buffer FinalZ from the 32-bit @divideZ@ quotient.
finalZOf :: BitVector 32 -> Unsigned 24
finalZOf q
  | v < 0 = 0
  | v > 0xFFFFFF = 0xFFFFFF
  | otherwise = unpack (resize (pack v))
  where
    v = (s32 q + 0x3FFF) `shiftL` 9

sext33 :: BitVector 32 -> Signed 33
sext33 = resize . s32

sext16to32 :: BitVector 16 -> BitVector 32
sext16to32 h = pack (resize (unpack h :: Signed 16) :: Signed 32)

absU64 :: Signed 66 -> Unsigned 64
absU64 p = unpack (resize (pack (abs p)))

lowestSet :: BitVector 32 -> Slot
lowestSet v = maybe 0 fromIntegral (C.findIndex (== 1) (C.reverse (C.bv2v v)))

------------------------------------------------------------------------------
-- The step

publicOut :: St -> PolyOut
publicOut s = PolyOut
  { poReady = sPhase s == PIdle && not (sVblPend s) && not (sAckPend s)
  , poMem = sMem s
  , poPolygons = sNumP s
  , poVertices = sNumV s
  , poOverflow = sOverflow s
  , poDone = sDone s
  , poTiming = sTiming s
  , poSwapped = sSwapped s
  , poBusy = sPhase s /= PIdle || sVblPend s || sAckPend s
  }

step :: MemAddr -> St -> PolyIn -> (St, (PolyOut, Ports))
step base s inp = (st', (publicOut s, ports))
  where
    memTx = isJust (sMem s) && piMemReady inp
    memFree = isNothing (sMem s) || piMemReady inp
    s0 = s
      { sVblPend = sVblPend s || piVBlank inp
      , sAckPend = sAckPend s || piAck inp
      , sMem = if memTx then Nothing else sMem s
      , sMulP = resize (sMulA s) * resize (sMulB s)
      , sDiv = divAdvance (sDiv s)
      , sDone = False, sTiming = Nothing, sSwapped = Nothing
      }
    (st', ports) = phaseStep base s inp memFree s0

phaseStep :: MemAddr -> St -> PolyIn -> Bool -> St -> (St, Ports)
phaseStep base s inp memFree s0 = case sPhase s of
  ------------------------------------------------------------------ reset
  PInitClr ->
    ( s0 { sJ = j + 1, sPhase = if j == 511 then PIdle else PInitClr }
    , noPorts { oHaWr = Just (resize j, 0), oHbWr = Just (resize j, 0) } )

  ------------------------------------------------------------------ idle
  PIdle
    | sVblPend s ->
        let s1 = s0 { sVblPend = piVBlank inp }
        in if sFlush s
             then (if sNumP s == 0 then go s1 PVblDone else (s1 { sPhase = PVblPre, sJ = 0, sSum = C.repeat 0 }, noPorts))
             else (s1, noPorts)
    | sAckPend s -> (s0 { sOverflow = False, sAckPend = piAck inp }, noPorts)
    | Just ev <- piEvent inp -> accept ev
    | otherwise -> (s0, noPorts)

  PVtx ->
    let v = sVtx s
        val = case j of
          0 -> pack (hvX v)
          1 -> pack (hvY v)
          2 -> pack (hvZ v)
          3 -> pack (hvW v)
          4 -> clipColour (hvR v)
          5 -> clipColour (hvG v)
          6 -> clipColour (hvB v)
          _ -> pack (hvT v) ++# pack (hvS v)
    in ( s0 { sJ = j + 1, sPhase = if j == 7 then PAsm else PVtx }
       , wr (sSlot s) (resize j) val )

  PAsm ->
    let n = sVtxIn s
        m = sMode s
        perm = sPerm s
        submit st = (st { sPhase = PCullRd, sJ = 0, sN0 = if testBit m 0 then 4 else 3 }, noPorts)
    in if m == 0 && n == 3 then submit s0 { sVtxIn = 0, sPost = 0 }
       else if m == 1 && n == 4 then submit s0 { sVtxIn = 0, sPost = 0 }
       else if m == 2 && sOdd s then submit s0 { sPerm = swapP 0 1 perm, sVtxIn = 2, sPost = 1 }
       else if m == 2 && n == 3 then submit s0 { sVtxIn = 2, sPost = 2 }
       else if m == 3 && n == 4 then submit s0 { sPerm = swapP 2 3 perm, sVtxIn = 2, sPost = 3 }
       else (s0 { sPhase = PIdle, sDone = True }, noPorts)

  ------------------------------------------------------------------ culling
  PCullRd ->
    let vtx = if j < 3 then 1 else if j < 6 then 0 else 2 :: Index 4
        fieldOf = case j `mod` 3 of { 0 -> 0; 1 -> 1; _ -> 3 }
        idx = j - 1
        rf = sR s
        val = if idx < 3 then q else q - rf C.!! (idx `mod` 3)
        s1 = if j >= 1 then s0 { sR = C.replace idx val rf } else s0
    in ( s1 { sJ = if j == 9 then 0 else j + 1, sPhase = if j == 9 then PCullMul else PCullRd }
       , if j < 9 then rd (tslot vtx) fieldOf else noPorts )

  PCullMul ->
    let rf = sR s
        (ia, ib) = case j of
          0 -> (4, 8)
          1 -> (5, 7)
          2 -> (5, 6)
          3 -> (3, 8)
          4 -> (3, 7)
          _ -> (4, 6) :: (Index 10, Index 10)
        s1 = if j < 6 then s0 { sMulA = sext33 (rf C.!! ia), sMulB = sext33 (rf C.!! ib) } else s0
        m = j - 2
        p = resize (sMulP s) :: Signed 64
        a = sAcc s
        k = m `shiftR` 1
        s2 = if j >= 2
               then s1 { sAcc = C.replace k (if even m then p else (a C.!! k) - p) a }
               else s1
    in (s2 { sJ = j + 1, sPhase = if j == 7 then PCullShrink else PCullMul }, noPorts)

  PCullShrink ->
    let fits a = let hi = a `shiftR` 31 in hi == 0 || hi == -1
        a = sAcc s
    in if C.and (C.map fits a)
         then go s0 { sJ = 0 } PCullDot
         else (s0 { sAcc = C.map (`shiftR` 4) a }, noPorts)

  PCullDot ->
    let rf = sR s
        jj = j
        s1 = if j < 3 then s0 { sMulA = sext33 (rf C.!! jj), sMulB = resize (sAcc s C.!! jj) } else s0
        p = resize (sMulP s) :: Signed 64
        d = if j == 2 then p else sDot s + p
        attr = hpAttr (sPs s)
        reject = (d < 0 && not (testBit attr 7)) || (d > 0 && not (testBit attr 6))
        cs = sReuse s
        b0 = (if cs then slotR0 else tslot 0) :> (if cs then slotR1 else tslot 1)
             :> tslot 2 :> tslot 3 :> C.repeat 0
        setup = s1 { sDot = d, sBufs = C.replace (0 :: Index 2) b0 (sBufs s), sCur = 0, sN = sN0 s
                   , sComp = 2, sHalf = 0, sDirty = 0, sEq = C.repeat True, sType = False, sJ = 0 }
    in if j < 4 then (s1 { sDot = if j >= 2 then d else sDot s, sJ = j + 1 }, noPorts)
       else if reject then go s1 PReject
       else go setup (if sN0 s == 3 then PType else PPass)

  PType ->
    let b = sBufs s C.!! (0 :: Index 2)
        k = j `mod` 3
        idx = (j - 1) `mod` 3
        rf = sR s
        e = sEq s
        e' | idx == 2 = (e C.!! (0 :: Index 3) && rf C.!! (0 :: Index 10) == rf C.!! (1 :: Index 10))
                        :> (e C.!! (1 :: Index 3) && rf C.!! (0 :: Index 10) == q)
                        :> (e C.!! (2 :: Index 3) && rf C.!! (1 :: Index 10) == q) :> Nil
           | otherwise = e
        s1 = if j >= 1 then s0 { sR = C.replace idx q rf, sEq = e' } else s0
    in if j == 12
         then go s1 { sType = C.or e' } PPass
         else (s1 { sJ = j + 1 }, rd (b C.!! k) (resize (j `div` 3)))

  ------------------------------------------------------------------ clipping
  PPass ->
    let n = sN s
        anyOut = C.or (C.imap (\ix sl -> let k = fromIntegral ix in k >= cs && k < n && outside sl) inB)
        out0 = C.replace (1 :: Index 10) (inB C.!! (1 :: Index 10))
                 (C.replace (0 :: Index 10) (inB C.!! (0 :: Index 10)) outB)
    in if n < cs then go s0 { sN = cs } PPassEnd
       else if not anyOut then go s0 PPassEnd
       else if sHalf s == 0 && sComp s == 2 && not (testBit (hpAttr (sPs s)) 12)
         then go s0 { sN = 0 } PPlaneEnd
       else go (setOut out0 s0) { sFree = workMask, sPi = 0, sC = cs } PLive

  -- Work slots referenced by the input buffer are live: they are removed
  -- from the free mask one buffer entry per cycle.
  PLive ->
    let i = sPi s
    in if i >= sN s then go s0 { sPi = cs } PPassVtx
       else (s0 { sFree = sFree s .&. complement (bit (fromIntegral (inB C.!! i))), sPi = i + 1 }, noPorts)

  PPassVtx ->
    let i = sPi s
        v = inB C.!! i
        c = sC s
    in if i >= sN s then go s0 { sN = c, sCur = complement (sCur s) } PPassEnd
       else if outside v then go s0 { sSide = 0 } PSide
       else if c < 10 then (setOut (C.replace c v outB) s0 { sC = c + 1, sPi = i + 1 }, noPorts)
       else (s0 { sPi = i + 1 }, noPorts)

  PSide ->
    let i = sPi s
        n = sN s
        nbIdx = if sSide s == 0 then (if i == 0 then n - 1 else i - 1)
                else (if i + 1 >= n then 0 else i + 1)
        nb = inB C.!! nbIdx
        slot = lowestSet (sFree s)
    in if not (outside nb) && sC s < 10
         then go s0 { sSlot = slot, sFree = sFree s .&. complement (bit (fromIntegral slot))
                    , sVin = inB C.!! i, sVout = nb, sJ = 0 } PIsFac
         else (nextSide s0, noPorts)

  PIsFac ->
    let comp = resize (sComp s) :: Field
        rf = sR s
        (sl, f) = case j of
          0 -> (sVin s, comp)
          1 -> (sVin s, 3)
          2 -> (sVout s, comp)
          _ -> (sVout s, 3)
        s1 = if j >= 1 then s0 { sR = C.replace (j - 1) q rf } else s0
        cIn = rf C.!! (0 :: Index 10)
        wIn = rf C.!! (1 :: Index 10)
        cOut = rf C.!! (2 :: Index 10)
        wOut = q
        plus = sHalf s == 0
        dist c w = if plus then w - c else w + c
        dIn = dist cIn wIn
        dOut = dist cOut wOut
        legacyDen = dIn - dOut
        wide c w = if plus then sext33 w - sext33 c else sext33 w + sext33 c
        wideIn = wide cIn wIn
        wideOut = wide cOut wOut
        (num, den)
          | legacyDen /= 0 = (sext33 dIn, resize (s32 legacyDen))
          | otherwise = (wideIn, resize wideIn - resize wideOut)
    in if j == 4
         then go s1 { sNum = num, sDen = den, sAt = 0, sJ = 0 } PIsAttr
         else (s1 { sJ = j + 1 }, rd sl f)

  -- Eight attributes, each @vin + (vout - vin) * num / den@. The next
  -- attribute's two pool reads and its multiply run while the divider works
  -- on the current one (sR 4 holds the current vin value, sR 9 the next).
  PIsAttr ->
    let at' = sAt s
        comp = sComp s
        f = attrField comp at'
        fN = attrField comp (at' + 1)
        rf = sR s
        r4 = rf C.!! (4 :: Index 10)
        r9 = rf C.!! (9 :: Index 10)
        ab k va vb
          | k == 6 = (sext16to32 (resize va), sext16to32 (resize vb))
          | k == 7 = (sext16to32 (resize (va `shiftR` 16)), sext16to32 (resize (vb `shiftR` 16)))
          | otherwise = (va, vb)
        p = sMulP s
        res = r4 + dq
        sl = sSlot s
        half1 = sHalf s == 1
        startDiv st = st { sDiv = divStart (absU64 p) (unpack (resize (pack (abs (sDen s)))))
                                            ((p < 0) /= (sDen s < 0)) (sDiv s) }
        -- the current attribute is done: store it, move on
        finishAttr st0 = case at' of
          7 -> (st0 { sPhase = PIsFin }, wr sl 7 ((resize res :: BitVector 16) ++# (resize (rf C.!! (8 :: Index 10)) :: BitVector 16)))
          _ ->
            let st1 = st0 { sAt = at' + 1, sJ = 4, sR = C.replace (4 :: Index 10) r9 (sR st0) }
            in case at' of
                 0 -> (st1 { sR = C.replace (5 :: Index 10) res (sR st1) }, wr sl 3 res)
                 1 -> (st1 { sR = C.replace (6 :: Index 10) res (sR st1) }, wr sl f res)
                 2 -> (st1 { sR = C.replace (7 :: Index 10) res (sR st1) }, wr sl f res)
                 6 -> (st1 { sR = C.replace (8 :: Index 10) res (sR st1) }, noPorts)
                 _ -> (st1, wr sl f (if half1 then fixColour res else res))
    in case j of
         0 -> (s0 { sJ = 1 }, rd (sVin s) f)
         1 -> (s0 { sJ = 2, sR = C.replace (4 :: Index 10) q rf }, rd (sVout s) f)
         2 -> let (a, b) = ab at' r4 q
              in (s0 { sJ = 3, sR = C.replace (4 :: Index 10) a rf
                     , sMulA = sext33 b - sext33 a, sMulB = sNum s }, noPorts)
         3 -> (s0 { sJ = 4 }, noPorts)
         4 | at' == 7 -> (startDiv s0 { sJ = 8 }, noPorts)
           | otherwise -> (startDiv s0 { sJ = 5 }, rd (sVin s) fN)
         5 -> (s0 { sJ = 6, sR = C.replace (9 :: Index 10) q rf }, rd (sVout s) fN)
         6 -> let (a, b) = ab (at' + 1) r9 q
              in (s0 { sJ = 7, sR = C.replace (9 :: Index 10) a rf
                     , sMulA = sext33 b - sext33 a, sMulB = sNum s }, noPorts)
         7 -> (s0 { sJ = 8 }, noPorts)
         _ | not (divIdle (sDiv s)) -> (s0, noPorts)
           | otherwise -> finishAttr s0

  PIsFin ->
    let sl = sSlot s
        c = sC s
        s1 = setOut (C.replace c sl outB) s0
               { sFlags = C.replace sl sharedFlags (sFlags s)
               , sDirty = if sHalf s == 0 then sDirty s .|. bit (fromIntegral sl) else sDirty s
               , sC = c + 1 }
    in (nextSide s1, wr sl (resize (sComp s)) finCv)

  PPassEnd ->
    if sHalf s == 0 then go s0 { sHalf = 1 } PPass else go s0 PPlaneEnd

  PPlaneEnd ->
    if sDirty s == 0 then nextPlane s0 else go s0 { sPi = 0, sJ = 0 } PFix

  PFix ->
    let i = sPi s
        p = curB C.!! i
        dirty = testBit (sDirty s) (fromIntegral p)
    in if i >= sN s then nextPlane s0 { sDirty = 0 }
       else case j of
         0 | not dirty -> (s0 { sPi = i + 1 }, noPorts)
           | otherwise -> (s0 { sJ = 1 }, rd p 4)
         1 -> (s0 { sJ = 2 }, (rd p 5) `withWr` wrP p 4 (fixColour q))
         2 -> (s0 { sJ = 3 }, (rd p 6) `withWr` wrP p 5 (fixColour q))
         _ -> (s0 { sJ = 0, sPi = i + 1 }, wr p 6 (fixColour q))

  PClipDone ->
    let n = sN s
    in if n == 0 then go s0 PReject
       else if sNumP s >= 2048 || sNumV s + resize n > 6144 then go s0 { sOverflow = True } PReject
       else go s0 { sK = cs, sJ = 0 } PVp

  ------------------------------------------------------------------ viewport
  PVp ->
    let k = sK s
        p = curB C.!! k
        rf = sR s
        ps = sPs s
        w = q .&. 0xFFFFFF
        px0 = rf C.!! (0 :: Index 10) + w
        py0 = negate (rf C.!! (1 :: Index 10)) + w
        (px, py, d)
          | w > 0xFFFF = (px0 `shiftR` 1, py0 `shiftR` 1, w `shiftR` 1)
          | otherwise = (px0, py0, w)
        den = d `shiftL` 1
        lo32 :: Signed 66 -> Unsigned 64
        lo32 x = resize (unpack (resize (pack x)) :: Unsigned 32)
        denU = unpack (resize (rf C.!! (5 :: Index 10))) :: Unsigned 33
        nextK st = st { sK = k + 1, sJ = 0 }
    in if k >= sN s then go s0 { sK = 0, sJ = 0, sOk = True } PDot1
       else case j of
         0 -> (s0 { sJ = 1 }, rd p 0)
         1 -> (s0 { sJ = 2, sR = C.replace (0 :: Index 10) q rf }, rd p 1)
         2 -> (s0 { sJ = 3, sR = C.replace (1 :: Index 10) q rf }, rd p 3)
         3 | w == 0 -> (s0 { sJ = 9 }, wr p 8 0)
           | otherwise ->
               ( s0 { sJ = 4
                    , sR = C.replace (3 :: Index 10) px (C.replace (4 :: Index 10) py (C.replace (5 :: Index 10) den rf))
                    , sMulA = unpack (resize (pack px)) `asTypeOf` sMulA s
                    , sMulB = resize (unpack (resize (pack (hpVpW ps)) :: BitVector 10) :: Signed 10) }
               , wr p 8 w )
         4 -> (s0 { sJ = 5 }, noPorts)
         5 -> ( s0 { sJ = 6
                   , sDiv = divStart (lo32 (sMulP s)) denU False (sDiv s)
                   , sMulA = unpack (resize (pack (rf C.!! (4 :: Index 10))))
                   , sMulB = resize (unpack (resize (pack (hpVpH ps)) :: BitVector 9) :: Signed 9) }
              , noPorts )
         6 | not (divIdle (sDiv s)) -> (s0, noPorts)
           | otherwise ->
               ( s0 { sJ = 7
                    , sR = C.replace (6 :: Index 10) ((dq + resize (pack (hpVpX0 ps))) .&. 0x1FF) rf
                    , sDiv = divStart (lo32 (sMulP s)) denU False (sDiv s) }
               , noPorts )
         7 | not (divIdle (sDiv s)) -> (s0, noPorts)
           | otherwise ->
               let fy = (dq + resize (pack (hpVpY1 ps))) .&. 0xFF
               in (nextK s0, wr p 9 (rf C.!! (6 :: Index 10) .|. (fy `shiftL` 16)))
         _ -> (nextK s0, wr p 9 0)

  PDot1 ->
    let k = sK s
        p = curB C.!! k
        rf = sR s
        zdw = resize (pack (hpZeroDotW (sPs s))) :: BitVector 32
    in if testBit (hpAttr (sPs s)) 13 then go s0 PBuild
       else if k >= sN s then go s0 (if sOk s then PReject else PBuild)
       else case j of
         0 -> (s0 { sJ = 1 }, rd p 9)
         1 -> ( s0 { sJ = 2, sR = C.replace (0 :: Index 10) q
                                 (if k == 0 then C.replace (9 :: Index 10) q rf else rf) }
              , rd p 8 )
         _ -> ( s0 { sJ = 0, sK = k + 1
                   , sOk = sOk s && rf C.!! (0 :: Index 10) == rf C.!! (9 :: Index 10) && q > zdw }
              , noPorts )

  ------------------------------------------------------------------ build
  PBuild ->
    let n = sN s
        lpv = if sMode s == 2 then 3 else 4
        byIdx = sReuse s && n == lpv
        copy = sReuse s && not byIdx
        nNew = resize (n - cs) :: Unsigned 13
        numV = sNumV s
        nv1 = numV + (if copy then 2 else 0)
        resolve ix sl =
          let k = fromIntegral ix :: Unsigned 4
              r = sReuseRef s C.!! k
              inCur = r >= vbase && r < vbase + 6144
              rel = resize (r - vbase) :: Unsigned 13
              hit = inCur && rel >= numV && rel < numV + nNew
          in if k < cs && byIdx && hit then curB C.!! (cs + resize (rel - numV)) else sl
    in go s0 { sRes = C.imap resolve curB, sByIdx = byIdx, sCopy = copy, sNv1 = nv1
             , sVTop = 0, sVBot = 0, sYTop = 192, sYBot = 0, sXTop = 256, sXBot = 0
             , sZeroW = False, sWSize = 0, sK = 0, sJ = 0 } PBounds

  PBounds ->
    let k = sK s
        p = sRes s C.!! k
        rf = sR s
        fxy = rf C.!! (0 :: Index 10)
        fx = unpack (resize fxy) :: Unsigned 9
        fy = unpack (resize (fxy `shiftR` 16)) :: Unsigned 8
        topHit = resize fy < (resize (sYTop s) :: Unsigned 9)
        xt = if topHit then fx else sXTop s
        yt = if topHit then fy else sYTop s
        vt = if topHit then k else sVTop s
        botHit = fy > sYBot s || (fy == sYBot s && fx > sXBot s)
        ws = wSizeOf q
    in if k >= sN s then go s0 { sK = 0, sJ = 0 } PStore
       else case j of
         0 -> (s0 { sJ = 1 }, rd p 9)
         1 -> (s0 { sJ = 2, sR = C.replace (0 :: Index 10) q rf }, rd p 8)
         _ -> ( s0 { sJ = 0, sK = k + 1, sXTop = xt, sYTop = yt, sVTop = vt
                   , sXBot = if botHit then fx else sXBot s
                   , sYBot = if botHit then fy else sYBot s
                   , sVBot = if botHit then k else sVBot s
                   , sZeroW = sZeroW s || resize q == (0 :: BitVector 24)
                   , sWSize = max (sWSize s) ws }
              , noPorts )

  PStore ->
    let k = sK s
        p = sRes s C.!! k
        rf = sR s
        ws = sWSize s
        pw = q
        (fw, wsh)
          | ws < 4 = let sh = 4 * fromIntegral (4 - ws) in (pw `shiftL` sh, pw)
          | otherwise = let sh = 4 * fromIntegral (ws - 4); a = pw `shiftR` sh in (a, a `shiftL` sh)
        wbuffer = testBit (sFlushAttr s) 1
        z0 = rf C.!! (0 :: Index 10)
        zmag = unpack (resize (pack (abs (resize (s32 z0) :: Signed 33)))) :: Unsigned 64
        zfinal = if sZDiv s then resize (pack (finalZOf dq)) else rf C.!! (2 :: Index 10)
        g = polyIndex
        slotW = resize (pack (refOf k)) .|. (resize (rf C.!! (8 :: Index 10)) `shiftL` 16)
                .|. (resize zfinal `shiftL` 32) :: BitVector 64
        isStore = if k < cs then sCopy s else True
        si = storeIdx k
        fxy = rf C.!! (3 :: Index 10)
        v0 = (resize fxy .&. 0x1FF) .|. (resize (fxy `shiftR` 16 .&. 0xFF) `shiftL` 16)
             .|. (resize (rf C.!! (7 :: Index 10)) `shiftL` 32) :: BitVector 64
        v1 = resize (colourCode (rf C.!! (4 :: Index 10)))
             .|. (resize (colourCode (rf C.!! (5 :: Index 10))) `shiftL` 20)
             .|. (resize (colourCode (rf C.!! (6 :: Index 10))) `shiftL` 40) :: BitVector 64
        nextK st = st { sK = k + 1, sJ = 0 }
    in if k >= sN s then go s0 { sJ = 0 } PHeader
       else case j of
         0 -> (s0 { sJ = 1 }, rd p 2)
         1 -> (s0 { sJ = 2, sR = C.replace (0 :: Index 10) q rf }, rd p 8)
         2 -> let rf1 = C.replace (8 :: Index 10) fw rf
                  s1 | wbuffer = s0 { sR = C.replace (2 :: Index 10) wsh rf1, sZDiv = False }
                     | pw == 0 = s0 { sR = C.replace (2 :: Index 10) 0x7FFE00 rf1, sZDiv = False }
                     | otherwise = s0 { sR = rf1, sZDiv = True
                                      , sDiv = divStart (zmag `shiftL` 14) (unpack (resize pw)) (s32 z0 < 0) (sDiv s) }
              in (s1 { sJ = 3 }, rd p 9)
         3 -> (s0 { sJ = 4, sR = C.replace (3 :: Index 10) q rf }, rd p 4)
         4 -> (s0 { sJ = 5, sR = C.replace (4 :: Index 10) q rf }, rd p 5)
         5 -> (s0 { sJ = 6, sR = C.replace (5 :: Index 10) q rf }, rd p 6)
         6 -> (s0 { sJ = 7, sR = C.replace (6 :: Index 10) q rf }, rd p 7)
         7 -> (s0 { sJ = 8, sR = C.replace (7 :: Index 10) q rf }, noPorts)
         8 | sZDiv s && not (divIdle (sDiv s)) -> (s0, noPorts)
           | otherwise -> issue (MemWrite (polySlotAddr base g k) 0xFF slotW)
                            s0 { sJ = if isStore then 9 else 11 }
         9 -> issue (MemWrite (vertexAddr base si 0) 0xFF v0) s0 { sJ = 10 }
         10 -> issue (MemWrite (vertexAddr base si 1) 0xFF v1) (nextK s0)
         _ -> (nextK s0, noPorts)

  PHeader ->
    let ps = sPs s
        attr = hpAttr ps
        t = translucent
        smask = attr .&. 0x3F000030 == 0x30
        degen = sZeroW s || sYBot s > 192
        key = (if t then 0x10000 else 0) .|. (resize (pack (sYBot s)) `shiftL` 8) .|. resize (pack (sYTop s))
        hdr = encodeHeader PolyHeader
          { phAttr = attr, phTexParam = hpTexParam ps, phTexPalette = resize (hpTexPalette ps)
          , phNumVerts = sN s, phWBuffer = testBit (sFlushAttr s) 1
          , phFacingView = sDot s <= 0, phShadowMask = smask
          , phShadow = attr .&. 0x30 == 0x30 && not smask, phDegenerate = degen
          , phTranslucent = t, phType = if sType s then 1 else 0
          , phVTop = sVTop s, phVBottom = sVBot s, phYTop = sYTop s, phYBottom = sYBot s
          , phXTop = sXTop s, phXBottom = sXBot s, phSortKey = key }
        entry = encodeRenderEntry (RenderEntry polyIndex (sYTop s) (sYBot s) t degen)
        g = polyIndex
    in case j of
         0 -> issue (MemWrite (polyHeaderAddr base g 0) 0xFF (hdr C.!! (0 :: Index 3))) s0 { sJ = 1 }
         1 -> issue (MemWrite (polyHeaderAddr base g 1) 0xFF (hdr C.!! (1 :: Index 3))) s0 { sJ = 2 }
         2 -> issue (MemWrite (polyHeaderAddr base g 2) 0xFF (hdr C.!! (2 :: Index 3))) s0 { sJ = 3 }
         _ -> issue (MemWrite (renderListAddr base (sBank s) (resize (sNumP s))) 0xFF entry)
                s0 { sJ = 0, sPhase = PHist }

  PHist ->
    let ba = bucket translucent (sYTop s)
        bb = bucket translucent (sYBot s)
    in case j of
         0 -> (s0 { sJ = 1 }, noPorts { oHaRd = ba, oHbRd = bb })
         _ -> ( s0 { sJ = 0, sK = 0, sPhase = PCopy }
              , noPorts { oHaWr = Just (ba, piHaQ inp + 1), oHbWr = Just (bb, piHbQ inp + 1) } )

  PCopy ->
    let m = sMode s
        n = sN s
        (id0, id1) | m == 3 = (3, 2)
                   | sOdd s = (0, 2)
                   | otherwise = (2, 1) :: (Unsigned 4, Unsigned 4)
        lpv = if m == 2 then 3 else 4
        res = sRes s
        src = res C.!! (if sK s == 0 then id0 else id1)
        dst = if sK s == 0 then slotR0 else slotR1
        ok = m >= 2 && n == lpv && res C.!! id0 < 6 && res C.!! id1 < 6
        rf = sR s
        srcF f = if f == 3 then 8 else f :: Field
        f = resize j - 1 :: Field          -- field read at step j (j = 1..10)
        fw = resize j - 2 :: Field         -- field written at step j (j = 2..11)
        rf1 = if fw < 4 then C.replace fw q rf else rf
        nextCopy st = if sK s == 0 then st { sK = 1, sJ = 1 } else st { sPhase = PFinish, sJ = 0 }
    in if j == 0
         then if ok
                then (s0 { sReuse = True, sReuseRef = refOf id0 :> refOf id1 :> Nil, sJ = 1 }, noPorts)
                else go s0 { sReuse = False } PFinish
         else if src == dst then (nextCopy s0, noPorts)
         else if j == 1 then (s0 { sJ = 2 }, rd src (srcF f))
         else if j < 11 then (s0 { sJ = j + 1, sR = rf1 }, (rd src (srcF f)) `withWr` wrP dst fw q)
         else ( nextCopy s0 { sFlags = C.replace dst sharedFlags (sFlags s) }
              , wr dst fw q )

  PFinish ->
    -- sReuse already describes the next polygon here; this one's reuse is
    -- sByIdx / sCopy.
    go s0 { sNumV = sNv1 s + resize (sN s - (if sByIdx s || sCopy s then 2 else 0)), sNumP = sNumP s + 1
          , sNumO = sNumO s + (if translucent then 0 else 1)
          , sClass = if sN s == 4 then SubBuilt4 else SubBuiltOther } PSubmitEnd

  PReject -> go s0 { sReuse = False, sClass = SubRejected } PSubmitEnd

  PSubmitEnd ->
    let perm = sPerm s
        at' :: Index 4 -> Unsigned 2
        at' = (perm C.!!)
        perm' = case sPost s of
          1 -> C.replace (1 :: Index 4) (at' 2) perm
          2 -> C.replace (1 :: Index 4) (at' 2) (C.replace (0 :: Index 4) (at' 1) perm)
          3 -> C.replace (1 :: Index 4) (at' 2) (C.replace (0 :: Index 4) (at' 3) perm)
          _ -> perm
    in go s0 { sPerm = perm', sOdd = not (sOdd s), sDone = True
             , sTiming = Just (submitTimingHw (sMode s) (sClass s)) } PIdle

  ------------------------------------------------------------------ VBlank sort
  PVblPre ->
    let manual = testBit (sFlushAttr s) 0
        e = j - 1
        frozen = manual && e >= 256
        sums = sSum s
        sa = sums C.!! (0 :: Index 2)
        sb = sums C.!! (1 :: Index 2)
        rdP = noPorts { oHaRd = resize j, oHbRd = resize j }
        wrP' = rdP { oHaWr = Just (resize e, sa), oHbWr = Just (resize e, sb) }
        sums' = (if frozen then sa else sa + piHaQ inp) :> (if frozen then sb else sb + piHbQ inp) :> Nil
    in if j == 0 then (s0 { sJ = 1 }, rdP)
       else if j == 512 then (s0 { sJ = 0, sI = 0, sPhase = PVblA }, wrP' { oHaRd = 0, oHbRd = 0 })
       else (s0 { sJ = j + 1, sSum = sums' }, wrP')

  PVblA ->
    let i = sI s
        bA w = let e = decodeRenderEntry w in sortBucket (reTranslucent e) (reYTop e)
    in if i >= sNumP s then go s0 { sI = 0, sJ = 0 } PVblB
       else case j of
         0 -> issue (MemRead (renderListAddr base (sBank s) (resize i))) s0 { sJ = 1 }
         1 -> case piMemResp inp of
                Just w -> (s0 { sJ = 2, sW = w }, noPorts { oHaRd = bA w })
                Nothing -> (s0, noPorts)
         2 -> (s0 { sJ = 3, sI = i, sR = C.replace (0 :: Index 10) (resize (pack (piHaQ inp))) (sR s) }
              , noPorts { oHaWr = Just (bA (sW s), piHaQ inp + 1) })
         _ -> issue (MemWrite (scratchAddr base (unpack (resize (sR s C.!! (0 :: Index 10))))) 0xFF (sW s))
                s0 { sJ = 0, sI = i + 1 }

  PVblB ->
    let i = sI s
        bB w = let e = decodeRenderEntry w in sortBucket (reTranslucent e) (reYBottom e)
        pos = unpack (resize (sR s C.!! (0 :: Index 10))) :: Unsigned 11
        e0 = decodeRenderEntry (sW s)
        (yd, ybe) = yRangeWrite (yRangeLane pos) (yRangeOf (reDegenerate e0) (reYTop e0) (reYBottom e0))
    in if i >= sNumP s then go s0 { sJ = 0 } PVblClr
       else case j of
         0 -> issue (MemRead (scratchAddr base (resize i))) s0 { sJ = 1 }
         1 -> case piMemResp inp of
                Just w -> (s0 { sJ = 2, sW = w }, noPorts { oHbRd = bB w })
                Nothing -> (s0, noPorts)
         2 -> (s0 { sJ = 3, sR = C.replace (0 :: Index 10) (resize (pack (piHbQ inp))) (sR s) }
              , noPorts { oHbWr = Just (bB (sW s), piHbQ inp + 1) })
         3 -> issue (MemWrite (renderListAddr base (sBank s) pos) 0xFF (sW s)) s0 { sJ = 4 }
         _ -> issue (MemWrite (yRangeAddr base (sBank s) pos) ybe yd) s0 { sJ = 0, sI = i + 1 }

  PVblClr ->
    ( s0 { sJ = j + 1, sPhase = if j == 511 then PVblDone else PVblClr }
    , noPorts { oHaWr = Just (resize j, 0), oHbWr = Just (resize j, 0) } )

  PVblDone
    | isNothing (sMem s) ->
        go s0 { sSwapped = Just (FrameDesc (sBank s) (sNumP s))
              , sBank = complement (sBank s), sNumV = 0, sNumP = 0, sNumO = 0, sFlush = False } PIdle
    | otherwise -> (s0, noPorts)
  where
    j = sJ s
    q = piPoolQ inp
    cs = if sReuse s then 2 else 0 :: Unsigned 4
    perm0 = sPerm s
    tslot :: Index 4 -> Slot
    tslot l = resize (perm0 C.!! l)
    inB = sBufs s C.!! sCur s
    outB = sBufs s C.!! complement (sCur s)
    curB = inB
    setOut v st = st { sBufs = C.replace (complement (sCur s)) v (sBufs s) }
    outside sl = outVec C.!! sl
    -- Outside bit of every pool slot for the current half-plane.
    outVec = C.map (\fl -> outsideBit fl (sComp s) (sHalf s)) (sFlags s)
    dq = divResult (sDiv s)
    -- The finished intersection: the plane component is +-W'.
    finW = sR s C.!! (5 :: Index 10)
    finCv = if sHalf s == 0 then finW else negate finW
    finO1 = sR s C.!! (6 :: Index 10)
    finO2 = sR s C.!! (7 :: Index 10)
    -- One plane-test unit, shared by the three places that write outside
    -- bits: an accepted vertex, a finished intersection, a reuse copy.
    (flX, flY, flZ, flW) = case sPhase s of
      PIsFin -> case sComp s of
        0 -> (finCv, finO1, finO2, finW)
        1 -> (finO1, finCv, finO2, finW)
        _ -> (finO1, finO2, finCv, finW)
      PCopy -> (sR s C.!! (0 :: Index 10), sR s C.!! (1 :: Index 10), sR s C.!! (2 :: Index 10), sR s C.!! (3 :: Index 10))
      _ -> case piEvent inp of
        Just (HeVertex v _) -> (pack (hvX v), pack (hvY v), pack (hvZ v), pack (hvW v))
        _ -> (0, 0, 0, 0)
    sharedFlags = planeFlags flX flY flZ flW
    go st ph = (st { sPhase = ph }, noPorts)
    rd sl f = noPorts { oPoolRd = poolA sl f }
    wrP sl f v = Just (poolA sl f, v)
    wr sl f v = noPorts { oPoolWr = wrP sl f v }
    withWr pt w = pt { oPoolWr = w }
    issue req st
      | memFree = (st { sMem = Just req }, noPorts)
      | otherwise = (s0, noPorts)
    nextSide st
      | sSide s == 0 = st { sSide = 1, sPhase = PSide }
      | otherwise = st { sPi = sPi s + 1, sPhase = PPassVtx }
    nextPlane st
      | sComp s == 0 = go st { sHalf = 0 } PClipDone
      | otherwise = go st { sComp = sComp s - 1, sHalf = 0 } PPass
    vbase = if sBank s == 1 then 6144 else 0 :: Unsigned 14
    polyIndex = (if sBank s == 1 then 2048 else 0) + sNumP s
    storeIdx k
      | k < cs = vbase + resize (sNumV s) + resize k
      | otherwise = vbase + resize (sNv1 s) + resize (k - cs)
    refOf k
      | k < cs && sByIdx s = sReuseRef s C.!! k
      | otherwise = storeIdx k
    translucent =
      let texfmt = (hpTexParam (sPs s) `shiftR` 26) .&. 7
          alpha = (hpAttr (sPs s) `shiftR` 16) .&. 0x1F
      in texfmt == 1 || texfmt == 6 || (alpha > 0 && alpha < 31)
    bucket t y = (if t then 256 else 0) + resize y :: Unsigned 9
    sortBucket t y
      | t && testBit (sFlushAttr s) 0 = 256
      | otherwise = bucket t y
    accept ev = case ev of
      HeBegin p -> (s0 { sMode = unpack p, sVtxIn = 0, sOdd = False, sReuse = False, sDone = True }, noPorts)
      HeEnd -> (s0 { sDone = True }, noPorts)
      HeSwap p -> (s0 { sFlush = True, sFlushAttr = p, sDone = True }, noPorts)
      HeVertex v ps ->
        let k = sVtxIn s
            used ph = C.or (C.imap (\l pl -> resize (fromIntegral l :: Unsigned 3) < k && pl == ph) perm0)
            phys | not (used 0) = 0
                 | not (used 1) = 1
                 | not (used 2) = 2
                 | otherwise = 3 :: Unsigned 2
        in ( s0 { sVtx = v, sPs = ps, sSlot = resize phys
                , sPerm = C.replace k phys perm0, sVtxIn = k + 1
                , sFlags = C.replace (resize phys :: Slot) sharedFlags (sFlags s)
                , sPhase = PVtx, sJ = 0 }
           , noPorts )

swapP :: Index 4 -> Index 4 -> Vec 4 (Unsigned 2) -> Vec 4 (Unsigned 2)
swapP a b v = C.replace a (v C.!! b) (C.replace b (v C.!! a) v)

-- | The pool field of clip attribute @at@ (0: W, 1-2: the two non-plane
-- position components, 3-5: R G B, 6-7: S T).
attrField :: Unsigned 2 -> Unsigned 3 -> Field
attrField comp at' = case at' of
  0 -> 3
  1 -> if comp == 0 then 1 else 0
  2 -> if comp == 2 then 1 else 2
  3 -> 4
  4 -> 5
  5 -> 6
  _ -> 7

------------------------------------------------------------------------------
-- The block

-- | The polygon pipeline. @base@ is the "Nds.Gpu3D.PolyRam" window.
polygonHw
  :: forall dom. KnownDomain dom
  => MemAddr
  -> Clock dom -> Reset dom -> Enable dom
  -> Signal dom (Maybe HwGeoEvent)       -- ^ events
  -> Signal dom Bool                     -- ^ VBlank pulse
  -> Signal dom Bool                     -- ^ DISP3DCNT bit-13 acknowledge pulse
  -> Signal dom Bool                     -- ^ memory ready
  -> Signal dom (Maybe (BitVector 64))   -- ^ memory read response
  -> Signal dom PolyOut
polygonHw base clk rst en ev vbl ack mrdy mresp = fst <$> outs
  where
    inp = PolyIn <$> ev <*> vbl <*> ack <*> mrdy <*> mresp <*> poolQ <*> haQ <*> hbQ
    (st', outs) = unbundle (step base <$> st <*> inp)
    st = register clk rst en initSt st'
    ports = snd <$> outs
    poolQ = blockRam clk en (C.replicate (SNat :: SNat 512) 0) (oPoolRd <$> ports) (oPoolWr <$> ports)
    haQ = blockRam clk en (C.replicate (SNat :: SNat 512) 0) (oHaRd <$> ports) (oHaWr <$> ports)
    hbQ = blockRam clk en (C.replicate (SNat :: SNat 512) 0) (oHbRd <$> ports) (oHbWr <$> ports)

{-# ANN polygonTopEntity
  (Synthesize
    { t_name = "nds_gpu3d_polygon"
    , t_inputs =
        [ PortName "CLK"
        , PortName "RST"
        , PortName "EN"
        , PortName "EVENT"
        , PortName "VBLANK"
        , PortName "OVERFLOW_ACK"
        , PortName "MEM_READY"
        , PortName "MEM_RESP"
        ]
    , t_output = PortProduct ""
        [ PortName "EV_READY", PortName "MEM", PortName "POLYGONS", PortName "VERTICES"
        , PortName "OVERFLOW", PortName "DONE", PortName "TIMING", PortName "SWAPPED"
        , PortName "BUSY" ]
    }) #-}
polygonTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System (Maybe HwGeoEvent)
  -> Signal System Bool
  -> Signal System Bool
  -> Signal System Bool
  -> Signal System (Maybe (BitVector 64))
  -> Signal System PolyOut
polygonTopEntity = polygonHw 0
{-# NOINLINE polygonTopEntity #-}
