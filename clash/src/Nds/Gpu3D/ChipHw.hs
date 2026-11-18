{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | The whole Nintendo DS 3D chip as one synthesizable entity: the GX front
-- end ("Nds.Gpu3D.GxFrontHw"), the geometry engine
-- ("Nds.Gpu3D.GeometryHw"), the polygon pipeline
-- ("Nds.Gpu3D.PolygonHw") and the scanline rasteriser
-- ("Nds.Gpu3D.RasterHw"), composed the way "Nds.Gpu3D.Chip" composes
-- their models.
--
-- __Ports__ (single clock domain, 100.541946 MHz; the clock crossing is the
-- board wrapper's):
--
-- * the ARM9 I/O port in the shape of the core's @proc_bus_gb_type@; the
--   address decode for @0x04000060-0x04000063@ (DISP3DCNT) and
--   @0x04000320-0x040006A3@ belongs to the wrapper, which presents only
--   those addresses and takes @BUS_READY@ as its wait state;
-- * the display and power events: @VBLANK@ (scanline 192), @RENDER_START@
--   (scanline 215), @FRAME_END@ (@FinishFrame@), @ABORT_FRAME@ (a VCOUNT
--   write that changed the next line counter), @IF_WRITE@ (@CheckFIFOIRQ@
--   after an IF acknowledge), @POWER_WE/GEOM/REND@ (POWCNT1 bits 3/2) and
--   @XPOS_WE/XPOS/XPOS_MASK@ (engine A BG0HOFS);
-- * @IRQ@ (IF bit 21) and @IRQ_CHECK@ (write it when high), @DMA@ (start
--   the GXFIFO DMA channels), @FIFO_LT_HALF@ (the level a channel armed in
--   start mode 7 samples), @STALL@ (the architectural ARM9 stall), @GXSTAT@,
--   @GEOM_BUSY@, @SWAP_PENDING@ (GXSTAT bit 27), @RENDER_BUSY@,
--   @RENDER_DONE@, @RENDER_OVERRUN@, @ABORT@ (the aborted-frame level)
--   and @XPOS@ (the live @RenderXPos@ the wrapper applies to a fetched line);
-- * two "Nds.Gpu3D.Mem" ports (the address map is below).
--
-- __Memory.__ The polygon pipeline's port and the rasteriser's four (polygon,
-- texture, lower layer, output lines) are merged into two:
--
-- > MEM_BASE + 0x000000   polygon/vertex RAM ("Nds.Gpu3D.PolyRam"), 0x0BE000 B
-- > MEM_BASE + 0x100000   lower layer and the frame snapshot, 0x90008 B
-- > MEM_BASE + 0x200000   output lines, 192 x 1024 B
-- > TEX_BASE + 0x000000   texture slots 0-3, 512 KiB
-- > TEX_BASE + 0x080000   texture palette slots 0-7, 128 KiB
--
-- The polygons and vertices are the one window the polygon pipeline
-- (read/write) and the rasteriser (read) both use; the lower layer and the
-- output lines are the rasteriser's alone; the texture port carries only its
-- texture and palette reads. This entity adds the wrapper's bases to every
-- internal offset above.
--
-- __Arbiter.__ On the @MEM@ port four requestors (the polygon pipeline, and
-- the rasteriser's polygon, lower-layer and output ports) share one request
-- stream. Each has a four-entry queue in registers; its @READY@ is the queue
-- not being full, so no block's request feeds back into its own @READY@
-- combinationally (the blocks build their requests from state and use @READY@
-- only to advance). One request is served per cycle by a rotating priority; the
-- served request is held on the port until the memory's @READY@ is high, and
-- the identity of every served read is pushed into a 32-entry tag FIFO and
-- popped by the in-order responses, each routed back to its requestor. At most
-- 16 reads are outstanding, so the FIFO never overflows and no requestor
-- starves. The texture port has one requestor and needs no arbitration.
--
-- __Composition decisions__ (every block's gate stays green; no block changed):
--
-- * __Geometry enable.__ A command entry reaches the geometry engine only while
--   POWCNT1 bit 3 is set (the front end keeps it in its FIFO otherwise),
--   exactly @GPU3D::Run@'s @GeometryEnabled@ test.
-- * __VBlank gating.__ With geometry disabled nothing happens at a VBlank:
--   the pulse does not reach the polygon pipeline, so the swap stays pending
--   (@GPU3D::VBlank@ runs nothing).
-- * __Render list.__ The render list is the polygon block's sorted list of the
--   bank it finished, latched at the VBlank that built it (geometry and
--   rendering enabled and a swap pending). A VBlank that does not build one
--   keeps the previous list, as @RenderPolygonRAM@ does. Rendering disabled
--   empties it (@RenderNumPolygons = 0@). The rasteriser reads the listed
--   polygons and vertices at render start, the model's timing (@strips@).
-- * __GXSTAT bit 27.__ It is the geometry engine's swap wait
--   (@SWAP_BUFFERS@ run, VBlank not yet seen), which the model reports as
--   @FlushRequest@. Mid-command the bit is low, as melonDS holds it only
--   from the swap entry to @FinishWork@.
--   @GEOM_BUSY@ instead reports in-flight geometry/polygon work, excluding
--   the quiescent swap wait; the separate @SWAP_PENDING@ remains asserted.
-- * __@RenderXPos@.__ The rasteriser applies it while it writes a line
--   ("Nds.Gpu3D.RasterHw"'s output stage); the model applies it when the
--   2D engine fetches the line (@GetLine@), which is also when the DS does.
--   The rasteriser is given @XPos = 0@ at render start, so the lines in
--   memory are un-scrolled, and the wrapper applies the live @XPOS@ (an output
--   here) with "Nds.Gpu3D.Render.outputLine" when it fetches one.
-- * __Aborted frames.__ @ABORT@ is the level the display-timing logic sets
--   (@AbortFrame@); the wrapper returns zeros for the 3D layer while it is
--   high, exactly as @GetLine@ does. The rasteriser still finishes its frame.
-- * __Overflow.__ The polygon pipeline's sticky flag sets the front end's
--   DISP3DCNT bit 13 and is acknowledged as soon as it is observed, so the
--   front end's register is the observable state (the model clears the block's
--   flag at once).
-- * __Render start.__ @RENDER_START@ sets a pending bit; the latched tables
--   are gathered into registers (one registered table read port, 74 entries, a
--   read address in a cycle and its data in the next) while the rasteriser is
--   idle, then the rasteriser starts. A render start that arrives while a
--   frame renders waits for it (one already pending absorbs a second one;
--   @RENDER_OVERRUN@ reports a start the rasteriser refused).
module Nds.Gpu3D.ChipHw
  ( OutReq (..)
  , ChipIn (..)
  , ChipOut (..)
  , chipHw
  , chipTopEntity
    -- * Debug
    -- * The address map (internal offsets)
  , offPoly
  , offLower
  , offOut
  , offPal
    -- * The arbiter
  , ArbSt (..)
  , Q (..)
  , arbInit
  , arbStep
  , arbiter
    -- * The render-table sequencer
  , TSt (..)
  , TIn (..)
  , TOut (..)
  , tInit
  , tblStep
  , seqTables
  ) where

import Prelude

import Data.Bits (shiftR, testBit, (.&.), (.|.))
import Data.Maybe (fromMaybe, isJust)
import Data.Word (Word16, Word32, Word8)
import GHC.Generics (Generic)
import GHC.TypeLits (type (<=))

import Clash.Annotations.TopEntity (PortName (..), TopEntity (..))
import Clash.Explicit.Prelude
  ( BitVector, Clock, Enable, Index, KnownDomain, KnownNat, NFDataX, Reset
  , Signal, System, Unsigned, Vec (..), bundle, register, resize, unbundle
  )
import qualified Clash.Explicit.Prelude as C

import Nds.Gpu3D.GeometryHw
import Nds.Gpu3D.GeometryHw.Event (HwGeoEvent)
import Nds.Gpu3D.GxFront (fifoIrqCond)
import Nds.Gpu3D.GxFrontHw
import Nds.Gpu3D.Mem (MemAddr, MemReq (..))
import Nds.Gpu3D.PolyRam (FrameDesc (..))
import Nds.Gpu3D.PolygonHw
import Nds.Gpu3D.RasterHw
import Nds.Gpu3D.RasterHw.Types
import Nds.Gpu3D.Types

------------------------------------------------------------------------------
-- Address map

-- | Polygon and vertex RAM ("Nds.Gpu3D.PolyRam"), in the @MEM@ window.
offPoly :: MemAddr
offPoly = 0x000000

-- | The lower layer and the end-of-frame snapshot, in the @MEM@ window.
offLower :: MemAddr
offLower = 0x100000

-- | The 192 output lines, in the @MEM@ window.
offOut :: MemAddr
offOut = 0x200000

-- | The texture slots, in the @TEX@ window.
offTex :: MemAddr
offTex = 0x000000

-- | The texture palette slots, in the @TEX@ window.
offPal :: MemAddr
offPal = 0x080000

------------------------------------------------------------------------------
-- Ports

-- | One request on an external memory port.
data OutReq = OutReq
  { oqAddr  :: !MemAddr
  , oqWrite :: !Bool
  , oqBena  :: !(BitVector 8)
  , oqData  :: !(BitVector 64)
  } deriving (Eq, Show, Generic, NFDataX)

outReqOf :: MemReq -> OutReq
outReqOf (MemRead a) = OutReq a False 0 0
outReqOf (MemWrite a be d) = OutReq a True be d

outReqSig :: Signal dom (Maybe MemReq) -> Signal dom (Maybe OutReq)
outReqSig = C.fmap (fmap outReqOf)

oqAddrOf :: Maybe OutReq -> MemAddr
oqAddrOf = maybe 0 oqAddr

oqWriteOf :: Maybe OutReq -> Bool
oqWriteOf = maybe False oqWrite

oqBenaOf :: Maybe OutReq -> BitVector 8
oqBenaOf = maybe 0 oqBena

oqDataOf :: Maybe OutReq -> BitVector 64
oqDataOf = maybe 0 oqData

-- | Everything the chip observes.
data ChipIn = ChipIn
  { ciBus         :: !(Maybe BusReq)
  , ciVBlank     :: !Bool
  , ciRenderStart :: !Bool
  , ciFrameEnd    :: !Bool
  , ciAbortFrame  :: !Bool
  , ciIfWrite     :: !Bool
  , ciPower       :: !(Maybe (Bool, Bool))     -- ^ POWCNT1: bit 3 geometry, bit 2 rendering
  , ciXPos        :: !(Maybe (Word16, Word16))  -- ^ engine A BG0HOFS value and lane mask
  , ciMemBase     :: !MemAddr
  , ciTexBase     :: !MemAddr
  , ciMemReady    :: !Bool
  , ciMemResp     :: !(Maybe (BitVector 64))
  , ciTexReady    :: !Bool
  , ciTexResp     :: !(Maybe (BitVector 64))
  } deriving (Eq, Show, Generic, NFDataX)

-- | Everything the chip drives.
data ChipOut = ChipOut
  { coBusReady      :: !Bool
  , coRdata         :: !(Maybe (BitVector 32))
  , coStall         :: !Bool
  , coIrq           :: !Bool
  , coIrqCheck      :: !Bool
  , coDma           :: !Bool
  , coFifoLtHalf    :: !Bool
  , coGxStat        :: !Word32
  , coGeomBusy      :: !Bool
  , coSwapPending   :: !Bool
  , coRenderBusy    :: !Bool
  , coRenderDone    :: !Bool
  , coRenderOverrun :: !Bool
  , coAbort         :: !Bool
  , coXPos          :: !Word16
  , coCmdValid      :: !Bool
  , coCmdAccept     :: !Bool
  , coCmdEntry      :: !(Maybe HwEntry) -- ^ offered command/data, checked on acceptance
  , coGeoOffered    :: !(Maybe HwGeoEvent) -- ^ includes events waiting for polygon ready
  , coGeoTransfer   :: !(Maybe HwGeoEvent) -- ^ event accepted by the polygon pipeline
  , coPolyReady     :: !Bool              -- ^ prior polygon work/VBlank has settled
  , coRenderLaunch  :: !Bool              -- ^ latched render work starts, after table gathering
  , coGeoComplete   :: !Bool              -- ^ no active control, accumulator or held event
  , coGeoCtlIdle    :: !Bool              -- ^ execution control phase has completed
  , coMemReq        :: !(Maybe OutReq)
  , coTexReq        :: !(Maybe OutReq)
  } deriving (Eq, Show, Generic, NFDataX)

------------------------------------------------------------------------------
-- Arbiter
--
-- A per-requestor four-entry queue, a rotating priority, and the served-read
-- tag FIFO that routes the in-order responses back. A requestor's request is
-- held until @READY@; a queue's head is what the port presents, and the port's
-- request is a function of the arbitration state only (it is held until the
-- memory's @READY@), so no requestor's @READY@ is a function of its own
-- request and the blocks' combinational paths stay acyclic.

-- | One requestor's queue.
data Q = Q
  { qMem :: !(Vec 4 (Maybe MemReq))
  , qRp  :: !(Index 4)
  , qCnt :: !(Unsigned 3)
  } deriving (Eq, Show, Generic, NFDataX)

-- | The arbiter state.
data ArbSt n = ArbSt
  { aqQ     :: !(Vec n Q)
  , atTags  :: !(Vec 32 (Maybe (Index n)))  -- ^ the served reads, oldest first
  , atCount :: !(Unsigned 6)
  , atRot   :: !(Index n)
  } deriving (Eq, Show, Generic, NFDataX)

qInit :: Q
qInit = Q (C.repeat Nothing) 0 0

-- | Index addition that wraps modulo @n@ (@Index@'s own @+@ is checked).
addIx :: forall n. KnownNat n => Index n -> Unsigned 3 -> Index n
addIx r c =
  let n = fromIntegral (C.length (C.indicesI :: Vec n (Index n))) :: Unsigned 4
      s = (fromIntegral r + fromIntegral c :: Unsigned 4) `mod` n
  in fromIntegral s :: Index n

arbInit :: forall n. (KnownNat n, 1 <= n) => ArbSt n
arbInit = ArbSt
  { aqQ = C.repeat qInit
  , atTags = C.repeat Nothing
  , atCount = 0
  , atRot = 0
  }

-- | The first requestor in rotation order whose queue is not empty.
pickN :: forall n. (KnownNat n, 1 <= n)
      => Index n -> Vec n Q -> Maybe (Index n)
pickN rot qs =
  case C.findIndex id (C.map (\k -> qCnt (qs C.!! k) > 0) order) of
    Just j -> Just (order C.!! j)
    Nothing -> Nothing
  where
    order = C.map (\k -> addIx k (fromIntegral rot :: Unsigned 3)) (C.indicesI :: Vec n (Index n))

arbStep
  :: forall n. (KnownNat n, 1 <= n)
  => MemAddr
  -> ArbSt n
  -> ( Vec n (Maybe MemReq), Bool, Maybe (BitVector 64) )
  -> ( ArbSt n
     , ( Vec n Bool, Maybe MemReq, Vec n (Maybe (BitVector 64)) ) )
arbStep base s (reqs, memReady, memResp) = (s', (readies, fwd, resps))
  where
    qs = aqQ s
    -- accept into a queue that is not full
    readies = C.map (\q -> qCnt q < 4) qs
    accepted k = case (reqs C.!! k, readies C.!! k) of
      (Just r, True) -> Just r
      _ -> Nothing
    wrOf q = let c = qCnt q :: Unsigned 3
             in addIx (qRp q) (qCnt q)
    qs1 = C.imap (\k q -> case accepted k of
                    Just r -> q { qMem = C.replace (wrOf q) (Just r) (qMem q)
                                , qCnt = qCnt q + 1 }
                    Nothing -> q)
                 qs
    -- serve from the queues as this cycle's accepts found them: a request
    -- accepted now is served next cycle, and a queue whose count was zero
    -- held nothing to serve
    sel = pickN (atRot s) qs
    headOf k = qMem (qs C.!! k) C.!! (qRp (qs C.!! k))
    outReq = case sel of
      Just k -> headOf k
      Nothing -> Nothing
    isRead = maybe False isReadReq outReq
    -- at most 16 reads outstanding, so the tag FIFO never overflows
    room = atCount s < 16
    served = isJust outReq && memReady && (not isRead || room)
    qs2 = case sel of
      Just k | served ->
        let q = qs1 C.!! k
        in C.replace k (q { qRp = addIx (qRp q) 1, qCnt = qCnt q - 1 }) qs1
      _ -> qs1
    pushTag = served && isRead
    popTag = isJust memResp
    tags0 = if popTag then C.tail (atTags s) C.++ (Nothing :> Nil) else atTags s
    tags1 = if pushTag
              then C.replace (pushIdx s) sel tags0
              else tags0
    pushIdx x = let c = (if popTag then atCount x - 1 else atCount x) :: Unsigned 6
               in fromIntegral c :: Index 32
    owner = C.head (atTags s) :: Maybe (Index n)
    resps = C.map (\k -> if owner == Just k then memResp else Nothing)
                   (C.indicesI :: Vec n (Index n))
    s' = ArbSt
      { aqQ = qs2
      , atTags = tags1
      , atCount = resize (atCount s) + (if pushTag then 1 else 0) - (if popTag then 1 else 0)
      , atRot = case sel of
          Just k | served -> addIx k 1
          _ -> atRot s
      }
    fwd = if isRead && not room then Nothing else addBase base <$> outReq

addBase :: MemAddr -> MemReq -> MemReq
addBase b (MemRead a) = MemRead (a + b)
addBase b (MemWrite a be d) = MemWrite (a + b) be d

isReadReq :: MemReq -> Bool
isReadReq (MemRead _) = True
isReadReq _ = False

-- | The arbiter: 'n' request streams in, one request stream out, the
-- in-order responses routed back, and every request addressed with the
-- wrapper's 'base' added.
arbiter
  :: forall dom n. (KnownDomain dom, KnownNat n, 1 <= n)
  => Signal dom MemAddr
  -> Clock dom -> Reset dom -> Enable dom
  -> Signal dom (Vec n (Maybe MemReq))
  -> Signal dom Bool
  -> Signal dom (Maybe (BitVector 64))
  -> ( Signal dom (Vec n Bool)
     , Signal dom (Maybe MemReq)
     , Signal dom (Vec n (Maybe (BitVector 64))) )
arbiter base clk rst en reqs rdy resp = (readies, fwd, resps)
  where
    outs = arbStep <$> base <*> st <*> bundle (reqs, rdy, resp)
    st = register clk rst en (arbInit @n) ((\(o, _) -> o) <$> outs)
    readies = (\(_, (a, _, _)) -> a) <$> outs
    fwd = (\(_, (_, b, _)) -> b) <$> outs
    resps = (\(_, (_, _, c)) -> c) <$> outs

------------------------------------------------------------------------------
-- The render-table sequencer
--
-- The rasteriser takes its latched @Render*@ tables as one register block, so
-- the front end's three registered table read ports are stepped through: 74
-- entries, one read address in a cycle and its data in the next. Entries 0-31
-- are the toon table, 32-39 the edge table and 40-73 the fog table; the fog
-- read of index 33 aliases 31, which the model reads identically (its render
-- table is @[t0, t0..t31, t31]@).

data TPh = TIdle | TRead | TPulse
  deriving (Eq, Show, Generic, NFDataX)

-- | One sequencer step's inputs.
data TIn = TIn
  { tiDesc    :: !(Maybe FrameDesc)
  , tiGo      :: !Bool           -- ^ a render start is pending
  , tiIdle    :: !Bool           -- ^ the rasteriser is idle
  , tiOk      :: !Bool           -- ^ the front end's table copy is done
  , tiScalars :: !RegsHw         -- ^ the latched scalars (its tables are ignored)
  , tiToon    :: !Word16
  , tiEdge    :: !Word16
  , tiFog     :: !Word8
  } deriving (Eq, Show, Generic, NFDataX)

-- | One sequencer step's outputs.
data TOut = TOut
  { toToon  :: !(Unsigned 5)
  , toEdge  :: !(Unsigned 3)
  , toFog   :: !(Unsigned 6)
  , toStart :: !(Maybe (RegsHw, FrameDesc))
  } deriving (Eq, Show, Generic, NFDataX)

data TSt = TSt
  { tsPh   :: !TPh
  , tsJ    :: !(Unsigned 8)
  , tsToon :: !(Vec 32 Word16)
  , tsEdge :: !(Vec 8 Word16)
  , tsFog  :: !(Vec 34 Word8)
  } deriving (Eq, Show, Generic, NFDataX)

tInit :: TSt
tInit = TSt TIdle 0 (C.repeat 0) (C.repeat 0) (C.repeat 0)

-- | The table read addresses for raw step @j@; the entry index is
-- @j div 2@.
tblAddrs :: Unsigned 8 -> (Unsigned 5, Unsigned 3, Unsigned 6)
tblAddrs j =
  let n = resize (j `shiftR` 1) :: Unsigned 8
  in ( if n < 32 then resize n else 0
     , if n >= 32 && n < 40 then resize (n - 32) else 0
     , if n >= 40 then resize (n - 40) else 0 )

tblStep :: TIn -> TSt -> (TSt, TOut)
tblStep i s = (s', o)
  where
    j = tsJ s
    odd = testBit j 0
    n = resize (j `shiftR` 1) :: Unsigned 8
    -- the state with this step's captured entry (the odd steps read data)
    sCap
      | not odd = s
      | n < 32 = s { tsToon = C.replace (fromIntegral n :: Index 32) (tiToon i) (tsToon s) }
      | n < 40 = s { tsEdge = C.replace (fromIntegral (n - 32) :: Index 8) (tiEdge i) (tsEdge s) }
      | otherwise = s { tsFog = C.replace (fromIntegral (n - 40) :: Index 34) (tiFog i) (tsFog s) }
    -- the register block handed to the rasteriser, tables complete
    regs = (tiScalars i) { rhToonTable = tsToon sCap
                         , rhEdgeTable = tsEdge sCap
                         , rhFogTable = tsFog sCap
                         , rhXPos = 0 }
    desc = fromMaybe (FrameDesc 0 0) (tiDesc i)
    done = tsPh s == TRead && odd && j == 147
    s' = case tsPh s of
      TIdle
        | tiGo i && tiIdle i && tiOk i -> s { tsPh = TRead, tsJ = 0 }
        | otherwise -> s
      TRead
        | done -> sCap { tsPh = TPulse }
        | odd -> sCap { tsJ = j + 1 }
        | otherwise -> s { tsJ = j + 1 }
      TPulse -> sCap { tsPh = TIdle }
    -- the read address: an even raw step drives its entry's address, and the
    -- odd step holds it while the data registers
    addrJ = if odd then j - 1 else j
    (aJ, eJ, fJ) = tblAddrs addrJ
    o = TOut aJ eJ fJ (if done then Just (regs, desc) else Nothing)

-- | The table sequencer: a render start pulse in, the table read addresses
-- out, and the render start to the rasteriser once the tables are gathered.
seqTables
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom (Maybe FrameDesc)  -- ^ the render list to hand over
  -> Signal dom Bool             -- ^ @RENDER_START@ is pending
  -> Signal dom Bool             -- ^ the rasteriser is idle
  -> Signal dom Bool             -- ^ the front end's table copy is done
  -> Signal dom RegsHw            -- ^ the latched scalars (tables ignored)
  -> Signal dom Word16           -- ^ the toon entry at the read address
  -> Signal dom Word16           -- ^ the edge entry at the read address
  -> Signal dom Word8            -- ^ the fog entry at the read address
  -> ( Signal dom (Maybe (RegsHw, FrameDesc))
     , Signal dom (Unsigned 5, Unsigned 3, Unsigned 6) )
seqTables clk rst en desc go idle ok regs toonD edgeD fogD = (start, addrs)
  where
    st = register clk rst en tInit st'
    (st', o) = unbundle (tblStep <$> tin <*> st)
    tin = TIn <$> desc <*> go <*> idle <*> ok <*> regs
              <*> toonD <*> edgeD <*> fogD
    start = toStart <$> o
    addrs = (\x -> (toToon x, toEdge x, toFog x)) <$> o

------------------------------------------------------------------------------
-- The chip

-- | The latched @Render*@ register block as the rasteriser takes it, from the
-- front end's latched scalars.
regsOf :: RenderScalars -> RegsHw
regsOf r = RegsHw
  { rhDispCnt = rsDispCnt r
  , rhAlphaRef = rsAlphaRef r
  , rhClear1 = rsClearAttr1 r
  , rhClear2 = rsClearAttr2 r
  , rhFogColor = rsFogColor r
  , rhFogOffset = rsFogOffset r
  , rhFogShift = rsFogShift r
  , rhFogTable = C.repeat 0
  , rhEdgeTable = C.repeat 0
  , rhToonTable = C.repeat 0
  , rhXPos = rsXPos r
  }

-- | One event in, one event out. Every block is the real one; this composes
-- them (see the module comment for the decisions).
chipHw
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom ChipIn -> Signal dom ChipOut
chipHw clk rst en inp = out
  where
    ---------------------------------------------------------------- inputs
    bus       = ciBus         <$> inp
    vbl       = ciVBlank     <$> inp
    rstart    = ciRenderStart <$> inp
    fend      = ciFrameEnd   <$> inp
    abrtIn    = ciAbortFrame <$> inp
    ifw       = ciIfWrite    <$> inp
    pwr       = ciPower      <$> inp
    xposW     = ciXPos       <$> inp
    memRdy    = ciMemReady   <$> inp
    memRsp    = ciMemResp    <$> inp
    texRdy    = ciTexReady   <$> inp
    texRsp    = ciTexResp    <$> inp

    ---------------------------------------------------------------- front end
    fout = gxFrontHw clk rst en bus cmdReady geoStatus pipeStatus geoRes
             vbl xposW pwr flags tblAddrs
    geomEn = foGeomEn <$> fout
    rendEn = foRendEn <$> fout
    cmdReady = (\g r -> g && r) <$> geomEn <*> (goCmdReady <$> geoOut)
    geoStatus = (\g w -> g { gsBusy = w }) <$> (goStatus <$> geoOut) <*> swapPend
    pipeStatus = polyPipeStatus <$> po
    flags = (,) False <$> (poOverflow <$> po)
    tblAddrs = tblAddrSig

    ---------------------------------------------------------------- geometry
    geoIn = GeoHwIn <$> geoCmd <*> poReadySig <*> poBusySig <*> geoVbl
                     <*> (foAck <$> fout) <*> (foZeroDotW <$> fout)
    geoCmd = (\g c -> if g then c else Nothing) <$> geomEn <*> (foCmd <$> fout)
    geoVbl = (\g v -> g && v) <$> geomEn <*> vbl
    resAddr = foResAddr <$> fout
    cmdValidSig = isJust <$> geoCmd
    cmdAcceptSig = (&&) <$> cmdValidSig <*> (goCmdReady <$> geoOut)
    (geoState, geoOut, geoRes) = geometryHwState clk rst en geoIn resAddr

    ---------------------------------------------------------------- polygon pipeline
    po = polygonHw offPoly clk rst en (goEvent <$> geoOut) polyVbl ovfAck
                    polyMemRdy polyMemRsp
    polyVbl = (\g v -> g && v) <$> geomEn <*> vbl
    ovfAck = poOverflow <$> po
    poReadySig = poReady <$> po
    poBusySig = poBusy <$> po
    -- the arbiter's grant to the polygon block is queue 0
    polyMemRdy = at4 (0 :: Index 4) memRdyV
    polyMemRsp = at4 (0 :: Index 4) memRspV
    at4 k v = (C.!! k) <$> v
    at1' k v = (C.!! k) <$> v

    ---------------------------------------------------------------- rasteriser
    rasterIn = RasterIn
      <$> renderStart
      <*> pure (Bases offPoly offTex offPal offLower offOut)
      <*> at4 (1 :: Index 4) memRdyV
      <*> at4 (1 :: Index 4) memRspV
      <*> at1' (0 :: Index 1) texRdyV
      <*> at1' (0 :: Index 1) texRspV
      <*> at4 (2 :: Index 4) memRdyV
      <*> at4 (2 :: Index 4) memRspV
      <*> at4 (3 :: Index 4) memRdyV
    rasterOut = rasterHw clk rst en rasterIn
    (memRdyV, memReq, memRspV) = arbiter (ciMemBase <$> inp) clk rst en memReqs memRdy memRsp
    (texRdyV, texReq, texRspV) = arbiter (ciTexBase <$> inp) clk rst en texReqs texRdy texRsp
    memReqs = (\a b c d -> a :> b :> c :> d :> Nil)
      <$> (poMem <$> po) <*> (roPolyReq <$> rasterOut)
      <*> (roLowReq <$> rasterOut) <*> (roOutReq <$> rasterOut)
    texReqs = (\a -> a :> Nil) <$> (roTexReq <$> rasterOut)

    ---------------------------------------------------------------- render start
    -- the render list: the descending bank the last building VBlank finished
    swapPend = goSwapWait <$> geoOut
    wantList = (\g r s v -> g && r && s && v)
                 <$> geomEn <*> rendEn <*> swapPend <*> vbl
    sw = poSwapped <$> po
    descPend = register clk rst en False
      ((\w d s' -> (d || w) && not (isJust s')) <$> wantList <*> descPend <*> sw)
    powerOff = (\p -> maybe False (not . snd) p) <$> pwr
    listBank = register clk rst en 0
      ((\d s' b -> case s' of
          Just fd | d -> fdBank fd
          _ -> b)
        <$> descPend <*> sw <*> listBank)
    listCount = register clk rst en 0
      ((\d s' off c -> case s' of
          Just fd | d -> fdCount fd
          _ -> if off then 0 else c)
        <$> descPend <*> sw <*> powerOff <*> listCount)
    listDesc = Just <$> (FrameDesc <$> listBank <*> listCount)
    renderIdle = not <$> (roBusy <$> rasterOut)
    tablesOk = not <$> (foRenderBusy <$> fout)
    scalars = regsOf <$> (foRender <$> fout)
    (renderStart0, tblAddrSig) =
      seqTables clk rst en listDesc renderPend renderIdle tablesOk scalars
        (foToon <$> fout) (foEdge <$> fout) (foFog <$> fout)
    renderPend = register clk rst en False
      ((\p s r -> (p || s) && not (isJust r))
        <$> renderPend <*> rstart <*> renderStart0)
    renderStart = renderStart0

    ---------------------------------------------------------------- aborted frame
    abrt = register clk rst en False
      ((\a f p -> (p || a) && not f) <$> abrtIn <*> fend <*> abrt)

    ---------------------------------------------------------------- IF bit 21
    -- CheckFIFOIRQ left IF bit 21 as the front end evaluated it. An IF write
    -- clears the bit and re-runs the check; use the live FIFO level rather
    -- than the previously evaluated condition, so a drained FIFO deasserts.
    gxLive = foGxStat <$> fout
    liveLevel = (\g -> (g `shiftR` 16) .&. 0x1ff) <$> gxLive
    liveMode = (.&. 0xc0000000) <$> gxLive
    liveIrq = fifoIrqCond <$> liveMode <*> liveLevel
    irq = register clk rst en False
      ((\c w li i p -> if w then li else if c then i else p)
        <$> (foIrqCheck <$> fout) <*> ifw <*> liveIrq <*> (foIrq <$> fout) <*> irq)

    ---------------------------------------------------------------- outputs
    out = ChipOut
      <$> (foBusReady <$> fout)
      <*> (foRdata <$> fout)
      <*> (foStall <$> fout)
      <*> irq
      <*> (foIrqCheck <$> fout)
      <*> (foDma <$> fout)
      <*> (foFifoLtHalf <$> fout)
      <*> (foGxStat <$> fout)
      <*> ((\g s e p -> (gsBusy g && not s) || isJust e || p)
             <$> (goStatus <$> geoOut) <*> swapPend <*> (goEvent <$> geoOut) <*> poBusySig)
      <*> swapPend
      <*> (roBusy <$> rasterOut)
      <*> (roDone <$> rasterOut)
      <*> (roOverrun <$> rasterOut)
      <*> abrt
      <*> (rsXPos <$> (foRender <$> fout))
      <*> cmdValidSig
      <*> cmdAcceptSig
      <*> geoCmd
      <*> (goEvent <$> geoOut)
      <*> ((\ready event -> if ready then event else Nothing) <$> poReadySig <*> (goEvent <$> geoOut))
      <*> poReadySig
      <*> (isJust <$> renderStart)
      <*> (geoTransactionIdle <$> geoState)
      <*> (geoControlIdle <$> geoState)
      <*> outReqSig memReq
      <*> outReqSig texReq

------------------------------------------------------------------------------
-- Synthesis top

-- | The chip's flat output-port record.
data TopOutC = TopOutC
  { tBusReady :: !Bool
  , tRdValid   :: !Bool
  , tRdata     :: !(BitVector 32)
  , tStall     :: !Bool
  , tIrq       :: !Bool
  , tIrqCheck :: !Bool
  , tDma       :: !Bool
  , tFifoLtHalf :: !Bool
  , tGxStat    :: !Word32
  , tGeomBusy  :: !Bool
  , tSwapPending :: !Bool
  , tRenderBusy :: !Bool
  , tRenderDone :: !Bool
  , tRenderOverrun :: !Bool
  , tAbort     :: !Bool
  , tXPos      :: !Word16
  , tCmdValid  :: !Bool
  , tCmdAccept :: !Bool
  , tMemAddr   :: !MemAddr
  , tMemWrite  :: !Bool
  , tMemBena   :: !(BitVector 8)
  , tMemData   :: !(BitVector 64)
  , tTexAddr   :: !MemAddr
  , tTexWrite  :: !Bool
  , tTexBena   :: !(BitVector 8)
  , tTexData   :: !(BitVector 64)
  } deriving (Generic, NFDataX)

{-# ANN chipTopEntity
  (Synthesize
    { t_name = "nds_gpu3d"
    , t_inputs =
        [ PortName "CLK", PortName "RST", PortName "EN"
        , PortName "BUS_ENA", PortName "BUS_RNW", PortName "BUS_ADR"
        , PortName "BUS_DIN", PortName "BUS_ACC"
        , PortName "BUS_BENA"
        , PortName "VBLANK", PortName "RENDER_START", PortName "FRAME_END"
        , PortName "ABORT_FRAME", PortName "IF_WRITE"
        , PortName "POWER_WE", PortName "POWER_GEOM", PortName "POWER_REND"
        , PortName "XPOS_WE", PortName "XPOS", PortName "XPOS_MASK"
        , PortName "MEM_BASE", PortName "TEX_BASE"
        , PortName "MEM_READY", PortName "MEM_RESP_VALID", PortName "MEM_RESP"
        , PortName "TEX_READY", PortName "TEX_RESP_VALID", PortName "TEX_RESP"
        ]
    , t_output = PortProduct ""
        [ PortName "BUS_READY", PortName "RD_VALID", PortName "RD_DATA"
        , PortName "STALL", PortName "IRQ", PortName "IRQ_CHECK", PortName "DMA"
        , PortName "FIFO_LT_HALF", PortName "GXSTAT"
        , PortName "GEOM_BUSY", PortName "SWAP_PENDING"
        , PortName "RENDER_BUSY", PortName "RENDER_DONE"
        , PortName "RENDER_OVERRUN", PortName "ABORT", PortName "XPOS_OUT"
        , PortName "CMD_VALID", PortName "CMD_ACCEPT"
        , PortName "MEM_REQ_ADDR", PortName "MEM_REQ_WE"
        , PortName "MEM_REQ_BENA", PortName "MEM_REQ_DATA"
        , PortName "TEX_REQ_ADDR", PortName "TEX_REQ_WE"
        , PortName "TEX_REQ_BENA", PortName "TEX_REQ_DATA"
        ]
    }) #-}
chipTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System Bool -> Signal System Bool
  -> Signal System (BitVector 28) -> Signal System (BitVector 32)
  -> Signal System (BitVector 2) -> Signal System (BitVector 4)
  -> Signal System Bool -> Signal System Bool -> Signal System Bool
  -> Signal System Bool -> Signal System Bool
  -> Signal System Bool -> Signal System Bool -> Signal System Bool
  -> Signal System Bool -> Signal System (BitVector 16) -> Signal System (BitVector 16)
  -> Signal System (BitVector 28) -> Signal System (BitVector 28)
  -> Signal System Bool -> Signal System Bool -> Signal System (BitVector 64)
  -> Signal System Bool -> Signal System Bool -> Signal System (BitVector 64)
  -> Signal System TopOutC
chipTopEntity clk rst en ena rnw adr din accw bena
               vbl rstart fend abrtF ifw pwe pg pr xwe xv xm mb tb
               mrdy mrv mr trdy trv tr = top
  where
    bus = (\e r a d c b -> if e then Just (BusReq a d r c b) else Nothing)
            <$> ena <*> rnw <*> adr <*> din <*> accw <*> bena
    pwr = (\w g r -> if w then Just (g, r) else Nothing)
            <$> pwe <*> pg <*> pr
    xposW = (\w x m -> if w
               then Just (C.bitCoerce x :: Word16, C.bitCoerce m :: Word16)
               else Nothing)
              <$> xwe <*> xv <*> xm
    mresp = (\v d -> if v then Just d else Nothing) <$> mrv <*> mr
    tresp = (\v d -> if v then Just d else Nothing) <$> trv <*> tr
    inp = ChipIn <$> bus <*> vbl <*> rstart <*> fend <*> abrtF <*> ifw
                    <*> pwr <*> xposW <*> (C.bitCoerce <$> mb) <*> (C.bitCoerce <$> tb)
                    <*> mrdy <*> mresp <*> trdy <*> tresp
    o = chipHw clk rst en inp
    top = TopOutC
      <$> (coBusReady <$> o)
      <*> (isJust <$> (coRdata <$> o))
      <*> (fromMaybe 0 <$> (coRdata <$> o))
      <*> (coStall <$> o)
      <*> (coIrq <$> o)
      <*> (coIrqCheck <$> o)
      <*> (coDma <$> o)
      <*> (coFifoLtHalf <$> o)
      <*> (coGxStat <$> o)
      <*> (coGeomBusy <$> o)
      <*> (coSwapPending <$> o)
      <*> (coRenderBusy <$> o)
      <*> (coRenderDone <$> o)
      <*> (coRenderOverrun <$> o)
      <*> (coAbort <$> o)
      <*> (coXPos <$> o)
      <*> (coCmdValid <$> o)
      <*> (coCmdAccept <$> o)
      <*> (oqAddrOf <$> (coMemReq <$> o))
      <*> (oqWriteOf <$> (coMemReq <$> o))
      <*> (oqBenaOf <$> (coMemReq <$> o))
      <*> (oqDataOf <$> (coMemReq <$> o))
      <*> (oqAddrOf <$> (coTexReq <$> o))
      <*> (oqWriteOf <$> (coTexReq <$> o))
      <*> (oqBenaOf <$> (coTexReq <$> o))
      <*> (oqDataOf <$> (coTexReq <$> o))
{-# NOINLINE chipTopEntity #-}
